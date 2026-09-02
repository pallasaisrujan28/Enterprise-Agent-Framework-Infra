# EAF-owned Firecrawl nuq-postgres image.
# Applies Debian security patches on top of the upstream release.
#
# WHY THIS IMAGE EXISTS AT ALL, when the other two were already here.
#
# Firecrawl's job queue is backed by Postgres, and it is NOT stock postgres. Upstream builds
# a purpose-made image from `apps/nuq-postgres` containing the schema and extensions the
# queue needs, and the API reaches it at the hostname `nuq-postgres` by default. Substituting
# the official `postgres` image gives a database the API can connect to and cannot use, which
# fails at query time rather than at connection time.
#
# It is published, so this only re-layers security patches rather than building from source.
#
# The design's Step 6 lists five services — API, Playwright, Postgres, Redis, RabbitMQ — and
# names only two images. This is the third. Redis and RabbitMQ are stock upstream images and
# need no EAF layer.
#
# NOT FoundationDB, which also appears in upstream's compose. It is reached only when
# `NUQ_BACKEND` is set: the compose expands `\${NUQ_BACKEND:+/var/fdb/fdb.cluster}`, so with the
# variable unset the queue uses Postgres and FoundationDB is never contacted. Two fewer
# services, and no distributed key-value store to operate.
#
# Pinned by digest. See images/firecrawl/Dockerfile for why, and `make image-digests` for
# when this pin has fallen behind.
FROM ghcr.io/firecrawl/nuq-postgres@sha256:aed86f62858f29bd971abddcdeb301c12888098d2cf5d33c1ba42b053bc460f6

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
