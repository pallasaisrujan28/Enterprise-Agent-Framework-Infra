variable "namespace" {
  description = "Namespace everything goes into. One namespace, no NetworkPolicy — services talk to each other freely, which is the point."
  type        = string
  default     = "agent"
}

variable "services" {
  description = <<-EOT
    The services, as a map. Adding one is an entry here.

    Sized to fit two m6i.xlarge — about 7,840m CPU and ~29 GiB allocatable across both nodes,
    minus roughly 1,200m the kube-system pods already request.

    Image tags verified to resolve before being written in, rather than assumed.
  EOT

  type = map(object({
    image      = string
    ports      = list(number)
    cpu        = string
    memory     = string
    storage    = optional(string)
    mount_path = optional(string)
    env        = optional(map(string), {})
    args       = optional(list(string))

    # A TCP readiness probe port. Without one, Kubernetes reports a pod Ready the moment the
    # container process starts — and Neo4j takes about 45 seconds after that before it accepts
    # a bolt connection. So `1/1 Running` meant "not serving yet", which is exactly the kind of
    # green signal that wastes an afternoon.
    ready_port = optional(number)
  }))

  default = {
    # Graph memory. Bolt on 7687, browser on 7474.
    #
    # Community edition: single database, no clustering, no licence. `server.default_listen_
    # address` is 0.0.0.0 because the default binds localhost only, and a pod that binds
    # localhost is unreachable through a Service — which presents as connection refused from
    # a pod that is plainly Running.
    neo4j = {
      image      = "neo4j:5.26.30-community"
      ports      = [7687, 7474]
      cpu        = "500m"
      memory     = "2Gi"
      storage    = "10Gi"
      mount_path = "/data"
      ready_port = 7687
      env = {
        NEO4J_server_default__listen__address       = "0.0.0.0"
        NEO4J_ACCEPT_LICENSE_AGREEMENT              = "yes"
        NEO4J_server_memory_heap_max__size          = "1G"
        NEO4J_server_memory_pagecache_size          = "512M"
        NEO4J_dbms_security_procedures_unrestricted = "apoc.*"
        NEO4J_PLUGINS                               = "[\"apoc\"]"
      }
    }

    # Vector store, for skills retrieval and semantic recall. 6333 REST, 6334 gRPC.
    qdrant = {
      image      = "qdrant/qdrant:v1.16.1"
      ports      = [6333, 6334]
      cpu        = "250m"
      memory     = "1Gi"
      storage    = "10Gi"
      mount_path = "/qdrant/storage"
      ready_port = 6333
    }

    # Relational state, and MLflow's backend store.
    #
    # PGDATA points at a subdirectory because the volume mounts with a lost+found and Postgres
    # refuses to initialise into a non-empty directory.
    postgres = {
      image      = "postgres:17-alpine"
      ports      = [5432]
      cpu        = "250m"
      memory     = "1Gi"
      storage    = "10Gi"
      mount_path = "/var/lib/postgresql/data"
      ready_port = 5432
      env = {
        PGDATA = "/var/lib/postgresql/data/pgdata"
      }
    }

    # Queues and short-term memory. No persistence — losing it loses in-flight work, which is
    # the correct trade for a scratch queue.
    redis = {
      image      = "redis:8-alpine"
      ports      = [6379]
      cpu        = "100m"
      memory     = "256Mi"
      ready_port = 6379
    }
  }
}
