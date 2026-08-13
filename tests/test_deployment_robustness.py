import json
import shutil
import subprocess
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SERVICE = ("agent", 8000, {"co-identity", "co-workspace"})
REMOVED_RUNTIME_TERMS = (
    "planner",
    "browser",
    "multimodal",
    "reviewer",
    "orchestrator",
    "workflow-uploads",
)


class DockerDeploymentRobustnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("docker") is None:
            raise unittest.SkipTest("Docker CLI is unavailable")
        result = subprocess.run(
            [
                "docker",
                "compose",
                "--env-file",
                ".env.example",
                "config",
                "--no-env-resolution",
                "--format",
                "json",
            ],
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        cls.compose = json.loads(result.stdout)

    def test_single_main_agent_is_loopback_only_restartable_and_persistent(self):
        service_name, expected_port, expected_volumes = EXPECTED_SERVICE
        services = self.compose["services"]
        self.assertEqual(set(services), {service_name})

        service = services[service_name]
        self.assertEqual(service.get("restart"), "unless-stopped")
        self.assertFalse(service.get("privileged", False))
        self.assertNotEqual(service.get("network_mode"), "host")

        ports = service.get("ports", [])
        self.assertEqual(len(ports), 1)
        self.assertEqual(ports[0]["host_ip"], "127.0.0.1")
        self.assertEqual(ports[0]["target"], expected_port)
        self.assertEqual(int(ports[0]["published"]), expected_port)

        identity_mounts = [
            volume
            for volume in service.get("volumes", [])
            if volume.get("target") == "/home/appuser/.co"
        ]
        self.assertEqual(len(identity_mounts), 1)
        self.assertEqual(identity_mounts[0]["type"], "volume")
        self.assertEqual(identity_mounts[0]["source"], "co-identity")

        workspace_mounts = [
            volume
            for volume in service.get("volumes", [])
            if volume.get("target") == "/agent-work"
        ]
        self.assertEqual(len(workspace_mounts), 1)
        self.assertEqual(workspace_mounts[0]["type"], "volume")
        self.assertEqual(workspace_mounts[0]["source"], "co-workspace")
        self.assertEqual(set(self.compose.get("volumes", {})), expected_volumes)

        self.assertEqual(
            service["environment"]["CONNECTONION_WORKSPACE"],
            "/agent-work",
        )
        self.assertNotIn("working_dir", service)
        self.assertIsNone(service.get("command"))
        host_workspace_mounts = [
            volume
            for volume in service.get("volumes", [])
            if volume.get("type") == "bind"
        ]
        self.assertEqual(host_workspace_mounts, [])

    def test_compose_has_no_internal_worker_or_workflow_runtime(self):
        compose_source = (PROJECT_ROOT / "docker-compose.yml").read_text(
            encoding="utf-8"
        ).lower()
        for term in REMOVED_RUNTIME_TERMS:
            with self.subTest(term=term):
                self.assertNotIn(term, compose_source)

    def test_image_contract_uses_healthcheck_non_root_user_and_secret_exclusions(self):
        dockerfile = (PROJECT_ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("HEALTHCHECK", dockerfile)
        self.assertIn("USER appuser", dockerfile)
        self.assertIn('ENTRYPOINT ["connectonion-entrypoint"]', dockerfile)
        self.assertNotIn("/workflow", dockerfile)
        self.assertLess(
            dockerfile.index("USER appuser"),
            dockerfile.index('CMD ["python", "/app/host_agent.py"]'),
        )
        self.assertLess(
            dockerfile.index('ENTRYPOINT ["connectonion-entrypoint"]'),
            dockerfile.index('CMD ["python", "/app/host_agent.py"]'),
        )

        ignored = {
            line.strip()
            for line in (PROJECT_ROOT / ".dockerignore")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        for sensitive_path in {".env", ".env.*", ".git", ".co/", ".agent-work/"}:
            with self.subTest(sensitive_path=sensitive_path):
                self.assertIn(sensitive_path, ignored)
        self.assertIn("!.env.example", ignored)
        self.assertIn("!evals/cases.json", ignored)

    def test_runtime_fails_fast_without_credentials_and_port_is_overridable(self):
        entrypoint = (PROJECT_ROOT / "docker" / "entrypoint.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("no model credentials configured", entrypoint)
        self.assertIn("exit 78", entrypoint)
        self.assertIn('"${1:-}" = "co"', entrypoint)
        self.assertIn('"${2:-}" = "auth"', entrypoint)
        self.assertIn("result_ttl: 315360000", entrypoint)
        self.assertIn('"${1:-}" = "python"', entrypoint)
        self.assertIn('"${2:-}" = "/app/host_agent.py"', entrypoint)

        compose_source = (PROJECT_ROOT / "docker-compose.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("${CONNECTONION_AGENT_PORT:-", compose_source)
        self.assertNotIn("CONNECTONION_WORKSPACE_HOST", compose_source)
        self.assertIn("CONNECTONION_WORKSPACE: /agent-work", compose_source)
        for term in REMOVED_RUNTIME_TERMS:
            with self.subTest(term=term):
                self.assertNotIn(term, compose_source.lower())

    def test_container_is_resource_capped_privilege_free_and_relay_disabled(self):
        service = self.compose["services"]["agent"]

        self.assertEqual(int(service["mem_limit"]), 4 * 1024**3)
        self.assertEqual(int(service["cpus"]), 2)
        self.assertEqual(service["pids_limit"], 512)

        self.assertIn("no-new-privileges:true", service.get("security_opt", []))
        self.assertEqual(service.get("cap_drop"), ["ALL"])
        self.assertEqual(service.get("cap_add", []), [])

        self.assertEqual(service["environment"]["CONNECTONION_RELAY_URL"], "")


if __name__ == "__main__":
    unittest.main()
