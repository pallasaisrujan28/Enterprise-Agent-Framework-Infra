# EAF-owned Firecrawl API + Worker image.
# Applies Debian security patches on top of the official release.
FROM ghcr.io/mendableai/firecrawl:latest

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
