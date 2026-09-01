# ConnectOnion macOS Client Installation Manual

This manual lets you install, run, verify, and test the oochat macOS
Client from a clean Mac. It is intended to be included in the Software Quality
client.

## 1. System scope and Docker arrangement

ConnectOnion consists of two parts:

- The **Main Agent** is a Python service running in Docker Compose. It is the
  only locally deployed backend service and is exposed only on
  `127.0.0.1:8000`.
- The **macOS client** is a native SwiftUI application. It can be built from
  source in Xcode or installed from the ad-hoc-signed DMG attached to a tagged
  GitHub Release. A native macOS GUI cannot run in the Linux Docker image.

Docker Desktop remains a required dependency because the client starts and
stops the Main Agent. Delivering the native client from source rather than as
a container is deliberate: a macOS GUI application cannot run inside a Linux
container. The system's only backend service — the Main Agent — runs entirely
in Docker.

## 2. Prerequisites

- macOS 15.7 or newer on Apple Silicon or Intel.
- Docker Desktop for Mac, including Docker Compose v2.
- Xcode (current stable version) for source builds.
- Internet access on the first run, to obtain the Docker image/dependencies and
  contact ConnectOnion services.
- Port `8000` available on the local machine.
- Python 3.11 or newer only when running the host-side Python tests.

Install Docker Desktop from <https://www.docker.com/products/docker-desktop/>,
open it, and wait until it reports that Docker Desktop is running. Verify the
installation in Terminal:

```bash
docker version
docker compose version
```

Expected result: `docker version` reports both Client and Server sections, and
`docker compose version` reports Compose v2.

## 3. Obtain and build the project

For a prebuilt client, download the DMG and matching `.sha256` from
<https://github.com/openonion/oochat-macos/releases>. Verify the checksum, open
the DMG, and drag the app to Applications. The DMG is ad-hoc signed rather than
Apple-notarized, so the first launch may require Finder → right-click → Open.

To build from source, continue below.

If you received the project as an archive, unzip it, `cd`
into the extracted folder, and run only the last two commands below.
Otherwise, from Terminal:

```bash
git clone https://github.com/openonion/oochat-macos.git
cd oochat-macos
cp .env.example .env
docker build --tag co-agent:1.0 .
```

The initial Docker build downloads the Python base image, Chromium, and the
Main Agent dependencies, and may take several minutes. A successful build ends
with an image tagged `co-agent:1.0`.

Do not add secrets, recovery phrases, or provider keys to the committed
`.env.example`. Put any local credentials only in the untracked `.env` file or
the runtime configuration created by the app.

## 4. Launch the macOS client

1. Open `ConnectOnionMacClient.xcodeproj` in Xcode.
2. Select the `ConnectOnionMacClient` scheme and your Mac as the destination.
3. Choose **Run**.

On first launch, the app shows progress while it:

1. checks Docker Desktop and Docker Compose;
2. prepares the configured image;
3. bootstraps a unique ConnectOnion account when required;
4. starts the Docker Compose Main Agent; and
5. discovers the healthy local Agent.

The local Main Agent then appears in the left sidebar. Closing the final app
window stops the Compose project while preserving the identity and workspace
volumes.

For command-line diagnostics after a successful first launch:

```bash
docker compose up -d --no-build --wait
docker compose ps
docker compose down
```

Never use `docker compose down -v`; the `-v` option deletes the persistent
identity and chat-history volumes.

## 5. First-use configuration

New ConnectOnion accounts may have a zero balance. In the app, open
**Settings → Account & Wallet**, choose **Add Balance**, complete the purchase
for the displayed account, then refresh the balance.

Alternatively, configure a provider key in the runtime `.env` and a model name
without the `co/` prefix:

```dotenv
CONNECTONION_MODEL=gpt-5
OPENAI_API_KEY=your-key
```

Use **Docker → Reveal Runtime .env in Finder** to locate this file, then
**Docker → Apply Configuration and Restart Agents** after editing it.

Never edit `AGENT_ADDRESS`, `AGENT_EMAIL`, or `OPENONION_API_KEY`; Docker
manages those values for the agent identity.

## 6. Acceptance check

**Deployment check — no account or credits needed.** This starts a disposable
Compose project with placeholder credentials on its own port, so it works even
with a zero balance and touches neither the App's containers nor its volumes:

```bash
CONNECTONION_AGENT_PORT=8010 docker compose -p co-smoke \
  -f docker-compose.yml -f docker-compose.integration.yml up -d --wait
curl -s http://127.0.0.1:8010/health   # {"status": "healthy", ...}
curl -s http://127.0.0.1:8010/info     # agent address and tool list
CONNECTONION_AGENT_PORT=8010 docker compose -p co-smoke \
  -f docker-compose.yml -f docker-compose.integration.yml down -v
```

A healthy response from both endpoints verifies the image, the Compose
deployment, and the agent's HTTP protocol layer. The `-v` flag is safe only
on this disposable `co-smoke` project; it removes that project's temporary
volumes and nothing else.

**End-to-end check — needs a funded account or provider key (section 5).**
Verify that Docker considers the service healthy:

```bash
docker compose ps
docker compose exec -T agent co status
```

Expected result: one healthy `agent` service with a loopback-only mapping such
as `127.0.0.1:8000->8000/tcp`; `co status` shows an agent address and balance.

Then, in the macOS client, select the Main Agent and send:

```text
Reply with DEMO_READY only.
```

Receiving `DEMO_READY` confirms the signed client-to-agent flow and model
configuration. A Docker health check alone verifies only that HTTP is alive.

## 7. Running automated checks

Prepare host development tools once:

```bash
brew bundle --file Brewfile
./scripts/bootstrap-dev.sh --reset
```

`--reset` intentionally replaces the local `.venv` with a Python 3.11+
environment. Then run linting and the complete regression suite:

```bash
./scripts/run_lint.sh
./scripts/run_tests.sh
```

Expected result: both commands exit with status `0`. Python branch coverage
must be at least 85%; the script also validates the offline evaluation corpus.

Optional focused checks:

```bash
./scripts/run_robustness_tests.sh
docker build --tag connectonion-agent:test .
./scripts/run_docker_integration_tests.sh
```

The Docker integration suite verifies the live Compose stack, startup failure
handling, persistent identity, and private workspace isolation. It does not
spend model credits.

## 8. Troubleshooting

| Symptom | Cause | Resolution |
| --- | --- | --- |
| `command not found: docker` | Docker Desktop is not installed | Install Docker Desktop, then reopen the app. |
| Cannot connect to Docker daemon | Docker Desktop is stopped | Start Docker Desktop and choose **Retry** in the app. |
| Compose v2 is unavailable | Docker Desktop is outdated | Update Docker Desktop. |
| `No such image: co-agent:1.0` | The local development image was not built | Run `docker build --tag co-agent:1.0 .`. |
| Agent is unhealthy after a code change | The image is stale | Rebuild the image, then restart the app or Compose stack. |
| `no model credentials configured` | First-launch bootstrap was not completed and no provider key exists | Launch the app once, or configure a provider key. |
| `address already in use` | Port 8000 is occupied | Stop the process using the port, or set `CONNECTONION_AGENT_PORT` in `.env`. |
| App is healthy but chat has no reply | The account has no credits or model configuration | Check **Account & Wallet**, add balance, or configure a provider key. |
| Python test dependencies missing | A stale or incomplete virtual environment is selected | Run `./scripts/bootstrap-dev.sh --reset`. |

For logs while the agent is running:

```bash
docker logs --tail 200 connectonion-mac-client-agent-1
```

## 9. Data, shutdown, and recovery

- Agent identity and chat history are stored in Docker named volumes
  `co-identity` and `co-workspace`.
- Normal app shutdown uses `docker compose down` and preserves these volumes.
- Deleting Docker Desktop data or running `docker compose down -v` permanently
  removes the agent identity, recovery material, and retained chat history.
- Files saved with **Save As…** or **Save to Desktop** are copies outside the
  container and remain after a chat is deleted.

## 10. Release checklist

- [ ] Run `./scripts/run_lint.sh` and `./scripts/run_tests.sh` on the final commit.
- [ ] Verify the Main Agent with the `DEMO_READY` acceptance check.
- [ ] Do not include `.env`, API keys, recovery phrases, `.co` state, or local
