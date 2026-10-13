# Tuning notes: Qwen3.8-27B on an 8 GB GPU

These are the measurements behind the `rtx5060-8gb-quality` and `rtx5060-8gb-fast` profiles, so you can re-derive settings for other hardware.

Test machine: RTX 5060 8 GB (≈6.6 GB free under a Wayland desktop), i7-12700F (8P+4E), 32 GB RAM,
llama.cpp b11576. Prompt: "LRU cache + tests", thinking off; generation tok/s.

## 1. The bottleneck is system-RAM bandwidth

| Run | Weights in RAM | tok/s | Implied bandwidth |
|---|---|---|---|
| Q4_0, CPU only | 14.9 GiB | 1.15 | ~17 GiB/s |
| IQ3_XXS, `-ngl 30` | ~5.2 GiB | 3.4 | ~17 GiB/s |

A dense 27B model reads every weight for every token, so speed ≈ RAM bandwidth ÷ bytes left in RAM.
17 GiB/s is low for this CPU (dual-channel DDR4-3200 should give ~40 GiB/s, DDR5 ~60+). If yours is similar,
check that both memory channels are populated and XMP/EXPO is enabled. That alone should roughly double speed.

Threads: 6 ≥ 8 ≥ 12 ≥ 16 (3.42 / 3.38 / 3.25 / 3.15 tok/s). More threads only add contention.

## 2. Use fewer bits: GSQ-RCO IQ2_XS

Fewer bytes per token beats everything else here. ISTA-DASLab's GSQ-RCO IQ2_XS (2.5 bpw, 8.4 GB) keeps
LiveCodeBench v6 at 76.6 (BF16: 85.7), versus 72.0 for UD-IQ2_S at the same size. IQ3_XXS (84.6) is the
better-quality option if you have more VRAM or bandwidth.

## 3. Place tensors by hand instead of whole layers

`--fit on` and plain `-ngl N` put whole layers on the CPU, including the output head (lm_head) when N < 65.
Measured: 1.2–2.8 tok/s (`--fit`), ~4.4 tok/s (best `-ngl`).

Better: `-ngl 99` plus `--override-tensor 'blk\.(0|…|N-1)\.ffn_(up|down|gate)\.weight=CPU'`.
Attention, the Gated-DeltaNet recurrent tensors, lm_head and the MTP head all stay on the GPU; only the
FFN matrices, which are the bulk of the bytes, are streamed from RAM.

VRAM budget at 32K context (IQ2_XS, `QLC_CPU_FFN=60`):

| Item | MiB |
|---|---|
| GPU weights | ~3,700 |
| KV cache (16 full-attention layers, q8_0) | 1,088 |
| Recurrent state (64 layers, 3 seqs for MTP) | 599 |
| MTP draft KV (f16) | 128 |
| Compute buffers | ~250 |

## 4. MTP speculative decoding

`--spec-type draft-mtp --spec-draft-n-max 3` drafts with the model's own MTP head: 77–96 % acceptance.
The speedup is only ~15 % because IQ2/IQ3 types have no CPU repack (batched GEMM) kernels, so verifying
4 tokens on the CPU costs nearly 4× one token. It is still a net win and has no quality cost.

Do **not** quantize the draft KV (`-ctkd/-ctvd q8_0`). It saves 64 MiB but OOM-crashes at runtime
(`cuMemCreate` during the first request).

## 5. Stability margin

Load-time success is not enough: the CUDA memory pool grows on the first real request. `qlc tune` therefore
starts the server, sends a ~2K-token prompt and checks it is still healthy before accepting a value.

| `QLC_CPU_FFN` @ 32K | Result |
|---|---|
| 56 (with q8 draft KV) | OOM at context creation |
| 58 (with q8 draft KV) | loads, crashes on first request |
| **60** | stable, 5.2 tok/s |
| 62 | stable, 4.9 tok/s |

58 without the q8 draft KV has not been re-tested; run `qlc tune --from 56` to check on your machine.
At 16K context, 52 is stable (5.4 tok/s).

## 6. The fast profile: whole model on the GPU, and where it breaks

Theoretical ceiling with every weight in VRAM: 448 GB/s ÷ ~6 GB ≈ 75 tok/s. Getting there on an 8 GB
desktop card runs into two walls.

**Wall 1: one large allocation fails.** With 6.6–6.8 GB reported free, any single `cudaMalloc` above about
5.4 GB fails (5.4, 5.6, 5.8 and 6.0 GB all tried). `-sm row` is not supported on one device, and
`-sm tensor` still makes one allocation. `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` (managed memory) gets past this,
An earlier claimed overhead comparison (12.53 vs 12.54 tok/s) is invalid: setting
`GGML_CUDA_ENABLE_UNIFIED_MEMORY=0` still enables it in b11576, which checks only
whether the variable exists. To disable managed memory, unset the variable entirely.

**Wall 2: the real budget is ~6.1 GB.** Everything llama.cpp allocates has to fit in about 6.1 GB, the same
total the stable quality profile uses. UD-IQ1_M's GPU-resident weights alone are 6.0 GB, so under managed
memory it fits only while the KV pages are untouched:

| Prompt tokens (ctx 8K, q8 KV) | Generation |
|---|---|
| 1,104 (first request) | 5.8 tok/s (pages migrating) |
| 2,184 | 32.7 tok/s |
| 4,344 | 31.7 tok/s |
| 6,144 | 5.0 tok/s |
| 10,824 (ctx 32K) | 0.4 tok/s |

So `rtx5060-8gb-fast` caps context at 4K. q4_0 KV with `-ub 256` did not fix it and made short prompts
slower. Offloading 4 FFN layers was erratic (5–23 tok/s).

**Speculation:** `ngram-mod` drafts by copying spans from the prompt. With the model fully on the GPU,
verification is cheap. A whole-file rename edit runs at **108–112 tok/s** (543/544 drafts accepted);
fresh code stays at ~31–33 tok/s (acceptance ~25 %, close to free). With FFN in system RAM it is a loss:
UD-IQ2_XXS with 6 CPU layers dropped from ~18 to 12 tok/s on the same edit.

**Quality** (HumanEval-20, greedy, tests in an offline sandbox):

| Weights | Placement | tok/s | Pass |
|---|---|---|---|
| GSQ-RCO IQ2_XS (2.5 bpw) | 60 FFN layers in RAM | 5.0 | **19/20** |
| UD-IQ2_XXS (≈2.1 bpw) | 6 FFN layers in RAM, managed | 13–18 | 17/20 |
| UD-IQ1_M (1.75 bpw) | all GPU, managed | 29–33 | 15/20 |
| UD-IQ1_M, thinking on (6K budget) | all GPU, managed | 33 | 14/20 (2 ran out of budget) |

IQ1_M fails the same problems with and without thinking, which points at knowledge lost to quantization
rather than missing reasoning. The UD-IQ2_XXS middle option is not shipped: at 2K prompts it collapsed to
0.5 tok/s for the same oversubscription reason.

MTP cannot be added to the fast profile: Unsloth's main GGUFs have `nextn_predict_layers = 0`, and grafting
the 332 MiB MTP layer plus its ~400 MiB of extra recurrent state does not fit in the budget.

## Things that did not help

- **Q4_0** (CPU repack kernels): 15 GB is too many bytes for 17 GiB/s, 1.6 tok/s at `-ngl 20`.
- **Bigger `-ub`** for prompt processing: 52 → 80 tok/s going from 512 to 1024 on Qwen3.6-35B-A3B,
  and `-ub` ≥ 2048 OOMs on 8 GB. Not yet measured on the 27B model, which stays at 512.
- **`--fit`**: picks a placement about 2× slower than the manual one above (2.8 vs 5.2 tok/s).

## Ideas not yet tried

- Requantizing only the CPU-resident FFN tensors to a repack-friendly type (Q2_K / IQ4_NL) so MTP verification
  batches on the CPU. Trades quality for possibly ~2× speed.
- `draft-mtp,ngram-mod` stacked, once the model is fully in VRAM.
- A 12–16 GB GPU, or any setup where the display runs on another GPU: the GSQ-RCO IQ2_XS/IQ3_XXS
  weights would sit entirely in VRAM. With MTP plus ngram speculation, this should give the fast profile's
  speed at the quality profile's accuracy and full context. Not yet measured.
