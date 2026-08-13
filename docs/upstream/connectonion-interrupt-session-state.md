# Upstream fix: ws_router leaks a `running` session when a run ends by exception

This is a ready-to-file report and patch for the `connectonion` project. We carry
a temporary monkeypatch for it in `host_agent.py`
(`_install_interrupt_session_state_fix` / `_interrupt_safe_agent_thread_body`);
once this lands upstream and we bump the pin, that patch and its startup guard can
be deleted. The contract test in `tests/test_connectonion_contract.py`
(`InterruptSessionStateFixContractTests`) watches the patched symbol so a version
bump that changes it fails CI loudly.

Verified against `connectonion==1.5.11`.

## Summary

`_agent_thread_body` marks the session connected only on the success path, so any
run that ends by raising — most importantly a user interrupt that unwinds
`agent.input()` — leaves the session stuck at `running` in the registry forever.
Every later `INPUT` on that session is then routed as a mid-execution runtime
input into the dead run instead of starting a new turn, so the agent appears
alive but silently ignores every following message.

## Root cause

`connectonion/network/host/ws_router/agent_io.py`:

```python
def _agent_thread_body(route_handlers, storage, prompt, io, session, images, files, registry, session_id, result_holder):
    """Thread target: run agent and store result. Calls io.mark_agent_done() when done."""
    try:
        result_holder[0] = route_handlers["ws_input"](storage, prompt, io, session, images, files)
        registry.mark_session_connected(session_id)   # ← success path only
    except Exception as e:
        result_holder[0] = e
    finally:
        io.mark_agent_done()
```

`mark_session_connected(session_id)` sits inside the `try`, after `ws_input`
returns. When `ws_input` raises (e.g. a `UserInterrupt` raised from an
`after_llm` / `before_each_tool` / `after_tools` / `after_iteration` event to
stop the run), control jumps to `except`, the call is skipped, and the registry
never leaves `running`. `start_agent` then rejects or misroutes subsequent input
for that session because it still looks busy.

## Fix

Move `mark_session_connected(session_id)` into the `finally`, so the session is
returned to a reusable state no matter how the run ends. `mark_agent_done()` is
already there for the same reason.

```diff
 def _agent_thread_body(route_handlers, storage, prompt, io, session, images, files, registry, session_id, result_holder):
     """Thread target: run agent and store result. Calls io.mark_agent_done() when done."""
     try:
         result_holder[0] = route_handlers["ws_input"](storage, prompt, io, session, images, files)
-        registry.mark_session_connected(session_id)
     except Exception as e:
         result_holder[0] = e
     finally:
+        registry.mark_session_connected(session_id)
         io.mark_agent_done()
```

Ordering note: `mark_session_connected` running just before `mark_agent_done`
(both in `finally`) is safe. The forwarder emits `OUTPUT`/`ERROR` from
`result_holder` after `mark_agent_done`, and the next `INPUT` can only arrive
after the client has seen that terminal frame, so the session is already back to
`connected` before it could be reused.

## Reproduction

1. Open a hosted session and send an `INPUT` that runs long enough to interrupt.
2. Send `INTERRUPT`; a stop hook raises to unwind `agent.input()`.
3. Send another `INPUT` on the same session.

Expected: the second `INPUT` starts a new turn. Actual (1.5.11): it is swallowed
as a runtime input into the finished run and never answered; every later message
is ignored too.

## Suggested test (upstream)

Drive `_agent_thread_body` with a `route_handlers["ws_input"]` that raises, and
assert `registry.mark_session_connected` was called and the registry status is
`connected` — mirroring `test_interrupt_safe_thread_body_frees_session_on_interrupt`
in this repo's `tests/test_host_agent.py`.
