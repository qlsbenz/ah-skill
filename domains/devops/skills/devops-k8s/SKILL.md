---
name: devops-k8s
description: >
  Executing agent. Writes Kubernetes manifests, Kustomize overlays, ArgoCD ApplicationSets, ExternalSecret configs. Scope: k8s/**, davinci/** (excluding helm/ subdirs). GitOps — prod deploy only via ArgoCD. Invoke as $devops-k8s in Codex.
---

# devops-k8s

Read `.agents/agents/devops-k8s.md` and follow its role, file scope, and output requirements. Use project `AGENTS.md` and relevant repository context. Advisory roles remain read-only. Executing roles make only authorized changes within their scope and run relevant checks. Report actual findings or changes with evidence.
