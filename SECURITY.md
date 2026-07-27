# Security policy

## Supported versions

This project tracks its default branch. Security fixes are applied to the
latest revision; older revisions may not receive backports.

## Reporting a vulnerability

Do not open a public issue containing an API key, Hugging Face token, private
host details, logs with secrets, or an exploitable vulnerability. Use
GitHub's **Security → Report a vulnerability** private reporting flow for
this repository. If private reporting is unavailable, open a minimal issue
requesting a private contact channel without disclosing the vulnerability.

Include:

- affected revision;
- operating-system family;
- exact command or code path;
- impact;
- minimal reproduction with all tokens, usernames, paths, addresses, and
  model-access details removed.

## Deployment requirements

- Keep `COLI_API_KEY` enabled. Use a long, random, unique value.
- Give the generated environment file mode `0640` or stricter and restrict
  its group membership to administrators who need the provider key.
- Bind to loopback when only host applications use the API.
- When Open WebUI runs in Docker, bind only to an interface reachable from
  that container and restrict the port with the host firewall.
- Put remote access behind a TLS reverse proxy and authenticated network
  boundary. Colibri's native HTTP listener is not a public Internet edge.
- Treat the Colibri dashboard as private: its static shell and telemetry
  profile path are not fully protected by the provider API key.
- Never commit `.env` files, tokens, API keys, model weights, or generated
  systemd units containing local paths.
- Use a Hugging Face read token with the least access required. Do not use a
  write-capable token merely to download a model.
- Keep Colibri and Open WebUI updated, and review upstream changes before
  deploying them.

Open WebUI is a separate security boundary. A Colibri provider key does not
replace Open WebUI user authentication, role controls, or TLS.

## Secret handling

The setup requires `HF_TOKEN` for managed Hugging Face Hub operations. It
stores the value in `~/.config/colibri-setup/.env` with mode `0600` and
exports it only to Hugging Face subprocesses. The file is parsed as one strict
assignment and is never sourced as executable shell code. The detached Screen
download inherits the variable. Environment variables remain visible to
sufficiently privileged local users, so treat Screen sessions as
administrator-only resources on a multi-user host.

Configure or remove the value with:

```bash
./colibri.sh hf-token set
./colibri.sh hf-token status
./colibri.sh hf-token remove
```

Avoid:

- placing a token on a command line;
- exporting it from a world-readable shell profile;
- writing it into `scripts/download_model.sh`;
- copying `./colibri.sh open-webui values` output into logs.

Rotate a provider key immediately if it was disclosed, update the Open WebUI
connection, and restart the Colibri service.

## Model and uninstall safety

The model can require hundreds of gigabytes and may include access-controlled
files. `stop` and `uninstall` always preserve the primary model, mirror,
usage profile, and KV sidecars. Optional uninstall flags can remove
tool-created source or generated configuration, but model deletion is never
part of application removal. Verify model paths before removing them
manually.
