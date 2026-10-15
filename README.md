# qwen-local-coder

Run **Qwen3.8-27B** (the strongest open coding model in the 20–40B class as of Oct 2026) as a local,
OpenAI-compatible backend for coding agents, on a **consumer 8 GB GPU**.

It is a single, dependency-light CLI (`qlc`) around a pinned [llama.cpp](https://github.com/ggml-org/llama.cpp)
build, with checksum-verified downloads, measured hardware profiles, speculative decoding,
safe defaults and a systemd user service.

```
$ qlc start
[qlc] started pid 1570707, loading model
[qlc] ready at http://127.0.0.1:8089/v1 (model: qwen3.8-27b)
```

## Why this model

| Model (20–40B) | Type | SWE-bench Pro | Terminal-Bench 2.1 | LiveCodeBench v6 |
|---|---|---|---|---|
| **Qwen3.8-27B** | dense | **61.7** | **73.0** | **90.3** |
| Qwen3.6-27B | dense | 53.5 | 63.4 | 83.9 |
| Muse Glimmer-30B | dense | 51.2 | 51.7 | – |
| Qwen3.6-35B-A3B | MoE (3B active) | 49.5 | 51.5¹ | – |

Vendor-reported numbers from the [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B),
[Muse Glimmer-30B](https://huggingface.co/meta-models/Muse-Glimmer-30B) and
[Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) model cards. ¹Terminal-Bench 2.0.

## Profiles and measured performance

RTX 5060 8 GB (desktop session) · i7-12700F · 32 GB RAM · llama.cpp b11576.
HumanEval-20 = 20 evenly spaced HumanEval problems, greedy, thinking off, tests run in an offline sandbox.

| | `rtx5060-8gb-quality` (default) | `rtx5060-8gb-fast` |
|---|---|---|
| Weights | [GSQ-RCO](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF) IQ2_XS, 2.5 bpw, with MTP head | [Unsloth](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) UD-IQ1_M, 1.75 bpw |
| Placement | GPU + FFN of 60/64 layers in RAM | whole model on GPU (CUDA managed memory) |
| Speculation | MTP, 77–96 % accepted | ngram, ~99 % accepted on edits |
| Writing new code | ~5 tok/s | **~32 tok/s** |
| Rewriting / editing code | ~5 tok/s | **~110 tok/s** |
| Prompt processing | ~60–80 tok/s | **~600–680 tok/s** |
| Context | 32K | **4K max** |
| HumanEval-20 | **19/20** | 15/20 |
| Use for | coding agents, anything needing context | quick questions, single-file edits, completions |

**Read before choosing `fast`:** it gets its speed by keeping a 6 GB model on a card with ~6.1 GB usable
under a desktop, which only works through managed-memory oversubscription. Past ~5K tokens of context the
KV cache evicts weights and generation collapses to 0.4–5 tok/s, so the profile caps context at 4K. That is
too small for coding agents, whose system prompts alone usually exceed it. The 1.75-bit weights also cost
real accuracy, and thinking mode does not recover it (14/20 with thinking).

`quality` is the default because it is the one that holds up in agent use. On this box it is limited by
system-RAM bandwidth (~17 GB/s measured), not by the GPU. A 16 GB card would let 2.5–3.5-bit weights
live entirely in VRAM; see [docs/TUNING.md](docs/TUNING.md) for every measurement and what would help.

## Docker API and management dashboards

Use the [Docker stack](docker/README.md) for a persistent OpenAI-compatible API
with LiteLLM virtual keys/rate limits/token usage and a Portainer CE infra UI.
It runs the quality profile and keeps its own PostgreSQL database.

## Requirements

- Linux x86_64, bash ≥ 4.4, `curl`, `tar`, `sha256sum`, `flock`, `setsid`, `python3` (bench/status only)
- NVIDIA GPU with ≥ 8 GB VRAM and driver ≥ 580 (CUDA 13), or set `QLC_LLAMA_VARIANT=cuda-12.8`
- ≥ 24 GB system RAM, ~10 GB disk (plus ~0.6 GB for llama.cpp)

## Quick start

```bash
git clone https://github.com/recycie/qwen-local-coder.git
cd qwen-local-coder
ln -s "$PWD/bin/qlc" ~/.local/bin/qlc   # optional

qlc doctor        # check GPU / RAM / disk
qlc install       # pinned llama.cpp + 8.4 GB model, sha256-verified, resumable
qlc start
qlc bench
```

Switch profile for one run, or permanently:

```bash
QLC_PROFILE=rtx5060-8gb-fast qlc install && QLC_PROFILE=rtx5060-8gb-fast qlc start
echo 'QLC_PROFILE=rtx5060-8gb-fast' >> ~/.config/qwen-local-coder/config.env
```

Already have the GGUF? Point `QLC_MODELS_DIR` at its directory (it is still verified):

```bash
mkdir -p ~/.config/qwen-local-coder
echo 'QLC_MODELS_DIR=~/models' >> ~/.config/qwen-local-coder/config.env
```

## Connecting a coding agent

Any OpenAI-compatible client works:

| Setting | Value |
|---|---|
| Base URL | `http://127.0.0.1:8089/v1` |
| Model | `qwen3.8-27b` |
| API key | anything (or a key from `QLC_API_KEY_FILE`) |

Tool/function calling is enabled (`--jinja`). Thinking is on by default; for quick edits a client can send
`"chat_template_kwargs": {"enable_thinking": false}`, or cap it server-side with
`QLC_EXTRA_ARGS=--reasoning-budget 4096`.

## Commands

| Command | |
|---|---|
| `qlc install [--no-model]` | download and verify pinned artifacts (idempotent) |
| `qlc start [--foreground] [--force]` | start; waits for `/health`, reports startup errors |
| `qlc stop` / `restart` | graceful SIGTERM, SIGKILL after `QLC_STOP_TIMEOUT_S` |
| `qlc status` | process, health, layout, VRAM, Prometheus counters |
| `qlc health` | exit status only, for scripts and probes |
| `qlc logs [-f]` | server log (rotated at 50 MB, 3 kept) |
| `qlc bench` | short-prompt and ~2K-prompt timing on the running server |
| `qlc tune` | find the smallest stable `QLC_CPU_FFN` for *your* GPU and context size |
| `qlc config` / `print-cmd` | resolved settings / exact llama-server command |
| `qlc service install [--now]` | systemd user unit with restart-on-failure |

## Configuration

Settings are resolved as
`config/defaults.env` < `config/profiles/$QLC_PROFILE.env` < `~/.config/qwen-local-coder/config.env` < `QLC_*` environment.
Files are parsed as plain `KEY=VALUE` (never sourced/executed), and unknown keys are rejected so typos fail loudly.
See [config/defaults.env](config/defaults.env) for every option and
[config/config.env.example](config/config.env.example) for common overrides.

The settings that matter most:

| Key | Default | Meaning |
|---|---|---|
| `QLC_CPU_FFN` | 60 | FFN weights of the first N of 64 layers stay in system RAM; everything else is on the GPU. Lower = faster, needs more VRAM. Use `qlc tune`. |
| `QLC_CTX` | 32768 | Context length. Only 16 of 64 layers use full attention, so KV is cheap (~1.1 GB at 32K q8). |
| `QLC_MODEL` | IQ2_XS | GSQ-RCO with MTP: `IQ2_XS` 8.4 GB, `IQ2_S` 9.3 GB, `IQ3_XXS` 10.1 GB, `IQ3_S` 11.8 GB. Unsloth, no MTP: `UD-IQ1_M` 6.3 GB, `UD-IQ2_XXS` 6.8 GB |
| `QLC_SPEC_TYPE` | draft-mtp | `draft-mtp` (needs an MTP model), `ngram-mod` (drafts by copying from the prompt; large win on edits when the model is fully on the GPU), `none` |
| `QLC_UNIFIED_MEMORY` | 0 | CUDA managed memory: lets a model bigger than the largest free contiguous VRAM block load, at the risk of collapse once VRAM is oversubscribed |
| `QLC_THREADS` | 6 | CPU threads; more than the P-core count does not help (bandwidth bound) |

## Running as a service

```bash
qlc service install --now
loginctl enable-linger "$USER"     # keep it running while logged out
journalctl --user -u qwen-local-coder -f
```

The unit restarts on failure with a start-rate limit, so a persistent OOM does not thrash the GPU.

## Security

- Binds to `127.0.0.1` by default. Binding to any other address **requires** `QLC_API_KEY_FILE`
  (one key per line, `chmod 600`) unless you explicitly set `QLC_ALLOW_INSECURE=1`.
- Keys are passed by file, never on the command line (not visible in `ps`).
- Every downloaded artifact is pinned by URL (Hugging Face revision / release tag), size and sha256 in
  [locks/artifacts.lock](locks/artifacts.lock); a mismatch aborts the install and deletes the partial file.
- No TLS is terminated here; put a reverse proxy in front if you expose it beyond your machine.

## Development

```bash
tests/test_cli.sh                                   # hermetic: no GPU, network or model needed
shellcheck -x bin/qlc lib/common.sh tests/test_cli.sh
```

CI runs both on every push.

## License

MIT for this repository. Qwen3.8-27B and the GSQ-RCO quantizations are Apache-2.0; llama.cpp is MIT.
