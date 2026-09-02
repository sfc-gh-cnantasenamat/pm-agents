#!/usr/bin/env bash
#
# Cortex Analyst evaluation of the semantic view (sql_correctness vs VQRs).
# Run after deploy.sh and before scripts/eval.sh (agent evals).
#
# Environment:
#   SV_FQN          default PM_AGENTS_DEMO.APP.GROWTH_ANALYTICS_SV
#   EVAL_STAGE      default PM_AGENTS_DEMO.APP.EVAL_CONFIG_STAGE
#   WAREHOUSE       default COMPUTE_WH
#   RUN_NAME        default GROWTH_SV_EVAL_<timestamp>
#   POLL_SECONDS    default 30
#   MAX_POLLS       default 40

set -uo pipefail

SV_FQN="${SV_FQN:-PM_AGENTS_DEMO.APP.GROWTH_ANALYTICS_SV}"
EVAL_STAGE="${EVAL_STAGE:-PM_AGENTS_DEMO.APP.EVAL_CONFIG_STAGE}"
WAREHOUSE="${WAREHOUSE:-COMPUTE_WH}"
RUN_NAME="${RUN_NAME:-GROWTH_SV_EVAL_$(date -u +%Y%m%d_%H%M%S)}"
POLL_SECONDS="${POLL_SECONDS:-30}"
MAX_POLLS="${MAX_POLLS:-40}"
THRESHOLDS_FILE="${THRESHOLDS_FILE:-evals/thresholds.yaml}"
EVAL_DIR="${EVAL_DIR:-/tmp/pm-agents-eval-sv}"
EVAL_YAML="${EVAL_YAML:-cortex_project/growth_analytics_sv.eval.yaml}"

SV_DB="${SV_FQN%%.*}"
SV_REST="${SV_FQN#*.}"
SV_SCHEMA="${SV_REST%%.*}"
SV_NAME="${SV_REST#*.}"

mkdir -p "$EVAL_DIR"
cp "$EVAL_YAML" "$EVAL_DIR/analyst_eval_config.yaml"

echo "Analyst eval config: $EVAL_DIR/analyst_eval_config.yaml"
echo "Run name: $RUN_NAME"
echo "Semantic view: $SV_FQN"

snow sql -q "USE SCHEMA ${SV_DB}.${SV_SCHEMA}; PUT file://${EVAL_DIR}/analyst_eval_config.yaml @${EVAL_STAGE} AUTO_COMPRESS=FALSE OVERWRITE=TRUE;" --warehouse "$WAREHOUSE"

start_sql="
USE SCHEMA ${SV_DB}.${SV_SCHEMA};
CALL EXECUTE_AI_EVALUATION(
  'START',
  OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'),
  '@${EVAL_STAGE}/analyst_eval_config.yaml'
);
"
if ! snow sql -q "$start_sql" --warehouse "$WAREHOUSE"; then
  echo "ERROR: failed to start Cortex Analyst evaluation" >&2
  exit 1
fi

status=""
for i in $(seq 1 "$MAX_POLLS"); do
  echo "Polling Analyst eval status (${i}/${MAX_POLLS})..."
  status_out="$(snow sql -q "
USE SCHEMA ${SV_DB}.${SV_SCHEMA};
CALL EXECUTE_AI_EVALUATION(
  'STATUS',
  OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'),
  '@${EVAL_STAGE}/analyst_eval_config.yaml'
);
" --warehouse "$WAREHOUSE" --format json 2>/dev/null || true)"
  status="$(python3 - "$status_out" <<'PY'
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.loads(raw)
except Exception:
    print("UNKNOWN")
    raise SystemExit
rows = data
if isinstance(data, list) and data and isinstance(data[0], dict) and "data" in data[0]:
    rows = data[0]["data"]
blob = json.dumps(rows).upper()
for token in ("COMPLETED", "FAILED", "INVOCATION_IN_PROGRESS", "COMPUTATION_IN_PROGRESS"):
    if token in blob:
        print(token)
        raise SystemExit
print("UNKNOWN")
PY
)"
  echo "    status: $status"
  if [[ "$status" == "COMPLETED" ]]; then
    break
  fi
  if [[ "$status" == "FAILED" ]]; then
    echo "ERROR: Cortex Analyst evaluation run FAILED" >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

if [[ "$status" != "COMPLETED" ]]; then
  echo "ERROR: Cortex Analyst evaluation did not complete within timeout" >&2
  exit 1
fi

scores_json="$(snow sql -q "
SELECT METRIC_NAME, AVG(EVAL_AGG_SCORE) AS AVG_SCORE
FROM TABLE(SNOWFLAKE.LOCAL.GET_ANALYST_AI_EVALUATION_DATA(
  '${SV_DB}',
  '${SV_SCHEMA}',
  '${SV_NAME}',
  'SEMANTIC VIEW',
  '${RUN_NAME}'
))
GROUP BY 1
ORDER BY 1;
" --warehouse "$WAREHOUSE" --format json)"

echo "$scores_json" > "$EVAL_DIR/scores.json"
echo "Analyst scores:"
echo "$scores_json"

python3 - "$THRESHOLDS_FILE" "$scores_json" "$EVAL_DIR/gate.json" <<'PY'
import json, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyyaml", "-q"])
    import yaml

thresholds_path, scores_raw, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = yaml.safe_load(Path(thresholds_path).read_text()) or {}
if "semantic_view" in cfg:
    thresholds = cfg["semantic_view"] or {}
else:
    thresholds = {"sql_correctness": (cfg.get("metrics") or {}).get("sql_correctness", 0.70)}

data = json.loads(scores_raw)
rows = data
if isinstance(data, list) and data and isinstance(data[0], dict) and "data" in data[0]:
    rows = data[0]["data"]

scores = {}
for row in rows or []:
    if isinstance(row, dict):
        name = row.get("METRIC_NAME") or row.get("metric_name")
        val = row.get("AVG_SCORE") or row.get("avg_score")
        if name is not None and val is not None:
            scores[str(name).lower()] = float(val)

failures = []
for metric, floor in thresholds.items():
    got = scores.get(metric.lower())
    if got is None:
        failures.append(f"{metric}: missing score")
        continue
    if got < float(floor):
        failures.append(f"{metric}: {got:.4f} < {float(floor):.2f}")

result = {"kind": "semantic_view", "scores": scores, "thresholds": thresholds, "failures": failures}
Path(out_path).write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
if failures:
    print("SV GATE FAILED")
    raise SystemExit(1)
print("SV GATE PASSED")
PY

echo "$RUN_NAME" > "$EVAL_DIR/run_name.txt"
