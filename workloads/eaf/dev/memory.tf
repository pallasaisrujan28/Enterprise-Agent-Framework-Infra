# AGENT MEMORY — Neo4j backing Graphiti temporal knowledge graph
#
# Graphiti (https://github.com/getzep/graphiti) builds self-correcting memory:
# facts age, contradict, and update over time instead of accumulating stale
# vector embeddings. The agent calls the graphiti-core Python library directly;
# Neo4j is the persistence layer it talks to.
#
# Requires Neo4j >= 5.x with APOC plugin (for triggers and UUID generation).
#
#   Bolt (agent):   bolt://neo4j.tools.svc.cluster.local:7687
#   HTTP (browser): http://neo4j.tools.svc.cluster.local:7474

resource "helm_release" "neo4j" {
  name             = "neo4j"
  repository       = "https://helm.neo4j.com/neo4j"
  chart            = "neo4j"
  version          = "5.26.0"
  namespace        = kubernetes_namespace.tools.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [<<-EOT
    neo4j:
      name: eaf-memory
      edition: community
      # Auth disabled in dev — the tools namespace is cluster-internal only.
      # Enable and rotate credentials before promoting to prod.
      passwordFromSecret: ""

    volumes:
      data:
        mode: defaultStorageClass
        defaultStorageClass:
          requests:
            storage: 10Gi

    resources:
      cpu: "500m"
      memory: "2Gi"

    config:
      server.default_listen_address: "0.0.0.0"
      server.bolt.enabled: "true"
      server.http.enabled: "true"
      server.https.enabled: "false"
      dbms.security.auth_enabled: "false"

    jvm:
      additionalJvmArguments:
        - "-XX:+ExitOnOutOfMemoryError"

    apoc_config:
      apoc.trigger.enabled: "true"
      apoc.uuid.enabled: "true"

    services:
      neo4j:
        spec:
          type: ClusterIP
  EOT
  ]

  depends_on = [kubernetes_namespace.tools]
}
