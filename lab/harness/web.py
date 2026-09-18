"""Web tools for the harness: one to find URLs, one to read them.

Two tools rather than one, because they are genuinely different jobs and the earlier confusion
between them cost a design round. Search turns a question into URLs. Fetch turns a URL into text
the model can afford to read.

NEITHER NEEDS AN API KEY.

  web_search  -> SearXNG in this cluster. A metasearch engine that queries others and merges
                 results, so there is no key, no per-query bill, and no third party sees the
                 agent's queries.

  web_fetch   -> trafilatura, in this process. Pure Python, reads static HTML, discards
                 navigation and boilerplate, returns the article. Falls back to r.jina.ai when
                 trafilatura finds nothing, which is what happens on JavaScript-rendered pages
                 and PDFs because trafilatura does not run a browser.

web_search is the tool the human-in-the-loop gate is placed on: it is the one that reaches
outside the cluster on the agent's initiative.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request

from langchain_core.tools import tool

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://searxng:8080")
JINA_READER = "https://r.jina.ai/"

# Some sites refuse the default Python user agent outright. This is not evasion — it is being
# honest about being a tool while not being rejected for the shape of the string.
USER_AGENT = "Mozilla/5.0 (compatible; EAF-lab-agent/0.1; +https://github.com/pallasaisrujan28)"

# Fetched pages are truncated. A single long article can fill the context window on its own, and
# the point of extraction is to spend tokens on content rather than on markup.
MAX_CHARS = 12000


def _get(url: str, timeout: int = 45) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


@tool
def web_search(query: str, max_results: int = 5) -> str:
    """Search the web and return titles, URLs and snippets.

    Use this to find pages when you do not already have a URL. Follow up with web_fetch to read
    any result in full.

    Args:
        query: What to search for.
        max_results: How many results to return, at most 10.
    """
    params = urllib.parse.urlencode({"q": query, "format": "json"})
    try:
        payload = json.loads(_get(f"{SEARXNG_URL}/search?{params}"))
    except urllib.error.HTTPError as error:
        # 403 here almost always means the instance is refusing the JSON format or the limiter is
        # on, not that the query was bad.
        return f"search failed: HTTP {error.code}. {error.read().decode()[:200]}"
    except Exception as error:  # noqa: BLE001 - a tool must report, not raise
        return f"search failed: {type(error).__name__}: {error}"

    results = payload.get("results", [])[: min(max_results, 10)]
    if not results:
        return f"No results for {query!r}."

    lines = []
    for index, item in enumerate(results, start=1):
        title = (item.get("title") or "").strip()
        url = (item.get("url") or "").strip()
        snippet = " ".join((item.get("content") or "").split())[:300]
        lines.append(f"{index}. {title}\n   {url}\n   {snippet}")
    return "\n".join(lines)


@tool
def web_fetch(url: str) -> str:
    """Fetch a URL and return its main content as clean text.

    Strips navigation, sidebars and boilerplate, so the result is the article rather than the
    page. Use after web_search, or whenever you are given a URL directly.

    Args:
        url: The absolute URL to read.
    """
    if not url.startswith(("http://", "https://")):
        return f"refusing to fetch {url!r}: not an absolute http(s) URL"

    # Local first. No third party sees the URL, and there is no rate limit to share.
    try:
        import trafilatura

        html = _get(url)
        extracted = trafilatura.extract(
            html,
            output_format="markdown",
            include_links=False,
            include_comments=False,
            with_metadata=True,
        )
        if extracted and extracted.strip():
            return _clip(extracted, source="trafilatura")
    except Exception:  # noqa: BLE001 - fall through to the remote reader
        pass

    # trafilatura found nothing. Usually the page renders its content with JavaScript, or it is a
    # PDF. The reader service runs a browser, so it sees what trafilatura cannot.
    try:
        return _clip(_get(JINA_READER + url, timeout=90), source="r.jina.ai")
    except Exception as error:  # noqa: BLE001
        return f"fetch failed for {url}: {type(error).__name__}: {error}"


def _clip(text: str, source: str) -> str:
    text = text.strip()
    if len(text) <= MAX_CHARS:
        return f"[extracted by {source}]\n\n{text}"
    return f"[extracted by {source}, truncated at {MAX_CHARS} chars]\n\n{text[:MAX_CHARS]}"


WEB_TOOLS = [web_search, web_fetch]
