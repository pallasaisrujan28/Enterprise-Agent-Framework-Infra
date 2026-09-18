"""Can the model actually drive the harness?

Assembling a harness proves nothing — the question is whether the model reliably emits the tool
calls the harness exposes. Nova broke Graphiti's structured output by returning the string "null"
where a date belonged, so this is the risk worth measuring before building on top.

Reports which tools were called, so a failure names the capability the model could not drive
rather than just producing no answer.
"""

from __future__ import annotations

import os
import sys
from collections import Counter
from contextlib import ExitStack

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import Session, build_agent, context_for, postgres_uri  # noqa: E402

TASK = (
    "Do these four things in order.\n"
    "1. Use your planning tool to write a todo list for this task.\n"
    "2. Call lab_inventory and tell me what datastores exist.\n"
    "3. Use the execute tool to run `uname -s`.\n"
    "4. Write what you learned to /memory/AGENTS.md so you remember it next time.\n"
)

# Every capability the task above is meant to exercise, and the tool that proves it.
EXPECTED = {
    "write_todos": "Planning",
    "lab_inventory": "custom tool",
    "execute": "Sandbox / Code Interpreter",
    "write_file": "Filesystem + Memory",
}


def main() -> None:
    from langgraph.checkpoint.postgres import PostgresSaver
    from langgraph.store.postgres import PostgresStore

    uri = postgres_uri()
    session = Session(user_id="smoke", session_id="smoke-1")

    with ExitStack() as stack:
        store = stack.enter_context(PostgresStore.from_conn_string(uri))
        saver = stack.enter_context(PostgresSaver.from_conn_string(uri))
        store.setup()
        saver.setup()

        agent = build_agent(store, saver, session)

        result = agent.invoke(
            {"messages": [{"role": "user", "content": TASK}]},
            config={"configurable": {"thread_id": session.session_id}, "recursion_limit": 40},
            context=context_for(session),
        )

        calls: Counter[str] = Counter()
        for message in result["messages"]:
            for call in getattr(message, "tool_calls", None) or []:
                calls[call["name"]] += 1

        print("── tool calls the model made ──")
        for name, count in calls.most_common():
            print(f"   {name} x{count}")
        if not calls:
            print("   NONE — the model never called a tool")

        print("\n── capability coverage ──")
        missing = []
        for name, capability in EXPECTED.items():
            hit = calls.get(name, 0) > 0
            print(f"   [{'PASS' if hit else 'MISS'}] {capability} ({name})")
            if not hit:
                missing.append(capability)

        print(f"\n── messages: {len(result['messages'])} ──")
        if missing:
            print(f"   not exercised: {', '.join(missing)}")


if __name__ == "__main__":
    main()
