# EAF-owned SearXNG image.
# SearXNG uses Alpine Linux — patches via apk, not apt.
FROM searxng/searxng:latest

USER root
RUN apk --no-cache upgrade
USER searxng
