# Langfuse — langfuse namespace

Self-hosted LLM observability. Deployed via Helm: workloads/eaf/dev/langfuse.tf
All traces stay inside the cluster — no data leaves eu-west-2.

## Access

```bash
# Port-forward Langfuse UI locally
kubectl port-forward -n langfuse svc/langfuse-web 3000:3000
# Then open: http://localhost:3000

# Check all Langfuse pods
kubectl get pods -n langfuse

# Tail Langfuse worker logs (trace processing)
kubectl logs -f deployment/langfuse-worker -n langfuse

# Check ClickHouse (traces storage)
kubectl get pods -n langfuse -l app=chi-langfuse
```

## Internal URL (for agent pod)
http://langfuse-web.langfuse.svc.cluster.local:3000
