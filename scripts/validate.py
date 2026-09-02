#!/usr/bin/env python3
"""Validate cortex_project artifacts. Credential-free PR gate."""

from __future__ import annotations

import pathlib
import sys

import yaml

MANIFEST = pathlib.Path("cortex_project/cortex-project.yaml")
VALID_TYPES = {"semantic_view", "cortex_agent", "cortex_eval", "cortex_analyst_eval"}
BUILTIN_METRICS = {
    "answer_correctness",
    "logical_consistency",
    "tool_selection_accuracy",
    "tool_execution_accuracy",
}
ANALYST_METRICS = {"sql_correctness"}


def main() -> int:
    if not MANIFEST.exists():
        print(f"ERROR: manifest not found at {MANIFEST}", file=sys.stderr)
        return 1

    manifest = yaml.safe_load(MANIFEST.read_text()) or {}
    project_dir = MANIFEST.parent
    errors: list[str] = []
    warnings: list[str] = []
    checked = 0

    for art in manifest.get("artifacts", []):
        path = art.get("path")
        typ = art.get("type")
        if not path or not typ:
            errors.append(f"artifact missing path/type: {art!r}")
            continue

        checked += 1
        print(f"Checking {path} ({typ})...")
        target = project_dir / path
        if not target.exists():
            errors.append(f"{path}: file not found")
            continue

        text = target.read_text()
        if "$$" in text:
            errors.append(f"{path}: contains '$$' which breaks dollar-quoting in deploy SQL")

        try:
            spec = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            errors.append(f"{path}: invalid YAML: {exc}")
            continue

        if typ == "semantic_view":
            if not isinstance(spec, dict) or not spec.get("name"):
                errors.append(f"{path}: semantic_view YAML must have a top-level 'name:'")
        elif typ == "cortex_agent":
            if not isinstance(spec, dict) or not spec:
                warnings.append(f"{path}: agent spec is empty")
            elif "tools" not in spec:
                warnings.append(f"{path}: agent spec has no tools")
        elif typ == "cortex_analyst_eval":
            if not isinstance(spec, dict):
                errors.append(f"{path}: eval YAML must be a mapping")
                continue
            evaluation = spec.get("evaluation") or {}
            params = evaluation.get("analyst_params") or {}
            if not params.get("analyst_name"):
                errors.append(f"{path}: evaluation.analyst_params.analyst_name is required")
            if (params.get("analyst_type") or "").upper() not in ("", "SEMANTIC VIEW"):
                errors.append(f"{path}: analyst_type must be 'SEMANTIC VIEW'")
            source = evaluation.get("source_metadata") or {}
            if source.get("type") != "verified_queries":
                errors.append(f"{path}: source_metadata.type must be verified_queries")
            metrics = spec.get("metrics") or []
            if not metrics:
                errors.append(f"{path}: metrics list is empty")
            for metric in metrics:
                if isinstance(metric, str):
                    name = metric
                    version = None
                elif isinstance(metric, dict):
                    name = metric.get("name")
                    version = metric.get("version")
                else:
                    errors.append(f"{path}: metric entries must be strings or objects")
                    continue
                if name not in ANALYST_METRICS:
                    errors.append(f"{path}: Analyst eval metric must be sql_correctness, got '{name}'")
                if isinstance(metric, dict) and name in ANALYST_METRICS and not version:
                    errors.append(f"{path}: sql_correctness must set version (use v3_0)")
        elif typ == "cortex_eval":
            if not isinstance(spec, dict):
                errors.append(f"{path}: eval YAML must be a mapping")
                continue
            evaluation = spec.get("evaluation") or {}
            if not evaluation.get("agent") and not (evaluation.get("agent_params") or {}).get(
                "agent_name"
            ):
                errors.append(f"{path}: evaluation.agent (or agent_params.agent_name) is required")
            if not evaluation.get("dataset_fqn") and not evaluation.get("dataset"):
                errors.append(f"{path}: evaluation.dataset_fqn is required")
            metrics = spec.get("metrics") or []
            if not metrics:
                errors.append(f"{path}: metrics list is empty")
            for metric in metrics:
                if isinstance(metric, str):
                    errors.append(
                        f"{path}: bare metric '{metric}' is invalid; use name + version"
                    )
                    continue
                if not isinstance(metric, dict) or not metric.get("name"):
                    errors.append(f"{path}: metric entries must be objects with name + version")
                    continue
                name = metric["name"]
                if name in BUILTIN_METRICS and not metric.get("version"):
                    errors.append(f"{path}: built-in metric '{name}' must set version")
        else:
            errors.append(f"{path}: unknown type '{typ}' (expected {sorted(VALID_TYPES)})")

    for warning in warnings:
        print(f"WARNING: {warning}")

    if errors:
        print("\nValidation FAILED:")
        for error in errors:
            print(f"  - {error}")
        return 1

    print(f"\nValidated {checked} manifest artifact(s) successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
