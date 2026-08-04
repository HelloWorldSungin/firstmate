# shellcheck shell=bash
# Per-home GBrain scoping primitives.
# Usage: . bin/fm-gbrain-lib.sh   (no FM_* setup required)
#
# This library is the single owner of how a Firstmate home resolves its OWN
# brain, how the three GBrain configuration planes are validated, and how a
# credential is read. bin/fm-gbrain.sh is the operator surface over it, and
# docs/gbrain-scoping.md owns the contract those two implement.
#
# The three planes exist because they propagate differently, and collapsing
# them would either leak a credential downstream or make two homes write one
# brain:
#
#   config/gbrain.json          SHARED, inherited by secondmate homes. A closed
#                               schema of endpoints and model choices. It can
#                               name a credential but never carry one, and it
#                               cannot name a brain location or a client
#                               identity, so inheriting it verbatim can never
#                               point two homes at one index.
#   config/gbrain-local.json    HOME-LOCAL, never inherited. This home's own
#                               brain root override and its own OAuth client id.
#   config/gbrain-secrets/<n>   CREDENTIALS, never inherited. Each is a regular
#                               file with mode 0600, refused when stored more
#                               loosely, exactly as config/forge-tokens/<host>
#                               already is (bin/fm-issue-status.sh).
#
# bin/fm-config-inherit-lib.sh carries gbrain.json and deliberately carries
# neither of the other two.

# --- plane locations --------------------------------------------------------

FM_GBRAIN_SHARED_FILE="gbrain.json"
FM_GBRAIN_LOCAL_FILE="gbrain-local.json"
FM_GBRAIN_SECRETS_DIR="gbrain-secrets"

# The brain root under a home when config/gbrain-local.json declares no
# override. data/ is the home's durable private record area and is already
# gitignored per home, so this derivation isolates two homes by construction
# rather than by an operator remembering to set a path.
FM_GBRAIN_DEFAULT_SUBDIR="data/gbrain"

FM_GBRAIN_ERROR=""
FM_GBRAIN_BRAIN_ROOT=""
FM_GBRAIN_HOME_DIR=""
FM_GBRAIN_PGLITE=""
FM_GBRAIN_ARCHIVE=""

fm_gbrain_fail() {
  FM_GBRAIN_ERROR=$1
  return 1
}

fm_gbrain_config_dir() {  # <home>
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$1/config}"
}

fm_gbrain_shared_path() {  # <home>
  printf '%s/%s\n' "$(fm_gbrain_config_dir "$1")" "$FM_GBRAIN_SHARED_FILE"
}

fm_gbrain_local_path() {  # <home>
  printf '%s/%s\n' "$(fm_gbrain_config_dir "$1")" "$FM_GBRAIN_LOCAL_FILE"
}

fm_gbrain_secret_path() {  # <home> <name>
  printf '%s/%s/%s\n' "$(fm_gbrain_config_dir "$1")" "$FM_GBRAIN_SECRETS_DIR" "$2"
}

# --- value shapes -----------------------------------------------------------
#
# The shared plane's schema is closed and every field is shape-checked. That is
# what makes "this file cannot carry a credential" a property rather than a
# naming convention: there is no free-form string field for one to hide in.

fm_gbrain_is_secret_name() {  # <value>
  case $1 in
    *[!a-z0-9-]* | '' | -* ) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fm_gbrain_is_mount_id() {  # <value>
  case $1 in
    *[!a-z0-9-]* | '' | -* | *- ) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

fm_gbrain_is_model_token() {  # <value>
  case $1 in
    *[!a-zA-Z0-9.:_-]* | '' ) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

fm_gbrain_is_positive_int() {  # <value>
  case $1 in
    '' | *[!0-9]* ) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

fm_gbrain_url_host() {  # <url> -> host, or empty
  local rest=$1
  rest=${rest#http://}
  rest=${rest#https://}
  rest=${rest%%/*}
  rest=${rest##*@}
  printf '%s\n' "${rest%%:*}"
}

fm_gbrain_host_is_loopback() {  # <host>
  case $1 in
    127.0.0.1 | ::1 | '[::1]' | localhost ) return 0 ;;
  esac
  return 1
}

# A URL that a client secret travels over must not be plaintext off-box. A
# loopback http:// endpoint is the normal single-machine shape and stays
# allowed; anything else must be https://.
fm_gbrain_is_endpoint_url() {  # <url> [--secret-bearing]
  local url=$1 bearing=${2:-} host
  case $url in
    https://*) return 0 ;;
    http://*) ;;
    *) return 1 ;;
  esac
  [ "$bearing" = --secret-bearing ] || return 0
  host=$(fm_gbrain_url_host "$url")
  fm_gbrain_host_is_loopback "$host"
}

# --- shared plane -----------------------------------------------------------

# The complete allowlist of leaf paths in config/gbrain.json. An unknown path is
# refused rather than ignored, so a field that a future version stops honoring
# cannot sit in a home's config silently doing nothing.
fm_gbrain_shared_fields() {
  cat <<'EOF'
version
local.embedding_base_url
local.embedding_model
local.embedding_dimensions
local.reranker_base_url
local.reranker_model
think.base_url
think.model
think.secret
main_brain.mcp_url
main_brain.token_url
main_brain.mount
main_brain.scopes
main_brain.secret
EOF
}

fm_gbrain_json_leaf_paths() {  # <file>
  jq -r 'paths(scalars) | join(".")' "$1" 2>/dev/null || true
}

# Read one optional field. An absent or unreadable file yields empty output and
# success: every field this reads is optional, and the file's own validity is
# established by fm_gbrain_validate_shared / _local, not here. Returning jq's
# failure instead would abort a `set -e` caller on a home that simply has not
# configured a brain yet.
fm_gbrain_json_str() {  # <file> <jq-path>
  jq -r "$2 // empty" "$1" 2>/dev/null || true
}

# Validate config/gbrain.json. Sets FM_GBRAIN_ERROR and returns 1 on the first
# problem, naming the exact field, because a half-understood credential config
# is worse than a refused one.
fm_gbrain_validate_shared() {  # <file>
  local file=$1 path value host
  FM_GBRAIN_ERROR=""
  [ -e "$file" ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE must be a regular file"
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE is not valid JSON"
    return 1
  fi
  if [ "$(jq -r 'type' "$file" 2>/dev/null)" != object ]; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE must be a JSON object"
    return 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! fm_gbrain_shared_fields | grep -qxF "$path"; then
      case $path in
        brain_root | *.brain_root | client_id | *.client_id)
          fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE must not set \"$path\": it is inherited by every secondmate home, and a brain location or client identity is this home's alone (put it in $FM_GBRAIN_LOCAL_FILE)"
          ;;
        *)
          fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE has an unknown field \"$path\""
          ;;
      esac
      return 1
    fi
  done <<EOF
$(fm_gbrain_json_leaf_paths "$file")
EOF

  value=$(fm_gbrain_json_str "$file" '.version')
  if [ -n "$value" ] && [ "$value" != 1 ]; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE has unsupported version \"$value\" (expected 1)"
    return 1
  fi

  for path in local.embedding_base_url local.reranker_base_url think.base_url main_brain.mcp_url main_brain.token_url; do
    value=$(fm_gbrain_json_str "$file" ".$path")
    [ -n "$value" ] || continue
    case $path in
      main_brain.*) fm_gbrain_is_endpoint_url "$value" --secret-bearing ;;
      *) fm_gbrain_is_endpoint_url "$value" ;;
    esac || {
      host=$(fm_gbrain_url_host "$value")
      if [ -n "$host" ] && ! fm_gbrain_host_is_loopback "$host"; then
        fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"$path\" reaches non-loopback host $host over plaintext http; use https"
      else
        fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"$path\" must be an http:// or https:// URL"
      fi
      return 1
    }
  done

  for path in local.embedding_model local.reranker_model think.model; do
    value=$(fm_gbrain_json_str "$file" ".$path")
    [ -n "$value" ] || continue
    fm_gbrain_is_model_token "$value" || {
      fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"$path\" is not a model token"
      return 1
    }
  done

  value=$(fm_gbrain_json_str "$file" '.local.embedding_dimensions')
  if [ -n "$value" ] && ! fm_gbrain_is_positive_int "$value"; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"local.embedding_dimensions\" must be a positive integer"
    return 1
  fi

  for path in think.secret main_brain.secret; do
    value=$(fm_gbrain_json_str "$file" ".$path")
    [ -n "$value" ] || continue
    fm_gbrain_is_secret_name "$value" || {
      fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"$path\" must NAME a file under config/$FM_GBRAIN_SECRETS_DIR/, not carry a credential"
      return 1
    }
  done

  value=$(fm_gbrain_json_str "$file" '.main_brain.mount')
  if [ -n "$value" ] && ! fm_gbrain_is_mount_id "$value"; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"main_brain.mount\" is not a mount id"
    return 1
  fi

  # The read-only boundary is a configuration-level refusal, not just an
  # operator instruction: a home cannot be configured to ask the main brain for
  # anything beyond read.
  value=$(fm_gbrain_json_str "$file" '.main_brain.scopes')
  if [ -n "$value" ] && [ "$value" != read ]; then
    fm_gbrain_fail "$FM_GBRAIN_SHARED_FILE field \"main_brain.scopes\" must be exactly \"read\"; a home never writes another home's brain"
    return 1
  fi
  return 0
}

# --- home-local plane -------------------------------------------------------

fm_gbrain_local_fields() {
  cat <<'EOF'
version
brain_root
client_id
EOF
}

fm_gbrain_validate_local() {  # <file>
  local file=$1 path value
  FM_GBRAIN_ERROR=""
  [ -e "$file" ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    fm_gbrain_fail "$FM_GBRAIN_LOCAL_FILE must be a regular file"
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    fm_gbrain_fail "$FM_GBRAIN_LOCAL_FILE is not valid JSON"
    return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_gbrain_local_fields | grep -qxF "$path" || {
      fm_gbrain_fail "$FM_GBRAIN_LOCAL_FILE has an unknown field \"$path\""
      return 1
    }
  done <<EOF
$(fm_gbrain_json_leaf_paths "$file")
EOF
  value=$(fm_gbrain_json_str "$file" '.brain_root')
  if [ -n "$value" ]; then
    case $value in
      /*) ;;
      *) fm_gbrain_fail "$FM_GBRAIN_LOCAL_FILE field \"brain_root\" must be an absolute path"; return 1 ;;
    esac
  fi
  # A client id identifies a registration; the matching secret lives only under
  # config/gbrain-secrets/. Refusing a secret-shaped value here keeps the two
  # from being pasted into the wrong plane.
  value=$(fm_gbrain_json_str "$file" '.client_id')
  if [ -n "$value" ]; then
    case $value in
      gbrain_cs_*)
        fm_gbrain_fail "$FM_GBRAIN_LOCAL_FILE field \"client_id\" holds a client SECRET; store it under config/$FM_GBRAIN_SECRETS_DIR/ instead"
        return 1
        ;;
    esac
  fi
  return 0
}

# --- credential plane -------------------------------------------------------

fm_gbrain_file_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# Read one credential into FM_GBRAIN_SECRET. Return 0 when read, 1 when absent,
# and 2 when present but stored too loosely to use, with the reason in
# FM_GBRAIN_ERROR. A credential a symlink could redirect, that is not a regular
# file, or that any other account can read is a finding, so it is refused
# outright rather than quietly used.
#
# The value lands in a variable rather than on stdout deliberately: a caller
# reading it through a command substitution would both lose FM_GBRAIN_ERROR to
# the subshell and leave the credential in a captured output buffer.
FM_GBRAIN_SECRET=""

fm_gbrain_read_secret() {  # <home> <name>
  local home=$1 name=$2 path mode
  FM_GBRAIN_ERROR=""
  FM_GBRAIN_SECRET=""
  if ! fm_gbrain_is_secret_name "$name"; then
    fm_gbrain_fail "invalid secret name \"$name\""
    return 2
  fi
  path=$(fm_gbrain_secret_path "$home" "$name")
  [ -e "$path" ] || return 1
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_gbrain_fail "refusing config/$FM_GBRAIN_SECRETS_DIR/$name: it must be a regular file with mode 0600"
    return 2
  fi
  mode=$(fm_gbrain_file_mode "$path")
  if [ "$mode" != 600 ]; then
    fm_gbrain_fail "refusing config/$FM_GBRAIN_SECRETS_DIR/$name: it must be a regular file with mode 0600, found mode ${mode:-unknown}"
    return 2
  fi
  IFS= read -r FM_GBRAIN_SECRET < "$path" || true
  [ -n "$FM_GBRAIN_SECRET" ] || {
    fm_gbrain_fail "config/$FM_GBRAIN_SECRETS_DIR/$name is empty"
    return 2
  }
  return 0
}

# --- resolved paths ---------------------------------------------------------

# Resolve this home's own brain locations. Sets FM_GBRAIN_BRAIN_ROOT,
# FM_GBRAIN_HOME_DIR (the GBRAIN_HOME a gbrain call needs), FM_GBRAIN_PGLITE,
# and FM_GBRAIN_ARCHIVE.
fm_gbrain_resolve_paths() {  # <home>
  local home=$1 local_file root
  # Cleared for the caller, which reads it after a failure return.
  # shellcheck disable=SC2034
  FM_GBRAIN_ERROR=""
  FM_GBRAIN_BRAIN_ROOT=""; FM_GBRAIN_HOME_DIR=""; FM_GBRAIN_PGLITE=""; FM_GBRAIN_ARCHIVE=""
  [ -n "$home" ] || { fm_gbrain_fail "no firstmate home given"; return 1; }
  local_file=$(fm_gbrain_local_path "$home")
  fm_gbrain_validate_local "$local_file" || return 1
  root=$(fm_gbrain_json_str "$local_file" '.brain_root')
  [ -n "$root" ] || root="$home/$FM_GBRAIN_DEFAULT_SUBDIR"
  root=${root%/}
  FM_GBRAIN_BRAIN_ROOT=$root
  FM_GBRAIN_HOME_DIR="$root/runtime"
  FM_GBRAIN_PGLITE="$root/pglite"
  FM_GBRAIN_ARCHIVE="$root/archive"
  return 0
}

# --- effective, redacted view ----------------------------------------------

# The one shareable rendering of a home's brain configuration. It merges the
# shared and home-local planes, resolves paths, and reports each credential only
# as a name plus a present/absent/refused state. It never reads a secret's
# bytes, which is why it is safe for a reread nudge, a status surface, or a log.
fm_gbrain_effective_json() {  # <home>
  local home=$1 shared local_file secret rc state name
  shared=$(fm_gbrain_shared_path "$home")
  local_file=$(fm_gbrain_local_path "$home")
  fm_gbrain_validate_shared "$shared" || return 1
  fm_gbrain_resolve_paths "$home" || return 1

  local secrets_json='{}'
  for name in think main_brain; do
    secret=$(fm_gbrain_json_str "$shared" ".$name.secret")
    [ -n "$secret" ] || continue
    rc=0
    fm_gbrain_read_secret "$home" "$secret" || rc=$?
    FM_GBRAIN_SECRET=""
    case $rc in
      0) state=present ;;
      1) state=absent ;;
      *) state=refused ;;
    esac
    secrets_json=$(printf '%s' "$secrets_json" \
      | jq --arg k "$name" --arg n "$secret" --arg s "$state" \
        '.[$k] = {name: $n, state: $s}')
  done

  jq -n \
    --slurpfile shared_doc <(if [ -f "$shared" ]; then cat "$shared"; else printf '{}\n'; fi) \
    --arg brain_root "$FM_GBRAIN_BRAIN_ROOT" \
    --arg gbrain_home "$FM_GBRAIN_HOME_DIR" \
    --arg pglite "$FM_GBRAIN_PGLITE" \
    --arg archive "$FM_GBRAIN_ARCHIVE" \
    --arg client_id "$(fm_gbrain_json_str "$local_file" '.client_id')" \
    --argjson secrets "$secrets_json" '
      ($shared_doc[0] // {}) as $s
      | {
          paths: {
            brain_root: $brain_root,
            gbrain_home: $gbrain_home,
            pglite: $pglite,
            archive: $archive
          },
          local: ($s.local // {}),
          think: (($s.think // {}) | del(.secret)),
          main_brain: (($s.main_brain // {}) | del(.secret) + {client_id: $client_id}),
          secrets: $secrets
        }
    '
}
