# Docker API stack

Qwen3.8-27B quality profile (32K context) + LiteLLM gateway/UI + dedicated PostgreSQL
+ Portainer CE. Inference uses the pinned upstream llama.cpp b11576 CUDA 13.4
binaries, not the experimental split-KV patch. Existing local GGUF files are
mounted read-only. The inference backend and database have no host ports.

## Start

Requires Linux x86_64, NVIDIA driver compatible with CUDA 13.4, Docker Compose,
and working NVIDIA CDI (`nvidia-ctk cdi list`). Tested on Docker 29.8.2 / RTX 5060
8GB. CDI avoids changing the Docker daemon runtime configuration.

From the repository root, with the quality GGUF already installed:

```bash
# If needed: bin/qlc install
python3 docker/setup.py --models-dir "$HOME/models"
(cd docker && docker compose up -d --build --wait --wait-timeout 300)
python3 docker/bootstrap.py
```

All public ports bind to loopback by default:

| Purpose | URL |
|---|---|
| OpenAI-compatible API base | http://127.0.0.1:4000/v1 |
| LiteLLM keys / model routing / usage UI | http://127.0.0.1:4000/ui/ |
| Portainer infrastructure / container logs / stats | https://127.0.0.1:9443 |

Portainer uses a self-signed certificate and username `admin`. LiteLLM uses a
database-backed admin (`admin@local.invalid` by default; configure with
`setup.py --admin-email`). Each account has a different random password. Credentials and the separate client API
key are saved to `~/.config/qwen-local-coder/docker-access.env` (mode 600).
They are not included in Git. Setup/bootstrap can be rerun without regenerating
existing credentials. If you change an admin password in the UI, update your
private access file and the matching private `.env` value before rerunning
bootstrap. Bootstrap preserves existing accounts and passwords. Environment
credential login is disabled; the master key remains a management API credential.

The client key is named `local-dev`, scoped to `qwen3.8-27b`, with 6 requests/min,
120,000 tokens/min and 1 parallel request. Change limits or create/revoke keys in
LiteLLM's Virtual Keys screen. Use the client key for applications, not the master
key. Local token costs are configured as $0; token counts are real, but hardware
and electricity costs are not estimated and dollar budgets do not enforce a
local-token allowance. TPM/RPM limits control rate.

```bash
source "$HOME/.config/qwen-local-coder/docker-access.env"
curl "$OPENAI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Write a Python add function"}],"max_tokens":256,"chat_template_kwargs":{"enable_thinking":false}}'
```

Other containers can join the `qlc-api` network and use
`http://gateway:4000/v1`, with the same client-key authentication. Loopback URLs
inside another container point to that container, not this gateway.

## Operations

```bash
(cd docker && docker compose ps)
(cd docker && docker compose logs --tail 100 inference gateway)
(cd docker && docker compose stop)
# Start again, preserving all data:
(cd docker && docker compose up -d)
```

Restart policy is `unless-stopped`. Portainer has Docker socket access so its
admin can manage this host's containers. Model parameters CTX, CPU_FFN, UBATCH, SPEC_TYPE and
THREADS can be set in `docker/.env`; then recreate only inference with Compose.
Portainer can start/stop containers and inspect resources/logs; Compose remains
the source of truth for this externally created stack's configuration.

Back up `docker/.env`, `docker/.runtime`, and the `qlc_postgres_data` and
`qlc_portainer_data` named volumes together. Do not regenerate LITELLM_SALT_KEY
against an existing database. Do not use `down -v` unless deleting the key/usage
and infrastructure databases is intended. GGUFs remain in the host models folder.

## Verification on 2026-10-15

- All services started; inference, database and gateway health checks passed.
- Both web UIs returned HTTP 200; admin authentication verified for both.
- Portainer's local endpoint successfully queried Docker 29.8.2.
- Client `/v1/models` listed the model; an invalid key returned HTTP 401.
- Chat generation, a `read_file` tool call, and SSE streaming passed through the
  gateway. No generated tools were executed on the host.
- The three inference requests reported 321 prompt + 46 completion = 367 tokens.
  The PostgreSQL usage rows and LiteLLM usage-dashboard API agreed. Activity
  also included two failed authorization probes (zero tokens).

Upstream: [LiteLLM](https://docs.litellm.ai/docs/proxy/docker_quick_start),
[Portainer CE](https://docs.portainer.io/start/install-ce/server/docker/linux).

## Stable inference and public access

The default profile keeps 32K context, moves all 64 FFN layers to CPU, uses
256-token microbatches and disables speculative MTP decoding. These defaults
leave VRAM headroom for generation on the tested 8GB GPU. Speculative decoding
can be enabled with `SPEC_TYPE=draft-mtp` after checking memory under load.
Readiness requires a real authenticated generation warm-up, not just model load.
The gateway defaults to 1,024 output tokens with thinking disabled; callers can
override these request settings. Long-context throughput is not guaranteed.

See [public deployment](PUBLIC.md) for the Cloudflare Tunnel deployment.
Compose commands above preserve the public override selected in `docker/.env`.

Additional verification on 2026-10-15: public HTTPS UI, API and Portainer login
passed; unauthenticated API access returned 401 and admin paths on the API host
returned 404. A real UI-session poem request completed (128 output tokens), and
public SSE generation passed. Inference stayed healthy with zero restarts after
the memory-profile fix. The old environment-password login returned 401 while
the new database admin login succeeded.

## Restore the short-context fast profile

Set `INFERENCE_PROFILE=fast` in private `docker/.env`, then recreate inference:

```bash
(cd docker && docker compose up -d --build --no-deps inference)
```

This selects the existing `Qwen3.8-27B-UD-IQ1_M.gguf`, whole-model GPU managed
memory, ngram speculation, 4,096-token context and 512-token microbatches. It
overrides CTX/CPU_FFN/UBATCH/SPEC_TYPE while selected. The API model alias stays
`qwen3.8-27b`. The smaller quantization trades accuracy for speed; long agent
prompts must fit the 4K total input/output budget. The first request can be slow
as managed-memory pages migrate. Set `INFERENCE_PROFILE=quality` to restore the
32K quality profile. See the measured limitations in [tuning notes](../docs/TUNING.md).
