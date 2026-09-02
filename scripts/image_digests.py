#!/usr/bin/env python3
"""Compare the base-image digests pinned in images/*/Dockerfile against what upstream serves.

WHY THIS EXISTS. Pinning a base image by digest fixes reproducibility and creates a new
problem in its place: the pin is silent. A `:latest` base rots by changing underneath you; a
digest base rots by NOT changing while upstream publishes security patches you never receive.
Both are bad, and only one of them is visible without a tool.

So this reports drift rather than resolving it. A drifted pin is not a failure — it is the pin
working — but it does mean patches are outstanding, and that should be a deliberate bump with
a scan attached rather than something noticed a year later.

Read-only, and needs no credentials: ghcr.io issues anonymous pull tokens for public images.

Exit codes:
  0  every pin matches upstream
  1  at least one pin has drifted
  2  a pin could not be checked, which is not the same as up to date
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

# ghcr serves an OCI index for multi-arch images and a v2 manifest otherwise. Asking for both
# matters: request only the v2 type and a multi-arch image answers with a DIFFERENT digest
# than the one `docker pull` resolves, so the comparison would report drift that is really a
# mismatch of Accept headers.
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

FROM_RE = re.compile(r"^FROM\s+(?P<registry>[^/]+)/(?P<repo>[^@:\s]+)(?:@(?P<digest>sha256:[0-9a-f]{64}))?(?::(?P<tag>\S+))?", re.M)


def anon_token(registry: str, repo: str) -> str | None:
    """ghcr hands out a pull token for public repositories without credentials."""
    if "ghcr.io" not in registry:
        return None
    url = f"https://{registry}/token?scope=repository:{repo}:pull&service={registry}"
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r).get("token")


def upstream_digest(registry: str, repo: str, ref: str = "latest") -> str:
    token = anon_token(registry, repo)
    req = urllib.request.Request(f"https://{registry}/v2/{repo}/manifests/{ref}", method="HEAD")
    req.add_header("Accept", ACCEPT)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=20) as r:
        d = r.headers.get("Docker-Content-Digest")
    if not d:
        raise RuntimeError("registry returned no Docker-Content-Digest header")
    return d


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1] / "images"
    dockerfiles = sorted(root.glob("*/Dockerfile"))
    if not dockerfiles:
        print("  no images/*/Dockerfile found")
        return 2

    print(f"\n  base image pins in {len(dockerfiles)} image(s)")
    print("  " + "─" * 74)

    drifted: list[str] = []
    unchecked: list[str] = []

    for df in dockerfiles:
        name = df.parent.name
        m = FROM_RE.search(df.read_text())
        if not m:
            print(f"  {name:<26} no FROM line understood")
            unchecked.append(name)
            continue

        registry, repo = m.group("registry"), m.group("repo")
        pinned, tag = m.group("digest"), m.group("tag")

        # A tag where a digest belongs is the defect this tool exists to make visible, so it
        # is reported as drift rather than skipped.
        if not pinned:
            print(f"  {name:<26} NOT PINNED — uses tag :{tag or 'latest'}")
            drifted.append(f"{name} is pinned to a mutable tag, not a digest")
            continue

        try:
            current = upstream_digest(registry, repo)
        except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, TimeoutError) as e:
            print(f"  {name:<26} COULD NOT CHECK — {e}")
            unchecked.append(name)
            continue

        if current == pinned:
            print(f"  {name:<26} up to date   {pinned[:26]}…")
        else:
            print(f"  {name:<26} DRIFTED")
            print(f"  {'':<26}   pinned   {pinned}")
            print(f"  {'':<26}   upstream {current}")
            drifted.append(f"{name}: upstream has moved to {current}")

    if unchecked:
        print(f"\n  !! {len(unchecked)} pin(s) could not be checked, so this is not a clean result.")

    if drifted:
        print("\n  DRIFT — upstream has published newer bases than these pins")
        print("  " + "─" * 74)
        for d in drifted:
            print(f"  * {d}")
        print("\n  Not urgent, and not an error: the pin is doing its job. It does mean security")
        print("  patches are outstanding. Bump the digest in the Dockerfile, then dispatch")
        print("  build-images so the scan runs against what actually gets deployed.")
        return 1

    if unchecked:
        return 2

    print("\n  every base image pin matches upstream")
    return 0


if __name__ == "__main__":
    sys.exit(main())
