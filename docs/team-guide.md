# ConnectOnion macOS Client Run Guide

Command reference for working on this project day to day. Every command is run
from the repository root.

- Full walkthrough of what each stage does, the GUI features, and the
  troubleshooting tables: [guide for experienced users](user-guide-experienced.md).
- The clean-machine path a new user follows:
  [installation manual](installation-manual.md).
- Architecture, protocol, and release pipeline: [README](../README.md).

## 1. One-time setup

```bash
brew bundle --file Brewfile        # SwiftLint, required by ./scripts/run_lint.sh
./scripts/bootstrap-dev.sh --reset         # .venv with Python 3.11+ and the dev deps
cp .env.example .env
```

`scripts/bootstrap-dev.sh` picks the first suitable interpreter from `python3.11`,
`python3.12`, `python3.13`, `python3`. Override it with
`PYTHON_BOOTSTRAP_EXECUTABLE=/path/to/python`.

Docker Desktop must be installed and running before anything below.

## 2. First run

```bash
docker build --tag co-agent:1.0 .
```

Then open `ConnectOnionMacClient.xcodeproj` in Xcode and **Run**. The App does
the rest: preflights Docker, bootstraps the agent account on first launch,
starts the Compose stack, and lists the healthy Main Agent in the sidebar.

The first build takes a few minutes (base image, Chromium, Python deps).
Rebuilds of unchanged code finish in seconds with every layer `CACHED`.

When launched from the App, the agent image is tagged by a hash of the build
context, so any change to `host_agent.py` or the dependencies produces a new tag
and the App rebuilds automatically instead of reusing a stale image. If you
instead build by hand with a fixed tag (`co-agent:1.0` above), rebuild after
changing `host_agent.py` or the dependencies — otherwise the old image keeps
running and interrupt/agent fixes never reach you.

## 3. Everyday commands

Quit the App before driving Compose by hand — otherwise both fight over the
same container.

| Task | Command |
| --- | --- |
| Start the stack | `docker compose up -d --wait` |
| Status | `docker compose ps` |
| Follow logs | `docker compose logs -f agent` |
| Last 100 log lines | `docker compose logs --tail 100 agent` |
| Stop (keeps volumes) | `docker compose down` |
| Health | `curl -s http://127.0.0.1:8000/health` |
| Address and tool list | `curl -s http://127.0.0.1:8000/info` |
| Account and balance | `docker compose exec -T agent co status` |
| Shell inside the agent | `docker compose exec agent bash` |
| Validate the Compose file | `docker compose --env-file .env.example config --quiet` |

A healthy `/health` means HTTP is alive. It does **not** mean chat works — that
also needs a positive balance or your own provider key.

## 4. After you change code

This is the most common way to lose an afternoon.

| Changed | What to run |
| --- | --- |
| Swift | Just **Run** again in Xcode |
| `host_agent.py`, `requirements.txt`, `Dockerfile`, `docker/entrypoint.sh` | Rebuild the image, then recreate the container |
| `docker-compose.yml` (env, limits, ports) | `docker compose up -d --wait` — no rebuild needed |

```bash
docker build --tag co-agent:1.0 .
docker compose up -d --wait
docker compose ps
```

`docker compose up` reuses an existing image and will happily run stale code
without warning. The image tag `co-agent:1.0` never changes, so nothing tells
you the container is out of date. When behaviour does not match the source,
check this first:

```bash
docker compose exec -T agent pip show connectonion | grep -i version
```

## 5. Tests

```bash
./scripts/run_lint.sh                      # ruff + SwiftLint (needs brew bundle first)
./scripts/run_lint.sh python               # ruff only
./scripts/run_tests.sh                     # Python suite with coverage, then the Swift suite
```

`scripts/run_tests.sh` enforces an 85% branch-coverage floor on the Python side and
then runs `xcodebuild test`. Narrower suites:

```bash
./scripts/run_python_tests.sh              # Python only, with the coverage gate
./scripts/run_robustness_tests.sh          # deployment contract + symlink escape + Swift Docker tests
./scripts/run_docker_integration_tests.sh  # live Compose stack, spends no credits
```

Run the Python regression suite the way CI does, inside the production image:

```bash
docker build --tag connectonion-agent:test .
docker run --rm --entrypoint python connectonion-agent:test \
  -m unittest discover -s tests -p "test_*.py" -v
```

If a script reports missing dependencies, the local environment is stale:
`./scripts/bootstrap-dev.sh --reset`.

## 6. Never do this

- **`docker compose down -v`.** The `-v` deletes the `co-identity` and
  `co-workspace` volumes. The agent account, its keys, its balance, and the
  durable chat history are gone permanently; credits do not transfer to a new
  address. The same applies to Docker Desktop's **Troubleshoot → Clean / Purge
  data**.
- **Editing `AGENT_ADDRESS`, `AGENT_EMAIL`, or `OPENONION_API_KEY`** in the
  runtime `.env`. These are the Docker-managed identity; changing the key
  silently switches the billing account.
- **Starting a second Agent host** (`python /app/host_agent.py`) while the
  stack is up. Port 8000 will already be taken.
- **Committing `.env`, `.co/`, or `.agent-work/`.** They hold real keys, the
  recovery phrase, and session records. `.gitignore` and `.dockerignore` cover
  them, but `zip -r` does not — package a release with
  `git archive --format=zip -o release.zip HEAD`.
