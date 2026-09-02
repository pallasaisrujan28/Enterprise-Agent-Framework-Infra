# EAF-owned Firecrawl Playwright service image.
# Applies Debian security patches on top of the upstream release.
#
# PINNED BY DIGEST, and here there is no alternative: upstream publishes only `latest`,
# `linux-amd64`, `linux-arm64` and two buildcache tags for this image. No version tag exists,
# so a digest is the only immutable reference available.
#
# See images/firecrawl/Dockerfile for the full reasoning, and `make image-digests` for how to
# tell when this pin has fallen behind upstream.
FROM ghcr.io/firecrawl/playwright-service@sha256:df1a393ce8bfc3801570a826a9b0dcc400ae48789adb4a0ad9d6cbf0229b059b

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
