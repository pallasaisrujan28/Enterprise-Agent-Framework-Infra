# Tool Services — tools namespace

Deployed via Terraform: workloads/eaf/dev/search-tools.tf

## Services

| Service | Port | Internal URL |
|---------|------|-------------|
| SearXNG | 8080 | http://searxng.tools.svc.cluster.local:8080/search |
| Firecrawl API | 3002 | http://firecrawl-api.tools.svc.cluster.local:3002 |
| Neo4j (Bolt) | 7687 | bolt://neo4j.tools.svc.cluster.local:7687 |
| Neo4j (HTTP) | 7474 | http://neo4j.tools.svc.cluster.local:7474 |

Neo4j backs **Graphiti** (getzep/graphiti) — a temporal knowledge graph that
builds self-correcting agent memory. Facts age, contradict, and update rather
than accumulating stale vector embeddings.

## Debug commands

```bash
# Check tool pods
kubectl get pods -n tools

# Test SearXNG
kubectl exec -n eaf deploy/agent -- curl -s "http://searxng.tools.svc.cluster.local:8080/search?q=test&format=json" | head -100

# Check Neo4j bolt is up
kubectl exec -n eaf deploy/agent -- curl -s http://neo4j.tools.svc.cluster.local:7474

# Port-forward Neo4j browser locally
kubectl port-forward -n tools svc/neo4j 7474:7474 7687:7687
# Then open: http://localhost:7474
```
