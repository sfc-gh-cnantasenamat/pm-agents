#!/usr/bin/env bash
#
# Point DEFAULT_VERSION (and the production alias, when possible) at LAST
# after evals have passed. Leaves earlier named versions in place so a failed
# later run can keep serving the previous default.

set -uo pipefail

AGENT_FQN="${AGENT_FQN:-PM_AGENTS_DEMO.APP.GROWTH_AGENT}"
WAREHOUSE="${WAREHOUSE:-COMPUTE_WH}"
AGENT_DB="${AGENT_FQN%%.*}"
AGENT_REST="${AGENT_FQN#*.}"
AGENT_SCHEMA="${AGENT_REST%%.*}"

echo "Promoting LAST committed version of ${AGENT_FQN} to default/production"

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
