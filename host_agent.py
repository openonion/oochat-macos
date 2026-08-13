from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import os
import shlex
import stat
import sys
import threading
import time
import uuid
from pathlib import Path

from connectonion import (
    Agent,
    after_iteration,
    after_llm,
    after_tools,
    after_user_input,
    before_each_tool,
    before_iteration,
    host,
    llm_do,
    on_complete,
)
from connectonion import (
    bash as connectonion_bash,
)
from connectonion.useful_events_handlers import reflect
from connectonion.useful_plugins import (
    eval as eval_plugin,
)
from connectonion.useful_plugins import (
    handle_mode_change,
    image_result_formatter,
    runtime_input,
    system_reminder,
    tool_approval,
    ulw,
)
from connectonion.useful_plugins.ulw import handle_ulw_mode_change
from connectonion.useful_tools import ask_user
from connectonion.useful_tools import edit as connectonion_edit
from connectonion.useful_tools import glob as connectonion_glob
from connectonion.useful_tools import grep as connectonion_grep
from connectonion.useful_tools import multi_edit as connectonion_multi_edit
from connectonion.useful_tools import write as connectonion_write
from connectonion.useful_tools.read_file import read_file as connectonion_read_file


def _interrupt_safe_agent_thread_body(
    route_handlers, storage, prompt, io, session, images, files,
    registry, session_id, result_holder,
):
    """Run the agent and always flip its session out of 'running'.

    Mirrors connectonion's ws_router thread body, but marks the session
    connected in a finally so an interrupt (which unwinds agent.input() via
    UserInterrupt) still returns the session to a reusable state instead of
    leaving it stuck 'running'. See [_install_interrupt_session_state_fix].
    """
    try:
        result_holder[0] = route_handlers["ws_input"](
            storage, prompt, io, session, images, files
        )
    except Exception as error:
        result_holder[0] = error
    finally:
        registry.mark_session_connected(session_id)
        io.mark_agent_done()


EXPECTED_CONNECTONION_VERSION = "1.5.11"

# How _install_interrupt_session_state_fix fared, read by the server entry point.
# Import-time installation never raises, so unit tests that stub `connectonion`
# keep importing this module cleanly; the startup path escalates a real-but-
# broken install.
_INTERRUPT_FIX_STATUS = "pending"


def _connectonion_looks_real() -> bool:
    """True when the imported `connectonion` is the real, versioned package.

    Unit tests stub `connectonion` with a bare module that has no __version__,
    so this separates a benign test double from a real package whose internals
    have moved out from under the interrupt fix.
    """
    try:
        import connectonion
    except ImportError:
        return False
    return isinstance(getattr(connectonion, "__version__", None), str)


def _install_interrupt_session_state_fix() -> None:
    """Flip a session out of 'running' even when its run ends by interrupt.

    connectonion 1.5.11's ws_router thread body only calls
    mark_session_connected() on the success path (agent_io._agent_thread_body).
    An interrupt unwinds agent.input() via UserInterrupt, so that call is
    skipped and the registry keeps the session marked 'running' forever. Every
    later INPUT is then misrouted as a mid-execution runtime input into the dead
    run and never answered — the agent appears alive but silently ignores all
    following messages. Swap in a thread body that flips the session to
    'connected' in a finally. Safe to drop once upstream makes the same
    guarantee; the ready-to-file upstream fix and report live in
    docs/upstream/connectonion-interrupt-session-state.md.

    Never raises: an import-time failure is recorded in _INTERRUPT_FIX_STATUS and
    escalated later by _verify_interrupt_session_state_fix on the server path, so
    stubbed unit tests keep importing this module cleanly.
    """
    global _INTERRUPT_FIX_STATUS
    try:
        from connectonion.network.host.ws_router import agent_io
    except (ImportError, AttributeError):
        # Either a unit-test stub (benign) or a real connectonion whose internals
        # moved (dangerous — the fix would silently do nothing). Tell them apart
        # so the server path can fail loudly only on the dangerous case.
        _INTERRUPT_FIX_STATUS = (
            "target_missing" if _connectonion_looks_real() else "absent_package"
        )
        return

    if not callable(getattr(agent_io, "_agent_thread_body", None)):
        _INTERRUPT_FIX_STATUS = "target_missing"
        return

    agent_io._agent_thread_body = _interrupt_safe_agent_thread_body
    # Self-check: a swap that did not take would silently corrupt session state.
    _INTERRUPT_FIX_STATUS = (
        "applied"
        if agent_io._agent_thread_body is _interrupt_safe_agent_thread_body
        else "target_missing"
    )


def _verify_interrupt_session_state_fix() -> None:
    """Fail fast on the server path if the interrupt fix is not active.

    Import-time installation stays silent so stubbed unit tests are unaffected.
    This runs only from the server entry point, where a real connectonion whose
    internals moved must stop the process rather than leak 'running' sessions
    that swallow every message sent after an interrupt.
    """
    import connectonion

    version = getattr(connectonion, "__version__", "unknown")
    if _INTERRUPT_FIX_STATUS != "applied":
        print(
            "fatal: the interrupt session-state fix did not install "
            f"(status={_INTERRUPT_FIX_STATUS}, connectonion={version}). The "
            "hosted agent would leak 'running' sessions on interrupt and then "
            "silently ignore every following message. Expected connectonion=="
            f"{EXPECTED_CONNECTONION_VERSION}; rebuild the image against the "
            "pinned requirements.",
            file=sys.stderr,
        )
        raise SystemExit(78)
    if version != EXPECTED_CONNECTONION_VERSION:
        print(
            f"warning: connectonion {version} differs from the validated "
            f"{EXPECTED_CONNECTONION_VERSION}; the interrupt fix applied but is "
            "only verified against the pinned version.",
            file=sys.stderr,
        )
    else:
        print(f"Interrupt session-state fix active (connectonion {version}).")


_install_interrupt_session_state_fix()


AGENT_NAME = os.environ.get("CONNECTONION_AGENT_NAME", "my-agent")
HOST_AGENT_ROOT = Path(__file__).resolve().parent
HOST_SYSTEM_PROMPT_PATH = HOST_AGENT_ROOT / "prompts" / "host_agent.md"
GLOBAL_CO_DIR = Path.home() / ".co"
UPLOAD_ROOT = GLOBAL_CO_DIR / "uploads"
DEFAULT_TOOLSETS = ("workspace", "web", "todo")
ALL_LOCAL_TOOLSETS = ("workspace", "web", "todo", "memory", "browser")
SUPPORTED_TOOLSETS = frozenset(
    (
        *ALL_LOCAL_TOOLSETS,
        "diff_writer",
        "gmail",
        "agent_email",
        "google_calendar",
        "outlook",
        "microsoft_calendar",
    )
)

WORKSPACE_ROOT = Path(
    os.environ.get("CONNECTONION_WORKSPACE", "/agent-work")
).expanduser().resolve()
MAX_EXPORTED_ARTIFACTS = 10
MAX_EXPORTED_ARTIFACT_BYTES = 8 * 1024 * 1024
_ARTIFACT_PAYLOADS: dict[str, dict] = {}
_ARTIFACT_PAYLOADS_LOCK = threading.Lock()
_ARTIFACT_REQUEST_STATE = threading.local()

ULW_TURNS = 10
# Response strategy per request. These name what actually happens here, not the
# ReAct/Reflect reasoning patterns: DIRECT answers immediately; TASK is an
# understood task (eval applies); PLAN additionally emits a visible plan first.
STRATEGY_DIRECT = "direct"
STRATEGY_TASK = "task"
STRATEGY_PLAN = "plan"

# Auxiliary plan generation is a cheap side call, kept independent of the main
# agent model so switching CONNECTONION_MODEL never forces it onto a heavy model.
PLAN_MODEL_DEFAULT = "co/gemini-2.5-flash"

# System prompt for the leading acknowledgment (ReAct "understanding" step).
# Inlined so the handler never depends on ConnectOnion's prompt file, which the
# test harness does not stub.
_ACKNOWLEDGE_SYSTEM_PROMPT = (
    "You acknowledge the user's request in 1-2 short sentences before the "
    "assistant begins working. Confirm what you are about to do in a warm, "
    "first-person voice (for example, \"Got it, I'll…\" or \"Understood, "
    "I'll…\"). Do not answer the request, do not ask questions, and never "
    "expose private chain-of-thought."
)

# Browser tool that blocks on interactive terminal input, so it is unusable in a
# hosted session and removed after the agent is built.
BROWSER_TERMINAL_ONLY_TOOL = "wait_for_manual_login"

# Obvious requests are routed locally to avoid an extra LLM call before the main
# agent. The main model still decides whether and how to use tools.
_TRIVIAL_INPUTS = frozenset(
    {
        "hi",
        "hello",
        "hey",
        "thanks",
        "thank you",
        "你好",
        "您好",
        "谢谢",
    }
)
_BUILD_TASK_MARKERS = (
    "implement",
    "build",
    "create",
    "add feature",
    "change",
    "modify",
    "update",
    "refactor",
    "debug",
    "fix",
    "migrate",
    "实现",
    "开发",
    "创建",
    "新增",
    "修改",
    "更新",
    "重构",
    "调试",
    "修复",
    "迁移",
)
_TOOL_TASK_MARKERS = (
    "search",
    "look up",
    "browse",
    "open the url",
    "read file",
    "run command",
    "system info",
    "current",
    "latest",
    "today",
    "weather",
    "price",
    "news",
    "搜索",
    "查找",
    "浏览",
    "打开网址",
    "读取文件",
    "运行命令",
    "系统信息",
    "当前",
    "最新",
    "今天",
    "天气",
    "价格",
    "新闻",
    "http://",
    "https://",
)


def _plugin_handler(plugin: list, name: str):
    """Resolve a public plugin handler by name instead of fragile list position."""
    handler = next(
        (candidate for candidate in plugin if getattr(candidate, "__name__", "") == name),
        None,
    )
    if handler is None:
        raise RuntimeError(f"ConnectOnion plugin handler '{name}' is unavailable")
    return handler


EVAL_GENERATE_HANDLER = _plugin_handler(eval_plugin, "generate_expected")
EVAL_COMPLETE_HANDLER = _plugin_handler(eval_plugin, "evaluate_completion")
VALID_EXECUTION_MODES = frozenset({"safe", "plan", "ulw"})
PLAN_MODE_ADDITIONAL_BLOCKED_TOOLS = frozenset({"export_file"})
REFLECTION_OFF = "off"
REFLECTION_ON_FAILURE = "on_failure"
REFLECTION_ALWAYS = "always"


class UserInterrupt(RuntimeError):
    """Stop a tool batch without treating a user cancellation as a tool failure."""


def enter_plan_mode(agent) -> str:
    """Enter the host's read-only planning mode for the current session."""
    session = agent.current_session
    if session.get("mode") != "plan":
        session["previous_mode"] = session.get("mode", "safe")
    session["mode"] = "plan"
    if not session.get("plan_path"):
        session_id = str(
            session.get("session_id")
            or session.get("id")
            or uuid.uuid4().hex
        )
        safe_session_id = "".join(
            character
            for character in session_id
            if character.isalnum() or character in {"-", "_"}
        ) or uuid.uuid4().hex
        session["plan_path"] = f".co/PLAN_{safe_session_id}.md"
    io = getattr(agent, "io", None)
    if io:
        io.send({"type": "mode_changed", "mode": "plan"})
    _checkpoint(agent)
    return (
        "Plan Mode enabled. Inspect with read-only tools, write the plan with "
        "write_plan, then call exit_plan_and_implement for user review."
    )


def write_plan(plan: str, agent) -> str:
    """Persist the proposed implementation inside the private workspace."""
    if agent.current_session.get("mode") != "plan":
        return "Error: write_plan is available only in Plan Mode."
    if not isinstance(plan, str) or not plan.strip():
        return "Error: plan must not be empty."

    plan_path = agent.current_session.get("plan_path")
    if not isinstance(plan_path, str) or not plan_path:
        enter_plan_mode(agent)
        plan_path = agent.current_session["plan_path"]
    target = resolve_workspace_path(plan_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(plan.strip() + "\n", encoding="utf-8")
    _checkpoint(agent)
    return f"Plan saved to {plan_path}."


def exit_plan_and_implement(agent) -> str:
    """Finish planning and return the saved proposal for explicit user review."""
    session = agent.current_session
    plan_path = session.get("plan_path")
    if not isinstance(plan_path, str) or not plan_path:
        return "Error: no plan has been created."
    target = resolve_workspace_path(plan_path)
    if not target.is_file():
        return "Error: write the plan before leaving Plan Mode."

    plan = target.read_text(encoding="utf-8").strip()
    session["mode"] = "safe"
    session.pop("previous_mode", None)
    io = getattr(agent, "io", None)
    if io:
        io.send({"type": "mode_changed", "mode": "safe"})
    _checkpoint(agent)
    return (
        "Plan ready for user review. Do not make changes until the user approves "
        f"the plan or selects Accept mode.\n\n{plan}"
    )


def env_flag(name: str, default: bool = False) -> bool:
    """Read a conventional boolean environment flag."""
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def online_eval_enabled() -> bool:
    """Online LLM-as-judge evaluation is opt-in because it adds cost and latency."""
    return env_flag("CONNECTONION_ENABLE_EVAL")


def acknowledge_enabled() -> bool:
    """The leading one-line acknowledgment (ReAct 'understanding') is on by
    default. Each turn spends one fast auxiliary LLM call on it, so deployments
    that want to save cost/latency can disable it with CONNECTONION_ACKNOWLEDGE=0.
    """
    return env_flag("CONNECTONION_ACKNOWLEDGE", default=True)


def acknowledge_model() -> str:
    """Model for the acknowledgment side call, overridable per deployment."""
    configured = os.environ.get("CONNECTONION_ACKNOWLEDGE_MODEL", "").strip()
    return configured or plan_model()


def plan_model() -> str:
    """Return the model for auxiliary plan generation, overridable per deployment."""
    configured_model = os.environ.get("CONNECTONION_PLAN_MODEL", "").strip()
    return configured_model or PLAN_MODEL_DEFAULT


def reflection_mode() -> str:
    """Return the configured reflection policy with a conservative default."""
    value = os.environ.get(
        "CONNECTONION_REFLECTION_MODE",
        REFLECTION_ON_FAILURE,
    ).strip().lower()
    if value not in {REFLECTION_OFF, REFLECTION_ON_FAILURE, REFLECTION_ALWAYS}:
        return REFLECTION_ON_FAILURE
    return value


def _checkpoint(agent) -> None:
    """Persist the session when hosted storage is available."""
    storage = getattr(agent, "storage", None)
    if storage:
        storage.checkpoint(agent.current_session)


def _update_run_state(agent, phase: str, status: str = "running", **details) -> dict:
    """Maintain one serializable run record for recovery and cancellation."""
    state = agent.current_session.setdefault(
        "run_state",
        {
            "run_id": uuid.uuid4().hex,
            "status": "running",
            "phase": "preparing",
            "mode": agent.current_session.get("mode", "safe"),
        },
    )
    state.update(status=status, phase=phase)
    state.update(details)
    return state


@after_user_input
def initialize_run_state(agent) -> None:
    """Start a fresh checkpointable run after each user request."""
    _reset_artifact_budget()
    agent.current_session.pop("stop_signal", None)
    # This runs first among after_user_input handlers, so messages ends exactly
    # with the user message the core just appended and before acknowledge/plan
    # add anything. Remember that boundary so an interrupt can truncate every
    # message this turn adds and leave the history well-formed.
    agent.current_session["interrupt_turn_mark"] = len(
        agent.current_session.get("messages", [])
    )
    agent.current_session["run_state"] = {
        "run_id": uuid.uuid4().hex,
        "status": "running",
        "phase": "preparing",
        "mode": agent.current_session.get("mode", "safe"),
        "cancel_requested": False,
    }
    _checkpoint(agent)


@on_complete
def finalize_run_state(agent) -> None:
    """Mark the durable run state before the hosted result is returned."""
    state = _update_run_state(agent, "finished")
    if state.get("cancel_requested"):
        state.update(status="cancelled", phase="cancelled")
    else:
        state.update(status="completed", phase="finished")
    _checkpoint(agent)


def _is_trivial_input(user_prompt: str) -> bool:
    """Greetings and empty input can be answered directly without understanding."""
    normalized = " ".join(user_prompt.lower().split())
    if not normalized:
        return True
    return normalized.strip(".!?。！？") in _TRIVIAL_INPUTS


def _local_reasoning_strategy(user_prompt: str) -> str:
    """Route obvious requests without paying for a separate intent classifier."""
    normalized = " ".join(user_prompt.lower().split())
    if _is_trivial_input(normalized):
        return STRATEGY_DIRECT
    if any(marker in normalized for marker in _BUILD_TASK_MARKERS):
        return STRATEGY_PLAN
    if any(marker in normalized for marker in _TOOL_TASK_MARKERS):
        return STRATEGY_TASK
    if len(normalized) > 200 or any(
        separator in normalized
        for separator in (" and then ", " then ", "并且", "然后", "\n- ", "\n1.")
    ):
        return STRATEGY_TASK
    return STRATEGY_DIRECT


@after_user_input
def route_reasoning_strategy(agent) -> None:
    """Select a response strategy locally without blocking on a side LLM call."""
    session = agent.current_session
    session.pop("intent", None)
    session["reasoning_strategy"] = _local_reasoning_strategy(
        session.get("user_prompt", "")
    )


@after_user_input
def acknowledge_request(agent) -> None:
    """Emit a short "I understood" sentence before the main answer — the leading
    line of the ReAct-style thought chain. Rendered by the client as an intent
    row (thinking/kind=intent). Skipped for trivial input and when disabled."""
    if not acknowledge_enabled():
        return

    user_prompt = agent.current_session.get("user_prompt", "")
    if not user_prompt or _is_trivial_input(user_prompt):
        return

    try:
        ack = str(
            llm_do(
                f"Current user input: {user_prompt}\n\n"
                "Acknowledge this request in 1-2 sentences.",
                model=acknowledge_model(),
                temperature=0.3,
                system_prompt=_ACKNOWLEDGE_SYSTEM_PROMPT,
            )
        ).strip()
    except Exception:
        # Acknowledgment is best-effort polish; never fail the turn over it.
        return
    if not ack:
        return

    agent._record_trace(
        {
            "type": "thinking",
            "kind": "intent",
            "content": ack,
        }
    )
    # Let the main model see its own acknowledgment for a coherent continuation.
    agent.current_session.setdefault("messages", []).append(
        {
            "role": "assistant",
            "content": ack,
            # This sentence is execution UI, not a second assistant reply.
            # Keep it in the model context while preventing durable-history
            # clients from importing it as a normal chat message.
            "internal": True,
        }
    )


@after_user_input
def generate_plan(agent) -> None:
    """Create a plan that is both visible and available to the main model."""
    if agent.current_session.get("reasoning_strategy") != STRATEGY_PLAN:
        return

    user_prompt = agent.current_session.get("user_prompt", "")
    try:
        plan = str(
            llm_do(
                "Write a concise, user-visible execution plan for this request. "
                "Use 1-3 sentences, mention the main actions and verification, and "
                "do not expose private chain-of-thought.\n\n"
                f"Request: {user_prompt}",
                model=plan_model(),
                temperature=0.2,
            )
        ).strip()
    except Exception as error:
        _update_run_state(agent, "plan_skipped", plan_error=str(error))
        return
    if not plan:
        return
    agent._record_trace(
        {
            "type": "thinking",
            "kind": "plan",
            "content": plan,
        }
    )
    agent.current_session.setdefault("messages", []).append(
        {
            "role": "assistant",
            "content": f"Execution plan: {plan}",
        }
    )
    _update_run_state(agent, "planned", plan_summary=plan)


def _tool_results(agent) -> list[dict]:
    return [
        entry
        for entry in agent.current_session.get("trace", [])
        if entry.get("type") == "tool_result"
    ]


def _reflection_required(agent) -> bool:
    """Reflect only on failure/no-progress unless explicitly configured otherwise."""
    mode = reflection_mode()
    if mode == REFLECTION_OFF:
        return False

    results = _tool_results(agent)
    if not results:
        return False
    if mode == REFLECTION_ALWAYS:
        return True

    latest = results[-1]
    if latest.get("status") != "success":
        return True
    if len(results) < 2:
        return False

    previous = results[-2]
    return (
        latest.get("name") == previous.get("name")
        and latest.get("args") == previous.get("args")
        and latest.get("result") == previous.get("result")
    )


@after_tools
def reflect_when_needed(agent) -> None:
    """Run event-driven reflection without feeding it back as assistant history."""
    if (
        agent.current_session.get("stop_signal") == "user_interrupt"
        or not _reflection_required(agent)
    ):
        return

    # Reflection is surfaced through the trace only; restore the message list to
    # its exact pre-reflection state so it is never fed back as assistant history.
    messages = agent.current_session.get("messages", [])
    messages_snapshot = list(messages)
    try:
        reflect(agent)
    finally:
        messages[:] = messages_snapshot

    reflection = next(
        (
            entry.get("content")
            for entry in reversed(agent.current_session.get("trace", []))
            if entry.get("type") == "thinking"
            and entry.get("kind") == "reflect"
        ),
        None,
    )
    if reflection:
        _update_run_state(agent, "reflecting", reflection_summary=reflection)


@after_user_input
def generate_expected_when_needed(agent) -> None:
    """Run online expected-output generation only when explicitly enabled."""
    if (
        online_eval_enabled()
        and agent.current_session.get("reasoning_strategy") != STRATEGY_DIRECT
    ):
        EVAL_GENERATE_HANDLER(agent)


@on_complete
def evaluate_when_needed(agent) -> None:
    """Run online completion grading only when explicitly enabled."""
    if (
        online_eval_enabled()
        and agent.current_session.get("reasoning_strategy") != STRATEGY_DIRECT
    ):
        EVAL_COMPLETE_HANDLER(agent)


REASONING_ROUTER_PLUGIN = [route_reasoning_strategy]
CONDITIONAL_SYSTEM_REMINDER_PLUGIN = system_reminder
ADAPTIVE_REASONING_PLUGIN = [acknowledge_request, generate_plan, reflect_when_needed]
CONDITIONAL_EVAL_PLUGIN = [generate_expected_when_needed, evaluate_when_needed]
RUN_STATE_PLUGIN = [initialize_run_state, finalize_run_state]


def _reset_artifact_budget() -> None:
    """Discard unclaimed exports and begin a fresh per-request transfer budget."""
    pending_ids = getattr(_ARTIFACT_REQUEST_STATE, "pending_ids", set())
    if pending_ids:
        with _ARTIFACT_PAYLOADS_LOCK:
            for artifact_id in pending_ids:
                _ARTIFACT_PAYLOADS.pop(artifact_id, None)
    _ARTIFACT_REQUEST_STATE.count = 0
    _ARTIFACT_REQUEST_STATE.total_bytes = 0
    _ARTIFACT_REQUEST_STATE.pending_ids = set()


def _artifact_metadata(payload: dict) -> dict:
    return {
        key: payload[key]
        for key in (
            "artifact_id",
            "name",
            "mime_type",
            "size_bytes",
            "sha256",
        )
    }


def _artifact_from_tool_result(result) -> dict | None:
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except (TypeError, ValueError, json.JSONDecodeError):
            return None
    if not isinstance(result, dict) or result.get("exported") is not True:
        return None
    artifact_id = result.get("artifact_id")
    if not isinstance(artifact_id, str):
        return None
    with _ARTIFACT_PAYLOADS_LOCK:
        return _ARTIFACT_PAYLOADS.pop(artifact_id, None)


@after_tools
def publish_exported_artifacts(agent) -> None:
    """Move exported bytes to transport/session storage without model exposure."""
    generated = agent.current_session.setdefault("generated_artifacts", [])
    known_ids = {
        item.get("artifact_id")
        for item in generated
        if isinstance(item, dict)
    }
    for entry in _tool_results(agent):
        if entry.get("name") != "export_file" or entry.get("status") == "error":
            continue
        result = entry.get("result")
        result_object = None
        if isinstance(result, str):
            try:
                result_object = json.loads(result)
            except (TypeError, ValueError, json.JSONDecodeError):
                continue
        elif isinstance(result, dict):
            result_object = result
        if not isinstance(result_object, dict):
            continue
        artifact_id = result_object.get("artifact_id")
        if artifact_id in known_ids:
            continue

        payload = _artifact_from_tool_result(result_object)
        if payload is None:
            continue
        generated.append(payload)
        known_ids.add(payload["artifact_id"])
        pending_ids = getattr(_ARTIFACT_REQUEST_STATE, "pending_ids", set())
        pending_ids.discard(payload["artifact_id"])
        io = getattr(agent, "io", None)
        if io:
            io.send({"type": "agent_artifact", "artifact": payload})
    _checkpoint(agent)


ARTIFACT_EXPORT_PLUGIN = [publish_exported_artifacts]


# These hooks unwind the run with UserInterrupt at every boundary instead of
# relying on connectonion's native stop_signal / on_stop_signal path, and that is
# deliberate — the native path is strictly weaker here. The loop (core/agent.py)
# checks stop_signal only once per iteration, after a full tool round, so it never
# sees a tool-free final answer (the loop returns that before the check) and it
# resolves the turn with a canned "What would you like me to do?" string rather
# than a clean interrupt. Raising UserInterrupt at after_llm / before_tool /
# after_tools / after_iteration stops on the next safe seam in every case and lets
# _consume_interrupt send the ack/complete and repair history first. Do not
# "simplify" this into on_stop_signal — it would regress interrupt responsiveness.
@after_llm
def stop_after_llm(agent) -> None:
    """Honor a cancellation the instant the model finishes generating.

    The iteration loop returns a tool-free final answer before after_iteration
    ever fires, so an interrupt polled only at after_iteration never sees that
    turn and the completed answer is emitted anyway. after_llm runs on every
    iteration right after llm.complete() returns and before the answer is
    surfaced, so this is the boundary that also covers the final answer.
    """
    if _consume_interrupt(agent, phase="after_llm"):
        raise UserInterrupt("Interrupted by user")


@before_each_tool
def stop_before_next_tool(agent) -> None:
    """Prevent a queued tool from starting after a cancellation request."""
    if _consume_interrupt(agent, phase="before_tool"):
        raise UserInterrupt("Interrupted by user")


@after_tools
def stop_after_tool_batch(agent) -> None:
    """Stop before the next model iteration when cancellation arrived mid-tool."""
    if _consume_interrupt(agent, phase="after_tools"):
        raise UserInterrupt("Interrupted by user")


@after_iteration
def stop_after_iteration(agent) -> None:
    """Catch cancellation that arrived while the model was running."""
    if _consume_interrupt(agent, phase="after_iteration"):
        raise UserInterrupt("Interrupted by user")


INTERRUPTED_TURN_CLOSING = "(Stopped by user.)"


def _repair_interrupted_history(agent) -> None:
    """Leave the conversation well-formed after an interrupt unwinds the run.

    The core appends the user message (and, for a tool turn, an assistant message
    carrying tool_calls) before the boundary that raises UserInterrupt, but the
    matching assistant reply / tool_result never lands. Truncating back to the
    turn mark drops everything this turn added after the user message — including
    a dangling tool_call block that would otherwise reach the model unpaired — and
    a single closing assistant message keeps the turn from ending on a user role.
    """
    session = agent.current_session
    session_messages = session.get("messages")
    if session_messages is None:
        return

    mark = session.get("interrupt_turn_mark")
    if isinstance(mark, int) and 0 <= mark <= len(session_messages):
        del session_messages[mark:]

    if not session_messages or session_messages[-1].get("role") != "assistant":
        session_messages.append(
            {"role": "assistant", "content": INTERRUPTED_TURN_CLOSING}
        )


def _consume_interrupt(agent, phase: str) -> bool:
    """Use one cancellation primitive at every safe execution boundary."""
    io = getattr(agent, "io", None)
    messages = io.receive_all("INTERRUPT") if io else []
    if not messages:
        return False

    observed_at_ms = int(time.time() * 1000)
    requested_at_ms = next(
        (
            value
            for message in reversed(messages)
            if isinstance(message, dict)
            and isinstance((value := message.get("requested_at_ms")), int)
        ),
        observed_at_ms,
    )
    latency_ms = max(0, observed_at_ms - requested_at_ms)
    # Echo the client's input_id back on the ack/complete so the client can match
    # each frame to the exact run it interrupted. A stale frame from an abandoned
    # run that replays onto a later request's socket then carries the old id and
    # is rejected by identity, even when that later turn is itself interrupting.
    input_id = next(
        (
            value
            for message in reversed(messages)
            if isinstance(message, dict)
            and isinstance((value := message.get("input_id")), str)
        ),
        None,
    )

    state = _update_run_state(
        agent,
        "cancelling",
        status="cancelling",
        cancel_requested=True,
        cancel_boundary=phase,
        interrupt_requested_at_ms=requested_at_ms,
        interrupt_observed_at_ms=observed_at_ms,
        interrupt_latency_ms=latency_ms,
    )
    agent.current_session["stop_signal"] = "user_interrupt"
    _repair_interrupted_history(agent)
    _checkpoint(agent)
    acknowledgement = {
        "type": "interrupt_ack",
        "run_id": state["run_id"],
        "phase": phase,
        "latency_ms": latency_ms,
    }
    if input_id is not None:
        acknowledgement["input_id"] = input_id
    io.send(acknowledgement)
    state.update(status="cancelled", phase="cancelled")
    _checkpoint(agent)
    completion = {
        "type": "interrupt_complete",
        "run_id": state["run_id"],
        "phase": phase,
    }
    if input_id is not None:
        completion["input_id"] = input_id
    io.send(completion)
    return True


INTERRUPT_CONTROLLER_PLUGIN = [
    stop_after_llm,
    stop_before_next_tool,
    stop_after_tool_batch,
]


def _clear_inactive_mode_state(agent, next_mode: str) -> None:
    session = agent.current_session
    session.pop("plan_path", None)
    session.pop("previous_mode", None)
    if next_mode != "ulw":
        for key in (
            "ulw_turns",
            "ulw_turns_used",
            "ulw_prompt",
            "skip_tool_approval",
        ):
            session.pop(key, None)


def transition_execution_mode(agent, mode: str, *, notify: bool = False) -> None:
    """Transition to exactly one execution mode and discard stale mode state."""
    if mode not in VALID_EXECUTION_MODES:
        return

    previous_mode = agent.current_session.get("mode", "safe")
    _clear_inactive_mode_state(agent, mode)
    if mode == "ulw":
        handle_ulw_mode_change(agent, turns=ULW_TURNS)
    elif mode == "plan":
        agent.current_session["mode"] = "safe"
        enter_plan_mode(agent=agent)
    else:
        handle_mode_change(agent, "safe")
        agent.current_session["mode"] = "safe"
        if notify and previous_mode != "safe" and getattr(agent, "io", None):
            agent.io.send(
                {
                    "type": "mode_changed",
                    "mode": "safe",
                    "triggered_by": "user",
                }
            )
    state = agent.current_session.get("run_state")
    if isinstance(state, dict):
        state["mode"] = mode
    _checkpoint(agent)


@after_user_input
def apply_client_mode_request(agent) -> None:
    """Apply the mode selected before an idle hosted session starts."""
    request = agent.current_session.pop("client_mode_request", None)
    if not isinstance(request, dict):
        return

    transition_execution_mode(agent, request.get("mode", ""))


def _apply_pending_execution_mode_changes(agent) -> None:
    """Drain live mode changes through the exclusive mode state machine."""
    if not getattr(agent, "io", None):
        return
    for request in agent.io.receive_all("mode_change"):
        transition_execution_mode(
            agent,
            request.get("mode", ""),
            notify=True,
        )


@before_iteration
def poll_execution_mode_changes(agent) -> None:
    """Apply mode changes before the next model iteration starts."""
    _apply_pending_execution_mode_changes(agent)


@before_each_tool
def poll_execution_mode_changes_before_tool(agent) -> None:
    """Close the race between an in-flight LLM call and its first tool."""
    _apply_pending_execution_mode_changes(agent)


MODE_CONTROLLER_PLUGIN = [
    apply_client_mode_request,
    poll_execution_mode_changes,
    poll_execution_mode_changes_before_tool,
]


@before_each_tool
def enforce_plan_mode_read_only(agent) -> None:
    """Block side effects in Plan even when a tool was approved previously."""
    session = agent.current_session
    if session.get("mode") != "plan":
        return

    pending = session.get("pending_tool")
    if not isinstance(pending, dict):
        return

    tool_name = pending.get("name")
    if not isinstance(tool_name, str):
        return

    from connectonion.useful_plugins.tool_approval.constants import (
        DANGEROUS_TOOLS,
    )

    if (
        tool_name in DANGEROUS_TOOLS
        or tool_name in PLAN_MODE_ADDITIONAL_BLOCKED_TOOLS
    ):
        raise ValueError(
            f"Tool '{tool_name}' is blocked in Plan Mode. "
            "Plan Mode can inspect and prepare a plan, but cannot execute "
            "commands, modify data, or export files."
        )


PLAN_MODE_GUARD_PLUGIN = [enforce_plan_mode_read_only]


HOST_TOOL_APPROVAL_PLUGIN = [
    handler
    for handler in tool_approval
    if getattr(handler, "__name__", "") != "poll_mode_changes"
]


ULW_COMPLETE_HANDLER = next(
    (
        handler
        for handler in ulw
        if getattr(handler, "__name__", "") == "ulw_keep_working"
    ),
    None,
)


@on_complete
def continue_ulw_unless_cancelled(agent) -> None:
    """Do not let autonomous continuation restart a cancelled run."""
    state = agent.current_session.get("run_state", {})
    if state.get("cancel_requested") or agent.current_session.get(
        "stop_signal"
    ) == "user_interrupt":
        return
    if ULW_COMPLETE_HANDLER:
        ULW_COMPLETE_HANDLER(agent)


HOST_ULW_PLUGIN = [
    continue_ulw_unless_cancelled,
    *[
        handler
        for handler in ulw
        if handler is not ULW_COMPLETE_HANDLER
    ],
]


def max_fetch_chars() -> int:
    try:
        return max(1000, int(os.environ.get("CONNECTONION_MAX_FETCH_CHARS", "16000")))
    except ValueError:
        return 16000


def resolve_workspace_path(relative_path: str) -> Path:
    """Resolve a relative path and prevent access outside the workspace."""
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise ValueError("Path must not be empty")

    requested = Path(relative_path)
    if requested.is_absolute():
        raise ValueError("Only workspace-relative paths are allowed")

    resolved = (WORKSPACE_ROOT / requested).resolve()

    try:
        resolved.relative_to(WORKSPACE_ROOT)
    except ValueError as error:
        raise PermissionError("Path escapes the configured workspace") from error

    return resolved


def _workspace_error(error: Exception) -> str:
    return f"Error: Workspace access denied: {error}"


def _validate_workspace_pattern(pattern: str) -> None:
    """Reject glob-like patterns that can address files outside the workspace."""
    if not isinstance(pattern, str) or not pattern.strip():
        raise ValueError("Pattern must not be empty")
    requested = Path(pattern)
    if requested.is_absolute():
        raise ValueError("Only workspace-relative patterns are allowed")
    if ".." in requested.parts:
        raise PermissionError("Pattern escapes the configured workspace")


def _validate_workspace_matches(base: Path, pattern: str) -> None:
    """Reject any glob result that resolves beyond the configured workspace."""
    for candidate in base.glob(pattern):
        try:
            candidate.resolve().relative_to(WORKSPACE_ROOT)
        except ValueError as error:
            raise PermissionError(
                "Pattern follows a symbolic link outside the configured workspace"
            ) from error


def read_file(path: str) -> str:
    """Read one workspace-relative file with the official document reader."""
    try:
        resolved = resolve_workspace_path(path)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_read_file(str(resolved))


def glob(pattern: str, path: str | None = None) -> str:
    """Find files below a workspace-relative directory."""
    try:
        _validate_workspace_pattern(pattern)
        resolved = resolve_workspace_path(path or ".")
        _validate_workspace_matches(resolved, pattern)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_glob(pattern, path=str(resolved))


def grep(
    pattern: str,
    path: str | None = None,
    file_pattern: str | None = None,
    output_mode: str = "files",
    context_lines: int = 0,
    ignore_case: bool = False,
    max_results: int = 50,
) -> str:
    """Search text only below a workspace-relative directory."""
    try:
        resolved = resolve_workspace_path(path or ".")
        if file_pattern is not None:
            _validate_workspace_pattern(file_pattern)
        search_pattern = f"**/{file_pattern}" if file_pattern else "**/*"
        _validate_workspace_matches(resolved, search_pattern)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_grep(
        pattern,
        path=str(resolved),
        file_pattern=file_pattern,
        output_mode=output_mode,
        context_lines=context_lines,
        ignore_case=ignore_case,
        max_results=max_results,
    )


def write(path: str, content: str) -> str:
    """Write one workspace-relative file."""
    try:
        resolved = resolve_workspace_path(path)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_write(str(resolved), content)


def export_file(path: str, display_name: str | None = None) -> str:
    """Export a completed work-area file to a downloadable chat card.

    This is required after writing or editing any file the user asked to
    receive, return, download, or save. Pasting its contents in the response is
    not a substitute for exporting it.
    """
    try:
        requested = Path(path)
        if requested.is_absolute():
            resolved = requested.resolve()
            try:
                resolved.relative_to(UPLOAD_ROOT.resolve())
            except ValueError as error:
                raise PermissionError(
                    "Absolute exports are limited to trusted uploaded files"
                ) from error
        else:
            resolved = resolve_workspace_path(path)
        if not resolved.exists():
            raise FileNotFoundError(f"File does not exist: {path}")
        if not stat.S_ISREG(resolved.stat().st_mode):
            raise ValueError("Only ordinary files can be exported")

        name = display_name.strip() if isinstance(display_name, str) else resolved.name
        if (
            not name
            or name in {".", ".."}
            or Path(name).name != name
            or "/" in name
            or "\\" in name
            or "\0" in name
        ):
            raise ValueError("Display name must be a plain file name")

        size_bytes = resolved.stat().st_size
        count = getattr(_ARTIFACT_REQUEST_STATE, "count", 0)
        total_bytes = getattr(_ARTIFACT_REQUEST_STATE, "total_bytes", 0)
        if count >= MAX_EXPORTED_ARTIFACTS:
            raise ValueError(
                f"At most {MAX_EXPORTED_ARTIFACTS} files can be exported per request"
            )
        if size_bytes > MAX_EXPORTED_ARTIFACT_BYTES:
            raise ValueError("File exceeds the 8 MB export limit")
        if total_bytes + size_bytes > MAX_EXPORTED_ARTIFACT_BYTES:
            raise ValueError("Exported files exceed the 8 MB combined limit")

        data = resolved.read_bytes()
        if len(data) != size_bytes:
            raise OSError("File changed while it was being exported; try again")
    except (OSError, TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)

    artifact_id = str(uuid.uuid4())
    mime_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    payload = {
        "artifact_id": artifact_id,
        "name": name,
        "mime_type": mime_type,
        "size_bytes": size_bytes,
        "sha256": hashlib.sha256(data).hexdigest(),
        "data_base64": base64.b64encode(data).decode("ascii"),
    }
    with _ARTIFACT_PAYLOADS_LOCK:
        _ARTIFACT_PAYLOADS[artifact_id] = payload

    pending_ids = getattr(_ARTIFACT_REQUEST_STATE, "pending_ids", set())
    pending_ids.add(artifact_id)
    _ARTIFACT_REQUEST_STATE.pending_ids = pending_ids
    _ARTIFACT_REQUEST_STATE.count = count + 1
    _ARTIFACT_REQUEST_STATE.total_bytes = total_bytes + size_bytes

    result = {"exported": True, **_artifact_metadata(payload)}
    return json.dumps(result, separators=(",", ":"), sort_keys=True)


def edit(
    file_path: str,
    old_string: str,
    new_string: str,
    replace_all: bool = False,
) -> str:
    """Edit one workspace-relative file."""
    try:
        resolved = resolve_workspace_path(file_path)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_edit(
        str(resolved),
        old_string,
        new_string,
        replace_all=replace_all,
    )


def multi_edit(file_path: str, edits: list[dict]) -> str:
    """Apply multiple edits to one workspace-relative file."""
    try:
        resolved = resolve_workspace_path(file_path)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    return connectonion_multi_edit(str(resolved), edits)


def _validate_workspace_command(command: str) -> None:
    """Reject explicit absolute or traversal paths before invoking a shell."""
    if any(
        marker in command
        for marker in (" /", ">/", "</", "=\"/", "='/", "('/", '(\"/')
    ):
        raise ValueError("Shell commands must not contain absolute paths")
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError as error:
        raise ValueError(f"Invalid shell command: {error}") from error
    for token in tokens:
        candidate = token.lstrip("<>").split("=", 1)[-1]
        if candidate.startswith(("~", "/", "$HOME", "${HOME}")):
            raise ValueError(
                "Shell commands must use workspace-relative paths, not "
                f"{candidate!r}"
            )
        if ".." in Path(candidate).parts:
            raise PermissionError(
                "Shell command contains a path that escapes the workspace"
            )
        path_candidate = candidate.strip("'\"(),;")
        is_workspace_symlink = (
            bool(path_candidate)
            and (WORKSPACE_ROOT / path_candidate).is_symlink()
        )
        if (
            "://" not in candidate
            and ("/" in candidate or is_workspace_symlink)
        ):
            try:
                resolve_workspace_path(path_candidate)
            except (ValueError, PermissionError) as error:
                raise PermissionError(
                    "Shell command contains a path outside the workspace"
                ) from error


def resolve_browser_seed_state() -> str | None:
    """Resolve an optional browser login state inside the configured workspace."""
    configured_path = os.environ.get(
        "CONNECTONION_BROWSER_SEED_STATE",
        "",
    ).strip()
    if not configured_path:
        return None

    seed_state = resolve_workspace_path(configured_path)
    if not seed_state.is_file():
        raise ValueError(
            "CONNECTONION_BROWSER_SEED_STATE must point to an existing "
            "workspace-relative file"
        )
    return str(seed_state)


def bash(
    command: str,
    description: str = "",
    cwd: str = ".",
    timeout: int = 120,
) -> str:
    """Run a shell command from a workspace-scoped working directory."""
    try:
        resolved_cwd = resolve_workspace_path(cwd)
        _validate_workspace_command(command)
    except (TypeError, ValueError, PermissionError) as error:
        return _workspace_error(error)
    if not resolved_cwd.exists() or not resolved_cwd.is_dir():
        return f"Error: shell working directory is not a directory: {cwd}"
    safe_timeout = max(1, min(timeout, 600))
    return connectonion_bash(
        command,
        description=description,
        cwd=str(resolved_cwd),
        timeout=safe_timeout,
    )


def configured_toolsets(value: str | None = None) -> tuple[str, ...]:
    """Return validated toolsets from CONNECTONION_TOOLSETS."""
    raw_value = (
        value
        if value is not None
        else os.environ.get(
            "CONNECTONION_TOOLSETS",
            ",".join(DEFAULT_TOOLSETS),
        )
    )
    aliases = {"agent_emails": "agent_email", "diff": "diff_writer"}
    requested = []
    for item in raw_value.split(","):
        normalized = item.strip().lower().replace("-", "_")
        if normalized:
            requested.append(aliases.get(normalized, normalized))
    if not requested:
        requested = list(DEFAULT_TOOLSETS)

    if "all" in requested:
        requested = [
            *ALL_LOCAL_TOOLSETS,
            *(item for item in requested if item != "all"),
        ]

    unknown = sorted(set(requested) - SUPPORTED_TOOLSETS)
    if unknown:
        raise ValueError(
            "Unknown CONNECTONION_TOOLSETS value(s): "
            f"{', '.join(unknown)}. Supported values: "
            f"{', '.join(sorted(SUPPORTED_TOOLSETS))}, all"
        )

    if "gmail" in requested and "outlook" in requested:
        raise ValueError(
            "Choose only one mail toolset: gmail or outlook. "
            "Their official tools expose overlapping method names."
        )
    if "agent_email" in requested and "web" in requested:
        raise ValueError(
            "Choose either agent_email or web. Both official toolsets expose "
            "a get_emails tool with different meanings."
        )
    if "google_calendar" in requested and "microsoft_calendar" in requested:
        raise ValueError(
            "Choose only one calendar toolset: google_calendar or "
            "microsoft_calendar. Their official tools expose overlapping "
            "method names."
        )
    if "diff_writer" in requested and "workspace" in requested:
        raise ValueError(
            "Choose either diff_writer or workspace. Both expose a 'write' "
            "tool; diff_writer is a preview-first file editor without bash, "
            "while workspace bundles bash and the full file toolkit."
        )

    return tuple(dict.fromkeys(requested))


def _integration_toolset(name: str):
    """Create one optional official ConnectOnion class-tool bundle."""
    try:
        if name == "web":
            from connectonion.useful_tools import WebFetch

            class HostedWebFetch(WebFetch):
                def fetch(self, url: str) -> str:
                    html = super().fetch(url)
                    title = self.get_title(html)
                    max_chars = max_fetch_chars()
                    content = self.strip_tags(html, max_chars=max_chars)
                    if not content.strip():
                        content = html[:max_chars]

                    parts = [f"URL: {url}"]
                    if title:
                        parts.append(f"Title: {title}")
                    parts.append(f"Content:\n{content}")
                    return "\n\n".join(parts)

            return HostedWebFetch()
        if name == "todo":
            from connectonion.useful_tools import TodoList

            return TodoList()
        if name == "diff_writer":
            from connectonion.useful_tools import DiffWriter

            # Zero-config, no auth. Exposes write/diff/read tools; the framework
            # injects `agent` and strips it from the schema, so `write` collides
            # with the workspace toolset — hence the mutual-exclusivity guard.
            return DiffWriter()
        if name == "memory":
            from connectonion.useful_tools import Memory

            return Memory(memory_file=str(GLOBAL_CO_DIR / "memory.md"))
        if name == "browser":
            if not os.environ.get("OPENONION_API_KEY", "").strip():
                raise RuntimeError(
                    "Browser screenshots require OPENONION_API_KEY. "
                    "Authenticate with `co auth` before enabling the browser toolset."
                )
            from connectonion.useful_tools.browser_tools import BrowserAutomation
            from connectonion.useful_tools.browser_tools.chrome_finder import (
                find_system_chrome,
            )
            from patchright.sync_api import sync_playwright  # noqa: F401

            if not find_system_chrome():
                raise RuntimeError(
                    "Google Chrome is unavailable. "
                    "Install Chrome with `python -m patchright install chrome`."
                )

            return BrowserAutomation(
                use_chrome_profile=False,
                headless=True,
                seed_state=resolve_browser_seed_state(),
            )
        if name == "gmail":
            from connectonion.useful_tools import Gmail

            return Gmail(
                emails_csv=str(GLOBAL_CO_DIR / "gmail-emails.csv"),
                contacts_csv=str(GLOBAL_CO_DIR / "gmail-contacts.csv"),
            )
        if name == "agent_email":
            from connectonion.useful_tools import (
                get_emails,
                mark_read,
                mark_unread,
                send_email,
            )

            return [send_email, get_emails, mark_read, mark_unread]
        if name == "google_calendar":
            from connectonion.useful_tools import GoogleCalendar

            return GoogleCalendar()
        if name == "outlook":
            from connectonion.useful_tools import Outlook

            return Outlook()
        if name == "microsoft_calendar":
            from connectonion.useful_tools import MicrosoftCalendar

            return MicrosoftCalendar()
    except (ImportError, RuntimeError, ValueError, PermissionError) as error:
        if name == "browser":
            setup = (
                "Run `co auth`, then install Chrome with "
                "`python -m patchright install chrome`."
            )
        elif name in {"gmail", "google_calendar"}:
            setup = "Authorize Google access with `co auth google`."
        elif name == "agent_email":
            setup = (
                "Sending is zero-config; configure IMAP environment variables "
                "to receive email."
            )
        elif name in {"outlook", "microsoft_calendar"}:
            setup = "Authorize Microsoft access with `co auth microsoft`."
        elif name == "diff_writer":
            setup = "diff_writer is zero-config; no setup or authorization is required."
        else:
            setup = "Install the optional dependencies required by this toolset."
        raise RuntimeError(
            f"Could not enable ConnectOnion toolset '{name}': {error}\n{setup}"
        ) from error

    raise ValueError(f"Unsupported integration toolset: {name}")


def configure_hosted_approval(toolsets: tuple[str, ...]) -> None:
    """Classify side-effecting optional tool methods for WebSocket approval."""
    if not set(toolsets).intersection(
        {
            "memory",
            "browser",
            "gmail",
            "agent_email",
            "google_calendar",
            "outlook",
            "microsoft_calendar",
        }
    ):
        return

    from connectonion.useful_plugins.tool_approval.constants import (
        DANGEROUS_TOOLS,
        FILE_EDIT_TOOLS,
    )

    dangerous = {
        # Browser interaction and local browser state.
        "click",
        "click_element_by_selector",
        "click_element_near_selector",
        "double_click",
        "right_click",
        "keyboard_press",
        "keyboard_type",
        "type_text_by_selector",
        "upload_file_by_selector",
        "upload_file_after_click_by_selector",
        "run_page_script",
        "run_frame_script",
        "check_checkbox",
        "select_option",
        "mouse_click",
        "save_state",
        "save_page_context",
        "close",
        "close_tab",
        # take_screenshot is read-only observation, not a side effect, so it is
        # intentionally left un-gated.
        # Mail mutations.
        "send",
        "send_email",
        "reply",
        "archive_email",
        # mark_read / mark_unread are low-risk and reversible, so they are
        # intentionally left un-gated to avoid an approval prompt per message.
        "star_email",
        "add_label",
        "update_contact",
        "bulk_update_contacts",
        "cancel_scheduled",
        # Calendar mutations.
        "create_event",
        "create_meet",
        "create_teams_meeting",
        "update_event",
        "delete_event",
        # Persistent memory mutation.
        "write_memory",
    }
    DANGEROUS_TOOLS.update(dangerous)
    FILE_EDIT_TOOLS.update({"write_memory"})


def build_agent_tools(toolsets: tuple[str, ...]) -> list:
    """Build official ConnectOnion tools and the workspace-scoped bash wrapper."""
    tools = []
    if "workspace" in toolsets:
        tools.extend(
            [read_file, glob, grep, edit, multi_edit, write, export_file, bash]
        )

    for name in toolsets:
        if name != "workspace":
            bundle = _integration_toolset(name)
            if isinstance(bundle, list):
                tools.extend(bundle)
            else:
                tools.append(bundle)

    tools.extend(
        [enter_plan_mode, write_plan, exit_plan_and_implement, ask_user]
    )
    return tools


def build_agent_plugins(toolsets: tuple[str, ...]) -> list:
    """Build hosted-compatible plugins for the selected toolsets."""
    plugins = [
        runtime_input,
        MODE_CONTROLLER_PLUGIN,
        RUN_STATE_PLUGIN,
        INTERRUPT_CONTROLLER_PLUGIN,
        PLAN_MODE_GUARD_PLUGIN,
        HOST_TOOL_APPROVAL_PLUGIN,
        ARTIFACT_EXPORT_PLUGIN,
        REASONING_ROUTER_PLUGIN,
        CONDITIONAL_SYSTEM_REMINDER_PLUGIN,
        ADAPTIVE_REASONING_PLUGIN,
        HOST_ULW_PLUGIN,
    ]
    if online_eval_enabled():
        plugins.append(CONDITIONAL_EVAL_PLUGIN)
    if set(toolsets).intersection({"workspace", "browser"}):
        plugins.append(image_result_formatter)
    if "browser" in toolsets:
        try:
            from connectonion.useful_plugins import bind_browser_session

            plugins.append(bind_browser_session)
        except ImportError as error:
            raise RuntimeError(
                "The browser toolset requires ConnectOnion's browser plugins."
            ) from error
    return plugins


def load_system_prompt(toolsets: tuple[str, ...]) -> str:
    """Load the versioned system prompt and inject the enabled toolsets."""
    template = HOST_SYSTEM_PROMPT_PATH.read_text(encoding="utf-8")
    return template.replace("{{toolsets}}", ", ".join(toolsets)).strip()


def create_agent():
    """Create an isolated agent instance for each hosted execution."""
    toolsets = configured_toolsets()
    configure_hosted_approval(toolsets)
    options = {
        "tools": build_agent_tools(toolsets),
        "plugins": build_agent_plugins(toolsets),
        "system_prompt": load_system_prompt(toolsets),
    }

    model = os.environ.get("CONNECTONION_MODEL", "").strip()
    if model:
        options["model"] = model

    max_iterations = os.environ.get("CONNECTONION_MAX_ITERATIONS", "").strip()
    if max_iterations:
        try:
            options["max_iterations"] = int(max_iterations)
        except ValueError:
            pass

    agent = Agent(AGENT_NAME, **options)
    if "browser" in toolsets:
        agent.remove_tool(BROWSER_TERMINAL_ONLY_TOOL)
    return agent


def resolve_host_trust() -> str:
    """Resolve trust without placing onboarding credentials in source control."""
    explicit_trust = os.environ.get("CONNECTONION_TRUST", "").strip()
    if explicit_trust:
        return explicit_trust

    explicit_policy = os.environ.get("CONNECTONION_TRUST_POLICY", "").strip()
    if explicit_policy:
        return str(Path(explicit_policy).expanduser().resolve())

    project_policy = HOST_AGENT_ROOT / ".co" / "trust-policy.md"
    if project_policy.is_file():
        return str(project_policy)

    environment = os.environ.get("CONNECTONION_ENV", "development").lower()
    return "strict" if environment == "production" else "open"


def configure_project_trust_storage() -> None:
    """Keep onboarded contacts with the shared ConnectOnion identity."""
    from connectonion.network.trust import tools as trust_tools

    trust_tools.CO_DIR = GLOBAL_CO_DIR


if __name__ == "__main__":
    _verify_interrupt_session_state_fix()
    WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
    print(f"Private agent work area: {WORKSPACE_ROOT}")
    os.chdir(WORKSPACE_ROOT)
    configure_project_trust_storage()
    relay_url = os.environ.get(
        "CONNECTONION_RELAY_URL",
        "wss://oo.openonion.ai",
    ).strip()
    port = int(os.environ.get("CONNECTONION_HOST_PORT", "8000"))

    host(
        create_agent,
        port=port,
        trust=resolve_host_trust(),
        relay_url=relay_url or None,
        co_dir=GLOBAL_CO_DIR,
        summary="A coding assistant that exports generated files to the macOS client.",
    )
