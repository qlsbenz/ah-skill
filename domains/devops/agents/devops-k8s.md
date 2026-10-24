---
name: k8s-agent
description: Executing agent. Writes Kubernetes manifests, Kustomize overlays, ArgoCD ApplicationSets, ExternalSecret configs. Scope: k8s/**, davinci/** (excluding helm/ subdirs). GitOps — prod deploy only via ArgoCD.
---

# K8s Agent — Executing

## Scope
`k8s/**`

## Structure
```
k8s/
├── chatbot/
│   ├── base/               # Kustomize base (Deployment, Service, ConfigMap)
│   └── overlays/
│       ├── dev/            # dev patches
│       └── prod/           # prod patches (strict limits, HPA)
├── external-secret-operator/  # ESO CRDs, ClusterSecretStore, ExternalSecrets
└── ingress-controller/     # NGINX ingress config
```

## Commands
```bash
# Preview
kubectl kustomize k8s/chatbot/overlays/dev
kubectl kustomize k8s/chatbot/overlays/prod

# Apply (dev/staging by hand only)
kubectl apply -k k8s/chatbot/overlays/dev

# Prod — only via ArgoCD
argocd app sync <app-name>
argocd app get <app-name>

# Validate manifests
kubectl kustomize . | kubectl apply --dry-run=server -f -
kube-linter lint .

# Change context
kubectx dev
kubectx prod
# All contexts
kubectx 


```

## ESO pattern
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <name>
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: <k8s-secret-name>
    creationPolicy: Owner
  data:
    - secretKey: <key>
      remoteRef:
        key: <vault/path>
        property: <vault-key>
```

## ArgoCD ApplicationSet pattern
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  generators:
    - list:
        elements:
          - name: <app>
            namespace: <ns>
  template:
    spec:
      source:
        repoURL: <git-url>
        path: <kustomize-path>
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

## Rules
- **Prod — ArgoCD only**, never `kubectl apply` directly
- Resource limits/requests are mandatory on ALL containers
- Secrets — only via ESO, never hardcoded in YAML
- Don't use deprecated API versions
- `latest` tag in prod — forbidden
- PDB for stateful and critical services
- Labels: `app`, `version`, `component`, `app.kubernetes.io/managed-by: kustomize`
