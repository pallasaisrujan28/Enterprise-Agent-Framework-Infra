# Tool Services — tools namespace

Deployed via Terraform: workloads/eaf/dev/search-tools.tf

## Services

| Service | Port | Internal URL |
|---------|------|-------------|
| SearXNG | 8080 | http://searxng.tools.svc.cluster.local:8080/search |
| Crawl4AI | 11235 | http://crawl4ai.tools.svc.cluster.local:11235 |
| Qdrant | 6333 | http://qdrant.tools.svc.cluster.local:6333 |

## Debug commands

```bash
# Check tool pods
kubectl get pods -n tools

# Test SearXNG
kubectl exec -n eaf deploy/agent -- curl -s "http://searxng.tools.svc.cluster.local:8080/search?q=test&format=json" | head -100

# Check Qdrant health
kubectl exec -n eaf deploy/agent -- curl -s http://qdrant.tools.svc.cluster.local:6333/healthz

# Check Crawl4AI health
kubectl exec -n eaf deploy/agent -- curl -s http://crawl4ai.tools.svc.cluster.local:11235/health

# Port-forward Qdrant UI locally
kubectl port-forward -n tools svc/qdrant 6333:6333
# Then open: http://localhost:6333/dashboard
```
