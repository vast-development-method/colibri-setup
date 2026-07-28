# Open WebUI integration

Colibri exposes an OpenAI-compatible API, so Open WebUI can use it as a
provider without a protocol adapter. The default deployment uses
`colibri-web`; `open-webui` is an explicit alternative that runs the API only
and keeps Open WebUI as the single browser interface.

The setup supports three UI modes:

| Mode | Colibri process | Intended use |
| --- | --- | --- |
| `open-webui` | OpenAI-compatible API only | Existing Open WebUI is the only browser UI |
| `colibri-web` | API and Colibri dashboard | Use Colibri's own dashboard and telemetry |
| `api-only` | OpenAI-compatible API only | API clients, reverse proxies, or custom front ends |

Changing mode does not duplicate the model process. Only one persistent
Colibri engine should serve the model.

## Configure Colibri

Prepare the detected Open WebUI container connection and switch Colibri to
`open-webui` mode:

```bash
./colibri.sh open-webui setup
./colibri.sh status
```

The default API port is `11435`. The configured model identifier and API key
are shown by:

```bash
./colibri.sh open-webui values
./colibri.sh api-key show
```

Do not paste the API key into tickets, chat logs, screenshots, or shell
history. Use the command output directly in the Open WebUI administrator
screen.

## Configure Open WebUI

Open WebUI running in Docker must address the host by the numeric gateway of
its own Docker network—not by `localhost`, which means the Open WebUI
container itself. The current Colibri server validates the HTTP `Host` header
against its exact bind address. For that reason, the commonly documented
`host.docker.internal` alias can receive HTTP 403 from Colibri even when it
resolves correctly.

`./colibri.sh open-webui setup` detects the selected container's network,
binds Colibri to that gateway only, and validates that the address exists on
the host. If more than one Open WebUI container is present, select it
explicitly:

```bash
./colibri.sh open-webui setup --container open-webui
```

If that container is attached to more than one Docker network, select the
network whose numeric gateway should carry the private provider connection:

```bash
./colibri.sh open-webui setup \
    --container open-webui \
    --network open-webui_default
```

If Open WebUI uses host networking instead of a Docker bridge:

```bash
./colibri.sh open-webui setup --local
```

That keeps Colibri on loopback.

Then configure the provider in Open WebUI:

1. Sign in as an Open WebUI administrator.
2. Open **Admin Settings → Connections → OpenAI → Manage**.
3. Select **Add New Connection**, then **Standard/Compatible**.
4. Copy the exact base URL from `./colibri.sh open-webui values`.
5. Copy the API key from `./colibri.sh api-key show`.
6. Set **API Type** to **Chat Completions**.
7. Leave **Prefix ID** blank unless another provider exposes the same model
   ID.
8. Save and enable the connection.

Colibri implements `GET /v1/models`, so Open WebUI should discover the model.
If the Open WebUI connection check succeeds but the model is absent, add the
model ID reported by `./colibri.sh open-webui values` to the connection's
**Model IDs (Filter)** allowlist.

Open WebUI's current, official connection instructions are available in
[OpenAI-Compatible providers](https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-openai-compatible/).

## Network scope

The installer should bind Colibri only where the selected client can reach
it:

- Local API clients: bind to `127.0.0.1`.
- Open WebUI in Docker: bind to the Docker bridge gateway or another explicit
  numeric Docker gateway selected by `open-webui setup`.
- Remote clients: put the API behind a firewall and TLS reverse proxy.

Never expose an unauthenticated Colibri listener to an untrusted network.
Keep `COLI_API_KEY` enabled even when a firewall limits access. The API key
protects the provider connection; Open WebUI's own authentication protects
the browser interface.

An Open WebUI administrator/global provider connection is made by Open
WebUI's backend, so it does not require a browser CORS origin. Do not enable
wildcard CORS merely to connect these two services.

Test the API without running a generation:

```bash
./colibri.sh test
./colibri.sh open-webui check
```

If Open WebUI cannot connect:

```bash
./colibri.sh status
./colibri.sh logs
./colibri.sh open-webui check
```

The check runs lightweight `/health` and authenticated `/v1/models` requests
from the selected container. It does not start a generation.

## Long-request timeout

CPU/NVMe prefill and generation can exceed Open WebUI's five-minute default
client timeout even though Colibri streams keepalives. The setup check
inspects the selected container and warns when its timeout is too short; it
does not mutate or recreate an existing Open WebUI deployment.

Add these values to the Open WebUI service's own environment configuration:

```yaml
environment:
  AIOHTTP_CLIENT_TIMEOUT: "1800"
  AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST: "15"
  AIOHTTP_CLIENT_TIMEOUT_OPENAI_MODEL_LIST: "15"
```

Then recreate Open WebUI through the same deployment mechanism that currently
manages it. `1800` allows a thirty-minute completion while retaining short
model-list timeouts. An empty `AIOHTTP_CLIENT_TIMEOUT` removes the total
timeout, but a bounded value is safer for normal operation.

See Open WebUI's official
[performance and timeout guidance](https://docs.openwebui.com/troubleshooting/performance/).

## Keep background work lightweight

Colibri serves one generation at a time. Open WebUI can create additional
background requests for titles, tags, query generation, and other interface
tasks; routing all of those through a disk-streamed large model delays the
user's main answer.

Keep Open WebUI's task/background model on an existing smaller local model.
Also keep embeddings on an embedding-capable local provider: Colibri's
endpoint is text-generation only and does not implement embeddings. This
does not send the main Colibri conversation to another provider; it only
avoids placing small administrative jobs in Colibri's inference queue.

Large system prompts, tools, and retrieved documents also increase prefill
time. Validate the connection first with `./colibri.sh test --chat`, then add
Open WebUI tools or retrieval features incrementally.

## Use Colibri's dashboard instead

To make Colibri's dashboard the active UI:

```bash
./colibri.sh ui set colibri-web
./colibri.sh restart
```

The same API port serves both the dashboard and `/v1`. Open WebUI can remain
configured, but there is normally no benefit in operating both UIs unless
Colibri's runtime telemetry is useful for an experiment.

The dashboard's static shell and telemetry profile path are not fully
protected by the provider API key. Keep `colibri-web` on a private network, or
place it behind a TLS reverse proxy with its own authentication before remote
use.

To return to one browser UI:

```bash
./colibri.sh open-webui setup
```

Upstream Colibri currently serves `web/dist` even under `coli serve` whenever
that built directory exists; it does not expose a `--no-web-ui` switch. The
toolkit therefore removes those generated assets in `open-webui` and
`api-only` modes, and rebuilds them when switching to `colibri-web`. Model
files are not involved in that mode change.

## API capability boundary

Open WebUI can use text chat completions, streaming, multi-turn/system
prompts, generation limits, temperature/top-p, supported reasoning fields,
current function tools/tool choice, and supported JSON response formats.
Image/audio inputs, custom stop sequences, log probabilities, per-request
seed, and non-zero presence/frequency penalties are not supported.

Colibri's dashboard-only Brain/Atlas/profiling telemetry is not reproduced in
Open WebUI. Terminal-only commands such as `doctor`, `plan`, `info`, `bench`,
`build`, and `convert` also cannot become OpenAI API operations. They remain
available through `colibri.sh`; see [Operations](OPERATIONS.md).

The upstream protocol and queue details are documented in
[Colibri's API guide](https://github.com/JustVugg/colibri/blob/main/docs/api.md).
