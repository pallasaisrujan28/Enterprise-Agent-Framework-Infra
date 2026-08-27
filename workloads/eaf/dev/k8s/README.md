# EAF-DEV Kubernetes Services

Quick reference for debugging deployed services.
All services run in EKS cluster `eaf-dev` in eu-west-2.

## Namespaces

| Namespace | Services |
|-----------|---------|
| `eaf` | Agent pod |
| `langfuse` | Langfuse web, worker, postgres, redis, clickhouse, seaweedfs |
| `tools` | SearXNG, Crawl4AI, Qdrant |

## Useful commands

```bash
# Connect to the cluster
aws eks update-kubeconfig --name eaf-dev --region eu-west-2

# Check all pods across namespaces
kubectl get pods -A

# Tail agent logs
kubectl logs -f deployment/agent -n eaf

# Tail Langfuse logs
kubectl logs -f deployment/langfuse-web -n langfuse
```
