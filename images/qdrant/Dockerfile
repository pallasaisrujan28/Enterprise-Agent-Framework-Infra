# EAF-owned Qdrant image.
# Builds on top of the official upstream release, applies all available
# Debian security patches so Trivy finds no fixable CVEs.
FROM qdrant/qdrant:v1.14.0

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
USER 1000
