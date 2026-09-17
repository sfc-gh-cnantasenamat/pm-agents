#!/usr/bin/env python3
"""Convert an OSI 0.2.0.dev0 semantic view YAML to the Snowflake native
YAML format and deploy it with SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML.

VQRs are extracted from custom_extensions vendor_name:SNOWFLAKE and merged
into the output YAML so they survive a full CREATE-OR-REPLACE deploy.

Metric-to-table assignment heuristic:
  - Metrics whose expression names match a field expression in exactly one
    dataset are assigned to that dataset's table.
  - Metrics whose expression references "dataset_name." patterns go to the
    root (derived metrics).
  - Everything else defaults to root (derived).

Usage:
  osi_to_sv.py <osi_yaml_path> <sv_fqn> <schema_fqn>
  e.g. osi_to_sv.py cortex_project/FOO.osi.yaml DB.SCH.FOO DB.SCH
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

import yaml


SNOW = os.environ.get("SNOW_CLI", "snow")
WAREHOUSE = os.environ.get("WAREHOUSE", "COMPUTE_WH")

# Map OSI primitive types to Snowflake data_type strings.
_DTYPE_MAP = {
    "String": "VARCHAR(16777216)",
    "Integer": "NUMBER(38,0)",
    "Decimal": "NUMBER(38,6)",
    "Float": "FLOAT",
    "Boolean": "BOOLEAN",
    "Date": "DATE",
    "DateTime": "TIMESTAMP_NTZ(9)",
    "DateTimeTz": "TIMESTAMP_LTZ(9)",
}

_NUMERIC_TYPES = {"Integer", "Decimal", "Float"}


def _dtype(osi_type: str) -> str:
    return _DTYPE_MAP.get(osi_type, "VARCHAR(16777216)")


def _sf_expr(field_or_metric: dict) -> str:
    dialects = (field_or_metric.get("expression") or {}).get("dialects") or []
    for d in dialects:
        if d.get("dialect", "").upper() == "SNOWFLAKE":
            return d.get("expression", "")
    return field_or_metric.get("name", "")


def _snowflake_ext(item: dict) -> dict:
    for ext in item.get("custom_extensions") or []:
        if ext.get("vendor_name") == "SNOWFLAKE":
            try:
                return json.loads(ext.get("data", "{}"))
            except (json.JSONDecodeError, TypeError):
                pass
    return {}


def convert(osi: dict) -> dict:
    sv: dict = {}
    sv["name"] = osi.get("name", "SEMANTIC_VIEW")
    if osi.get("description"):
        sv["description"] = osi["description"]

    ai_ctx = osi.get("ai_context") or {}
    if ai_ctx.get("instructions"):
        sv["module_custom_instructions"] = {"sql_generation": ai_ctx["instructions"]}

    datasets = osi.get("datasets") or []
    dataset_names_lower = {d["name"].lower() for d in datasets}

    # ── Build tables ────────────────────────────────────────────────────────
    tables: list[dict] = []
    for ds in datasets:
        table: dict = {"name": ds["name"]}
        if ds.get("description"):
            table["description"] = ds["description"]

        # source: "DB.SCH.TABLE"
        parts = (ds.get("source") or "").split(".")
        if len(parts) >= 3:
            table["base_table"] = {
                "database": parts[0],
                "schema": parts[1],
                "table": parts[2],
            }

        pk = ds.get("primary_key") or []
        if pk:
            table["primary_key"] = {"columns": list(pk)}

        uks = ds.get("unique_keys") or []
        if uks:
            table["unique_keys"] = [{"columns": list(uk)} for uk in uks]

        dims: list[dict] = []
        time_dims: list[dict] = []
        facts_list: list[dict] = []

        for f in ds.get("fields") or []:
            expr = _sf_expr(f)
            dtype = f.get("datatype", "String")
            ai_f = f.get("ai_context") or {}
            sf_ext = _snowflake_ext(f)
            is_private = sf_ext.get("access_modifier") == "private_access"
            is_time = (f.get("dimension") or {}).get("is_time", False)
            is_numeric = dtype in _NUMERIC_TYPES

            entry: dict = {
                "name": f["name"],
                "expr": expr,
                "data_type": _dtype(dtype),
            }
            if f.get("description"):
                entry["description"] = f["description"]
            if ai_f.get("synonyms"):
                entry["synonyms"] = list(ai_f["synonyms"])
            if ai_f.get("examples"):
                entry["sample_values"] = list(ai_f["examples"])
            if is_private:
                entry["access_modifier"] = "private_access"

            if is_time:
                time_dims.append(entry)
            elif is_numeric:
                facts_list.append(entry)
            else:
                dims.append(entry)

        if dims:
            table["dimensions"] = dims
        if time_dims:
            table["time_dimensions"] = time_dims
        if facts_list:
            table["facts"] = facts_list

        # Filters from dataset custom_extensions
        ds_sf = _snowflake_ext(ds)
        if ds_sf.get("filters"):
            table["filters"] = ds_sf["filters"]

        tables.append(table)

    sv["tables"] = tables

    # ── Build relationships ──────────────────────────────────────────────────
    rels: list[dict] = []
    for r in osi.get("relationships") or []:
        rel: dict = {
            "name": r["name"],
            "left_table": r["from"],
            "right_table": r["to"],
            "relationship_columns": [
                {"left_column": lc, "right_column": rc}
                for lc, rc in zip(r["from_columns"], r["to_columns"])
            ],
        }
        r_sf = _snowflake_ext(r)
        if r_sf.get("join_type"):
            rel["join_type"] = r_sf["join_type"]
        if r_sf.get("relationship_type"):
            rel["relationship_type"] = r_sf["relationship_type"]
        rels.append(rel)
    sv["relationships"] = rels

    # ── Assign metrics to tables or root ─────────────────────────────────────
    # 1. Load metric_datasets hint from root SNOWFLAKE custom_extensions.
    # 2. Fall back to expression-based heuristic for unmapped metrics.
    metric_dataset_hints: dict[str, str] = {}
    for ext in osi.get("custom_extensions") or []:
        if ext.get("vendor_name") == "SNOWFLAKE":
            try:
                data = json.loads(ext.get("data", "{}"))
            except (json.JSONDecodeError, TypeError):
                data = {}
            metric_dataset_hints = data.get("metric_datasets", {})
            break

    table_metrics: dict[str, list] = {d["name"]: [] for d in datasets}
    root_metrics: list[dict] = []

    for m in osi.get("metrics") or []:
        expr = _sf_expr(m)
        expr_lower = expr.lower()

        m_sf = _snowflake_ext(m)
        is_private = m_sf.get("access_modifier") == "private_access"

        entry: dict = {"name": m["name"], "expr": expr}
        if m.get("description"):
            entry["description"] = m["description"]
        ai_m = m.get("ai_context") or {}
        if ai_m.get("synonyms"):
            entry["synonyms"] = list(ai_m["synonyms"])
        if is_private:
            entry["access_modifier"] = "private_access"

        # 1. Use explicit hint from metric_datasets map.
        if m["name"] in metric_dataset_hints:
            table_metrics[metric_dataset_hints[m["name"]]].append(entry)
            continue

        # 2. Cross-table check: does the expression mention "dataset_name."?
        cross_table = any(
            re.search(r"\b" + re.escape(dname) + r"\.", expr_lower)
            for dname in dataset_names_lower
        )
        if cross_table:
            root_metrics.append(entry)
            continue

        # 3. Fallback: assign to root (derived).
        root_metrics.append(entry)

    # Attach per-table metrics
    for table in tables:
        tname = table["name"]
        if table_metrics.get(tname):
            table["metrics"] = table_metrics[tname]

    if root_metrics:
        sv["metrics"] = root_metrics

    # ── VQRs from root custom_extensions ────────────────────────────────────
    for ext in osi.get("custom_extensions") or []:
        if ext.get("vendor_name") == "SNOWFLAKE":
            try:
                data = json.loads(ext.get("data", "{}"))
            except (json.JSONDecodeError, TypeError):
                data = {}
            if data.get("verified_queries"):
                sv["verified_queries"] = data["verified_queries"]
            break

    return sv


def deploy(sv_yaml: dict, schema: str) -> None:
    merged = yaml.dump(
        sv_yaml,
        default_flow_style=False,
        allow_unicode=True,
        width=100_000,
        sort_keys=False,
    )
    if "$$" in merged:
        raise RuntimeError("Converted YAML contains '$$' — cannot use dollar-quoting")

    sql = f"CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{schema}', $${merged}$$);"
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False) as f:
        f.write(sql)
        sql_file = f.name
    try:
        proc = subprocess.run(
            [SNOW, "sql", "-f", sql_file, "--warehouse", WAREHOUSE, "--format", "json"],
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(sql_file)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())


def main() -> int:
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <osi_yaml_path> <sv_fqn> <schema_fqn>", file=sys.stderr)
        return 1

    osi_path, _sv_fqn, schema = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(osi_path) as f:
        osi = yaml.safe_load(f)

    print(f"osi_to_sv: converting {osi_path} → Snowflake YAML + VQRs")
    sv_yaml = convert(osi)

    # Count metrics for logging
    root_m = len(sv_yaml.get("metrics") or [])
    table_m = sum(len(t.get("metrics") or []) for t in sv_yaml.get("tables") or [])
    vqrs = len(sv_yaml.get("verified_queries") or [])
    print(f"osi_to_sv: {table_m} table metrics, {root_m} derived metrics, {vqrs} VQRs")

    deploy(sv_yaml, schema)
    print(f"osi_to_sv: deployed {_sv_fqn} with {table_m + root_m} metrics + {vqrs} VQRs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
