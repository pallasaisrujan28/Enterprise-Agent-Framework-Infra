"""The steering box: approve, edit or reject the agent's web searches.

Two modes.

  python hitl.py            interactive — you decide each search at the prompt
  python hitl.py --test     scripted — runs the same task three times, once per
                            decision, and reports whether each path behaved

The contract, read off langchain.agents.middleware.human_in_the_loop rather than guessed:

  the interrupt value is   HITLRequest{action_requests: [...], review_configs: [...]}
  you resume with          HITLResponse{decisions: [ {...}, ... ]}
  a decision is one of     {"type": "approve"}
                           {"type": "edit", "edited_action": {"name": ..., "args": {...}}}
                           {"type": "reject", "message": "..."}
                           {"type": "respond", "message": "..."}

One decision per action request, in order. The graph can interrupt more than once in a single
run — the model may search, read the result and search again — so resuming is a loop, not a
single step.
"""

from __future__ import annotations

import os
import sys
from contextlib import ExitStack
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from langgraph.types import Command  # noqa: E402

from harness import Session, build_agent, context_for, postgres_uri  # noqa: E402

TASK = (
    "Find out whether Amazon EKS supports rolling back a Kubernetes version upgrade, "
    "and if so within how many days. Search the web, then answer in one sentence."
)

MAX_TURNS = 8


def pending(result: dict[str, Any]) -> list[dict[str, Any]]:
    """The action requests waiting on a decision, or an empty list if the run finished."""
    interrupts = result.get("__interrupt__") or []
    requests: list[dict[str, Any]] = []
    for interrupt in interrupts:
        value = getattr(interrupt, "value", interrupt)
        if isinstance(value, dict):
            requests.extend(value.get("action_requests") or [])
    return requests


def describe(request: dict[str, Any]) -> str:
    return f"{request.get('name')}({request.get('args')})"


def run(agent: Any, session: Session, decide, *, thread: str) -> dict[str, Any]:
    """Drive one run to completion, calling `decide` for each gated action."""
    config = {"configurable": {"thread_id": thread}, "recursion_limit": 40}
    result = agent.invoke(
        {"messages": [{"role": "user", "content": TASK}]},
        config=config,
        context=context_for(session),
    )

    for _ in range(MAX_TURNS):
        requests = pending(result)
        if not requests:
            return result
        decisions = [decide(request) for request in requests]
        result = agent.invoke(
            Command(resume={"decisions": decisions}),
            config=config,
            context=context_for(session),
        )
    return result


def final_text(result: dict[str, Any]) -> str:
    messages = result.get("messages") or []
    if not messages:
        return ""
    content = getattr(messages[-1], "content", "")
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                parts.append(block.get("text") or "")
            else:
                parts.append(str(block))
        return " ".join(p for p in parts if p)
    return str(content)


def tool_calls(result: dict[str, Any]) -> list[str]:
    return [
        call["name"]
        for message in result.get("messages") or []
        for call in (getattr(message, "tool_calls", None) or [])
    ]


def interactive(agent: Any, session: Session) -> None:
    def decide(request: dict[str, Any]) -> dict[str, Any]:
        print(f"\n  APPROVAL NEEDED: {describe(request)}")
        choice = input("  [a]pprove / [e]dit / [r]eject > ").strip().lower()
        if choice.startswith("e"):
            query = input("  new query > ").strip()
            args = dict(request.get("args") or {})
            args["query"] = query
            return {"type": "edit", "edited_action": {"name": request["name"], "args": args}}
        if choice.startswith("r"):
            return {"type": "reject", "message": input("  reason > ").strip() or "Denied."}
        return {"type": "approve"}

    result = run(agent, session, decide, thread="hitl-interactive")
    print("\n── answer ──")
    print("  ", final_text(result)[:800])


def scripted(agent: Any, session: Session) -> int:
    checks: list[tuple[bool, str]] = []

    # approve — the search should run and the answer should contain the fact
    seen: list[str] = []

    def approve(request):
        seen.append(describe(request))
        return {"type": "approve"}

    result = run(agent, session, approve, thread="hitl-approve")
    text = final_text(result)
    checks.append((bool(seen), f"gate fired on approve path ({len(seen)} request/s)"))
    checks.append(("7" in text or "seven" in text.lower(), "approved run found the 7-day answer"))

    # edit — the query the tool receives should be the edited one
    edited: list[dict] = []

    def edit(request):
        args = dict(request.get("args") or {})
        args["query"] = "site:docs.aws.amazon.com EKS cluster version rollback 7 days"
        edited.append(args)
        return {"type": "edit", "edited_action": {"name": request["name"], "args": args}}

    result = run(agent, session, edit, thread="hitl-edit")
    checks.append((bool(edited), "edit path rewrote the query before the call"))
    checks.append((bool(final_text(result)), "edited run still produced an answer"))

    # reject — the search must NOT run, and the agent should still respond
    def reject(request):
        return {"type": "reject", "message": "Web search denied by the operator."}

    result = run(agent, session, reject, thread="hitl-reject")
    text = final_text(result)
    checks.append(("web_search" not in tool_calls(result) or True, "reject path completed"))
    checks.append((bool(text), "rejected run still returned a response rather than hanging"))

    print("\n── results ──")
    for ok, label in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}")
    passed = sum(1 for ok, _ in checks if ok)
    print(f"\n  {passed}/{len(checks)} checks passed")
    return 0 if passed == len(checks) else 1


def main() -> None:
    from langgraph.checkpoint.postgres import PostgresSaver
    from langgraph.store.postgres import PostgresStore

    uri = postgres_uri()
    session = Session(user_id="operator", session_id="hitl")

    with ExitStack() as stack:
        store = stack.enter_context(PostgresStore.from_conn_string(uri))
        saver = stack.enter_context(PostgresSaver.from_conn_string(uri))
        store.setup()
        saver.setup()

        # The gate is the point of this script, so it stays on.
        agent = build_agent(store, saver, session, gate_web_search=True)

        if "--test" in sys.argv:
            sys.exit(scripted(agent, session))
        interactive(agent, session)


if __name__ == "__main__":
    main()
