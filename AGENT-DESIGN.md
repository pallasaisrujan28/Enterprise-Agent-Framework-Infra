# Enterprise Agent Framework — Agent Design Document

**Status:** Living document. Decisions are final until marked for revisit.
All open questions are flagged — research them when you hit them in code, not before.

---

## Mental Model: Brain, Arms, Legs, Memory

```
        ┌─────────────────────────────────────────────┐
        │                   BRAIN                     │
        │   LangGraph graph — the agent is the graph  │
        │   LLM is called AT nodes, not between them  │
        └──────────────────┬──────────────────────────┘
                           │ decides what to do
              ┌────────────┼─────────────────┐
              ▼            ▼                 ▼
           ARMS           ARMS             ARMS
        built-in tools  MCP tools     sub-agents
        (always there)  (connected     (spawned on
                        by user)        demand)
              │            │                 │
              └────────────┴─────────────────┘
                           │ results come back
              ┌────────────▼──────────────────────────┐
              │               GATE                    │
              │  obligation check — outside the model │
              │  fails closed — model cannot bypass   │
              └───────────────────────────────────────┘
                           │ passed
              ┌────────────▼──────────────────────────┐
              │              MEMORY                   │
              │  working → episodic → semantic → skills│
              └───────────────────────────────────────┘
```

---

## THE BRAIN

### What it is
The brain is a LangGraph `StateGraph`. The agent IS the graph — not a wrapper around a loop, but explicit nodes with explicit edges. The LLM is called inside nodes. The graph structure encodes the workflow logic.

This is Karpathy's "graph engineering" — the structure is in code, not in the model's head.

### The graph structure

```
START
  ↓
assemble_context       ← load skill index + memory into stable prefix
  ↓
call_llm               ← Bedrock Converse API, streaming
  ↓
parse_response
  ├── tool_calls?  → execute_tools → call_llm    [CYCLE — explicit]
  └── text only?   → gate → deliver_or_retry
  ↓
END
```

**The cycle is explicit** — not a while loop. The `execute_tools → call_llm` edge is a declared edge in the graph. Termination is a conditional edge, not a break statement.

Source confirmation: LangGraph `chat_agent_executor.py` — `add_edge("tools", "agent")` is the cycle, `should_continue()` conditional is the termination.

### Technology

| Component | Decision | Source |
|---|---|---|
| Execution framework | LangGraph StateGraph | Confirmed from source code |
| LLM primary | Amazon Bedrock — Claude 3.5 Sonnet | Confirmed: eu-west-2 available |
| LLM fast path | Amazon Bedrock — Claude 3 Haiku | Confirmed: eu-west-2 available |
| Session state | Aurora PostgreSQL Serverless v2 + `PostgresSaver` | Confirmed: only official AWS-native LangGraph checkpointer |
| HITL (human in loop) | LangGraph `interrupt()` + `Command(resume=...)` | Confirmed from types.py source |
| Parallel sub-agents | LangGraph `Send` API | Confirmed from types.py source |
| Agent handoffs | LangGraph `Command(goto=..., graph=Command.PARENT)` | Confirmed from types.py source |

### Agent state (TypedDict)

```python
class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    # add_messages reducer merges by message ID — confirmed from source
```

Start minimal. Add fields as the agent needs them.

### Context window structure

```
STABLE PREFIX — cached by Bedrock, pay once per session
  Identity and persona
  Skill index: each skill as "{name}: {description}" (60-char description MAX)
  Active memory facts (MEMORY equivalent)
  Tool schemas for built-in tools

VOLATILE TAIL — appended each turn, has cache breakpoints
  Conversation history (windowed)
  Active skill body (loaded on demand when skill fires)
  Tool results (current turn)
  User message
```

The 60-char description limit on skills is a hard constraint. It lives in the stable prefix which every request pays for. The body loads only when triggered via `skill_view()`.

Cache breakpoints: placed on trailing 3 `tool_result` blocks. Max 4 total per Anthropic API.

### Task management

For simple requests: single ReAct loop, no plan needed.

For complex requests: plan-and-execute pattern (confirmed from LangGraph type signatures):

```python
class PlanExecute(TypedDict):
    input: str
    plan: list[str]                                      # ordered step strings
    past_steps: Annotated[list[tuple], operator.add]     # (step, result) accumulated
    response: str                                        # final answer
```

Tasks are plain strings. No complex task objects. A "plan" is just an ordered list of step strings. The replanner node checks `past_steps` and either extends the plan or declares done.

> **OPEN QUESTION (research when you need it):**
> How do we handle a plan step that partially fails? Voyager just tracks
> `failed_tasks: list[str]` and keeps trying. Is that good enough for enterprise?
> Or do we need retry logic, fallback steps, or escalation to a human?
> Don't design this until you hit the first real failure case in production.

### Sub-agents

Fan-out (parallel):
```python
def distribute(state) -> list[Send]:
    return [Send("process_item", {"item": x}) for x in state["items"]]
```

Handoff (sequential delegation):
```python
def worker(state):
    return Command(goto="supervisor", update={"result": output})
```

Cross-graph (sub-agent back to parent):
```python
return Command(graph=Command.PARENT, goto="orchestrator", update={...})
```

Each sub-agent has its own context window. State passes through overlapping TypedDict key names only. Checkpoint namespace: `parent_task:id|child_task:id`.

> **OPEN QUESTION (research when needed):**
> For long-running sub-agents (minutes to hours), should each be a separate
> LangGraph thread (separate `thread_id`) or a subgraph within the parent thread?
> Separate threads are isolated but harder to aggregate. Subgraphs are easier
> to aggregate but share the parent's context budget.

---

## THE ARMS

### What they are
Arms are how the agent touches the world. The model never directly calls anything — it always goes through a tool. There are two kinds: built-in tools (always available) and MCP tools (connected by the user or configured per deployment).

### Tool format

Every tool has exactly these fields (confirmed from OpenManus source + Playwright MCP):

```python
class BaseTool(ABC, BaseModel):
    name: str              # unique identifier, used by the model to call it
    description: str       # what the model reads to decide when to use this tool
    parameters: dict       # JSON Schema — what inputs it takes
    version: str = "1.0"  # we add this — none of the systems do, but schema drift is real
```

The `to_param()` method outputs the OpenAI function-calling format:
```python
{
    "type": "function",
    "function": {
        "name": self.name,
        "description": self.description,
        "parameters": self.parameters
    }
}
```

This is the universal standard. Every LLM provider (Bedrock, OpenAI, Anthropic) accepts it.

### Tool registry

```python
class ToolCollection:
    tools: tuple[BaseTool, ...]
    tool_map: dict[str, BaseTool]   # name → tool, for fast lookup

    def to_params(self) -> list[dict]:
        return [tool.to_param() for tool in self.tools]

    def execute(self, name: str, tool_input: dict) -> ToolResult:
        tool = self.tool_map.get(name)
        if not tool:
            return ToolFailure(error=f"Tool '{name}' is not available")
        return tool.execute(**tool_input)
```

**In-memory only.** No database. The code is the registry. All tools are sent to the model every turn (confirmed from OpenManus source — this is what every system does).

> **OPEN QUESTION (research when you have >20 tools):**
> OpenManus sends ALL tools every turn regardless of relevance. This works
> at small scale but burns tokens. When does this become a problem?
> At what tool count should we implement per-turn tool filtering?
> Karpathy would say: encode which tools are relevant in the graph structure
> (route to nodes that only have the relevant tools) rather than filtering at runtime.

### Built-in tools (always available)

These are Python classes in the repo. Registered at graph compile time.

| Tool | What it does | Status |
|---|---|---|
| `memory_read(user_id, query)` | Read from AgentCore Memory | Implement in v1 |
| `memory_write(user_id, key, value)` | Write to AgentCore Memory | Implement in v1 |
| `document_search(query)` | Semantic search in S3 Vectors | Implement in v1 |
| `skill_view(skill_id)` | Load full skill body on demand | Implement in v1 |
| `calculate(expression)` | Safe math evaluation | Implement in v1 |
| `file_read(path)` | Read from user's S3 workspace | Implement in v1 |
| `file_write(path, content)` | Write to user's S3 workspace | Implement in v1 |
| `spawn_subagent(task)` | Delegate to child LangGraph graph | Implement later |

### MCP tools (connected by user or configured per deployment)

Discovered at session start via `list_tools()`. Added to the same `ToolCollection`. Refreshed every N steps (OpenManus uses 5). Removed when the MCP server disconnects.

```python
# On session start
mcp_tools = await gateway.list_tools(session_id)
tool_collection.add_tools(*mcp_tools)

# Every N steps — refresh in case tools changed
updated = await gateway.list_tools(session_id)
tool_collection.sync(updated)   # add new, remove gone
```

MCP tools come through **AgentCore Gateway** (eu-west-2 ✅). Auth is handled by the Gateway. The agent never sees credentials.

If a tool doesn't exist: `ToolFailure(error="Tool 'X' is not available. The required MCP is not connected.")` — this is what goes back to the model and eventually to the user.

> **OPEN QUESTION (research before building MCP integration):**
> How does AgentCore Gateway actually expose MCP servers to LangGraph?
> Is it a standard MCP protocol endpoint we call, or a proprietary API?
> Read the AgentCore Gateway docs before implementing the MCP connection code.

### Tool execution rules

- Non-interactive tools: execute in parallel within the `execute_tools` node
  (confirmed from LangGraph source: v2 uses `Send` API per tool call)
- Interactive tools (require user confirmation): execute sequentially, trigger `interrupt()`
- Destructive tools (configured per skill's obligations): require approval before execution
- All tool calls: logged to audit trail before execution (not after — we need the pre-execution record)

### No browser automation

The agent does NOT control a real browser. All web interactions happen through:
- Web search MCPs (Brave Search API via Gateway)
- Service-specific MCPs (Google Drive, Calendar, booking services — whatever the user connects)
- If the MCP doesn't exist: "I don't have access to that service"

This is the right model. APIs are more reliable than browser scraping, and it's what the user confirmed they want.

---

## THE GATE

Every answer goes through the gate before reaching the user. The gate runs outside the model — the model cannot override it.

### Structure (from existing EAF code — keep this)

```python
def evaluate(draft: Draft, triggered_skills: tuple[Skill, ...]) -> GateResult:
    violations = []
    for skill in triggered_skills:
        for obligation in skill.obligations:
            detail = check(draft, obligation)  # pure function, no LLM
            if detail:
                violations.append(Violation(skill, obligation.kind, detail, obligation.blocking))
    return GateResult(violations=tuple(violations))
```

Fails closed: any error inside the gate blocks delivery.
Two modes: `observe` (log but deliver) and `enforce` (block).

### Obligation types implemented

- `must_cite` — answer must include sources
- `must_ask_when_missing` — ask rather than guess when context is absent
- `must_disclose` — include required disclosures when conditions hold
- `requires_approval_when` — tool call needs human approval
- `must_not_call` — tool is forbidden for this skill

Adding a new obligation type: one function in `obligations.py`. Available to all skills immediately.

---

## SKILLS

### Format (decided)

```markdown
---
name: skill_name                         # unique, snake_case
description: Max 60 chars — hard limit   # lives in stable prefix, every request pays
version: "1.0.0"                         # semantic versioning
required_tools:                          # validated at load — missing tool = skill fails
  - tool_name_1
  - tool_name_2
obligations:                             # machine-checkable, run through gate
  - must_cite: {contains: "source"}
---

Markdown guidance body.
Only loaded when this skill fires (skill_view tool call).
Never in the stable prefix.
```

### Lifecycle

```
S3 bucket (source of truth)
  ↓
Session start: load index (name + description only) → stable prefix
  ↓
User request matches skill: skill_view(skill_id) called
  ↓
Full body loaded → volatile tail of context
  ↓
Skill executes: tools called, answer produced
  ↓
Gate checks obligations on the answer
  ↓
Delivered or blocked
```

> **OPEN QUESTION (research before building skill management UI):**
> Voyager retrieves top-5 skills per turn via semantic search.
> Hermes puts all skill descriptions in the stable prefix.
> At what number of skills does "all descriptions in prefix" break down?
> (60 chars × 100 skills = 6,000 tokens in the stable prefix = always cached = cheap.)
> (60 chars × 1,000 skills = 60,000 tokens = potentially a problem.)
> Test empirically when you have more than 50 skills.

---

## MEMORY

| Tier | Technology | What it stores |
|---|---|---|
| Working | LangGraph state (in-context) | This conversation, tool results |
| Episodic | AgentCore Memory (eu-west-2 ✅) | User facts, preferences, past decisions |
| Semantic | S3 Vectors | Documents, knowledge corpus, RAG |
| Procedural | S3 + DynamoDB index | Skill files, tool definitions |

Start with Pattern B (paper recommendation): working + semantic only. Add episodic when you have evidence it improves outcomes.

> **OPEN QUESTION (research when episodic memory is needed):**
> The arxiv paper warns: "self-reinforcing error" — a false belief written to
> episodic memory blocks evidence collection forever. Severity scales with
> agent lifetime. How do we handle memory correction? What does AgentCore
> Memory's update/delete API look like? Read the AgentCore Memory docs
> before implementing the write path.

---

## USER ISOLATION

| Resource | Isolation mechanism |
|---|---|
| S3 files | Prefix: `/workspaces/{user_id}/{session_id}/` — IAM enforces this |
| AgentCore Memory | `user_id` parameter per call |
| LangGraph state | `thread_id` per conversation |
| MCP tool execution | Each invocation is isolated by AgentCore Runtime microVM |
| Code execution | Fresh microVM per invocation — no shared state |

The permissions boundary built in the EAF-DEV/EAF-PROD baseline layer is the ceiling. Even if a bug causes the agent to attempt cross-user access, the IAM policy blocks it at the AWS level.

Multi-tenancy (multiple companies): **not in v1**. Design for one user for now. When you productise, add `tenant_id` as the first prefix in the S3 path and namespace all AgentCore Memory calls by tenant.

---

## OPEN QUESTIONS SUMMARY

All questions to research when you actually hit them — not before:

1. **Failed plan step handling** — retry logic, fallback, or escalate to human?
2. **Long sub-agent threads** — separate `thread_id` or subgraph within parent?
3. **Tool count threshold** — when does "all tools every turn" become too expensive?
4. **AgentCore Gateway MCP protocol** — how exactly to connect MCP servers through it?
5. **Episodic memory write path** — how does AgentCore Memory handle corrections/deletions?
6. **Skill count threshold** — when does "all descriptions in prefix" stop being viable?
7. **Self-improvement loop** — when to implement (needs working agent + real usage patterns first)?

---

## WHAT IS NOT IN V1

| Feature | Deferred until |
|---|---|
| Self-improvement loop (skill proposals) | After agent has real usage to learn from |
| Knowledge graph (Neptune) | Only if relational queries prove necessary |
| Memory consolidation (episodic → semantic) | After episodic memory is live and measurable |
| Learned memory control (AgeMem) | After pattern B is insufficient by empirical measure |
| Multi-tenancy | Before productising |
| Step Functions DAG workflows | Only if linear plans prove insufficient |

---

## FUTURE ENGINEERING TOPICS

Topics from production agent research (DeepSeek, Kimi, Anthropic) that we must
tackle as the system matures. Ordered roughly by when they become relevant.

### Context Engineering ← highest priority future topic

Anthropic named this explicitly. Every production agent system hits this wall.
Context fills up, retrieval accuracy degrades (n² attention), and performance drops.

**Sub-topics to implement:**

| Topic | What it is | When we need it |
|---|---|---|
| **Compaction** | When context approaches the window limit, summarise the old conversation. Preserve: architectural decisions, unresolved errors, key facts. Discard: redundant tool outputs, superseded reasoning. | When multi-turn conversations start exceeding ~80k tokens |
| **JIT retrieval** | Never load the full content of a document into context upfront. Keep lightweight identifiers (file paths, URLs, chunk IDs). Fetch only the specific parts the agent actually needs, at the moment it needs them. | When skill bodies or retrieved documents are large |
| **Sub-agent isolation** | Each sub-agent gets a clean, minimal context window — not the parent's full history. Sub-agent does its work, returns a 1-2K token summary. Parent never sees the full trace. This prevents context from compounding across agent layers. | When we split into specialist agents (Phase 2) |
| **External memory** | Agent writes its own progress to files (NOTES.md equivalent) and reloads them across sessions. State that must survive context resets lives in files, not in the conversation. Already partially done via AgentCore Memory and S3. | When long-running multi-step tasks start dropping context |
| **Budget control** | Per-task token limits. If a task is approaching its budget, truncate and summarise rather than letting context explode. Kimi implemented this in RL training — we implement it in the agent loop. | When tasks run significantly longer than expected |
| **Context anxiety mitigation** | Models prematurely wrap up work as they approach their context limit. Anthropic solved this by compacting at ~80% full (not 100%) and by reloading context from external memory. | When we observe agents stopping tasks early |

**Research source:** Anthropic engineering blog — "Effective Context Engineering for AI Agents"

---

### Prompt injection protection

Every tool result that comes from the outside world (web search, file read, API response) is untrusted input. A malicious website could contain instructions designed to hijack the agent.

Anthropic runs a server-side prompt injection probe on all tool outputs before they enter the agent's context. On detection: warning injected instructing the agent to treat the content skeptically and re-anchor on the user's original intent.

**What to build:** A pre-processing step in the tool execution layer that scans tool outputs for instruction-shaped content before passing them to the LLM.

---

### Think tool

A minimal tool that gives the agent a mid-response scratchpad — not for external actions, just for reasoning between tool calls. Anthropic measured a 54% relative improvement in policy-heavy environments (like airline booking with many rules).

```python
@tool
def think(thought: str) -> str:
    """Use this to reason about tool results before deciding the next action."""
    return ""  # returns nothing — just logs the thought
```

Distinct from extended thinking (which is pre-response). Called after receiving a tool result to process what it means before deciding what to call next. Particularly useful for sequential tool chains where each step depends on reasoning about the previous step.

---

### Async multi-agent coordination

The current unresolved frontier. Both Anthropic and Kimi K2.5 acknowledge that subagent execution is currently **synchronous** — the orchestrator waits for a full batch before proceeding.

Kimi K2.5 measures this as "critical path length." The fastest path is the bottleneck.

For our system: when we parallelize across 10 research agents, the result takes as long as the slowest one. True async coordination (orchestrator receiving and acting on results as they arrive, not waiting for all) is not solved cleanly by anyone yet.

**What to research when we get to parallel agents:** LangGraph streaming, async task queues, result-driven orchestration.

---

### Massive parallel agents — file-based coordination

Anthropic's C compiler study: 16 parallel agents, NO orchestrator. Agents coordinate by claiming tasks via file locks in a shared git repo. No message queue, no shared memory, no direct inter-agent calls.

```
Agent wants a task:
  → write workspaces/tasks/task_name.lock
  → git commit + push
  → if push succeeds: task is mine
  → if push fails (someone else got it): try next task
```

This is the pattern for batch processing: "analyse 100 documents and find themes." 100 agent pods, S3 as the coordination layer, each pod claims files from a task list.

**When relevant:** when we need to process large document sets in parallel without building an orchestrator.

---

### Two-stage safety classifier

Anthropic uses a two-stage classifier on all non-trivial tool calls in auto mode:

- Stage 1: single-token yes/no, tuned to err toward blocking (fast, cheap)
- Stage 2: chain-of-thought reasoning, triggered only when Stage 1 flags (slow, expensive but rare)

The classifier sees: user messages + tool call payloads. It deliberately does NOT see: assistant prose, tool outputs, tool descriptions. Reason: prevents the agent from "talking the classifier into a bad call."

**When relevant:** when we add auto-mode (no human approval for any tool call).

---

## FIRST THING TO BUILD

Walking skeleton — confirms the architecture works end-to-end before adding anything:

```
LangGraph ReAct graph
  + one built-in tool: web_search (Brave API)
  + one skill: general_assistant (no obligations, just guidance)
  + working memory only (no episodic, no semantic yet)
  + gate (existing EAF obligations code, adapted)
  + no sub-agents, no MCP, no file system yet
```

Goal: user sends a message, agent searches the web, returns an answer. 
That's it. Everything else comes after this works.
