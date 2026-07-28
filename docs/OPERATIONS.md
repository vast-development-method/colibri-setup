# Operations

`colibri.sh` is the single administrative entry point. It installs and
updates Colibri, manages the persistent service, starts resumable model
downloads in GNU Screen, exposes diagnostics, and forwards upstream Colibri
commands.

Run it from this repository:

```bash
./colibri.sh --help
```

## Lifecycle

```bash
./colibri.sh install
./colibri.sh start
./colibri.sh stop
./colibri.sh restart
./colibri.sh enable
./colibri.sh disable
./colibri.sh status
./colibri.sh logs
./colibri.sh test
./colibri.sh upgrade
./colibri.sh uninstall
```

`stop` stops the service and releases its RAM. `uninstall` stops and disables
the service and removes the generated unit. By default it preserves the
configuration, source checkout, primary model, and mirror. `--remove-source`
removes only a source checkout created by this toolkit, and `--purge-config`
explicitly removes its generated configuration. The primary model and mirror
are always preserved.

`uninstall` is also safe after a failed first installation. Installation
ownership is recorded before package and build steps; if transactional cleanup
already removed everything, `uninstall` reports that state successfully.

The generated configuration is `/etc/colibri-setup/colibri.env`; its API key
is secret. The managed unit is `colibri.service`.

Follow service logs until interrupted:

```bash
./colibri.sh logs --follow
```

The first start can remain quiet for several minutes while the model loads.
Before reporting success, the wrapper checks that the process remains active
and has not automatically restarted during an initial five-second guard.
This catches configuration and engine-contract failures without waiting for
the several-minute model load or `/health`. The systemd unit permits only
three restart attempts within five minutes, preventing an invalid
configuration from looping forever. Use `status`, `logs --follow`, and `test`
to follow normal loading after the early guard passes.

## Installation and reconfiguration

The installer accepts explicit options for the primary model directory,
Hugging Face repository, source directory/ref, listener, UI mode, and resource
profile. It displays the resolved plan and asks for confirmation before
making changes:

```bash
./colibri.sh install
```

The defaults are port `11435`, the `performance` profile, and the
`colibri-web` dashboard.

If the model is absent, installation offers to start the resumable download.
Hugging Face token management and the optional second-NVMe mirror remain
separate, explicit operations.

Run it again safely to repair or update an existing installation:

```bash
./colibri.sh install
```

Install, reinstall, and upgrade prepare a complete sibling checkout before
touching the live source. The service stops only for an atomic directory
exchange. The previous checkout is retained with a timestamped `.previous-*`
suffix, and a post-activation failure restores it and attempts to restart the
previous service.

Change operational choices without manually editing the systemd unit:

```bash
./colibri.sh configure
./colibri.sh configure --port 11435 --profile balanced
```

Configuration automatically restarts an active service after validation. A
stopped service remains stopped.

The setup must never print secret values as part of normal status or log
output. API-key management is intentionally separated:

```bash
./colibri.sh api-key show
./colibri.sh api-key rotate
```

## Model downloads in GNU Screen

Start the guided download:

```bash
./colibri.sh model download
```

The helper:

1. checks or installs the `hf` CLI and GNU Screen;
2. asks for the Hugging Face model repository and destination;
3. requires and exports `HF_TOKEN` from the private user `.env` file;
4. launches a resumable download in a detached Screen session;
5. prints the session name and exact commands used to inspect it.

A read-only Hugging Face token is required for every managed remote `hf`
operation. It raises authenticated rate limits and grants access to gated or
private repositories for which the account has permission. Create one at
[Hugging Face access tokens](https://huggingface.co/settings/tokens). See the
[Hugging Face authentication guide](https://huggingface.co/docs/huggingface_hub/en/quick-start#authentication)
for token scope.

Store it as the `HF_TOKEN` variable in the toolkit's private user `.env` file:

```bash
./colibri.sh hf-token set
./colibri.sh hf-token status
./colibri.sh model download
```

The file is `~/.config/colibri-setup/.env`, contains only the exact
`HF_TOKEN=...` assignment, and is created with mode `0600`. It is parsed
strictly rather than sourced. The variable is exported only to Hugging Face
subprocesses and is inherited by the detached Screen worker. Interactive
commands prompt once and save it if the file is absent; non-interactive
commands stop instead of falling back to anonymous Hub access.

To inspect downloads:

```bash
./colibri.sh model status
./colibri.sh model attach
```

Detach from an attached Screen session with `Ctrl-A`, then `D`. The download
continues after SSH disconnects. Re-running the download is safe: the
Hugging Face CLI resumes from the destination's existing cache and files.

For direct, non-interactive use of the reusable helper:

```bash
scripts/download_model.sh start MODEL_REPOSITORY MODEL_DESTINATION
scripts/download_model.sh status
scripts/download_model.sh attach JOB
scripts/download_model.sh cancel JOB
scripts/download_model.sh resume JOB
```

Use `./colibri.sh model download` when possible because it validates the
destination and manages the detached session.

### Verify an existing model

Run a complete checksum check after a download, after moving the model, or
when storage integrity is in doubt:

```bash
./colibri.sh model verify
```

This invokes Hugging Face's checksum verifier against the configured model
repository. The operation is read-only and reports missing or checksum-broken
files without modifying the model. `.coli_usage` is excluded because Colibri
owns that mutable runtime file. The manager prints an elapsed-time heartbeat
every 10 seconds while the model is read.

To verify a different repository and local directory without changing the
deployment configuration:

```bash
./colibri.sh model verify OWNER/REPOSITORY /absolute/model/directory
```

Extra local files are warnings only. This is intentional because Colibri
stores KV data and other runtime sidecars beside the model.

### Repair only missing or corrupt model files

When verification reports missing files or checksum failures, run:

```bash
./colibri.sh model repair
```

The command extracts the exact missing/corrupt path list, prints it, and asks
for confirmation. It downloads only those paths into a separate staging
directory without `--force-download`. It then replaces only the listed files,
reruns the full checksum verification, and restores every original file if the
check fails. Existing files that passed verification are never touched.

One large Hugging Face file can be transferred as many Xet chunks. A long
chunk list does not mean additional model files are being downloaded; the
repair scope is exactly the file list printed before confirmation.

For unattended use after reviewing the printed plan:

```bash
./colibri.sh model repair --yes
```

Stop Colibri before repair. The command refuses to write model files while the
managed service is active.

## Primary model and dual-NVMe mirror

The primary directory is authoritative and writable. Colibri stores its
usage/KV sidecars there. A mirror is a second, byte-identical copy on a
different physical NVMe and is read-only from Colibri's point of view.

The mirror feature:

- distributes expert reads between both physical devices;
- validates mirrored files at startup by size and safetensors header;
- falls back to the primary copy if a mirror file is absent or invalid;
- supports a partial mirror;
- never writes `.coli_usage`, `.coli_kv`, or other sidecars to the mirror.

Do not put the mirror on another partition of the same physical NVMe. That
adds no storage bandwidth and may make latency worse.

Configure or refresh the mirror through:

```bash
./colibri.sh model mirror SECOND_NVME_DESTINATION
./colibri.sh model mirror-status
./colibri.sh model enable-mirror SECOND_NVME_DESTINATION
./colibri.sh restart
./colibri.sh logs --follow
```

The mirror copy also runs in a detached Screen session. Use:

```bash
./colibri.sh model mirror-attach
./colibri.sh model disable-mirror
```

Disabling a mirror stops routing reads to it; it does not delete the copied
model.

Leave disk weights on automatic detection initially. After a generation,
look for Colibri's `MIRROR:` statistics line to confirm reads came from both
devices. A mirror is not RAID and not a backup: the primary remains the
authoritative model directory.

## Diagnostics and upstream commands

Safe, read-only checks:

```bash
./colibri.sh doctor
./colibri.sh plan
./colibri.sh test
./colibri.sh cli info
```

Interactive or one-shot use:

```bash
./colibri.sh cli chat
./colibri.sh cli run "Summarize the operational risks in three bullets."
```

The wrapper exposes the upstream `coli` interface so advanced commands and
new upstream flags remain accessible:

```bash
./colibri.sh cli --help
./colibri.sh cli doctor --json
./colibri.sh cli plan --json
./colibri.sh cli bench --help
```

Upstream commands that can load an additional engine (`chat --no-attach`,
`run`, `bench`) can compete with the persistent service for RAM and storage
bandwidth. Stop the service first when intentionally starting a separate
engine:

```bash
./colibri.sh stop
./colibri.sh cli run "A short test prompt"
```

Do not run two persistent Colibri servers against the same model. Each
process owns its own dense weights, expert cache, KV state, and I/O workload.
Use the built-in request queue and one persistent service.

Upstream command reference:

- [Colibri README](https://github.com/JustVugg/colibri)
- [Colibri API and web UI](https://github.com/JustVugg/colibri/blob/main/docs/api.md)
- [Colibri tuning](https://github.com/JustVugg/colibri/blob/main/docs/tuning.md)
