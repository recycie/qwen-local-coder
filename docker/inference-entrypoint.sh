#!/usr/bin/env bash
set -Eeuo pipefail
# Unset entirely: even GGML_CUDA_ENABLE_UNIFIED_MEMORY=0 enables managed memory.
unset GGML_CUDA_ENABLE_UNIFIED_MEMORY
cpu_ffn=${CPU_FFN:-60}
if [[ ! $cpu_ffn =~ ^(0|[1-9][0-9]?)$ ]] || ((cpu_ffn > 64)); then
  echo "CPU_FFN must be 0..64" >&2
  exit 2
fi
override=()
if ((cpu_ffn > 0)); then
  layers=$(seq -s '|' 0 "$((cpu_ffn - 1))")
  override=(-ot "blk\.(${layers})\.ffn_(up|down|gate)\.weight=CPU")
fi
exec /opt/llama/llama-server \
  -m /models/Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf --alias qwen3.8-27b \
  -ngl 99 "${override[@]}" --spec-type draft-mtp --spec-draft-n-max 3 \
  -c "${CTX:-32768}" -np 1 -fa on -ctk q8_0 -ctv q8_0 -ub 512 \
  -t "${THREADS:-6}" --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --host 0.0.0.0 --port 8080 --api-key-file /run/secrets/llama_api_key \
  --metrics --no-slots --cache-ram 512 --timeout 1800 "$@"
