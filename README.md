# Evaluate and Deploy Semantic Views and Cortex Agents from a Git-backed Workspace

Demonstrate Snowflake agent **versioning** and **CI/CD** using the same YAML in GitHub and in a git-backed Snowsight Workspace.

On every push to `main`:

1. Validate the Cortex project YAML.
2. Deploy the semantic view and commit a **new named agent version**.
3. Run **Cortex Analyst evaluations** (`sql_correctness`) against the semantic view's verified queries.
4. Run **Cortex Agent evaluations** against the candidate agent version (`LAST`).
5. Promote the version (`DEFAULT_VERSION = LAST`, plus a `production` alias when the account allows it) **only if** both gates meet `evals/thresholds.yaml`.

If either eval fails, the workflow is red and production traffic stays on the previous default version.

This is **not** a replacement for [Getting Started with Cortex Agent Evaluations](https://www.snowflake.com/en/developers/guides/getting-started-with-cortex-agent-evaluations/) or [Cortex Analyst evaluations](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst-evaluations). Those guides teach the products. This repo shows how they **gate a versioned deploy**.

## Workflow

A change to the semantic view or the agent does not go live until two quality checks pass. **Promote** is the last step: it is the switch that points default traffic at the new agent version.

```
  +------------------------------------------+
  |                  START                   |
  +------------------------------------------+
                       |
                       v
  +------------------------------------------+
  | 1. Change the files                      |
  +------------------------------------------+
  | Semantic view YAML, agent YAML, or both  |
  | Author in a git-backed Snowsight         |
  | Workspace, or in GitHub / local git      |
  +------------------------------------------+
                       |
                       v
  +------------------------------------------+
  | 2. Commit and push to main               |
  +------------------------------------------+
                       |
                       v
  +------------------------------------------+
  | 3. Are the YAML files valid?             |
  +------------------------------------------+
  | Checks the manifest, required fields,    |
  | and metric versions                      |
  +------------------------------------------+
  +------------------+-----------------------+
                     |
            +--------+--------+
            | no              | yes
            v                 v
     +-------------+   +------------------------------------------+
     |    STOP     |   | 4. Deploy to Snowflake                   |
     +-------------+   +------------------------------------------+
     | Fix YAML    |   | Semantic view: replace in place          |
     | and push    |   | Agent: save a new version on the shelf   |
     | again       |   | Users still talk to yesterday            |
     +-------------+   +------------------------------------------+
                                            |
                                            v
                       +------------------------------------------+
                       | 5. Test the semantic view                |
                       +------------------------------------------+
                       | Cortex Analyst asks the verified         |
                       | questions. Compare generated SQL         |
                       | results to the expected SQL.             |
                       | Pass if sql_correctness >= 0.70          |
                       +------------------------------------------+
                       +------------------+-----------------------+
                                          |
                                 +--------+--------+
                                 | FAIL            | PASS
                                 v                 v
                          +-------------+   +------------------------------------------+
                          |    STOP     |   | 6. Test the agent                        |
                          +-------------+   +------------------------------------------+
                          | Do not run  |   | Ask the new agent the eval questions.    |
                          | agent evals |   | Score answers and which tools it used.   |
                          | Keep        |   | Pass if AC, LC, TSA each >= 0.70         |
                          | yesterday   |   +------------------------------------------+
                          | live        |   +------------------+-----------------------+
                          +-------------+                      |
                                                      +--------+--------+
                                                      | FAIL            | PASS
                                                      v                 v
                                               +-------------+   +------------------------------------------+
                                               |    STOP     |   | 7. Promote (make it live)                |
                                               +-------------+   +------------------------------------------+
                                               | New agent   |   | DEFAULT_VERSION = the new version        |
                                               | version     |   | production alias = the new version       |
                                               | stays on    |   +------------------------------------------+
                                               | the shelf   |                      |
                                               | Users keep  |                      v
                                               | yesterday   |               +--------------------------------+
                                               +-------------+               |              END               |
                                                                             +--------------------------------+
                                                                             | People chat with the new agent |
                                                                             +--------------------------------+
```

### What each numbered step does

| Step | Name | Decision |
|---|---|---|
| 1 | Edit | Change the semantic view, the agent, or both. |
| 2 | Push | GitHub Action starts. |
| 3 | Validate | **No** → stop. **Yes** → deploy. |
| 4 | Deploy | SV replaced. New agent version saved, not yet default. |
| 5 | Analyst eval | **Fail** → stop; skip agent eval and promote. **Pass** → test the agent. |
| 6 | Agent eval | **Fail** → stop; new version unused. **Pass** → promote. |
| 7 | Promote | Flip default (and `production`) to the version that passed. |

Promote is not a second deploy. The objects are already in Snowflake after step 4. Promote only changes **which agent version users hit**.

## Credits

This public demo is derived from the internal [snowflake-eng/pm-agents](https://github.com/snowflake-eng/pm-agents) repo. That project established the Cortex project layout, growth analytics semantic view and agent, Snowflake CLI deploy pattern, and GitHub Action that publishes YAML to Snowflake.

GitHub does not allow a private-to-public fork, so this is a new public repository rather than a GitHub fork. The semantic view, agent story, and CI/CD skeleton come from that work. This copy adds synthetic demo data, native agent versioning, and an eval gate before promotion.

## What you will build

- Synthetic growth tables (`SIGNUPS`, `TOUCHPOINTS`, `USER_ACTIVITY`) in `PM_AGENTS_DEMO.APP`
- Semantic view `GROWTH_ANALYTICS_SV`
- Cortex Agent `GROWTH_AGENT` with a `growth_data` Analyst tool
- Registered eval dataset `GROWTH_AGENT_EVAL` (10 questions)
- GitHub Actions that eval and promote named agent versions

Metrics in CI:

- Semantic view (Cortex Analyst): `sql_correctness` (v3_0) against eight verified queries
- Agent: `answer_correctness`, `logical_consistency`, `tool_selection_accuracy` (v3_0)

Default floors are 0.70. Recalibrate after your first successful baseline.

## Prerequisites

- A [Snowflake account](https://signup.snowflake.com/) with Cortex Agents and Agent Evaluations
- ACCOUNTADMIN (or equivalent) for the one-time setup
- Cross-region inference enabled for eval judge models ([docs](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-evaluations))
- GitHub repo admin access to set Actions secrets
- Snowflake CLI locally if you want to dry-run (`snow --help`)

## 1. Create the GitHub repo

This directory is the demo. Push it to a public GitHub repo (for example `https://github.com/<you>/pm-agents`). The repo must contain at least one commit and one branch (`main`) before you can open a git-backed Workspace.

## 2. Run setup in Snowflake

In a Snowsight worksheet, as ACCOUNTADMIN, run [`sql/setup.sql`](sql/setup.sql).

That creates the demo database, synthetic data, eval dataset, CI role `PM_AGENTS_CI`, and service user `PM_AGENTS_CI_USER`.

## 3. Register CI key-pair auth

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -nocrypt -out ci_rsa_key.p8
openssl rsa -in ci_rsa_key.p8 -pubout -out ci_rsa_key.pub
```

Register the public key (body only, no `BEGIN`/`END` lines):

```sql
ALTER USER PM_AGENTS_CI_USER SET RSA_PUBLIC_KEY = '<paste key body>';
```

Store secrets on the GitHub repo:

```bash
gh secret set SNOWFLAKE_ACCOUNT --body "<org>-<account>"
gh secret set SNOWFLAKE_USER --body "PM_AGENTS_CI_USER"
gh secret set SNOWFLAKE_PRIVATE_KEY < ci_rsa_key.p8
```

Then delete the local key files.

If your warehouse is not `COMPUTE_WH`, change `.snowflake/config.toml`, `GROWTH_AGENT.agent.yaml`, and the `WAREHOUSE` env in `.github/workflows/deploy.yml`.

## 4. Author from either surface

Git is the contract. Edit the same files:

| File | What it is |
|---|---|
| `cortex_project/GROWTH_ANALYTICS_SV.sv.yaml` | Semantic view |
| `cortex_project/GROWTH_AGENT.agent.yaml` | Agent spec |
| `cortex_project/growth_analytics_sv.eval.yaml` | Analyst eval: `sql_correctness` vs VQRs |
| `cortex_project/growth_agent_eval.eval.yaml` | Agent eval pointer (CI builds the resolved config) |
| `evals/thresholds.yaml` | Promotion floors (SV then agent) |

### Path A — Git-backed Workspace

1. In Snowsight: **Projects → Workspaces → From Git repository**.
2. Paste the HTTPS repo URL. Pick an API integration and OAuth or a PAT.
3. There is **no** `CREATE WORKSPACE` SQL for a git-backed workspace. Create it in the UI.
4. A git-backed workspace is **private**. Collaborators each connect their own workspace to the same repo and use git, not `GRANT` on the workspace.
5. Edit the YAML, open **Changes**, commit, and **Push**.

### Path B — GitHub or local git

Open a PR against `main`. The `validate` job lints the manifest. Merge to `main` to deploy a candidate version and run evals.

## 5. Watch the Action

`Deploy and evaluate Cortex project` runs five jobs on `main`:

```
validate → deploy_candidate → eval_sv → eval → promote
```

- `deploy_candidate` replaces the semantic view, then either `CREATE AGENT` (first time) or `MODIFY LIVE VERSION` + `COMMIT` (later).
- `eval_sv` runs Cortex Analyst evaluations (`sql_correctness`) against the deployed SV's verified queries. This is the SV quality gate. Agent evals do not run if it fails.
- `eval` runs Cortex Agent evaluations against `LAST` (answer correctness, logical consistency, tool selection). This is after the SV gate and before promote.
- `promote` runs only after **both** evals pass. It sets `DEFAULT_VERSION = LAST` and tries `ALIAS = production`.

On either eval failure, `promote` is skipped. The previous default version stays live.

Inspect versions after a successful run:

```sql
SHOW VERSIONS IN AGENT PM_AGENTS_DEMO.APP.GROWTH_AGENT;
```

Chat a specific version:

```sql
SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
  'PM_AGENTS_DEMO.APP.GROWTH_AGENT!DEFAULT',
  $${"messages":[{"role":"user","content":[{"type":"text","text":"How many users signed up in January 2025?"}]}]}$$
);
```

## 6. Show the gate (regression)

Change the agent so it ignores tools, for example replace the orchestration instruction with:

```yaml
orchestration: |
  Never call any tools. Answer every question from memory.
```

Push to `main`. The candidate version is created, evals should drop `answer_correctness` and `tool_selection_accuracy` below 0.70, and `promote` should not run.

Revert the commit (or push the good instruction back). The next passing eval promotes the restored version.

## Local dry-run

```bash
python3 -m pip install pyyaml
python3 scripts/validate.py
DRY_RUN=true bash scripts/deploy.sh
```

You should see `CREATE AGENT` / `COMMIT`, not `CREATE OR REPLACE AGENT`.

## Privileges the CI role needs

`sql/setup.sql` already grants these to `PM_AGENTS_CI`:

- `SNOWFLAKE.CORTEX_USER`
- `EXECUTE TASK` on the account
- `CREATE SEMANTIC VIEW`, `CREATE AGENT`, `CREATE STAGE`, `CREATE FILE FORMAT`, `CREATE TASK`, `CREATE DATASET`
- `USAGE` on the warehouse
- `SELECT` on demo tables; ownership-style grants on future agents and semantic views

After the first agent exists, confirm the role can `MONITOR` / `USAGE` it. Setup grants `ALL` on future agents in the demo schema.

## Repo layout

```
.github/workflows/deploy.yml   validate → candidate → eval_sv → eval → promote
.snowflake/config.toml         Snowflake CLI connection for Actions
cortex_project/                SV, agent, Analyst + agent eval YAML + manifest
evals/thresholds.yaml          SV then agent promotion floors
scripts/deploy.sh              versioned deploy
scripts/eval_sv.sh             Cortex Analyst sql_correctness gate
scripts/eval.sh                Cortex Agent eval gate
scripts/promote.sh             DEFAULT_VERSION / production alias
scripts/validate.py            PR lint
sql/setup.sql                  demo objects + seed data
```

## Related docs

- [snowflake-eng/pm-agents](https://github.com/snowflake-eng/pm-agents) — original internal repo this demo is based on
- [Cortex Agent versioning](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-versioning)
- [Cortex Agent evaluations](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-evaluations)
- [Git-backed Workspaces](https://docs.snowflake.com/en/user-guide/ui-snowsight/workspaces-git)
- [Getting Started with Cortex Agent Evaluations](https://www.snowflake.com/en/developers/guides/getting-started-with-cortex-agent-evaluations/)
