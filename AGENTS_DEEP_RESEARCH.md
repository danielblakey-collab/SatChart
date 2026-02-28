# Agents: Deep Research UI

Primary objective: DeepResearchView.swift chart rendering.

- Keep Chart builders shallow: precompute points and split series outside Chart { }.
- July 17 cutoff rules are non-negotiable (see tmp/CODEX_DASHED_SPEC.md).
- Togiak 2020 requires dashed, linear post-07/17 cumulative harvest approximation.
- No changes to ETL or SQLite schema unless explicitly requested.
