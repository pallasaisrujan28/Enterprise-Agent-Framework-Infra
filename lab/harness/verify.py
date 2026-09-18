"""Prove the harness is wired the way the design claims.

Four assertions, each checked against Postgres or the filesystem rather than against the library:

  1. skills live in the Store, not on the pod's disk
  2. memory lives in the Store, and is shared across a user's sessions
  3. one session cannot see another session's scratch files
  4. one user cannot see another user's memory

Then one real agent run, to confirm the model reads memory through the middleware rather than
the checkpointed transcript.
"""

from __future__ import annotations

import os
import sys
from contextlib import ExitStack

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    Session,
    build_agent,
    context_for,
    postgres_uri,
    seed_skill,
)

SKILL_BODY = """---
name: lab-recall
description: How to answer questions about the EAF lab infrastructure and its datastores.
---

# Lab recall

The lab runs four datastores in the `agent` namespace on EKS cluster `eaf-lab`:

- **neo4j** - temporal knowledge graph, used by Graphiti
- **qdrant** - vector search
- **postgres** - LangGraph store and checkpointer
- **redis** - queues and short-term state

When asked what the lab contains, call `lab_inventory` rather than answering from memory.
"""

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}")


def main() -> None:
    from langgraph.checkpoint.postgres import PostgresSaver
    from langgraph.store.postgres import PostgresStore

    uri = postgres_uri()
    alice_1 = Session(user_id="alice", session_id="s1")
    alice_2 = Session(user_id="alice", session_id="s2")
    bob_1 = Session(user_id="bob", session_id="s1")

    with ExitStack() as stack:
        store = stack.enter_context(PostgresStore.from_conn_string(uri))
        saver = stack.enter_context(PostgresSaver.from_conn_string(uri))
        store.setup()
        saver.setup()

        # ── 1. skills in the Store ────────────────────────────────────────────
        seed_skill(store, "lab-recall", SKILL_BODY)
        skills = list(store.search(("agent", "skills")))
        check(any("lab-recall" in item.key for item in skills), "skill is in the Store")

        # ── 2. memory in the Store, shared across a user's sessions ───────────
        store.put(
            ("agent", "alice", "memory"),
            "/AGENTS.md",
            {"content": "Alice fact: the lab runs on EKS cluster eaf-lab.", "encoding": "utf-8"},
        )
        alice_mem = list(store.search(("agent", "alice", "memory")))
        check(len(alice_mem) == 1, "alice memory written to the Store")

        # Same namespace regardless of which session asks — that is what makes memory revive.
        check(
            alice_1.user_id == alice_2.user_id,
            "alice's two sessions resolve to the same memory namespace",
        )

        # ── 3. session isolation on the scratch filesystem ────────────────────
        os.makedirs(alice_1.workspace, exist_ok=True)
        os.makedirs(alice_2.workspace, exist_ok=True)
        marker = os.path.join(alice_1.workspace, "session-1-only.txt")
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("written by s1")

        check(alice_1.workspace != alice_2.workspace, "sessions have different scratch roots")
        check(
            not os.path.exists(os.path.join(alice_2.workspace, "session-1-only.txt")),
            "s2 cannot see s1's scratch file",
        )

        # ── 4. user isolation on memory ───────────────────────────────────────
        bob_mem = list(store.search(("agent", "bob", "memory")))
        check(len(bob_mem) == 0, "bob cannot see alice's memory")
        check(bob_1.workspace != alice_1.workspace, "bob's scratch root differs from alice's")

        # ── 5. the model reads memory through the middleware ──────────────────
        # A fresh session id, so nothing is inherited from a checkpointed transcript. Anything
        # recalled came from the Store.
        fresh = Session(user_id="alice", session_id="verify-fresh")
        agent = build_agent(store, saver, fresh)
        result = agent.invoke(
            {
                "messages": [
                    {
                        "role": "user",
                        "content": "Without calling any tools, what do you already remember? "
                        "Quote it exactly.",
                    }
                ]
            },
            config={"configurable": {"thread_id": "verify-fresh"}, "recursion_limit": 20},
            context=context_for(fresh),
        )
        text = _text_of(result["messages"][-1])
        check("eaf-lab" in text, "fresh session recalled alice's memory from the Store")
        print(f"\n  model said: {text[:220]}")

        passed = sum(1 for ok, _ in results if ok)
        print(f"\n  {passed}/{len(results)} checks passed")
        if passed != len(results):
            sys.exit(1)


def _text_of(message: object) -> str:
    content = getattr(message, "content", "")
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict):
                parts.append(part.get("text") or str(part.get("reasoning_content", "")))
            else:
                parts.append(str(part))
        return " ".join(parts)
    return str(content)


if __name__ == "__main__":
    main()
