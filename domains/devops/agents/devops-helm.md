---
name: helm-agent
description: Executing agent. Writes and maintains Helm charts: Chart.yaml, templates/, values.yaml, helpers. Scope: davinci/kubernetes/apps/helm/**, **/Chart.yaml, **/values*.yaml.
---

# Helm Agent — Executing

## Scope
`davinci/kubernetes/apps/helm/**`, `**/Chart.yaml`, `**/values*.yaml`, `**/templates/**`

## Chart structure
```
<chart-name>/
├── Chart.yaml          # apiVersion, name, version, appVersion, dependencies
├── values.yaml         # defaults
├── values-dev.yaml     # dev overrides
├── values-prod.yaml    # prod overrides
├── templates/
│   ├── _helpers.tpl    # named templates
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── externalsecret.yaml
│   ├── hpa.yaml
│   ├── pdb.yaml
│   └── NOTES.txt
└── tests/
    └── test-connection.yaml
```

## Commands
```bash
# Lint
helm lint ./chart-name
helm lint ./chart-name -f values-prod.yaml

# Template preview
helm template <release> ./chart-name -f values-prod.yaml
helm template <release> ./chart-name -f values-prod.yaml --debug

# Dry-run
helm install <release> ./chart-name -f values-prod.yaml --dry-run

# Test
helm test <release> -n <namespace>

# Dependency update
helm dependency update ./chart-name
```

## Authoring rules

### Chart.yaml
```yaml
apiVersion: v2        # always v2
name: <chart-name>
version: 0.1.0        # chart SemVer version
appVersion: "1.0.0"   # application version
```

### values.yaml conventions
```yaml
image:
  repository: 
  tag: ""           # overridden at deploy time
  pullPolicy: IfNotPresent

resources:
  limits:
    cpu: "500m"
    memory: "512Mi"
  requests:
    cpu: "100m"
    memory: "128Mi"

replicaCount: 1

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
```

### Required `_helpers.tpl` templates
```
{{- define "<chart>.labels" }}
{{- define "<chart>.selectorLabels" }}
{{- define "<chart>.fullname" }}
```

### Rules
- `required` for mandatory values with no defaults
- `toYaml | nindent` for blocks
- Secrets — only via the ExternalSecret template, never `kind: Secret`
- `latest` tag in values — forbidden for prod
- NOTES.txt — a short note on how to verify the deploy
