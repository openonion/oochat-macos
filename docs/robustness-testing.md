# Robustness Testing

The production runtime is deliberately a single Docker-hosted Main Agent. The
focused suite verifies the security and deployment properties that make that
choice reliable: one loopback service, durable identity and chat history, no
host workspace bind mount, clear startup failures, and safe tool/file
boundaries. The deterministic
tests do not spend model credits or depend on an external LLM response.

## Automated robustness matrix

| ID | Failure or condition | Expected invariant | Automated evidence |
| --- | --- | --- | --- |
| ROB-01 | A workspace path traverses a symlink outside the Main Agent workspace | Access is rejected before a file or shell tool can use the path | `BashWorkspaceTests.test_resolve_workspace_path_rejects_symlink_escape` |
| ROB-02 | Compose is rendered on a clean machine | Exactly one `agent` service publishes only `127.0.0.1:8000`, is restartable, and keeps `co-identity` plus `co-workspace` | `DockerDeploymentRobustnessTests.test_single_main_agent_is_loopback_only_restartable_and_persistent` |
| ROB-03 | A removed internal-service name reappears in Compose | Planner, Browser, Multimodal, Reviewer, Orchestrator, and workflow-volume declarations are absent | `DockerDeploymentRobustnessTests.test_compose_has_no_internal_worker_or_workflow_runtime` |
| ROB-04 | The image/runtime contract changes accidentally | A health check, non-root user, secret exclusions, and no unused workflow directory remain | `DockerDeploymentRobustnessTests.test_image_contract_uses_healthcheck_non_root_user_and_secret_exclusions` |
| ROB-05 | Credentials are absent or port 8000 is occupied | Startup fails non-zero with a recognizable, actionable error | `tests/docker_integration.py` failure probes |
| ROB-06 | The production Compose project starts from a clean state | The Main Agent becomes healthy and returns valid `/health` and `/info` payloads | `tests/docker_integration.py` live-stack probe |
| ROB-07 | The Main Agent container is recreated | Its address remains unchanged because `co-identity` survives recreation | `tests/docker_integration.py` identity probe |
| ROB-08 | The container is recreated | `/agent-work` remains container-private and its named-volume files survive recreation | `tests/docker_integration.py` workspace-isolation and persistence probe |
| ROB-09 | Docker Desktop is unavailable or unhealthy | Startup stops at preflight and presents the matching install/start/retry guidance | `DockerRuntimeRobustnessTests` |
| ROB-10 | Account bootstrap returns incomplete identity data | Credentials are rejected, temporary material is removed, and Compose is not started | `DockerRuntimeRobustnessTests.testBootstrapRejectsIncompleteCredentialsBeforeComposeStartup` |

## Why a single local agent

The earlier internal workflow design multiplied deployment dependencies: six
containers, six exposed loopback ports, six identities, service discovery, and
inter-container scheduling/retry paths. Those mechanisms were product-added
complexity rather than a client requirement. The final product instead runs the
tool-enabled Main Agent directly.

This trades private parallel specialist execution for a smaller and more
predictable customer deployment: one container, one port, one health check, and
one identity volume. Users may still connect an external ConnectOnion Agent by
address or Direct URL; that is an explicit user choice, not a hidden internal
runtime dependency.

## Running the focused suite

From the repository root on macOS:

```bash
./scripts/run_robustness_tests.sh
```

This runs focused Python and Compose checks, validates the deterministic
evaluation corpus, and runs the Swift Docker-runtime fault-injection tests
(daemon down, non-daemon `docker info` failures, CLI missing, Compose v2
missing, image pull failure, incomplete credentials, and the
failure-to-guidance mapping). On Linux, the Swift portion is reported as
skipped and is executed by the separate macOS CI job.

The complete regression suite remains:

```bash
./scripts/run_lint.sh
./scripts/run_tests.sh
```

The Python portion can be run independently with:

```bash
./scripts/run_python_tests.sh
```

It measures statement and branch coverage for the production Python source,
prints missing lines, and fails when total coverage is below 85%. It also
executes the real ConnectOnion package contract; missing runtime dependencies
fail the suite rather than silently skipping that contract.

## Container-level verification

Pull requests build the production Dockerfile and run the real ConnectOnion
package contract inside that image. This catches missing runtime dependencies
that mocked host tests cannot detect:

```bash
docker build --tag connectonion-agent:test .
docker run --rm --entrypoint python connectonion-agent:test \
  -m unittest tests.test_connectonion_contract -v
```

## Live Docker integration suite

After building `connectonion-agent:test`, run:

```bash
./scripts/run_docker_integration_tests.sh
```

The runner creates a unique Compose project with a dynamically allocated
loopback port and an isolated identity volume. It starts the real Main Agent,
validates `/health` and `/info`, recreates the container, verifies private
workspace isolation, and injects credential and port-binding failures. Cleanup
removes only the runner's project-scoped containers and volumes.

## Deliberate boundary

Live model quality and availability are not asserted by the deterministic suite
because they depend on credits, provider availability, and non-deterministic
external responses. Before a client demonstration, run the signed-message
smoke test documented in the main README after confirming the Main Agent is
healthy and the account has a positive balance.
