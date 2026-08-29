# EAF-owned SearXNG image.
# SearXNG moved from Alpine to Debian — patches via apt-get.
FROM searxng/searxng:latest

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
USER searxng
