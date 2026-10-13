#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # terse assertions; the literal $(...) is the injection payload
# Hermetic CLI tests: no GPU, network or model needed.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
QLC="$ROOT/bin/qlc"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# isolate from the developer's real config and environment
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" NO_COLOR=1
mkdir -p "$HOME"
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^QLC_' || true)

pass=0 fail=0
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
expect_contains() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "missing: $3"; }
expect_fail() { local name=$1; shift; if out=$("$@" 2>&1); then bad "$name" "unexpectedly succeeded"; else expect_contains "$name" "$out" "${EXPECT:-}"; fi; }

out=$("$QLC" --help)
expect_contains "help lists commands" "$out" "service install"

out=$("$QLC" print-cmd)
expect_contains "default port" "$out" "--port 8089"
expect_contains "default ctx" "$out" "--ctx-size 32768"
expect_contains "mtp speculation" "$out" "--spec-type draft-mtp"
expect_contains "ffn override covers layer 59" "$out" "\|58\|59\)"
[[ "$out" != *"\|60\|"* ]] && ok "ffn override stops at 59" || bad "ffn override stops at 59"
[[ "$out" != *"-ctkd"* ]] && ok "draft KV not quantized" || bad "draft KV not quantized"
expect_contains "binds loopback" "$out" "--host 127.0.0.1"

out=$(QLC_CPU_FFN=0 QLC_SPEC_TYPE=none "$QLC" print-cmd)
[[ "$out" != *"override-tensor"* && "$out" != *"spec-type"* ]] && ok "cpu_ffn=0 / spec none drop flags" || bad "cpu_ffn=0 / spec none drop flags"

mkdir -p "$XDG_CONFIG_HOME/qwen-local-coder"
cat >"$XDG_CONFIG_HOME/qwen-local-coder/config.env" <<'EOF'
# user overrides
QLC_PORT=9001
QLC_MODELS_DIR=~/models
QLC_EXTRA_ARGS=--reasoning-budget 4096
EOF
out=$("$QLC" print-cmd)
expect_contains "user config overrides port" "$out" "--port 9001"
expect_contains "tilde expanded" "$out" "$HOME/models/Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf"
expect_contains "extra args split" "$out" "--reasoning-budget 4096"

out=$(QLC_PORT=9002 "$QLC" print-cmd)
expect_contains "env beats user config" "$out" "--port 9002"

out=$("$QLC" config)
expect_contains "config shows source" "$out" "QLC_PORT=9001"

printf 'QLC_PROT=1\n' >>"$XDG_CONFIG_HOME/qwen-local-coder/config.env"
EXPECT="unknown setting QLC_PROT" expect_fail "typo in config rejected" "$QLC" print-cmd
sed -i '/QLC_PROT/d' "$XDG_CONFIG_HOME/qwen-local-coder/config.env"

printf 'QLC_PORT=$(touch %s/pwned)\n' "$TMP" >>"$XDG_CONFIG_HOME/qwen-local-coder/config.env"
"$QLC" print-cmd >/dev/null 2>&1 || true
[[ ! -e "$TMP/pwned" ]] && ok "config is parsed, never executed" || bad "config is parsed, never executed"
sed -i '$d' "$XDG_CONFIG_HOME/qwen-local-coder/config.env"

EXPECT="refusing to bind" expect_fail "public bind needs api key" env QLC_HOST=0.0.0.0 "$QLC" print-cmd
out=$(QLC_HOST=0.0.0.0 QLC_ALLOW_INSECURE=1 "$QLC" print-cmd 2>&1)
expect_contains "insecure override" "$out" "--host 0.0.0.0"

printf 'secret\n' >"$TMP/keys"; chmod 600 "$TMP/keys"
out=$(QLC_HOST=0.0.0.0 QLC_API_KEY_FILE="$TMP/keys" "$QLC" print-cmd)
expect_contains "api key file passed" "$out" "--api-key-file $TMP/keys"
[[ "$out" != *secret* ]] && ok "key never on command line" || bad "key never on command line"

EXPECT="QLC_CTX must be" expect_fail "non-numeric ctx rejected" env QLC_CTX=big "$QLC" print-cmd
EXPECT="QLC_UBATCH" expect_fail "ubatch > batch rejected" env QLC_UBATCH=4096 QLC_BATCH=512 "$QLC" print-cmd
EXPECT="unknown profile" expect_fail "unknown profile rejected" env QLC_PROFILE=nope "$QLC" print-cmd
EXPECT="not found in locks" expect_fail "unknown model rejected" env QLC_MODEL=Q9 "$QLC" print-cmd
EXPECT="unknown command" expect_fail "unknown command" "$QLC" frobnicate

out=$("$QLC" status 2>&1 || true)
expect_contains "status when stopped" "$out" "not running"
out=$("$QLC" stop 2>&1)
expect_contains "stop is idempotent" "$out" "not running"
EXPECT="llama.cpp not installed" expect_fail "start without install" "$QLC" start

# lock file sanity: every row has 5 fields and a 64-hex sha256
while read -r id file size sha url; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  if [[ "$sha" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ && "$url" == https://* && "$url" == *"$file" ]]; then
    ok "lock entry $id"
  else
    bad "lock entry $id"
  fi
done <"$ROOT/locks/artifacts.lock"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
