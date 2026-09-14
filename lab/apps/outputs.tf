output "endpoints" {
  description = "In-cluster addresses. Put these in the agent's environment."
  value = {
    neo4j_bolt = "bolt://neo4j.${var.namespace}.svc.cluster.local:7687"
    neo4j_http = "http://neo4j.${var.namespace}.svc.cluster.local:7474"
    qdrant     = "http://qdrant.${var.namespace}.svc.cluster.local:6333"
    postgres   = "postgres://agent@postgres.${var.namespace}.svc.cluster.local:5432/agent"
    redis      = "redis://redis.${var.namespace}.svc.cluster.local:6379"
  }
}

output "port_forward" {
  description = "Reach them from your laptop. Nothing is exposed outside the cluster."
  value = {
    neo4j_browser = "kubectl -n ${var.namespace} port-forward svc/neo4j 7474:7474 7687:7687"
    qdrant        = "kubectl -n ${var.namespace} port-forward svc/qdrant 6333:6333"
    postgres      = "kubectl -n ${var.namespace} port-forward svc/postgres 5432:5432"
    redis         = "kubectl -n ${var.namespace} port-forward svc/redis 6379:6379"
  }
}

output "get_credentials" {
  description = "The generated passwords. Read from the Secret rather than from Terraform output, so they are not copied into a second place."
  value       = "kubectl -n ${var.namespace} get secret agent-credentials -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{\"\\n\"}}{{end}}'"
}

output "requested_capacity" {
  description = "What this asks for, against roughly 7,840m and ~29GiB across both nodes."
  value = {
    cpu_millicores = sum([for k, v in var.services : tonumber(trimsuffix(v.cpu, "m"))])
    memory_mib = sum([for k, v in var.services :
      endswith(v.memory, "Gi") ? tonumber(trimsuffix(v.memory, "Gi")) * 1024 : tonumber(trimsuffix(v.memory, "Mi"))
    ])
    pods = length(var.services)
  }
}
