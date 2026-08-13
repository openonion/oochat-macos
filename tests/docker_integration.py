"""Black-box Docker and Compose integration tests for the production image."""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.request import urlopen

PROJECT_ROOT = Path(__file__).resolve().parents[1]
BASE_COMPOSE = PROJECT_ROOT / "docker-compose.yml"
INTEGRATION_COMPOSE = PROJECT_ROOT / "docker-compose.integration.yml"
SERVICES = ("agent",)
PORT_VARIABLES = {"agent": "CONNECTONION_AGENT_PORT"}


class IntegrationFailure(RuntimeError):
    """A Docker integration invariant was not satisfied."""


def run_command(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    check: bool = True,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=PROJECT_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise IntegrationFailure(
            f"command timed out after {timeout}s: {' '.join(arguments)}"
        ) from error
    if check and result.returncode != 0:
        output = (result.stderr or result.stdout).strip()
        raise IntegrationFailure(
            f"command failed ({result.returncode}): {' '.join(arguments)}\n"
            f"{output[-4_000:]}"
        )
    return result


def compose_arguments(project_name: str, *arguments: str) -> list[str]:
    command = [
        "docker",
        "compose",
        "--project-name",
        project_name,
        "--env-file",
        ".env.example",
        "--file",
        str(BASE_COMPOSE),
        "--file",
        str(INTEGRATION_COMPOSE),
    ]
    command.extend(arguments)
    return command


def run_compose(
    project_name: str,
    environment: dict[str, str],
    *arguments: str,
    check: bool = True,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    return run_command(
        compose_arguments(project_name, *arguments),
        environment=environment,
        check=check,
        timeout=timeout,
    )


def reserve_local_ports(count: int) -> list[int]:
    sockets: list[socket.socket] = []
    try:
        for _ in range(count):
            reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            reservation.bind(("127.0.0.1", 0))
            sockets.append(reservation)
        return [int(reservation.getsockname()[1]) for reservation in sockets]
    finally:
        for reservation in sockets:
            reservation.close()


def http_json(port: int, path: str) -> dict[str, Any]:
    with urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise IntegrationFailure(f"{path} on port {port} returned non-object JSON")
    return payload


def verify_missing_credentials(image: str) -> None:
    print("[docker-integration] missing credentials fail fast", flush=True)
    missing = run_command(
        ["docker", "run", "--rm", image],
        check=False,
        timeout=30,
    )
    output = f"{missing.stdout}\n{missing.stderr}".lower()
    if missing.returncode != 78 or "no model credentials configured" not in output:
        raise IntegrationFailure(
            "credential-free container did not exit 78 with an actionable error:\n"
            f"{output[-2_000:]}"
        )

    accepted = run_command(
        [
            "docker",
            "run",
            "--rm",
            "--env",
            "OPENAI_API_KEY=integration-provider-placeholder",
            image,
            "python",
            "-c",
            "print('provider credential accepted')",
        ],
        timeout=30,
    )
    if "provider credential accepted" not in accepted.stdout:
        raise IntegrationFailure("provider credential was not accepted")


def verify_port_conflict(
    project_name: str,
    environment: dict[str, str],
) -> None:
    print("[docker-integration] occupied host port fails clearly", flush=True)
    conflict_project = f"{project_name}-port"
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        occupied_port = int(listener.getsockname()[1])
        conflict_environment = dict(environment)
        conflict_environment["CONNECTONION_AGENT_PORT"] = str(occupied_port)

        conflict = run_compose(
            conflict_project,
            conflict_environment,
            "up",
            "--detach",
            "--no-build",
            "agent",
            check=False,
            timeout=60,
        )
        output = f"{conflict.stdout}\n{conflict.stderr}".lower()
        expected_errors = (
            "address already in use",
            "port is already allocated",
            "failed to bind host port",
            "ports are not available",
        )
        if conflict.returncode == 0 or not any(
            message in output for message in expected_errors
        ):
            raise IntegrationFailure(
                "occupied-port startup did not fail with a recognizable Docker "
                f"error:\n{output[-4_000:]}"
            )
    finally:
        listener.close()
        run_compose(
            conflict_project,
            environment,
            "down",
            "--volumes",
            "--remove-orphans",
            check=False,
            timeout=60,
        )


def verify_running_stack(
    project_name: str,
    environment: dict[str, str],
    ports: dict[str, int],
) -> None:
    print("[docker-integration] Main Agent becomes healthy", flush=True)
    run_compose(
        project_name,
        environment,
        "up",
        "--detach",
        "--no-build",
        "--wait",
        "--wait-timeout",
        "120",
        *SERVICES,
        timeout=150,
    )
    running = set(
        run_compose(
            project_name,
            environment,
            "ps",
            "--services",
            "--status",
            "running",
        ).stdout.split()
    )
    if running != set(SERVICES):
        raise IntegrationFailure(
            f"expected the Main Agent to be running, found: {sorted(running)}"
        )

    health = http_json(ports["agent"], "/health")
    if health.get("status") != "healthy":
        raise IntegrationFailure(f"agent health response is invalid: {health}")
    info = http_json(ports["agent"], "/info")
    address = info.get("address")
    if not isinstance(address, str) or re.fullmatch(r"0x[0-9a-f]{64}", address) is None:
        raise IntegrationFailure(f"agent info has invalid address: {info}")
    if not isinstance(info.get("name"), str) or not info["name"]:
        raise IntegrationFailure(f"agent info has no name: {info}")

    print("[docker-integration] identity survives container recreation", flush=True)
    run_compose(
        project_name,
        environment,
        "up",
        "--detach",
        "--no-build",
        "--no-deps",
        "--force-recreate",
        "--wait",
        "--wait-timeout",
        "90",
        "agent",
        timeout=120,
    )
    recreated_address = http_json(ports["agent"], "/info").get("address")
    if recreated_address != address:
        raise IntegrationFailure(
            "agent identity changed after container recreation: "
            f"{address} -> {recreated_address}"
        )


def verify_private_agent_work_area(
    project_name: str,
    environment: dict[str, str],
) -> None:
    print("[docker-integration] Main Agent work area is container-private", flush=True)
    workspace_probe = run_compose(
        project_name,
        environment,
        "exec",
        "-T",
        "agent",
        "python",
        "-c",
        (
            "from pathlib import Path; "
            "path = Path('/agent-work/hello.txt'); "
            "path.write_text('hello'); "
            "print(path.read_text())"
        ),
        timeout=30,
    ).stdout.strip()
    if workspace_probe.splitlines()[-1:] != ["hello"]:
        raise IntegrationFailure("Main Agent could not write its private workspace")

    container_id = run_compose(
        project_name,
        environment,
        "ps",
        "--quiet",
        "agent",
    ).stdout.strip()
    mounts = json.loads(
        run_command(
            ["docker", "inspect", container_id, "--format", "{{json .Mounts}}"],
            timeout=30,
        ).stdout
    )
    if any(mount.get("Type") == "bind" for mount in mounts):
        raise IntegrationFailure("Main Agent unexpectedly has a host bind mount")
    workspace_mounts = [
        mount for mount in mounts if mount.get("Destination") == "/agent-work"
    ]
    if len(workspace_mounts) != 1 or workspace_mounts[0].get("Type") != "volume":
        raise IntegrationFailure(
            "/agent-work must use exactly one private Docker named volume"
        )

    run_compose(
        project_name,
        environment,
        "up",
        "--detach",
        "--no-build",
        "--no-deps",
        "--force-recreate",
        "--wait",
        "--wait-timeout",
        "90",
        "agent",
        timeout=120,
    )
    persisted_probe = run_compose(
        project_name,
        environment,
        "exec",
        "-T",
        "agent",
        "python",
        "-c",
        "from pathlib import Path; print(Path('/agent-work/hello.txt').read_text())",
        timeout=30,
    ).stdout.strip()
    if persisted_probe.splitlines()[-1:] != ["hello"]:
        raise IntegrationFailure("Main Agent workspace did not survive recreation")


def main() -> int:
    image = os.environ.get("CONNECTONION_IMAGE", "connectonion-agent:test")
    requested_name = os.environ.get(
        "CONNECTONION_INTEGRATION_PROJECT",
        f"connectonion-integration-{os.getpid()}",
    )
    project_name = re.sub(r"[^a-z0-9_-]+", "-", requested_name.lower())[:42]
    if not project_name:
        raise IntegrationFailure("integration project name is empty")

    run_command(["docker", "info"], timeout=30)
    run_command(["docker", "image", "inspect", image], timeout=30)
    reserved_ports = reserve_local_ports(len(SERVICES))
    if len(reserved_ports) != len(SERVICES):
        raise IntegrationFailure("failed to reserve one port per service")
    ports = dict(zip(SERVICES, reserved_ports))  # noqa: B905 - Python 3.9 runner
    environment = dict(os.environ)
    environment["CONNECTONION_IMAGE"] = image
    for service, port in ports.items():
        environment[PORT_VARIABLES[service]] = str(port)

    verify_missing_credentials(image)
    verify_port_conflict(project_name, environment)
    try:
        run_compose(project_name, environment, "config", "--quiet")
        verify_running_stack(project_name, environment, ports)
        verify_private_agent_work_area(project_name, environment)
    except Exception:
        diagnostics = run_compose(
            project_name,
            environment,
            "logs",
            "--no-color",
            "--tail",
            "120",
            check=False,
            timeout=60,
        )
        if diagnostics.stdout.strip():
            print(diagnostics.stdout[-12_000:], file=sys.stderr)
        raise
    finally:
        print("[docker-integration] cleaning isolated containers and volumes", flush=True)
        run_compose(
            project_name,
            environment,
            "down",
            "--volumes",
            "--remove-orphans",
            "--timeout",
            "10",
            check=False,
            timeout=90,
        )

    print("[docker-integration] PASS", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except IntegrationFailure as error:
        print(f"[docker-integration] FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
