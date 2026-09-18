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

    # Set this to the name of a ServiceAccount that has a Pod Identity association, and the
    # pod gets AWS credentials. Only the services that call AWS want it — the datastores do
    # not, and giving them the association would hand Bedrock to Postgres for no reason.
    service_account = optional(string)

    # A single config file, rendered into a ConfigMap and mounted. LiteLLM needs one; nothing
    # else does yet. Kept generic rather than special-cased so the next service that wants a
    # config file is a map entry too.
    config = optional(object({
      mount_path = string
      filename   = string
      content    = string
    }))

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

    # ── Bedrock, wearing an OpenAI face ────────────────────────────────────────
    #
    # Graphiti has no Bedrock provider — its options are OpenAI, Azure OpenAI, Gemini,
    # Anthropic (the direct API, not Bedrock), Groq and Ollama. So Bedrock is reached through
    # an OpenAI-compatible proxy rather than natively, and this is that proxy.
    #
    # NOVA, NOT CLAUDE, AND NOT BY PREFERENCE. Every id below was checked by invoking it in
    # eu-west-2. Three separate ceilings rule out everything else:
    #
    #   amazon.nova-pro-v1:0                     works
    #   amazon.nova-lite-v1:0                    works
    #   amazon.nova-micro-v1:0                   works
    #   amazon.titan-embed-text-v2:0             works, 1024 dimensions
    #
    #   anthropic.claude-3-7-sonnet              AccessDenied: requires aws-marketplace:
    #   anthropic.claude-3-sonnet                Subscribe/ViewSubscriptions, and
    #                                            INVALID_PAYMENT_INSTRUMENT — "a valid payment
    #                                            instrument must be provided"
    #
    #   claude-sonnet-4-5, opus-4-5, haiku-4-5,  on-demand not supported at all; reachable only
    #   amazon.nova-2-lite                       through an inference profile
    #
    #   eu.* / global.* inference profiles       AccessDenied, explicit deny in service control
    #                                            policy p-j1oakqhe
    #
    # 1. ANTHROPIC MODELS ON BEDROCK ARE AWS MARKETPLACE PRODUCTS. They need a Marketplace
    #    subscription, and a subscription needs a payment instrument. Credits are not one. No
    #    IAM change fixes this — the SSO administrator hits the same wall, so granting the pod
    #    aws-marketplace:Subscribe would only move the failure, not remove it.
    #
    #    AND A SUCCESSFUL CALL WAS NOT PROOF OF ACCESS. The first two calls to Claude 3.7
    #    Sonnet returned real completions, and the same call minutes later returned
    #    AccessDenied — the subscription was pending, then failed. An earlier version of this
    #    comment recorded Claude as verified working on the strength of those calls. It was
    #    wrong.
    #
    # 2. Newer models are on-demand-ineligible, so they need an inference profile.
    # 3. Inference profiles are denied by the organisation's SCP, which lives in the management
    #    account (193027353132) and is out of reach from here.
    #
    # The intersection of "no Marketplace subscription needed", "on-demand eligible" and "not a
    # profile" is Amazon's own first-party models. Nova Pro is the most capable of them.
    #
    # The OpenAI names are aliases. Graphiti picks its own defaults (gpt-4.1-mini for the main
    # model, a smaller one for cheap calls) unless told otherwise, so the aliases are named to
    # match those defaults and mapped to Nova by capability: Pro where quality matters, Lite
    # where Graphiti is doing bulk work.
    litellm = {
      image           = "ghcr.io/berriai/litellm:v1.101.0"
      ports           = [4000]
      cpu             = "250m"
      memory          = "512Mi"
      ready_port      = 4000
      service_account = "agent-bedrock"
      args            = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

      config = {
        mount_path = "/etc/litellm"
        filename   = "config.yaml"
        content    = <<-EOT
          model_list:
            - model_name: gpt-4.1-mini
              litellm_params:
                model: bedrock/amazon.nova-pro-v1:0
                aws_region_name: eu-west-2
            - model_name: gpt-4.1-nano
              litellm_params:
                model: bedrock/amazon.nova-lite-v1:0
                aws_region_name: eu-west-2
            - model_name: gpt-4o-mini
              litellm_params:
                model: bedrock/amazon.nova-lite-v1:0
                aws_region_name: eu-west-2
            - model_name: nova-pro
              litellm_params:
                model: bedrock/amazon.nova-pro-v1:0
                aws_region_name: eu-west-2
            - model_name: nova-lite
              litellm_params:
                model: bedrock/amazon.nova-lite-v1:0
                aws_region_name: eu-west-2
            # Titan returns 1024 dimensions, not the 1536 an OpenAI client assumes from the
            # name. Graphiti has to be told embedding_dim=1024 or it builds an index of the
            # wrong width and similarity search silently misbehaves.
            - model_name: text-embedding-3-small
              litellm_params:
                model: bedrock/amazon.titan-embed-text-v2:0
                aws_region_name: eu-west-2

          litellm_settings:
            # Bedrock rejects a tool-calling request that arrives without a tools array, which
            # is how a plain summarisation call looks. modify_params lets LiteLLM insert a
            # dummy tool rather than returning UnsupportedParamsError. Graphiti leans on
            # structured output constantly, so without this the common path fails.
            modify_params: true
            # Bedrock does not accept every OpenAI parameter. Dropping the unknown ones beats
            # a 400 from a field the caller did not know it was sending.
            drop_params: true

          general_settings:
            master_key: os.environ/LITELLM_MASTER_KEY
        EOT
      }
    }

    # ── Search the agent owns ──────────────────────────────────────────────────
    #
    # A metasearch engine, self-hosted. It queries other engines and merges the results, so there
    # is no API key, no per-query bill and no quota — and no third party sees the agent's queries.
    #
    # THREE THINGS BLOCK API ACCESS OUT OF THE BOX, and all three are configured below:
    #
    #   1. JSON is not an allowed output format. The default is HTML only, so a caller asking for
    #      format=json gets a 403 that reads like a permissions problem.
    #   2. The limiter is bot protection. It exists to stop scrapers, and a Python client is
    #      indistinguishable from one. Off, because this instance is reachable only inside the
    #      namespace.
    #   3. Searches default to POST. A GET with a query string is refused until method is
    #      changed, which makes the simplest possible client fail first.
    #
    # `use_default_settings: true` means this file overrides rather than replaces — the several
    # dozen default engine definitions are inherited instead of being re-declared here.
    searxng = {
      image      = "searxng/searxng:2026.9.18-0d6910ae5"
      ports      = [8080]
      cpu        = "250m"
      memory     = "512Mi"
      ready_port = 8080

      env = {
        # Pointed at the mounted file explicitly. The image looks in /etc/searxng by default and
        # would find it anyway, but naming it means a future change to the mount path fails
        # loudly here rather than silently falling back to the built-in defaults.
        SEARXNG_SETTINGS_PATH = "/etc/searxng/settings.yml"
      }

      config = {
        mount_path = "/etc/searxng"
        filename   = "settings.yml"
        # $${...} escapes the interpolation so the literal reaches the ConfigMap, where
        # templatestring renders it against a generated secret. Writing $ {...} unescaped would
        # make Terraform try to resolve it while parsing this file and fail.
        content = <<-EOT
          use_default_settings: true

          server:
            secret_key: "$${searxng_secret}"
            limiter: false
            image_proxy: false
            method: "GET"

          search:
            formats:
              - html
              - json
            safe_search: 0
            autocomplete: ""
            default_lang: "en"
        EOT
      }
    }

    # ── Where the experiment actually runs ─────────────────────────────────────
    #
    # No ports, no volume: a pod to `kubectl exec` into. It holds the clients rather than
    # being a service, which is why it is here instead of on the laptop — the datastores are
    # ClusterIP and reachable by DNS from inside, and not from outside without port-forwards.
    #
    # Dependencies install at start rather than being baked into an image, because baking one
    # needs an ECR repository, a build and a push for every change to the dependency list.
    # The trade is a slower start and no reproducibility guarantee across restarts.
    #
    # `|| echo` rather than `&&`: a failed install leaves the pod up with the failure in its
    # logs. With `&&` the container exits and Kubernetes reports CrashLoopBackOff, which says
    # nothing about which package broke.
    workbench = {
      image           = "python:3.12-slim"
      ports           = []
      cpu             = "500m"
      memory          = "1Gi"
      service_account = "agent-bedrock"

      # A volume, so work survives the pod. Without it the harness code lives in the container's
      # /tmp and a restart erases it — which is not a development loop, it is a demo that has to
      # be rebuilt every time. /workspace is where the harness and the agent's own files live.
      storage    = "10Gi"
      mount_path = "/workspace"

      # langgraph-checkpoint-postgres carries PostgresStore and PostgresSaver, which are what
      # make StoreBackend persistent. Without it the only backend available is StateBackend,
      # and StateBackend forgets everything when the thread ends.
      #
      # `psycopg[binary]`, NOT psycopg2-binary. They are different libraries: langgraph wants
      # psycopg 3, and psycopg2 does not satisfy it. The `[binary]` extra matters too, because
      # python:3.12-slim ships no libpq, so psycopg's pure-Python fallback cannot load either:
      #
      #   ImportError: no pq wrapper available.
      #     - couldn't import psycopg 'binary' implementation: No module named 'psycopg_binary'
      #     - couldn't import psycopg 'python' implementation: libpq library not found
      #
      # Quoted because the brackets are shell glob characters.
      args = ["sh", "-lc",
        "pip install --quiet --root-user-action=ignore graphiti-core langchain-aws deepagents langgraph-checkpoint-postgres 'psycopg[binary]' neo4j qdrant-client redis trafilatura || echo DEPENDENCY_INSTALL_FAILED; sleep infinity"
      ]

      env = {
        NEO4J_URI        = "bolt://neo4j:7687"
        QDRANT_URL       = "http://qdrant:6333"
        REDIS_URL        = "redis://redis:6379"
        SEARXNG_URL      = "http://searxng:8080"
        PYTHONUNBUFFERED = "1"
      }
    }
  }
}
