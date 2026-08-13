import os
import subprocess
import sys
import unittest

# Parameter list of connectonion's ws_router thread body, the private function the
# interrupt session-state fix replaces. A drift here means the fix would silently
# stop applying.
EXPECTED_THREAD_BODY_PARAMS = [
    "route_handlers",
    "storage",
    "prompt",
    "io",
    "session",
    "images",
    "files",
    "registry",
    "session_id",
    "result_holder",
]


class ConnectOnionContractTests(unittest.TestCase):
    def test_real_package_can_build_the_workspace_agent(self):
        environment = dict(os.environ)
        environment["CONNECTONION_TOOLSETS"] = "workspace"
        environment["OPENONION_API_KEY"] = "contract-test-placeholder"
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "import host_agent; "
                    "agent = host_agent.create_agent(); "
                    "assert 'read_file' in agent.tools.names(); "
                    "assert 'wait_for_manual_login' not in agent.tools.names()"
                ),
            ],
            cwd=os.path.dirname(os.path.dirname(__file__)),
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)


class InterruptSessionStateFixContractTests(unittest.TestCase):
    """Guard the ws_router internal that the interrupt session-state fix patches.

    connectonion ships the patch target as a private function, so a version bump
    can move or rename it and the fix would silently stop working — the exact
    failure that leaves a session stuck 'running' and makes the agent ignore
    every message after an interrupt. These run against the real package in a
    fresh subprocess (the sibling unit tests stub `connectonion` in-process) so a
    drift fails CI loudly instead of surfacing only in production.
    """

    def _run(self, code: str) -> subprocess.CompletedProcess:
        environment = dict(os.environ)
        environment["OPENONION_API_KEY"] = "contract-test-placeholder"
        return subprocess.run(
            [sys.executable, "-c", code],
            cwd=os.path.dirname(os.path.dirname(__file__)),
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_patch_target_exists_with_expected_signature(self):
        result = self._run(
            "import inspect; "
            "from connectonion.network.host.ws_router import agent_io; "
            "body = getattr(agent_io, '_agent_thread_body', None); "
            "assert callable(body), 'agent_io._agent_thread_body is missing'; "
            "params = list(inspect.signature(body).parameters); "
            f"expected = {EXPECTED_THREAD_BODY_PARAMS!r}; "
            "assert params == expected, params"
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def test_host_agent_applies_and_verifies_the_fix(self):
        result = self._run(
            "import connectonion, host_agent; "
            "from connectonion.network.host.ws_router import agent_io; "
            "assert agent_io._agent_thread_body "
            "is host_agent._interrupt_safe_agent_thread_body, 'patch not applied'; "
            "assert host_agent._INTERRUPT_FIX_STATUS == 'applied', "
            "host_agent._INTERRUPT_FIX_STATUS; "
            "assert connectonion.__version__ "
            "== host_agent.EXPECTED_CONNECTONION_VERSION, connectonion.__version__; "
            "host_agent._verify_interrupt_session_state_fix()"
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)


if __name__ == "__main__":
    unittest.main()
