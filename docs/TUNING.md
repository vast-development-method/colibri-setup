# Tuning

Start with the `balanced` profile, run `doctor` and `plan`, and change only one
resource dimension at a time. A large MoE model can use substantially more
RAM, context memory, and storage bandwidth than a normal desktop model even
when the GPU is disabled.

## Profiles

The setup provides CPU/NVMe profiles. Exact values are calculated from
the host at installation time rather than encoding one person's hardware in
the repository.

| Profile | Goal | RAM approach | Context/queue approach |
| --- | --- | --- | --- |
| `conservative` | Share the host with other workloads | Keep the largest OS/application reserve | Smaller context, one KV slot, short queue |
| `balanced` | Recommended first deployment | Use a controlled cache while retaining healthy headroom | Moderate context and queue |
| `performance` | Press toward the host's safe boundary | Larger expert cache; requires dedicated monitoring | Larger context and/or queue only when memory permits |
| `experimental` | Explicit experiments | May trade headroom or quality for a measured hypothesis | Review every generated setting |
| `custom` | Operator-defined budget | Values supplied by the operator | Values supplied by the operator |

Select a profile:

```bash
./colibri.sh profile set balanced
./colibri.sh restart
./colibri.sh plan
```

Every managed build is compiled without CUDA, and the generated environment
sets `COLI_GPU=none`. This leaves the GPU available for another runtime while
preserving Colibri's CPU/OpenMP tuning path. Check the effective plan before
starting:

```bash
./colibri.sh doctor
./colibri.sh plan
```

## CPU and memory

Colibri's `RAM_GB` budget is an expert cache budget, not the total memory the
process can ever consume. Dense weights, KV contexts, mappings, Python, the
operating system, Open WebUI, and other services need additional memory.

Use these host checks while testing:

```bash
free -h
vmstat 1
pidstat -r -u -p "$(systemctl show --property MainPID --value colibri.service)" 1
```

Treat sustained swap-in/swap-out, an increasing memory-pressure stall, or an
OOM kill as a failed profile. Move down one profile before reducing model
quality.

The wrapper keeps GPU off in this deployment:

```text
CPU-only Colibri binary
COLI_GPU=none
```

Do not set CUDA or VRAM expert variables in the generated environment unless
you deliberately decide to give Colibri the GPU.

## Context and KV slots

Context length and KV slots consume memory independently from the expert
cache.

- Increase context only for a demonstrated workload that needs it.
- Keep one KV slot until a client explicitly sends `cache_slot`.
- OpenAI-compatible clients normally use slot zero.
- More slots isolate saved conversation caches; they do not make the single
  model decode multiple requests in parallel.
- The API processes one generation at a time and queues the rest.

If requests time out while queued, first reduce competing clients or increase
the queue timeout. Increasing queue depth does not increase inference
throughput.

## NVMe pipeline

For a quality-preserving CPU/NVMe setup:

```text
PIPE=1
DIRECT=1
COLI_MODEL_MIRROR=/path/on/a/second/physical/nvme
```

`PIPE=1` enables the asynchronous expert-load pool. `DIRECT=1` uses direct
expert reads where supported. Direct I/O can regress on some storage and
kernel combinations, so benchmark it both on and off before keeping it.

The dual-NVMe mirror should contain byte-identical copies of shards, not a
split collection of mandatory shards. The mirror can improve aggregate
expert-read bandwidth while retaining primary-drive fallback. Let Colibri
measure the initial primary/mirror ratio; override `COLI_DISK_WEIGHTS` only
after repeatable measurements.

Measure on the same prompt after the learning cache has warmed:

1. Run the prompt several times with only the primary.
2. Record time to first token, decode tokens/second, hit rate, and disk
   service time.
3. Enable the mirror and repeat.
4. Compare Colibri's `MIRROR:` line and the same runtime metrics.

Do not use a sequential disk benchmark as proof of model throughput. Expert
access is workload-dependent.

## Learning cache and quality

The default quality policy preserves checkpoint quantization and router
decisions. Keep:

```text
COLI_POLICY=quality
AUTOPIN=1
KVSAVE=1
```

The model records expert usage and improves its hot-expert placement over
time. Preserve `.coli_usage` and `.coli_kv*` unless you intentionally want to
reset learned placement or conversation cache state.

`--topk` and `--topp` change expert routing and are explicitly lossy. Do not
use them for the production quality profile merely to report a higher token
rate. `DRAFT`/MTP can improve speed when the supplied model has the correct
MTP weights, but establish a stable baseline before enabling it.

## A repeatable tuning cycle

```bash
./colibri.sh stop
./colibri.sh profile set balanced
./colibri.sh plan
./colibri.sh doctor
./colibri.sh start
./colibri.sh logs --follow
```

Record:

- selected profile and Colibri revision;
- RAM available before start and peak process RSS;
- model and mirror physical devices;
- prompt and generation limits;
- cold and warm time to first token;
- decode rate and cache hit rate;
- whether swapping or OOM events occurred.

Change one setting, repeat the same prompt, and retain the setting only if it
improves the target metric without exhausting host headroom.

The authoritative list of runtime knobs and their current semantics is
[upstream Colibri tuning](https://github.com/JustVugg/colibri/blob/main/docs/tuning.md).
