#!/usr/bin/env bash
#
# Deploy semantic views and add a named Cortex Agent version.
#
# Semantic views: SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML (CREATE OR REPLACE).
# Agents:
#   first run  -> CREATE AGENT ... FROM SPECIFICATION  (VERSION$1 + LIVE)
#   later runs -> update LIVE spec and COMMIT a new named version
#
# This script never points the production alias or DEFAULT_VERSION at the
# new version. scripts/promote.sh does that after evals pass.
#
# Environment:
#   DEPLOY_TARGET   Manifest target (default: default)
#   WAREHOUSE       snow sql warehouse (default: COMPUTE_WH)
#   DRY_RUN         If "true", print SQL only
#   GIT_SHA         Optional comment stamped on COMMIT

set -uo pipefail

MANIFEST="cortex_project/cortex-project.yaml"
PROJECT_DIR="$(dirname "$MANIFEST")"
DEPLOY_TARGET="${DEPLOY_TARGET:-default}"
WAREHOUSE="${WAREHOUSE:-COMPUTE_WH}"
DRY_RUN="${DRY_RUN:-false}"
GIT_SHA="${GIT_SHA:-local}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found at $MANIFEST" >&2
  exit 1
fi

if ! rows="$(python3 - "$MANIFEST" "$DEPLOY_TARGET" <<'PY'
import sys, yaml

manifest_path, preferred = sys.argv[1], sys.argv[2]
with open(manifest_path) as fh:
    manifest = yaml.safe_load(fh) or {}

for art in manifest.get("artifacts", []):
    typ = art.get("type")
    if typ == "cortex_eval":
        continue
    path = art.get("path")
    targets = art.get("targets") or {}
    target = targets.get(preferred) or targets.get("default")
    obj = (target or {}).get("object")
    if not (path and typ and obj):
        sys.stderr.write(f"WARNING: skipping artifact: {art!r}\n")
        continue
    print(f"{path}\t{typ}\t{obj}")
PY
)"; then
  echo "ERROR: failed to parse manifest $MANIFEST" >&2
  exit 1
fi

echo "Deploying artifacts from $MANIFEST (target: $DEPLOY_TARGET)"
[[ "$DRY_RUN" == "true" ]] && echo "(DRY_RUN: printing SQL only)"
echo

run_sql() {
  local sql="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "--- SQL ---"
    echo "$sql"
    echo "-----------"
    return 0
  fi
  snow sql -q "$sql" --warehouse "$WAREHOUSE"
}

agent_exists() {
  local obj="$1"
  local db schema name
  db="${obj%%.*}"
  rest="${obj#*.}"
  schema="${rest%%.*}"
  name="${rest#*.}"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 1
  fi
  python3 - "$db" "$schema" "$name" <<'PY'
import json, subprocess, sys
db, schema, name = sys.argv[1], sys.argv[2], sys.argv[3]
sql = f"SHOW AGENTS LIKE '{name}' IN SCHEMA {db}.{schema};"
proc = subprocess.run(
    ["snow", "sql", "-q", sql, "--warehouse", __import__("os").environ.get("WAREHOUSE", "COMPUTE_WH"), "--format", "json"],
    capture_output=True, text=True,
)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    sys.exit(2)
try:
    data = json.loads(proc.stdout)
except json.JSONDecodeError:
    sys.exit(1)
rows = data if isinstance(data, list) else []
# snow sql --format json can wrap results
if rows and isinstance(rows[0], dict) and "data" in rows[0]:
    rows = rows[0]["data"]
sys.exit(0 if rows else 1)
PY
}

declare -a SUCCEEDED=()
declare -a FAILED=()

while IFS=$'\t' read -r path typ obj; do
  [[ -z "${path:-}" ]] && continue

  file="$PROJECT_DIR/$path"
  echo "==> $path ($typ) -> $obj"

  if [[ ! -f "$file" ]]; then
    echo "    ERROR: file not found: $file"
    FAILED+=("$path (file not found)")
    continue
  fi

  content="$(cat "$file")"
  if [[ "$content" == *'$$'* ]]; then
    echo "    ERROR: $path contains '\$\$', which breaks dollar-quoting"
    FAILED+=("$path (\$\$ in file)")
    continue
  fi

  case "$typ" in
    semantic_view)
      schema="${obj%.*}"
      sql="CALL SYSTEM\$CREATE_SEMANTIC_VIEW_FROM_YAML('${schema}', \$\$${content}\$\$);"
      if run_sql "$sql"; then
        echo "    OK"
        SUCCEEDED+=("$path -> $obj")
      else
        echo "    FAILED"
        FAILED+=("$path -> $obj")
      fi
      ;;
    cortex_agent)
      db_schema="${obj%.*}"
      if agent_exists "$obj"; then
        echo "    Agent exists: updating LIVE spec and committing a named version"
        sql="
USE SCHEMA ${db_schema};
ALTER AGENT ${obj} ADD LIVE VERSION FROM LAST COMMENT = 'ci resume ${GIT_SHA}';
"
        run_sql "$sql" || true
        sql="
USE SCHEMA ${db_schema};
ALTER AGENT ${obj} MODIFY LIVE VERSION SET SPECIFICATION = \$\$${content}\$\$;
"
        if ! run_sql "$sql"; then
          echo "    FAILED to update LIVE spec"
          FAILED+=("$path -> $obj (modify live)")
          continue
        fi
        sql="
USE SCHEMA ${db_schema};
ALTER AGENT ${obj} COMMIT COMMENT = 'ci ${GIT_SHA}';
"
        if run_sql "$sql"; then
          echo "    OK committed new version"
          SUCCEEDED+=("$path -> $obj (new version)")
        else
          echo "    FAILED to commit version"
          FAILED+=("$path -> $obj (commit)")
        fi
      else
        echo "    Agent missing: creating VERSION\$1"
        sql="
USE SCHEMA ${db_schema};
CREATE AGENT ${obj}
  COMMENT = 'ci ${GIT_SHA}'
  FROM SPECIFICATION
  \$\$${content}\$\$;
"
        if run_sql "$sql"; then
          echo "    OK created"
          SUCCEEDED+=("$path -> $obj (created)")
        else
          echo "    FAILED to create"
          FAILED+=("$path -> $obj (create)")
        fi
      fi
      ;;
    *)
      echo "    ERROR: unknown artifact type '$typ'"
      FAILED+=("$path (unknown type: $typ)")
      ;;
  esac
done <<< "$rows"

echo
echo "===== Deploy summary ====="
printf 'SUCCEEDED (%d):\n' "${#SUCCEEDED[@]}"
for item in "${SUCCEEDED[@]:-}"; do
  [[ -n "$item" ]] && echo "  + $item"
done
printf 'FAILED (%d):\n' "${#FAILED[@]}"
for item in "${FAILED[@]:-}"; do
  [[ -n "$item" ]] && echo "  - $item"
done

if [[ "${#SUCCEEDED[@]}" -eq 0 && "${#FAILED[@]}" -eq 0 ]]; then
  echo "ERROR: no artifacts found in $MANIFEST" >&2
  exit 1
fi

if [[ "${#FAILED[@]}" -ne 0 ]]; then
  echo
  echo "One or more artifacts failed to deploy."
  exit 1
fi

echo
echo "Candidate version is ready. Run scripts/eval.sh next."
