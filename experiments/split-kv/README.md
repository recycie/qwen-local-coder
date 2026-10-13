# Experimental split KV placement — 2026-10-13

This experiment did not achieve the goal of 30 tok/s with extended context. It is
not enabled in production. Runtime compiled and executed on RTX 5060 8GB,
i7-12700F, 32GB RAM, with UD-IQ1_M. Desktop VRAM use fluctuated roughly 1.3–1.7GB.

## Implementation

Patch base: llama.cpp 358a420ec4ed59b6b0be08b1d1f71dd478b99a99 (b11576).

- `QLC_HOST_KV_LAYERS=N`: first N attention layers store K/V in host RAM. Counts
  attention layers, not all transformer blocks. No change to recurrent memory.
- `QLC_KV_ATTN_GPU=1`: force Flash Attention onto the first GPU backend. The
  scheduler copies host KV views to GPU. Single-GPU experiment only. This is
  synchronous scheduler staging, not a custom overlapped prefetch pipeline.
- Neither option is set by default. The patch does not evict tokens or truncate
  attention history, and does not alter weight quantization.

Memory confirmed from runtime logs at configured 32K, q8 KV:
- 16 host KV layers: CPU KV 1088 MiB; GPU recurrent state 149.62 MiB.
- 12 host / 4 GPU KV layers: CPU KV 816 MiB; GPU KV 272 MiB;
  GPU recurrent state 149.62 MiB.

## Results

32 generated tokens per completed request; synthetic repeated Python prompt;
greedy decoding, thinking disabled. These are small performance probes, not a
coding-quality benchmark or proof of agent reliability.

| Configuration | Actual prompt | Decode tok/s | Prefill tok/s |
|---|---:|---:|---:|
| All attention KV in RAM, default attention placement, full decode weights GPU/managed | 2181 | 0.32 | 147 |
| All attention KV RAM, force GPU attention, reserve VRAM | 2181 | 4.23 | 71 |
| Same | 10821 | 1.80 | 202 |
| 12 host / 4 GPU KV layers, force GPU, reserve VRAM, ub64, graphs off | 2181 | 4.85 | 82 |

"Reserve VRAM" moves output.weight and FFN weights of blocks 0–3 to CPU. It does NOT satisfy the all-decode-weights-on-GPU requirement.
These initial reserved runs ALSO had managed memory enabled: the probe mistakenly
set GGML_CUDA_ENABLE_UNIFIED_MEMORY=0, which does not disable it. Their timings
remain valid for those actual configurations, but are not a no-paging control.
Token embeddings use the runtime's normal placement.

After fixing the probe to UNSET the managed-memory variable, allocation failed at
5145 MiB (4 CPU FFN blocks), 4747 MiB (12 blocks), and 4117 MiB (24 blocks).
No decode throughput can be inferred from these load failures. The updated probe
uses the correct unset behavior. Earlier timing rows must not be described as
managed-memory-disabled. No 30 tok/s extended-context configuration was obtained. Without that reserve,
forcing GPU attention with ub64/graphs disabled timed out at 180s on a 2.2K
prompt. The reserved all-host/default-placement case also timed out at 180s.

Rows with different batch/graph settings are not a controlled comparison of the
number of offloaded KV layers. The 12-host/4-GPU 10K request timed out
at 180s; it has no completed decode-rate measurement. Do not attribute the speed difference to that
variable alone. Inspect results.jsonl for the complete collected timings/errors.
The first full-weight/default-attention run's 10K request was interrupted after
its slow 2K result; it is not a measured timeout or throughput result.

## Reproduction

Apply llama-b11576.patch to the exact upstream commit above. Build a CUDA server
normally, or for this host's no-toolkit setup build shared libraries with dynamic
backends and attach the *exact same commit's* official CUDA backend and CUDA
runtime libraries. Do not mix backends from other commits/ABIs.

Local build used CMake Release, GGML_BACKEND_DL=ON, BUILD_SHARED_LIBS=ON,
GGML_NATIVE=OFF, GGML_CPU_ALL_VARIANTS=ON, LLAMA_OPENSSL=OFF,
LLAMA_BUILD_TESTS=OFF, LLAMA_BUILD_EXAMPLES=OFF. LLAMA_UI_GZIP=OFF worked around
upstream UI asset generation on /home -> /var/home. No compiled binaries or model
weights are included in this experiment.

```
python3 probe.py --runtime /absolute/path/to/bin --model /absolute/path/model.gguf \
  --layers 16 --force 1 --reserve
python3 probe.py --runtime /absolute/path/to/bin --model /absolute/path/model.gguf \
  --layers 12 --force 1 --reserve --ub 64 --no-graphs
```

Probe uses loopback port 8094; run sequentially. Child server is stopped in
finally. Logs go to split-kv-results (override --out). JSON results print to stdout.
