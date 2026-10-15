#!/usr/bin/env bash
set -Eeuo pipefail
# Unset entirely: even GGML_CUDA_ENABLE_UNIFIED_MEMORY=0 enables managed memory.
unset GGML_CUDA_ENABLE_UNIFIED_MEMORY
cpu_ffn=${CPU_FFN:-64}
if [[ ! $cpu_ffn =~ ^(0|[1-9][0-9]?)$ ]] || ((cpu_ffn > 64)); then
  echo "CPU_FFN must be 0..64" >&2
  exit 2
fi
override=()
if ((cpu_ffn > 0)); then
  layers=$(seq -s '|' 0 "$((cpu_ffn - 1))")
  override=(-ot "blk\.(${layers})\.ffn_(up|down|gate)\.weight=CPU")
fi
spec_args=()
case ${SPEC_TYPE:-none} in
  none) ;;
  draft-mtp) spec_args=(--spec-type draft-mtp --spec-draft-n-max 2) ;;
  *) echo "SPEC_TYPE must be none or draft-mtp" >&2; exit 2 ;;
esac
rm -f /tmp/model-ready
/opt/llama/llama-server \
  -m /models/Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf --alias qwen3.8-27b \
  -ngl 99 "${override[@]}" "${spec_args[@]}" \
  -c "${CTX:-32768}" -np 1 -fa on -ctk q8_0 -ctv q8_0 -ub "${UBATCH:-256}" \
  -t "${THREADS:-6}" --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --host 0.0.0.0 --port 8080 --api-key-file /run/secrets/llama_api_key \
  --metrics --no-slots --cache-ram 512 --timeout 1800 "$@" &
server_pid=$!
cleanup() {
  rm -f /tmp/model-ready
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT
for ((attempt = 0; attempt < 120; attempt++)); do
  kill -0 "$server_pid" 2>/dev/null || { wait "$server_pid"; exit 1; }
  if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then break; fi
  sleep 1
done
# Pass the private key through stdin, never argv or logs.
printf 'header = "Authorization: Bearer %s"\n' "$(cat /run/secrets/llama_api_key)" |
  curl --config - --fail --silent --show-error --max-time 180 \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Reply exactly OK"}],"max_tokens":8,"chat_template_kwargs":{"enable_thinking":false}}' \
    -o /tmp/model-warmup.json http://127.0.0.1:8080/v1/chat/completions
touch /tmp/model-ready
echo "Model warm-up complete; ready for inference."
wait "$server_pid"
