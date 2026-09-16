#!/usr/bin/env python3
"""Post-OSI deploy: extract VQRs from OSI custom_extensions and merge them
into the live semantic view via SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML.

Usage:
  add_vqrs.py <osi_yaml_path> <sv_fqn> <schema_fqn>
  e.g. add_vqrs.py cortex_project/FOO.osi.yaml DB.SCH.FOO DB.SCH
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

import yaml


SNOW = os.environ.get("SNOW_CLI", "snow")
WAREHOUSE = os.environ.get("WAREHOUSE", "COMPUTE_WH")


def run_snow_sql(sql: str) -> list[dict]:
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
    return json.loads(proc.stdout)


def main() -> int:
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <osi_yaml_path> <sv_fqn> <schema_fqn>", file=sys.stderr)
        return 1

    osi_path, sv_fqn, schema = sys.argv[1], sys.argv[2], sys.argv[3]

    # 1. Extract VQRs from OSI custom_extensions (vendor_name: SNOWFLAKE).
    with open(osi_path) as f:
        osi = yaml.safe_load(f)

    vqrs: list[dict] = []
    for ext in osi.get("custom_extensions", []):
        if ext.get("vendor_name") == "SNOWFLAKE":
            try:
                data = json.loads(ext.get("data", "{}"))
                vqrs = data.get("verified_queries", [])
            except (json.JSONDecodeError, TypeError):
                pass
            break

    if not vqrs:
        print("add_vqrs: no VQRs found in OSI custom_extensions, skipping")
        return 0

    print(f"add_vqrs: found {len(vqrs)} VQR(s) — merging into {sv_fqn}")

    # 2. Read the live SV YAML produced by osi_write_model.
    try:
        result = run_snow_sql(f"SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW('{sv_fqn}');")
    except RuntimeError as exc:
        print(f"add_vqrs ERROR reading SV YAML: {exc}", file=sys.stderr)
        return 1

    sv_yaml_str = list(result[0].values())[0]
    sv_data = yaml.safe_load(sv_yaml_str)

    # 3. Merge VQRs in Snowflake YAML format.
    sv_data["verified_queries"] = vqrs

    # 4. Serialise to YAML; must not contain $$ so dollar-quoting stays safe.
    merged_yaml = yaml.dump(
        sv_data,
        default_flow_style=False,
        allow_unicode=True,
        width=100_000,
        sort_keys=False,
    )
    if "$$" in merged_yaml:
        print("add_vqrs ERROR: merged YAML contains '$$' — cannot use dollar-quoting", file=sys.stderr)
        return 1

    # 5. Redeploy via SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML.
    redeploy_sql = (
        f"CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{schema}', $${merged_yaml}$$);"
    )
    try:
        run_snow_sql(redeploy_sql)
    except RuntimeError as exc:
        print(f"add_vqrs ERROR redeploying with VQRs: {exc}", file=sys.stderr)
        return 1

    print(f"add_vqrs: {len(vqrs)} VQR(s) added to {sv_fqn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
