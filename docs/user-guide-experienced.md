# ConnectOnion macOS Client Guide for Experienced Users

This guide is for developers and anyone comfortable with a
terminal. It takes you from a clean macOS machine to a working chat by
building the project from source, and covers verification, the credit/key
requirements, troubleshooting, and how to run the test suites. For a short command
reference once the project is already set up, see the
[run guide](team-guide.md). Development topics (architecture,
release pipeline, protocol details) stay in the main [README](../README.md).

The expected outputs below are abridged; timings, addresses, and balances
will differ on your machine.

## 1. Scope: what runs in Docker, and what does not

The product has two parts:

- **One Python Main Agent service.** It runs **entirely in Docker** from the
  `co-agent:1.0` image, managed as a single Docker Compose project. No host
  Python setup is needed to run it.
- **The native macOS client** (SwiftUI). A macOS GUI application cannot run
  inside a Linux container, so the client is built and run from source through
  Xcode rather than delivered as a container.

Running the client from source affects only its delivery format. It does
not remove the Docker requirement: **Docker Desktop is a hard dependency**,
and without it the App cannot start the Main Agent.

## 2. Supported environment

- macOS 15.7 or newer, on Apple Silicon or Intel. The agent image is built
  locally from the `Dockerfile`, which supports both ARM64 and AMD64.
- Docker Desktop for Mac with the Compose plugin, version 2 or later
  (`docker compose`, not the legacy standalone `docker-compose` binary).
- Xcode (current stable release) to run the client from source.
- Python 3.11 or newer, only needed to run the Python test suite on the host
  (section 10); the Main Agent itself uses the Python inside the image.
- Network access to Docker Hub, PyPI, `oo.openonion.ai`, and
  `o.openonion.ai`.
- Free loopback port: 8000.

## 3. Install and verify Docker Desktop

1. Download Docker Desktop from
   <https://www.docker.com/products/docker-desktop/> and install it.
2. Launch it and wait until the whale menu-bar icon reports
   "Docker Desktop is running".
3. Verify from a terminal:

```bash
docker version
docker compose version
```

Expected: `docker version` prints both a `Client:` and a `Server:` section;
`docker compose version` prints a version line (the plugin form of Compose,
version 2 or later).

| Output | Cause | Fix |
| --- | --- | --- |
| `command not found: docker` | Docker Desktop is not installed | Install it (step 1) |
| `Cannot connect to the Docker daemon` | Docker Desktop is not running | Launch it and wait (step 2) |
| `'compose' is not a docker command` | Compose v2 missing (very old install) | Update Docker Desktop |

The App runs these same checks itself on every launch, before pulling any
image or creating any container, and shows a guided error banner if one
fails (section 9).

## 4. Run the project from source

```bash
git clone https://github.com/openonion/oochat-macos.git
cd oochat-macos
cp .env.example .env
docker build --tag co-agent:1.0 .
```

The first build pulls the base image and installs Chromium and Python
dependencies, so expect a few minutes. It ends with:

```text
 => exporting to image
 => => naming to docker.io/library/co-agent:1.0
```

Rebuilding unchanged code finishes in under a second with every step
`CACHED`; that is normal.

Then open `ConnectOnionMacClient.xcodeproj` in Xcode, select the
`ConnectOnionMacClient` scheme, and **Run**.

There is no separate launcher: **opening the App starts the whole Docker
stack, and closing the last App window stops it** (`docker compose down`,
never `-v`).

For headless debugging without the App, the same Compose project works from
the CLI, but only after the App has completed one successful launch: the
first launch bootstraps the account credentials the containers need. On a
machine that has never run the App, the containers exit with code 78 (no
model credentials); launch the App once, or follow the manual bootstrap
steps in the [README](../README.md#development-notes).

```bash
docker compose up -d --no-build --wait
docker compose ps
docker compose down
```

## 5. What happens on first launch

The App shows a progress banner while it brings the stack up. The stages,
in order:

| Banner stage | Meaning | Normal wait |
| --- | --- | --- |
| Checking Docker Desktop… | `docker info` preflight | ~1 s |
| Checking Docker Compose… | `docker compose version` preflight | ~1 s |
| Preparing the Agent image… | Reuses, builds, or pulls `co-agent:1.0` | seconds if already built; minutes on first build |
| Preparing the Docker account… | One-time `co auth` bootstrap that creates the agent account | ~10–30 s, first launch only |
| Starting the Main Agent… | `compose up` and its health check | ~10–20 s |

When the banner disappears, the sidebar fills in automatically: the App
probes port 8000 every 15 seconds and lists the healthy Main Agent.

The account created during bootstrap and the Agent's chat history live in
private named Docker volumes. They are reused on every later launch and survive
restarts, upgrades, and container recreation. Never use
`docker compose down -v`, because that deletes both the identity and history
volumes.

## 6. Verify the Main Agent is running

The one local service must be healthy:

```bash
docker compose ps
```

```text
NAME                                     IMAGE          STATUS                    PORTS
connectonion-mac-client-agent-1          co-agent:1.0   Up 14 seconds (healthy)   127.0.0.1:8000->8000/tcp
```

The main account must exist and hold a positive balance:

```bash
docker compose exec -T agent co status
```

```text
╭──────────── 📊 Account Status ────────────╮
│ Agent Address: 0x402ecc55…f82e07          │
│ Email: 0x402ecc5597@mail.openonion.ai     │
│ Balance: $<positive amount>               │
╰───────────────────────────────────────────╯
```

The address, email, and balance are unique to each install. If the balance
is $0, add credits or configure your own key first (section 8).

Finally, in the macOS client send this message to the main agent:

```text
Reply with DEMO_READY only.
```

A reply proves the signed WebSocket flow and the configured model end to
end. Health checks only prove HTTP is alive; this message is the real
acceptance test.

## 7. Using the App

**Connect an agent.** On the home screen, paste a ConnectOnion `0x` address
or an HTTP(S) Direct URL and click **Connect**. The local Docker Main Agent is
discovered automatically and appears in the sidebar without any manual step.

**Chat.** Select an agent in the sidebar to start or continue a
conversation. Each agent keeps its own collapsible list of chats; deleting
chats never touches the agent account.

**Execution mode.** The composer offers **Safe**, **Plan**, and **Accept**
modes for the Main Agent. Safe requests approval for risky tools; Plan asks the
Main Agent to prepare a plan before changes; Accept can run enabled tools
without a per-action confirmation.

**Attach files.** Click the attach button in the composer or drag files
onto the chat ("Drop files to attach"). Files the agent generates come back
as cards with **Save As…** and **Save to Desktop** actions; Desktop copies
never overwrite an existing file.

**Voice input.** Click the microphone button in the composer to record,
and click it again to stop and transcribe. Transcription runs inside the
local Main Agent container, so it has the same preconditions as chat: the
agent must be online and the account funded (or set
`CONNECTONION_TRANSCRIPTION_MODEL` plus a provider key in the runtime
`.env`, section 8). Nothing needs to be installed on the Mac itself.

**Change configuration.** Menu **Docker → Reveal Runtime .env in Finder**,
edit the file, then **Docker → Apply Configuration and Restart Agents**.
The App validates the file, restores the protected identity fields if they
were changed, and recreates the containers. Model and key options are
listed in the [README configuration section](../README.md#configuration).

## 8. Credits and bring-your-own-key

A newly created account can start with a **zero balance**. A healthy Main Agent
in the sidebar does not guarantee a working chat:
messages still fail while the balance is $0. If a chat fails with healthy
containers, check the balance first (`co status`, section 6). Then take
either path:

- **Add credits.** In the App, open **Settings** and find the
  **Account & Wallet** section, which shows this install's balance. Click
  **Add Balance** to open the ConnectOnion purchase page for that exact
  account, complete the top-up, then use the refresh button next to the
  balance. Credits belong to the `0x` address shown; funding any other
  address does not help this install.
- **Bring your own key.** In the runtime `.env`, set a provider key and a
  model name without the `co/` prefix, for example
  `CONNECTONION_MODEL=gemini-2.5-pro` plus `GEMINI_API_KEY=…`. Section 7
  explains how to edit and apply the file.

After either path, repeat the `DEMO_READY` check from section 6 to confirm
the chat works end to end.

Even with your own key, auxiliary plan generation defaults to
`co/gemini-2.5-flash`, so the ConnectOnion account still needs a positive
balance unless you also override `CONNECTONION_PLAN_MODEL`.

Never edit `AGENT_ADDRESS`, `AGENT_EMAIL`, or `OPENONION_API_KEY`: these
are the Docker-managed identity, and changing the key silently switches the
billing account.

## 9. Troubleshooting

The App classifies startup failures and shows the matching action in the
banner:

| Banner message | Meaning | Action offered |
| --- | --- | --- |
| Docker Desktop is not installed… | The `docker` CLI was not found | **Get Docker Desktop** (opens the download page) + **Check Again** |
| Docker Desktop is installed but not running… | `docker info` reports the daemon is unreachable | **Open Docker Desktop** + **Retry** |
| Docker Compose v2 is required but unavailable… | `docker compose version` failed | **Update Docker Desktop** + **Retry** |
| Any other error (network, image pull, ports, …) | The real diagnostic is shown | **Retry** |

Command-line quick reference, keyed by what you see:

| Output | Cause | Fix |
| --- | --- | --- |
| `no configuration file provided: not found` | Not in the repository root | `cd` to the repository root |
| `Cannot connect to the Docker daemon` | Docker Desktop not running | Start Docker Desktop |
| `No such image: co-agent:1.0` / `Error pull access…` | Image never built (it exists only locally) | `docker build --tag co-agent:1.0 .` |
| `container …-agent-1 is unhealthy` while others are healthy | Image older than the checked-out code | Rebuild, then restart: build → up → ps |
| Log: `error: no model credentials configured` (exit 78) | No credentials in `.env` or identity volume | Launch the App once (it bootstraps), or add a provider key |
| `address already in use` / `port is already allocated` | Port 8000 is occupied (often by a manually started Agent host) | Close the occupier, or change `CONNECTONION_AGENT_PORT` in `.env` |
| `co status` → `Balance: $0.0000` | New account without credits | Section 8 |
| `service "agent" is not running` | The stack is down | Start the App (or `docker compose up`) first |

Log inspection (only meaningful while the stack is up):

```bash
docker logs --tail 200 connectonion-mac-client-agent-1
```

## 10. Running the tests

Host tooling (one-time):

```bash
brew bundle --file Brewfile
./scripts/bootstrap-dev.sh --reset
```

Lint and the complete regression suite:

```bash
./scripts/run_lint.sh
./scripts/run_tests.sh
```

Expected: both exit 0. `scripts/run_tests.sh` runs the Python suite with branch
coverage and fails below 85% (last verified baseline: 88%), validates the
offline evaluation corpus, then runs the full Swift suite.

The test runner ignores virtual environments created with Python older than
3.11. If it reports missing dependencies, recreate the local environment with
`./scripts/bootstrap-dev.sh --reset`.

Focused robustness tests, including the Docker environment-guidance tests
(CLI missing, engine down, Compose v2 missing, pull failure):

```bash
./scripts/run_robustness_tests.sh
```

The full failure matrix and expected invariants are in
[robustness-testing.md](robustness-testing.md).

Live Docker integration suite (builds a test image, runs the real Main Agent,
spends no credits):

```bash
docker build --tag connectonion-agent:test .
./scripts/run_docker_integration_tests.sh
```

## 11. Things you must never do

- **Never run `docker compose down -v`.** The `-v` flag deletes the identity
  and chat-history volumes. The agent account, its keys, balance, and durable
  server chat records are lost permanently; credits do not transfer to a new
  address.
- **Never edit `AGENT_ADDRESS`, `AGENT_EMAIL`, or `OPENONION_API_KEY`** in
  the runtime `.env`.
- **Never start another Agent host (`python /app/host_agent.py`)** while
  the stack runs.
- After changing Python or Dockerfile code, **always rebuild the image
  before restarting**; `Apply & Restart` and `compose up` reuse the
  existing image and will happily run stale code:

```bash
docker build --tag co-agent:1.0 .
docker compose up -d --no-build --wait
docker compose ps
```
