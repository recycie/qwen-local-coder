# qwen-local-coder

Run **Qwen3.8-27B** (the strongest open coding model in the 20–40B class as of Oct 2026) as a local,
OpenAI-compatible backend for coding agents, on a **consumer 8 GB GPU**.

It is a single, dependency-light CLI (`qlc`) around a pinned [llama.cpp](https://github.com/ggml-org/llama.cpp)
build, with checksum-verified downloads, a tuned tensor placement for small GPUs, MTP speculative decoding,
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

The weights are the [ISTA-DASLab GSQ-RCO](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF)
non-uniform quantization, which keeps far more quality at 2.5 bits than standard quants
(LiveCodeBench v6 76.6 vs 72.0 for UD-IQ2_S at the same 8.4 GB), and ships the model's
Multi-Token-Prediction head for speculative decoding.

## Measured performance

RTX 5060 8 GB · i7-12700F · 32 GB RAM · llama.cpp b11576 · profile `rtx5060-8gb`

| | |
|---|---|
| Generation | **~5 tok/s** (4.3–5.4 depending on content) |
| Prompt processing | ~60–80 tok/s |
| MTP draft acceptance | 77–96 % |
| Context | 32K tokens |
| VRAM / RAM | ~5.8 GB (6.8 GB incl. desktop) / ~6 GB mapped |

That is about 4× faster than a naive `--fit` / `-ngl` setup (1.2–2.8 tok/s) on the same machine.
On this box the ceiling is system-RAM bandwidth (~17 GB/s measured), not the GPU; see
[docs/TUNING.md](docs/TUNING.md) for the full investigation and what would make it faster.

**Be realistic:** ~5 tok/s is fine for focused tasks and reviews, slow for long autonomous agent loops.
If you need speed over quality on 8 GB, a 3B-active MoE such as Qwen3.6-35B-A3B runs at ~20 tok/s.

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
| `QLC_MODEL` | IQ2_XS | `IQ2_XS` 8.4 GB, `IQ2_S` 9.3 GB, `IQ3_XXS` 10.1 GB, `IQ3_S` 11.8 GB (higher = better quality, slower here) |
| `QLC_SPEC_TYPE` | draft-mtp | MTP speculative decoding; `none` to disable |
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
