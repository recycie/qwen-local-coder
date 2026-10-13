# shellcheck shell=bash
# Shared helpers for qlc. Sourced, never executed directly.

# ---------------------------------------------------------------- logging

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _C_RED=$'\e[31m' _C_YEL=$'\e[33m' _C_BLU=$'\e[34m' _C_RST=$'\e[0m'
else
  _C_RED='' _C_YEL='' _C_BLU='' _C_RST=''
fi

log()  { printf '%s[qlc]%s %s\n' "$_C_BLU" "$_C_RST" "$*" >&2; }
warn() { printf '%s[qlc] warning:%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
die()  { printf '%s[qlc] error:%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; exit "${2:-1}"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ---------------------------------------------------------------- config

# Names of QLC_* variables supplied by the caller's environment; they win over files.
declare -A _QLC_ENV_SET=()

config_snapshot_env() {
  local v
  while IFS= read -r v; do
    [[ -n "$v" ]] && _QLC_ENV_SET["$v"]=1
  done < <(compgen -e | grep '^QLC_' || true)
}

# shellcheck disable=SC2016,SC2088  # matching literal "$HOME"/"~" text on purpose
_expand_home() {
  local s=$1
  s=${s//'${HOME}'/$HOME}
  s=${s//'$HOME'/$HOME}
  [[ "$s" == "~" ]] && s=$HOME
  [[ "$s" == "~/"* ]] && s="$HOME/${s#\~/}"
  printf '%s' "$s"
}

# Parse KEY=VALUE lines without executing anything. Unknown keys are rejected
# so that typos surface instead of being silently ignored.
config_load_file() {
  local file=$1 only_key=${2:-} line key val n=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*(QLC_[A-Z0-9_]+)=(.*)$ ]]; then
      die "$file:$n: expected QLC_KEY=VALUE, got: $line"
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    # strip one layer of matching quotes
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val=${BASH_REMATCH[1]}
    fi
    if [[ -n "${_QLC_KNOWN:-}" && " $_QLC_KNOWN " != *" $key "* ]]; then
      die "$file:$n: unknown setting $key"
    fi
    [[ -n "$only_key" && "$key" != "$only_key" ]] && continue
    [[ -n "${_QLC_ENV_SET[$key]:-}" ]] && continue
    printf -v "$key" '%s' "$(_expand_home "$val")"
  done <"$file"
}

config_user_file() {
  printf '%s' "${QLC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/qwen-local-coder/config.env}"
}

# Resolve all settings: defaults < profile < user config < environment.
config_load() {
  local root=$1 user_file
  user_file=$(config_user_file)
  config_snapshot_env
  _QLC_KNOWN=""
  config_load_file "$root/config/defaults.env"
  _QLC_KNOWN=$(grep -oE '^QLC_[A-Z0-9_]+' "$root/config/defaults.env" | tr '\n' ' ')
  # the profile name itself may come from the user file
  config_load_file "$user_file" QLC_PROFILE
  local profile="$root/config/profiles/${QLC_PROFILE}.env"
  [[ -f "$profile" ]] || die "unknown profile '$QLC_PROFILE' (no $profile)"
  config_load_file "$profile"
  config_load_file "$user_file"
  # environment values also get ~ expansion
  local k
  for k in "${!_QLC_ENV_SET[@]}"; do
    printf -v "$k" '%s' "$(_expand_home "${!k}")"
  done
  : "${QLC_MODELS_DIR:=$QLC_DATA_DIR/models}"
  config_validate
}

_is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
_is_num()  { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

config_validate() {
  local k
  for k in QLC_PORT QLC_CTX QLC_CPU_FFN QLC_THREADS QLC_BATCH QLC_UBATCH QLC_SPEC_N_MAX \
           QLC_TOP_K QLC_TIMEOUT_S QLC_START_TIMEOUT_S QLC_STOP_TIMEOUT_S QLC_MIN_FREE_VRAM_MIB \
           QLC_CACHE_RAM_MIB; do
    _is_uint "${!k}" || die "$k must be a non-negative integer (got '${!k}')"
  done
  for k in QLC_TEMP QLC_TOP_P QLC_MIN_P; do
    _is_num "${!k}" || die "$k must be a number (got '${!k}')"
  done
  ((QLC_PORT >= 1 && QLC_PORT <= 65535)) || die "QLC_PORT out of range: $QLC_PORT"
  ((QLC_UBATCH <= QLC_BATCH)) || die "QLC_UBATCH ($QLC_UBATCH) must be <= QLC_BATCH ($QLC_BATCH)"
  ((QLC_CPU_FFN <= 64)) || die "QLC_CPU_FFN must be 0..64 (Qwen3.8-27B has 64 layers)"
  case "$QLC_KV_TYPE" in f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0) ;; *) die "bad QLC_KV_TYPE: $QLC_KV_TYPE" ;; esac
  case "$QLC_FLASH_ATTN" in on|off|auto) ;; *) die "bad QLC_FLASH_ATTN: $QLC_FLASH_ATTN" ;; esac
  case "$QLC_SPEC_TYPE" in none|draft-mtp|ngram-mod|ngram-simple|draft-mtp,ngram-mod) ;; *) die "bad QLC_SPEC_TYPE: $QLC_SPEC_TYPE" ;; esac
  case "$QLC_ALLOW_INSECURE" in 0|1) ;; *) die "QLC_ALLOW_INSECURE must be 0 or 1" ;; esac
  case "$QLC_UNIFIED_MEMORY" in 0|1) ;; *) die "QLC_UNIFIED_MEMORY must be 0 or 1" ;; esac
  [[ "$QLC_ALIAS" =~ ^[A-Za-z0-9._:-]+$ ]] || die "bad QLC_ALIAS: $QLC_ALIAS"
  if [[ -n "$QLC_API_KEY_FILE" ]]; then
    [[ -r "$QLC_API_KEY_FILE" ]] || die "QLC_API_KEY_FILE not readable: $QLC_API_KEY_FILE"
    local perm
    perm=$(stat -c '%a' "$QLC_API_KEY_FILE")
    [[ "$perm" =~ ^[0-7]00$ ]] || warn "API key file $QLC_API_KEY_FILE has mode $perm; use chmod 600"
  fi
  if ! is_loopback "$QLC_HOST" && [[ -z "$QLC_API_KEY_FILE" && "$QLC_ALLOW_INSECURE" != 1 ]]; then
    die "refusing to bind $QLC_HOST without QLC_API_KEY_FILE (set QLC_ALLOW_INSECURE=1 to override)"
  fi
}

is_loopback() {
  case "$1" in 127.*|::1|localhost) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- artifacts

# lock_get <id> -> sets LOCK_FILE LOCK_SIZE LOCK_SHA LOCK_URL
lock_get() {
  local id=$1 lid file size sha url
  while read -r lid file size sha url; do
    [[ -z "$lid" || "$lid" == \#* ]] && continue
    if [[ "$lid" == "$id" ]]; then
      LOCK_FILE=$file LOCK_SIZE=$size LOCK_SHA=$sha LOCK_URL=$url
      return 0
    fi
  done <"$QLC_ROOT/locks/artifacts.lock"
  die "artifact '$id' not found in locks/artifacts.lock"
}

# Cheap cache of a successful verification so huge files are not re-hashed on
# every start: "<sha256> <size> <mtime>" stored next to the file.
_stamp_of() { stat -c '%s %Y' "$1"; }

verify_file() {
  local path=$1 sha=$2 size=$3 marker="$1.verified" actual
  [[ -f "$path" ]] || return 1
  [[ "$(stat -c '%s' "$path")" == "$size" ]] || return 1
  if [[ -f "$marker" && "$(cat "$marker")" == "$sha $(_stamp_of "$path")" ]]; then
    return 0
  fi
  log "verifying sha256 of $(basename "$path") ..."
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  if [[ "$actual" != "$sha" ]]; then
    warn "checksum mismatch for $path (expected $sha, got $actual)"
    return 1
  fi
  printf '%s %s\n' "$sha" "$(_stamp_of "$path")" >"$marker" 2>/dev/null || true
}

# fetch_artifact <id> <dest-dir> -> prints the verified file path
fetch_artifact() {
  local id=$1 dir=$2 dest part
  lock_get "$id"
  dest="$dir/$LOCK_FILE"
  part="$dest.part"
  mkdir -p "$dir"
  if verify_file "$dest" "$LOCK_SHA" "$LOCK_SIZE"; then
    printf '%s\n' "$dest"
    return 0
  fi
  [[ -e "$dest" ]] && { warn "replacing invalid $dest"; rm -f -- "$dest" "$dest.verified"; }
  local avail need
  avail=$(df -B1 --output=avail "$dir" | tail -1 | tr -d ' ')
  need=$((LOCK_SIZE - $( [[ -f "$part" ]] && stat -c '%s' "$part" || echo 0 )))
  ((avail > need + 1073741824)) || die "not enough disk space in $dir (need $((need >> 20)) MiB + 1 GiB headroom)"
  log "downloading $LOCK_FILE ($((LOCK_SIZE >> 20)) MiB)"
  local tries=0 progress=(-sS)
  [[ -t 2 ]] && progress=(--progress-bar)
  until curl -fL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
          -C - "${progress[@]}" -o "$part" "$LOCK_URL"; do
    tries=$((tries + 1))
    ((tries < 3)) || die "download failed: $LOCK_URL"
    warn "download interrupted, resuming (attempt $((tries + 1)))"
    sleep 5
  done
  verify_file "$part" "$LOCK_SHA" "$LOCK_SIZE" || { rm -f -- "$part" "$part.verified"; die "verification failed for $LOCK_FILE; partial file removed"; }
  mv -f -- "$part" "$dest"
  mv -f -- "$part.verified" "$dest.verified" 2>/dev/null || true
  printf '%s %s\n' "$LOCK_SHA" "$(_stamp_of "$dest")" >"$dest.verified"
  printf '%s\n' "$dest"
}

llama_dir()  { printf '%s/llama.cpp/b11576-%s' "$QLC_DATA_DIR" "$QLC_LLAMA_VARIANT"; }
model_path() { lock_get "model-$QLC_MODEL"; printf '%s/%s' "$QLC_MODELS_DIR" "$LOCK_FILE"; }

# ---------------------------------------------------------------- process

pid_file() { printf '%s/run/server-%s.pid' "$QLC_STATE_DIR" "$QLC_PORT"; }
log_file() { printf '%s/logs/server-%s.log' "$QLC_STATE_DIR" "$QLC_PORT"; }

# Prints the running server pid for this port, if any (validated against /proc
# so a recycled pid never gets signalled).
server_pid() {
  local pf pid
  pf=$(pid_file)
  [[ -f "$pf" ]] || return 1
  pid=$(<"$pf")
  _is_uint "$pid" || return 1
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q 'llama-server' || return 1
  printf '%s\n' "$pid"
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

base_url() {
  local h=$QLC_HOST
  [[ "$h" == 0.0.0.0 || "$h" == "::" ]] && h=127.0.0.1
  [[ "$h" == *:* ]] && h="[$h]"
  printf 'http://%s:%s' "$h" "$QLC_PORT"
}

# curl wrapper that adds the API key when configured
api_curl() {
  local args=(-sS --max-time "${API_TIMEOUT:-30}")
  if [[ -n "$QLC_API_KEY_FILE" ]]; then
    local key
    key=$(grep -v '^[[:space:]]*#' "$QLC_API_KEY_FILE" | grep -m1 . || true)
    [[ -n "$key" ]] && args+=(-H "Authorization: Bearer $key")
  fi
  curl "${args[@]}" "$@"
}

health_status() {
  # prints HTTP status code (000 when unreachable)
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(base_url)/health" || true
}

gpu_free_mib() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '
}
