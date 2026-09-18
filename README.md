# semantic-view-eval-cicd

Demo repository for the **Build an Eval-Gated CI/CD Pipeline for Snowflake Semantic Views** quickstart.

A five-stage GitHub Actions pipeline that validates, deploys, evaluates, and promotes Snowflake Semantic Views and Cortex Agents using eval-gated versioning with Apache Ossie and Cortex evaluations.

## Get Started

- **Quickstart:** [sfguide-semantic-view-eval-cicd](https://github.com/sfc-gh-cnantasenamat/sfguide-semantic-view-eval-cicd/blob/main/quickstart/semantic-view-eval-cicd/semantic-view-eval-cicd.md)
- **Pre-pipeline notebook:** [01_Explore_and_Deploy.ipynb](https://github.com/sfc-gh-cnantasenamat/sfguide-semantic-view-eval-cicd/blob/main/notebook/Semantic_View_Eval_CICD/01_Explore_and_Deploy.ipynb)
- **Post-pipeline notebook:** [02_Inspect_Pipeline_Results.ipynb](https://github.com/sfc-gh-cnantasenamat/sfguide-semantic-view-eval-cicd/blob/main/notebook/Semantic_View_Eval_CICD/02_Inspect_Pipeline_Results.ipynb)

## Repo Layout

```
.github/workflows/deploy.yml   five-job GitHub Actions workflow
cortex_project/                GROWTH_ANALYTICS.osi.yaml, GROWTH_AGENT.agent.yaml,
                               GROWTH_ANALYTICS_APP.py, eval configs, manifest
evals/thresholds.yaml          promotion floor scores
requirements.txt               Python dependencies
scripts/                       deploy.sh, eval_sv.sh, eval.sh, promote.sh, validate.py, osi_to_sv.py
sql/setup.sql                  demo objects, synthetic data, CI role, eval dataset
```

## Pipeline

```
validate → deploy_candidate → eval_sv → eval → promote
```

| Job | What it does |
|-----|-------------|
| `validate` | Validates the OSI YAML against the Ossie spec |
| `deploy_candidate` | Deploys the semantic view, agent, and Streamlit dashboard |
| `eval_sv` | Runs Cortex Analyst eval — gates on `sql_correctness` |
| `eval` | Runs Cortex Agent eval — gates on correctness, consistency, tool accuracy |
| `promote` | Sets `DEFAULT_VERSION = LAST` when both gates pass |
