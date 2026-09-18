#!/usr/bin/env bash
#
# Point DEFAULT_VERSION (and the production alias, when possible) at LAST
# after evals have passed. Leaves earlier named versions in place so a failed
# later run can keep serving the previous default.

set -uo pipefail

AGENT_FQN="${AGENT_FQN:-SV_EVAL_CICD.APP.GROWTH_AGENT}"
WAREHOUSE="${WAREHOUSE:-COMPUTE_WH}"
AGENT_DB="${AGENT_FQN%%.*}"
AGENT_REST="${AGENT_FQN#*.}"
AGENT_SCHEMA="${AGENT_REST%%.*}"

echo "Promoting LAST committed version of ${AGENT_FQN} to default/production"

# Pre-flight: verify there is at least one committed version to promote.
version_count="$(snow sql -q "SHOW VERSIONS IN AGENT ${AGENT_FQN};" \
  --warehouse "$WAREHOUSE" --format json 2>/dev/null | python3 -c "
import json, sys
try:
    rows = json.loads(sys.stdin.read())
    # Handle flat list or nested list (multi-statement snow sql output).
    flat = []
    for r in rows:
        if isinstance(r, dict):
            flat.append(r)
        elif isinstance(r, list):
            flat.extend(v for v in r if isinstance(v, dict))
    print(len(flat))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

if [[ "${version_count:-0}" -eq 0 ]]; then
  echo "ERROR: no committed versions found in ${AGENT_FQN}." >&2
  echo "The deploy step must commit a version before promotion can proceed." >&2
  exit 1
fi
echo "Found ${version_count} version(s) — proceeding with promotion."

snow sql -q "
USE SCHEMA ${AGENT_DB}.${AGENT_SCHEMA};
ALTER AGENT ${AGENT_FQN} SET DEFAULT_VERSION = LAST;
SHOW VERSIONS IN AGENT ${AGENT_FQN};
" --warehouse "$WAREHOUSE"

# Alias reassignment is best-effort: some accounts reject moving an in-use alias.
snow sql -q "
USE SCHEMA ${AGENT_DB}.${AGENT_SCHEMA};
ALTER AGENT ${AGENT_FQN} MODIFY VERSION LAST SET ALIAS = production;
" --warehouse "$WAREHOUSE" || echo "WARNING: could not assign production alias; DEFAULT_VERSION=LAST is live."

echo "Promotion complete."
