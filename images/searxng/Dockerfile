# EAF-owned SearXNG image.
# Try apk (Alpine) then apt-get (Debian). If the base image ships neither,
# the || true means the build still succeeds — Trivy scanning in the pipeline
# catches any unfixed CVEs in the upstream image.
FROM searxng/searxng:latest

USER root
RUN apk --no-cache upgrade 2>/dev/null \
    || (apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*) 2>/dev/null \
    || true
USER searxng
