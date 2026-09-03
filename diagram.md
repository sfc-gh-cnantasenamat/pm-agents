# Workflow

A change to the semantic view or the agent does not go live until two quality checks pass. **Promote** is the last step: it is the switch that points default traffic at the new agent version.

```
  +------------------------------------------+
  | START                                    |
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
  +------------------+-----------------------+
                     |
            +--------+--------+
            | no              | yes
            v                 v
     +-------------+   +------------------------------------------+
     | STOP        |   | 4. Deploy to Snowflake                   |
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
                       +------------------+-----------------------+
                                          |
                                 +--------+--------+
                                 | fail            | pass
                                 v                 v
                          +-------------+   +------------------------------------------+
                          | STOP        |   | 6. Test the agent                        |
                          +-------------+   +------------------------------------------+
                          | Do not run  |   | Ask the new agent the eval questions.    |
                          | agent evals |   | Score answers and which tools it used.   |
                          | Keep        |   | Pass if AC, LC, TSA each >= 0.70         |
                          | yesterday   |   +------------------+-----------------------+
                          | live        |                      |
                          +-------------+             +--------+--------+
                                                      | fail            | pass
                                                      v                 v
                                               +-------------+   +------------------------------------------+
                                               | STOP        |   | 7. Promote (make it live)                |
                                               +-------------+   +------------------------------------------+
                                               | New agent   |   | DEFAULT_VERSION = the new version        |
                                               | version     |   | production alias = the new version       |
                                               | stays on    |   +------------------------------------------+
                                               | the shelf   |                      |
                                               | Users keep  |                      v
                                               | yesterday   |               +--------------------------------+
                                               +-------------+               | END                            |
                                                                             +--------------------------------+
                                                                             | People chat with the new agent |
                                                                             +--------------------------------+
```

## What each numbered step does

| Step | Name | Decision |
|---|---|---|
| 1 | Edit | Change the semantic view, the agent, or both. |
| 2 | Push | GitHub Action starts. |
| 3 | Validate | **No** → stop. **Yes** → deploy. |
| 4 | Deploy | SV replaced. New agent version saved, not yet default. |
| 5 | Analyst eval | **Fail** → stop; skip agent eval and promote. **Pass** → test the agent. |
| 6 | Agent eval | **Fail** → stop; new version unused. **Pass** → promote. |
| 7 | Promote | Flip default (and `production`) to the version that passed. |

## What “promote” is not

It is not a second deploy. The objects are already in Snowflake after step 4. Promote only changes **which agent version users hit**.
