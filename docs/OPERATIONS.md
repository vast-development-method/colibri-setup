# Operations

`colibri.sh` is the single administrative entry point. It installs and
updates Colibri, manages the persistent service, starts resumable model
downloads in GNU Screen, exposes diagnostics, and forwards upstream Colibri
commands.

Run it from this repository:

```bash
chmod +x colibri.sh scripts/download_model.sh
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

The generated configuration is `/etc/colibri-setup/colibri.env`; its API key
is secret. The managed unit is `colibri.service`.

Follow service logs until interrupted:

```bash
./colibri.sh logs --follow
```

The first start can remain quiet for several minutes while the model loads.
Use `status`, `logs --follow`, and `test` before treating that startup time
as a failure.

## Installation and reconfiguration

The installer accepts explicit options for the primary model directory,
Hugging Face repository, source directory/ref, listener, UI mode, and resource
profile. It displays the resolved plan and asks for confirmation before
making changes:

```bash
./colibri.sh install \
    --port 11435 \
    --profile balanced \
    --ui api-only
```

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
3. asks whether a Hugging Face token should be used;
4. launches a resumable download in a detached Screen session;
5. prints the session name and exact commands used to inspect it.

A read-only Hugging Face token is recommended. It raises authenticated rate
limits and is required for gated or private repositories for which the
account has access. Create one at
[Hugging Face access tokens](https://huggingface.co/settings/tokens). See the
[Hugging Face authentication guide](https://huggingface.co/docs/huggingface_hub/en/quick-start#authentication)
for token scope and login behavior.

The token can be supplied to the detached process through `HF_TOKEN`. Do not
put it directly in the script or a repository file. A session-scoped example
is:

```bash
read -rsp "Hugging Face token (input hidden): " HF_TOKEN
printf '\n'
export HF_TOKEN
./colibri.sh model download
unset HF_TOKEN
```

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

Run a complete repository checksum verification after a download, after
moving the model, or whenever storage integrity is in doubt:

```bash
./colibri.sh model verify
```

This invokes Hugging Face's native `hf cache verify` against the configured
repository and model directory. Missing repository files and checksum
mismatches return a non-zero exit status. The operation is read-only and does
not download, repair, or delete anything. Because it reads the complete model,
the approximately 372 GB default model may take several minutes to verify on
NVMe storage.

To verify a different repository and local directory without changing the
deployment configuration:

```bash
./colibri.sh model verify OWNER/REPOSITORY /absolute/model/directory
```

Extra local files are warnings only. This is intentional because Colibri
stores `.coli_usage`, KV data, and other runtime sidecars beside the model.

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
