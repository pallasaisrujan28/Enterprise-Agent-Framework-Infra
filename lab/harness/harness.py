"""The base deepagents harness, assembled against the lab's services.

Maps onto the anatomy diagram:

  EXECUTION ENVIRONMENT   Filesystem / Sandbox / Code Interpreter
                          -> LocalShellBackend on a per-session directory
  DELEGATION              Planning / Subagents
                          -> TodoListMiddleware (not in the base stack) + SubAgent
  STEERING                Human-in-the-loop
                          -> interrupt_on; see WEB SEARCH note below
  CONTEXT MANAGEMENT      Skills / Memory / Summarization / Context offloading / Prompt caching
                          -> skills= and memory=, both routed to Postgres, not local disk

Nothing here invents agent scaffolding. Every capability is a documented deepagents parameter;
the work is choosing backends, scoping them, and proving the model can drive them.

WHAT IS AND IS NOT LOCAL
------------------------
Memory and skills live in the LangGraph Store, which is Postgres. They are not on the pod's
disk, so they survive the pod, and a second replica would see the same memory.

The scratch filesystem is local, and has to be. Execution needs a real directory for a shell to
run in — you cannot exec inside Postgres. So `/workspace/sessions/<id>` is local by necessity,
isolated per session, and disposable. Anything the agent must not lose belongs under /memory/.

SESSION ISOLATION, AND THE ASYMMETRY IN HOW IT IS ENFORCED
----------------------------------------------------------
Two mechanisms, because the two backends scope differently:

  StoreBackend      scopes at RUNTIME through a namespace factory that reads Runtime.context,
                    so one compiled agent can serve many sessions.
  LocalShellBackend scopes at CONSTRUCTION, because root_dir is a real path fixed when the
                    backend is built.

They must agree. `build_agent` therefore takes the session and derives both from it, so a caller
cannot namespace the store as one session while the shell writes into another.

Memory is scoped to the USER and shared across that user's sessions — that is the point of
long-term memory. Only the scratch filesystem is per session.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Any

from langchain.agents.middleware import TodoListMiddleware
from langchain_core.tools import tool
from langgraph.runtime import Runtime

from deepagents import SubAgent, create_deep_agent
from deepagents.backends import CompositeBackend, LocalShellBackend, StoreBackend
from web import WEB_TOOLS

# Root for per-session scratch directories. An EBS volume, so a session's working files can be
# inspected after the run — but never the place durable knowledge goes.
SESSIONS_ROOT = os.environ.get("AGENT_SESSIONS_ROOT", "/workspace/sessions")

# Bedrock is native in deepagents: _BEDROCK_PROVIDERS includes bedrock_converse and _models.py
# has explicit Nova handling, so nothing proxies this path. LiteLLM is only for Graphiti, which
# has no Bedrock provider of its own.
#
# Nova Pro because it is the most capable model this account can invoke. Claude is walled off by
# the AWS Marketplace payment-instrument requirement, and Claude 4.x/5 need inference profiles,
# which the organisation's SCP denies.
MODEL = os.environ.get("AGENT_MODEL", "bedrock_converse:amazon.nova-pro-v1:0")

# Store namespace components are validated against [A-Za-z0-9\-_.@+:~], and anything else is
# rejected to stop glob injection into store lookups. So identifiers are sanitised rather than
# trusted, and a caller passing "../other-user" gets flattened instead of escaping its namespace.
_UNSAFE = re.compile(r"[^A-Za-z0-9\-_.@+:~]")


def _safe(component: str) -> str:
    cleaned = _UNSAFE.sub("-", component).strip("-")
    return cleaned or "default"


@dataclass(frozen=True)
class Session:
    """Who is running, and which run this is.

    `user_id` scopes memory and skills; `session_id` scopes the scratch filesystem. Two sessions
    for the same user share memory and share nothing else.
    """

    user_id: str = "default"
    session_id: str = "default"

    def __post_init__(self) -> None:
        object.__setattr__(self, "user_id", _safe(self.user_id))
        object.__setattr__(self, "session_id", _safe(self.session_id))

    @property
    def workspace(self) -> str:
        return os.path.join(SESSIONS_ROOT, self.user_id, self.session_id)


@dataclass
class AgentContext:
    """Run-scoped context. Reaches the namespace factories via `Runtime.context`."""

    user_id: str = "default"
    session_id: str = "default"


def memory_namespace(runtime: Runtime[Any]) -> tuple[str, ...]:
    """Memory: per user, shared across that user's sessions."""
    context = getattr(runtime, "context", None)
    user = _safe(getattr(context, "user_id", None) or "default")
    return ("agent", user, "memory")


def skills_namespace(_runtime: Runtime[Any]) -> tuple[str, ...]:
    """Skills: shared. A skill is a capability, not private knowledge."""
    return ("agent", "skills")


def postgres_uri() -> str:
    user = os.environ["POSTGRES_USER"]
    password = os.environ["POSTGRES_PASSWORD"]
    database = os.environ["POSTGRES_DB"]
    return f"postgresql://{user}:{password}@postgres:5432/{database}"


@tool
def lab_inventory() -> str:
    """List the datastores running in the lab and what each is for."""
    return (
        "neo4j: temporal knowledge graph (Graphiti)\n"
        "qdrant: vector search\n"
        "postgres: langgraph store and checkpointer\n"
        "redis: queues and short-term state"
    )


def build_backend(store: Any, session: Session) -> CompositeBackend:
    """Compose the execution environment.

    LocalShellBackend as the default route lights up three boxes at once: it is the Filesystem,
    it is the Sandbox, and because it implements execution the `execute` tool stops being
    filtered out — that is the Code Interpreter. Context offloading is a sandbox capability, so
    it arrives with the same choice.

    NO ISOLATION BETWEEN THE AGENT AND THIS POD. The class documents itself as unrestricted
    shell execution and it runs here as root. Per-session root_dir separates sessions from each
    other; it does not stop the agent leaving its directory. A pod-per-session backend is the
    honest version, and this is not it.
    """
    os.makedirs(session.workspace, exist_ok=True)

    return CompositeBackend(
        default=LocalShellBackend(root_dir=session.workspace),
        routes={
            "/memory/": StoreBackend(namespace=memory_namespace, store=store),
            "/skills/": StoreBackend(namespace=skills_namespace, store=store),
        },
    )


def build_agent(
    store: Any,
    checkpointer: Any,
    session: Session | None = None,
    *,
    gate_web_search: bool = True,
) -> Any:
    """Assemble the harness for one session.

    `gate_web_search` is the STEERING box. On, the graph suspends before every web_search call
    and waits for a decision — which is correct for a supervised run and a hang for an unattended
    one, so the tests that are not about approval turn it off.
    """
    session = session or Session()

    researcher = SubAgent(
        name="researcher",
        description="Answers questions about the lab's own infrastructure. Use for anything "
        "about which services exist or what they are for.",
        system_prompt="You answer questions about the lab infrastructure. Use lab_inventory.",
        # The tool object, not its name. SubAgent.tools is
        # Sequence[BaseTool | Callable | dict] — a bare string is none of those, and the failure
        # surfaces deep inside ToolNode as `'function' object has no attribute 'name'` rather
        # than anywhere near the spec that caused it.
        tools=[lab_inventory],
    )

    return create_deep_agent(
        model=MODEL,
        tools=[lab_inventory, *WEB_TOOLS],
        system_prompt=(
            "You are the EAF lab agent. You have a per-session filesystem, a shell, shared "
            "skills, and memory that persists across sessions. Prefer your tools over guessing. "
            "To research something you do not know, use web_search to find pages and web_fetch "
            "to read them. When you learn something durable, write it to /memory/AGENTS.md."
        ),
        # DELEGATION. Planning is NOT in the base stack — TodoListMiddleware lives in
        # langchain.agents.middleware and deepagents only pulls it in through harness profiles
        # such as _openai_codex. Passing it here is what puts write_todos in front of the model.
        middleware=[TodoListMiddleware()],
        subagents=[researcher],
        # CONTEXT MANAGEMENT. POSIX paths relative to the backend root; both prefixes are routed
        # to Postgres by build_backend, so neither is on local disk.
        skills=["/skills/"],
        memory=["/memory/AGENTS.md"],
        backend=build_backend(store, session),
        store=store,
        checkpointer=checkpointer,
        context_schema=AgentContext,
        # STEERING. The gate goes on web_search and not on web_fetch, because search is where the
        # agent decides for itself to reach outside the cluster. web_fetch acts on a URL that is
        # already in the conversation, so gating it would ask for the same approval twice.
        #
        # Three decisions are allowed rather than a yes/no: approve runs the call as proposed,
        # edit rewrites the query first — which is the useful one, since a bad query is more
        # common than a forbidden one — and reject returns a refusal to the model so it can
        # continue without the result instead of failing.
        interrupt_on=(
            {
                "web_search": {
                    "allowed_decisions": ["approve", "edit", "reject"],
                    "description": "The agent wants to search the web",
                }
            }
            if gate_web_search
            else None
        ),
    )


def context_for(session: Session) -> AgentContext:
    """The context to pass at invoke time, derived from the same session as the backend."""
    return AgentContext(user_id=session.user_id, session_id=session.session_id)


def seed_skill(store: Any, name: str, body: str) -> None:
    """Put a skill in the Store.

    Skills used to be seeded onto the pod's disk, which meant they died with the pod and were
    invisible to any other replica. They live in Postgres now, so seeding is a store write.
    """
    store.put(("agent", "skills"), f"/{name}/SKILL.md", {"content": body, "encoding": "utf-8"})
