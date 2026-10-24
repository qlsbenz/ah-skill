---
name: ci-agent
description: Executing agent. Writes GitLab CI/CD pipelines, shared templates, Dockerfile optimizations. Scope: **/.gitlab-ci.yml, ci-templates/**, abp/ci-templates/**. Corporate registry and Nexus only.
---

# CI Agent — Executing

## Scope
`**/.gitlab-ci.yml`, `ci-templates/**`, `abp/ci-templates/**`, `**/Dockerfile`

## Structure
```
ci-templates/         # shared templates (include: in projects)
abp/ci-templates/     # ABP-specific templates
agents/<name>/.gitlab-ci.yml
applications/<name>/.gitlab-ci.yml
```

## Commands
```yaml
# Include shared template
include:
  - project: ''
    ref: main
    file: '/build.yml'
```

## Rules
- PyPI: `--build-arg PIP_INDEX_URL=$NEXUS_PYPI_URL`
- NuGet: `--build-arg NUGET_SOURCE=$NEXUS_NUGET_URL`
- Secrets: GitLab CI Variables (masked+protected) — not in YAML
- `tags: [kubernetes]` — the standard; `tags: [vm]` — only for heavy builds (model downloads)
- Python agents: use the `agents-models/libs/agent-libs` base (avoids OOM)
- `--cache-from` for layer caching where possible

## Stages (standard)
```yaml
stages:
  - build
  - test
  - push
  - deploy
```
