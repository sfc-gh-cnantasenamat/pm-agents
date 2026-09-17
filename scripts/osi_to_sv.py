#!/usr/bin/env python3
"""Convert an OSI 0.2.0.dev0 semantic view YAML to the Snowflake native
YAML format and deploy it with SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML.

Parsing is done via the apache-ossie Pydantic models for full spec
compliance. VQRs and metric-dataset assignments are extracted from
SNOWFLAKE vendor custom_extensions and included in the output.

Usage:
  osi_to_sv.py <osi_yaml_path> <sv_fqn> <schema_fqn>
  e.g. osi_to_sv.py cortex_project/FOO.osi.yaml DB.SCH.FOO DB.SCH
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

import yaml

try:
    from ossie import (
        OssieCustomExtension,
        OssieDataType,
        OssieDialect,
        OssieField,
        OssieMetric,
        OssieRelationship,
        OssieSemanticModel,
    )
except ImportError:
    # Auto-install apache-ossie, invalidate finder caches, then retry.
    import importlib
    subprocess.check_call([
        sys.executable, "-m", "pip", "install", "-q",
        "git+https://github.com/apache/ossie.git#subdirectory=python",
    ])
    importlib.invalidate_caches()
    for _k in [k for k in sys.modules if k.startswith("ossie")]:
        del sys.modules[_k]
    from ossie import (  # type: ignore[no-redef]
        OssieCustomExtension,
        OssieDataType,
        OssieDialect,
        OssieField,
        OssieMetric,
        OssieRelationship,
        OssieSemanticModel,
    )


SNOW = os.environ.get("SNOW_CLI", "snow")
WAREHOUSE = os.environ.get("WAREHOUSE", "COMPUTE_WH")

# Map OSI DataType enum values to Snowflake data_type strings.
_DTYPE_MAP: dict[OssieDataType, str] = {
    OssieDataType.STRING: "VARCHAR(16777216)",
    OssieDataType.INTEGER: "NUMBER(38,0)",
    OssieDataType.DECIMAL: "NUMBER(38,6)",
    OssieDataType.FLOAT: "FLOAT",
    OssieDataType.BOOLEAN: "BOOLEAN",
    OssieDataType.DATE: "DATE",
    OssieDataType.DATE_TIME: "TIMESTAMP_NTZ(9)",
    OssieDataType.DATE_TIME_TZ: "TIMESTAMP_LTZ(9)",
}

_NUMERIC_TYPES = {OssieDataType.INTEGER, OssieDataType.DECIMAL, OssieDataType.FLOAT}
_TEMPORAL_TYPES = {OssieDataType.DATE, OssieDataType.TIME, OssieDataType.DATE_TIME, OssieDataType.DATE_TIME_TZ}


def _dtype(osi_type: OssieDataType | None) -> str:
    if osi_type is None:
        return "VARCHAR(16777216)"
    return _DTYPE_MAP.get(osi_type, "VARCHAR(16777216)")


def _sf_expr(item: OssieField | OssieMetric) -> str:
    """Return the SNOWFLAKE-dialect expression, falling back to the item name."""
    for d in (item.expression.dialects or []):
        if d.dialect == OssieDialect.SNOWFLAKE:
            return d.expression
    return item.name


def _sf_ext_data(extensions: list[OssieCustomExtension] | None) -> dict:
    """Return parsed JSON data from the first SNOWFLAKE custom_extension."""
    for ext in extensions or []:
        if ext.vendor_name == "SNOWFLAKE":
            try:
                return json.loads(ext.data)
            except (json.JSONDecodeError, TypeError):
                pass
    return {}


def convert(model: OssieSemanticModel) -> dict:
    sv: dict = {"name": model.name}
    if model.description:
        sv["description"] = model.description

    if model.ai_context and model.ai_context.instructions:
        sv["module_custom_instructions"] = {
            "sql_generation": model.ai_context.instructions
        }

    dataset_names_lower = {ds.name.lower() for ds in model.datasets}

    # ── Build tables ────────────────────────────────────────────────────────
    tables: list[dict] = []
    for ds in model.datasets:
        table: dict = {"name": ds.name}
        if ds.description:
            table["description"] = ds.description

        # source: "DB.SCH.TABLE"
        parts = ds.source.split(".")
        if len(parts) >= 3:
            table["base_table"] = {
                "database": parts[0],
                "schema": parts[1],
                "table": parts[2],
            }

        if ds.primary_key:
            table["primary_key"] = {"columns": list(ds.primary_key)}
        if ds.unique_keys:
            table["unique_keys"] = [{"columns": list(uk)} for uk in ds.unique_keys]

        dims: list[dict] = []
        time_dims: list[dict] = []
        facts_list: list[dict] = []

        for f in ds.fields or []:
            expr = _sf_expr(f)
            sf_ext = _sf_ext_data(f.custom_extensions)
            is_private = sf_ext.get("access_modifier") == "private_access"

            entry: dict = {
                "name": f.name,
                "expr": expr,
                "data_type": _dtype(f.datatype),
            }
            if f.description:
                entry["description"] = f.description
            if f.ai_context and f.ai_context.synonyms:
                entry["synonyms"] = list(f.ai_context.synonyms)
            if f.ai_context and f.ai_context.examples:
                entry["sample_values"] = list(f.ai_context.examples)
            if is_private:
                entry["access_modifier"] = "private_access"

            if f.is_time_dimension():
                time_dims.append(entry)
            elif f.datatype in _NUMERIC_TYPES:
                facts_list.append(entry)
            else:
                dims.append(entry)

        if dims:
            table["dimensions"] = dims
        if time_dims:
            table["time_dimensions"] = time_dims
        if facts_list:
            table["facts"] = facts_list

        # Filters from dataset SNOWFLAKE custom_extensions.
        ds_sf = _sf_ext_data(ds.custom_extensions)
        if ds_sf.get("filters"):
            table["filters"] = ds_sf["filters"]

        tables.append(table)

    sv["tables"] = tables

    # ── Build relationships ──────────────────────────────────────────────────
    rels: list[dict] = []
    for r in model.relationships or []:
        rel: dict = {
            "name": r.name,
            "left_table": r.from_dataset,
            "right_table": r.to,
            "relationship_columns": [
                {"left_column": lc, "right_column": rc}
                for lc, rc in zip(r.from_columns, r.to_columns)
            ],
        }
        r_sf = _sf_ext_data(r.custom_extensions)
        if r_sf.get("join_type"):
            rel["join_type"] = r_sf["join_type"]
        if r_sf.get("relationship_type"):
            rel["relationship_type"] = r_sf["relationship_type"]
        rels.append(rel)
    sv["relationships"] = rels

    # ── Assign metrics to tables or root ─────────────────────────────────────
    # Use metric_datasets hints from root SNOWFLAKE custom_extensions.
    # Metrics not in the hint map whose expressions contain "dataset_name."
    # are treated as cross-table (root/derived); everything else also goes
    # to root as a safe fallback.
    root_sf = _sf_ext_data(model.custom_extensions)
    metric_dataset_hints: dict[str, str] = root_sf.get("metric_datasets", {})

    table_metrics: dict[str, list] = {ds.name: [] for ds in model.datasets}
    root_metrics: list[dict] = []

    for m in model.metrics or []:
        expr = _sf_expr(m)
        expr_lower = expr.lower()
        m_sf = _sf_ext_data(m.custom_extensions)
        is_private = m_sf.get("access_modifier") == "private_access"

        entry: dict = {"name": m.name, "expr": expr}
        if m.description:
            entry["description"] = m.description
        if m.ai_context and m.ai_context.synonyms:
            entry["synonyms"] = list(m.ai_context.synonyms)
        if is_private:
            entry["access_modifier"] = "private_access"

        # 1. Explicit hint from metric_datasets map.
        if m.name in metric_dataset_hints:
            table_metrics[metric_dataset_hints[m.name]].append(entry)
            continue

        # 2. All non-hinted metrics (cross-table or unresolved) go to root.
        root_metrics.append(entry)

    # Attach per-table metrics.
    for table in tables:
        if table_metrics.get(table["name"]):
            table["metrics"] = table_metrics[table["name"]]

    if root_metrics:
        sv["metrics"] = root_metrics

    # ── VQRs from root SNOWFLAKE custom_extensions ───────────────────────────
    if root_sf.get("verified_queries"):
        sv["verified_queries"] = root_sf["verified_queries"]

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

    osi_path, sv_fqn, schema = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(osi_path) as f:
        raw = yaml.safe_load(f)

    # Parse with apache-ossie for spec compliance validation.
    from pydantic import ValidationError
    try:
        model = OssieSemanticModel.model_validate(raw)
    except ValidationError as exc:
        print(f"osi_to_sv ERROR: OSI spec validation failed:\n{exc}", file=sys.stderr)
        return 1

    print(f"osi_to_sv: converting {osi_path} → Snowflake YAML + VQRs")
    sv_yaml = convert(model)

    root_m = len(sv_yaml.get("metrics") or [])
    table_m = sum(len(t.get("metrics") or []) for t in sv_yaml.get("tables") or [])
    vqrs = len(sv_yaml.get("verified_queries") or [])
    print(f"osi_to_sv: {table_m} table metrics, {root_m} derived metrics, {vqrs} VQRs")

    deploy(sv_yaml, schema)
    print(f"osi_to_sv: deployed {sv_fqn} with {table_m + root_m} metrics + {vqrs} VQRs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
