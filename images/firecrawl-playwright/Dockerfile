# EAF-owned Firecrawl Playwright service image.
FROM ghcr.io/mendableai/firecrawl-playwright-service:latest

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
