"""Does the memory grow, consolidate, and fix itself?

Three properties, checked against Neo4j rather than against Graphiti's return values.

  GROWS          episodes become entities and facts
  CONSOLIDATES   build_communities produces clusters with summaries
  FIXES ITSELF   a contradicting episode expires the STALE fact and leaves the NEW one live

The third is the one that matters and the one that is easy to fake. It is not enough that some
edge got invalidated — Nova Pro invalidated the wrong one, expiring "Sai has left Reply" and
leaving "Sai works at Reply" live, so the graph asserted both employers at once. This script
therefore asserts the direction, not the count.

Model is configurable so the same test can be run against different models and compared:

    python graphiti_memory.py                  # gpt-4.1-mini alias -> gpt-oss-120b
    GRAPHITI_MODEL=nova-pro python graphiti_memory.py
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from datetime import datetime, timezone

# The Neo4j 6.x driver reports every selected-but-absent property as a server notification, and
# Graphiti's queries legitimately select columns that do not exist on a fresh graph. Hundreds of
# lines of warning about a graph that is merely empty.
for name in ("neo4j", "neo4j.notifications"):
    logging.getLogger(name).setLevel(logging.ERROR)

from graphiti_core import Graphiti  # noqa: E402
from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig  # noqa: E402
from graphiti_core.llm_client.config import LLMConfig  # noqa: E402
from graphiti_core.llm_client.openai_client import OpenAIClient  # noqa: E402
from graphiti_core.nodes import EpisodeType  # noqa: E402

MODEL = os.environ.get("GRAPHITI_MODEL", "gpt-4.1-mini")
USER, PASSWORD = os.environ["NEO4J_AUTH"].split("/", 1)
URI = os.environ["NEO4J_URI"]
KEY = os.environ["OPENAI_API_KEY"]
BASE = os.environ["OPENAI_BASE_URL"]

EPISODES = [
    "Sai is a platform engineer. He works at Reply, based in London.",
    "Sai is building an agent framework on EKS. The project is called EAF.",
    "EAF uses Neo4j for long-term memory and Qdrant for vector search.",
]
CONTRADICTION = "Sai has left Reply. He now works at Acme Corp."

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}")


def build() -> Graphiti:
    llm = OpenAIClient(
        config=LLMConfig(
            api_key=KEY,
            base_url=BASE,
            model=MODEL,
            # The same model for both roles. Graphiti routes deduplication and contradiction
            # detection to the small model, so that is the last place to save money — it is
            # exactly where the weaker model produced the string "null" for a date.
            small_model=MODEL,
        )
    )
    embedder = OpenAIEmbedder(
        config=OpenAIEmbedderConfig(
            api_key=KEY,
            base_url=BASE,
            embedding_model="text-embedding-3-small",
            # Titan returns 1024, not the 1536 the OpenAI name implies. Get this wrong and the
            # index is built at the wrong width and similarity search misbehaves quietly.
            embedding_dim=1024,
        )
    )
    return Graphiti(URI, USER, PASSWORD, llm_client=llm, embedder=embedder)


async def facts(graph: Graphiti) -> list[dict]:
    records, _, _ = await graph.driver.execute_query(
        "MATCH ()-[r:RELATES_TO]->() RETURN r.fact AS fact, r.invalid_at AS invalid_at, "
        "r.expired_at AS expired_at ORDER BY fact"
    )
    return [dict(record) for record in records]


def state_of(row: dict) -> str:
    if row.get("expired_at"):
        return "EXPIRED"
    if row.get("invalid_at"):
        return "INVALIDATED"
    return "live"


async def main() -> None:
    print(f"  model: {MODEL}\n")
    graph = build()
    await graph.build_indices_and_constraints()
    await graph.driver.execute_query("MATCH (n) DETACH DELETE n")

    now = datetime.now(timezone.utc)

    # ── grows ─────────────────────────────────────────────────────────────────
    for index, body in enumerate(EPISODES):
        await graph.add_episode(
            name=f"episode-{index}",
            episode_body=body,
            source_description="lab test",
            reference_time=now,
            source=EpisodeType.text,
        )

    rows = await facts(graph)
    entities, _, _ = await graph.driver.execute_query(
        "MATCH (n:Entity) RETURN count(n) AS n"
    )
    entity_count = entities[0]["n"] if entities else 0
    print(f"  -> {entity_count} entities, {len(rows)} facts from {len(EPISODES)} sentences")
    check(entity_count >= 4 and len(rows) >= 4, "GROWS: episodes became entities and facts")

    # ── fixes itself ──────────────────────────────────────────────────────────
    await graph.add_episode(
        name="episode-contradiction",
        episode_body=CONTRADICTION,
        source_description="lab test",
        reference_time=now,
        source=EpisodeType.text,
    )

    rows = await facts(graph)
    print("\n  fact table after the contradiction:")
    for row in rows:
        print(f"    {state_of(row):12s} {row['fact']}")

    def find(*needles: str) -> list[dict]:
        """Facts containing every needle."""
        return [
            r
            for r in rows
            if all(needle.lower() in (r["fact"] or "").lower() for needle in needles)
        ]

    # THE EMPLOYMENT FACT SPECIFICALLY, not every fact mentioning Reply.
    #
    # An earlier version of this check matched on "reply" alone and reported a failure the model
    # had not committed: "Reply is based in London" is still live and *should* be, because the
    # contradiction said nothing about Reply's location. Only "Sai works at Reply" is superseded.
    # A test that cannot tell a stale fact from a still-true one about the same entity will call
    # a correct model wrong.
    stale_employment = find("sai", "works at reply")
    acme_rows = find("acme")

    stale_retired = bool(stale_employment) and all(
        state_of(r) != "live" for r in stale_employment
    )
    new_live = bool(acme_rows) and any(state_of(r) == "live" for r in acme_rows)

    check(stale_retired, "FIXES ITSELF: the stale 'works at Reply' fact is no longer live")
    check(new_live, "FIXES ITSELF: the new Acme fact is live")

    # A CORRECT GRAPH IS NOT THE SAME AS CORRECT RECALL.
    #
    # graph.search does not filter expired edges by default, so a stale fact the graph has
    # already retired still comes back in results and still reaches the model. The invalidation
    # is only half the value unless retrieval respects it — checked here so the gap is visible
    # rather than assumed away.
    recalled = await graph.search("Where does Sai work?", num_results=5)
    stale_in_recall = [
        item.fact
        for item in recalled
        if "works at reply" in (item.fact or "").lower()
    ]
    check(
        not stale_in_recall,
        "RECALL excludes expired facts (default search does not filter them)",
    )

    # ── consolidates ──────────────────────────────────────────────────────────
    nodes, _ = (await graph.build_communities())[:2]
    communities, _, _ = await graph.driver.execute_query(
        "MATCH (c:Community) RETURN c.name AS name, c.summary AS summary"
    )
    print(f"\n  -> {len(communities)} community node(s)")
    for community in communities:
        summary = " ".join((community["summary"] or "").split())[:180]
        print(f"    - {summary}")
    check(
        bool(communities) and any((c["summary"] or "").strip() for c in communities),
        "CONSOLIDATES: communities exist and carry summaries",
    )

    # ── recall ────────────────────────────────────────────────────────────────
    found = await graph.search("Where does Sai work?", num_results=5)
    print("\n  recall for 'Where does Sai work?':")
    for item in found:
        print(f"    - {item.fact}")

    await graph.close()

    passed = sum(1 for ok, _ in results if ok)
    print(f"\n  {passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    asyncio.run(main())
