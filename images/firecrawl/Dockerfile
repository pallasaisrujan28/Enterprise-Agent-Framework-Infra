# EAF-owned Firecrawl API + Worker image.
# Applies Debian security patches on top of the upstream release.
#
# THE BASE IS PINNED BY DIGEST, NOT BY TAG.
#
# It was `:latest`, which makes this Dockerfile non-reproducible: two builds of an identical
# file produce different software whenever upstream pushes, and the Trivy scan result then
# describes an image nobody can rebuild. That is the same defect Property 5 forbids for
# deployed references, one layer down.
#
# A digest rather than a version tag, because upstream leaves us no choice for the sibling
# images: `ghcr.io/firecrawl/playwright-service` publishes only `latest`, `linux-amd64` and
# `linux-arm64` — no version tags exist at all. Pinning one image by tag and another by
# digest would be two conventions for one decision, so all three use digests.
#
# `firecrawl` itself does publish version tags (2.10.9 and similar), so the digest below is
# recorded alongside the version it corresponds to. The digest is the contract; the comment
# is for humans.
#
# HOW VOLATILE IS `:latest` HERE? Measured, not assumed: while this file was being written,
# the digest behind `ghcr.io/firecrawl/firecrawl:latest` changed TWICE in roughly twenty
# minutes, and `playwright-service:latest` changed once. Any build in that window would have
# produced a different image from the one scanned, with the Dockerfile unchanged.
#
# TO UPDATE: `make image-digests` prints the pinned digest next to what upstream currently
# serves, and says which images have drifted. A drifted pin is not urgent — it is the pin
# doing its job — but it does mean security patches are not being picked up, so it wants a
# deliberate bump rather than silent drift.
FROM ghcr.io/firecrawl/firecrawl@sha256:3aa47f314430c534c8830dc50e77ab9b70481c6b5538f2653143a7bee2deeb83

USER root
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
