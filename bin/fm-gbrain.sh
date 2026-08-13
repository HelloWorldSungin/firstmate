#!/usr/bin/env bash
# fm-gbrain.sh - operator surface for per-home GBrain scoping and the read-only
# share of the main brain.
#
# Every Firstmate home owns exactly one brain and writes only that brain. A
# secondmate reads the main brain through GBrain's own OAuth 2.1 server using a
# client registered with the single scope "read", so the refusal to write is
# enforced by GBrain per operation rather than by a Firstmate convention.
# docs/gbrain-scoping.md owns the contract; bin/fm-gbrain-lib.sh owns the
# configuration planes, path derivation, and credential handling.
#
# Usage:
#   fm-gbrain.sh paths [--json]
#   fm-gbrain.sh config [--json]
#   fm-gbrain.sh env
#   fm-gbrain.sh check [--json]
#   fm-gbrain.sh token
#   fm-gbrain.sh grant-read <label> --home <target-home> [--replace]
#   fm-gbrain.sh revoke-read <client-id>
#   fm-gbrain.sh retire <target-home> [--yes]
#   fm-gbrain.sh serving-check
#
# Commands:
#   paths        This home's own brain root, GBRAIN_HOME, index, and archive.
#   config       The effective configuration, always redacted: a credential is
#                reported as a name and a present/absent/refused state, never as
#                bytes. Safe for a status surface, a log, or a reread nudge.
#   env          The environment a gbrain call against THIS home needs. Prints
#                no credential; the MiniMax key is injected separately and only
#                into the one process that synthesizes.
#   check        Validate the local plane and report reachability. A main brain
#                or MiniMax endpoint that is down is reported as degraded and
#                exits 0, because local search does not depend on either. A
#                broken local plane - invalid configuration, or a credential
#                stored too loosely to use - exits non-zero. A home that serves
#                its brain while hosted synthesis is reachable on it - a usable
#                credential in its credential plane, or a think endpoint that
#                leaves this host - fails the serving-credential row for the
#                same reason, because that configuration is what the read-only
#                share rule forbids.
#   token        Mint a short-lived read-only access token for the main brain.
#                This is the one command that writes a credential to stdout.
#   grant-read   Register a read-scoped OAuth client on THIS home's brain and
#                install it into <target-home>: the client id into that home's
#                config/gbrain-local.json, the secret into its
#                config/gbrain-secrets/ at mode 0600. Run it in the home that
#                owns the main brain; that home records its own ownership here.
#                --replace revokes the target's previous client after the new
#                one is installed, which is the rotation path: no secret is ever
#                copied through inherited config.
#   revoke-read  Revoke a client on THIS home's brain. GBrain cascades its
#                tokens and authorization codes.
#   retire       Secondmate retirement cleanup: revoke that home's client, then
#                remove its credentials and the brain directories this tool
#                derives - runtime/, pglite/, and archive/ - leaving the brain
#                root itself in place, because an operator-supplied brain_root
#                may hold a deployment this tool did not create. A revocation
#                that fails stops the retirement with nothing removed, so it can
#                be retried. Destructive, so it refuses without --yes.
#   serving-check
#                Read-only alarm for the serving-credential rule that
#                docs/gbrain.md owns: print one GBRAIN_SERVING_CREDENTIAL line
#                when THIS home both serves its brain as the main brain and
#                has hosted synthesis reachable on it, or when a plane the
#                verdict needs cannot be read; stay silent when it finds
#                neither. A home that serves nothing is clear whatever its
#                credential plane holds, so a reading home never raises this
#                alarm. It reads this home's own Firstmate config planes,
#                GBrain's runtime configuration, and the fleet runtime
#                credential store. It never exits non-zero: the line itself
#                is the signal, so a caller that finds nothing stays quiet
#                rather than failing.
#
# Environment:
#   FM_HOME            active firstmate home (default: this code root)
#   FM_GBRAIN_BIN      gbrain executable (default: gbrain on PATH)
#   FM_GBRAIN_TIMEOUT  seconds allowed per HTTP call this script makes - the
#                      token mint and each reachability probe (default: 10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-gbrain-lib.sh
. "$SCRIPT_DIR/fm-gbrain-lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"

# Print the header comment block, whatever length it grows to, rather than a
# hard-coded line range that silently starts spilling code into --help.
usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf 'fm-gbrain: %s\n' "$1" >&2; exit 1; }

require_tool() {  # <tool>
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"
}

shared_str() { fm_gbrain_json_str "$(fm_gbrain_shared_path "$FM_HOME")" "$1"; }

resolve_or_die() {
  fm_gbrain_validate_shared "$(fm_gbrain_shared_path "$FM_HOME")" || die "$FM_GBRAIN_ERROR"
  fm_gbrain_resolve_paths "$FM_HOME" || die "$FM_GBRAIN_ERROR"
}

# --- paths / config / env ---------------------------------------------------

cmd_paths() {
  resolve_or_die
  if [ "${1:-}" = --json ]; then
    jq -n --arg r "$FM_GBRAIN_BRAIN_ROOT" --arg h "$FM_GBRAIN_HOME_DIR" \
      --arg p "$FM_GBRAIN_PGLITE" --arg a "$FM_GBRAIN_ARCHIVE" \
      '{brain_root: $r, gbrain_home: $h, pglite: $p, archive: $a}'
    return 0
  fi
  printf 'brain_root  %s\n' "$FM_GBRAIN_BRAIN_ROOT"
  printf 'gbrain_home %s\n' "$FM_GBRAIN_HOME_DIR"
  printf 'pglite      %s\n' "$FM_GBRAIN_PGLITE"
  printf 'archive     %s\n' "$FM_GBRAIN_ARCHIVE"
}

cmd_config() {
  local json
  # Validated in this shell first: fm_gbrain_effective_json runs in a command
  # substitution below, whose FM_GBRAIN_ERROR would die with the subshell.
  resolve_or_die
  json=$(fm_gbrain_effective_json "$FM_HOME") || die "could not render the configuration"
  if [ "${1:-}" = --json ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf '%s\n' "$json" | jq -r '
    "brain_root  \(.paths.brain_root)",
    "gbrain_home \(.paths.gbrain_home)",
    "embedding   \(.local.embedding_model // "<unset>") @ \(.local.embedding_base_url // "<unset>")",
    "reranker    \(.local.reranker_model // "<unset>") @ \(.local.reranker_base_url // "<unset>")",
    "think       \(.think.model // "<unset>") @ \(.think.base_url // "<unset>")",
    "main_brain  \(.main_brain.mcp_url // "<unshared>") scopes=\(.main_brain.scopes // "<unset>") client=\(if (.main_brain.client_id // "") == "" then "<none>" else .main_brain.client_id end)",
    (.secrets | to_entries[] | "secret      \(.key) name=\(.value.name) \(.value.state)")
  '
}

cmd_env() {
  resolve_or_die
  local embed
  embed=$(shared_str '.local.embedding_base_url')
  printf 'GBRAIN_HOME=%s\n' "$FM_GBRAIN_HOME_DIR"
  [ -n "$embed" ] && printf 'OLLAMA_BASE_URL=%s\n' "$embed"
  return 0
}

# --- main-brain read path ---------------------------------------------------

# Print a client_credentials token for the configured main brain on stdout.
# fm_gbrain_mint_token owns the mint itself, shared with bin/fm-recall.sh; this
# wrapper only renders its failure reason on stderr.
mint_token() {
  fm_gbrain_mint_token "$FM_HOME" || { printf '%s\n' "$FM_GBRAIN_ERROR" >&2; return 1; }
  printf '%s\n' "$FM_GBRAIN_TOKEN"
  FM_GBRAIN_TOKEN=""
}

cmd_token() {
  require_tool curl; require_tool jq
  resolve_or_die
  mint_token
}

# --- check ------------------------------------------------------------------

CHECK_ROWS=()
check_row() { CHECK_ROWS+=("$1|$2|$3"); }   # <name> <state> <detail>

probe_url() {  # <url> -> 0 reachable
  curl -sS -o /dev/null -m "${FM_GBRAIN_TIMEOUT:-10}" "$1" >/dev/null 2>&1
}

# `hard` is this run's exit status: any finding sets it. `plane_broken` is the
# narrower question of whether the configuration this run reads from is
# unusable, which is what makes a downstream row unanswerable rather than
# merely bad news. They are not the same: a serving-credential violation is a
# finding over planes that both read fine, so it must not blank a row whose
# answer this run already knows.
cmd_check() {
  local json_mode=0 hard=0 plane_broken=0 shared local_file url secret_name rc
  [ "${1:-}" = --json ] && json_mode=1

  shared=$(fm_gbrain_shared_path "$FM_HOME")
  local_file=$(fm_gbrain_local_path "$FM_HOME")

  if fm_gbrain_validate_shared "$shared"; then
    check_row config ok "shared configuration valid"
  else
    check_row config failed "$FM_GBRAIN_ERROR"; hard=1; plane_broken=1
  fi
  if fm_gbrain_validate_local "$local_file"; then
    check_row config-local ok "home-local configuration valid"
  else
    check_row config-local failed "$FM_GBRAIN_ERROR"; hard=1; plane_broken=1
  fi

  if [ "$plane_broken" -eq 0 ] && fm_gbrain_resolve_paths "$FM_HOME"; then
    if [ -d "$FM_GBRAIN_PGLITE" ]; then
      check_row brain ok "$FM_GBRAIN_PGLITE"
    else
      check_row brain absent "no index yet at $FM_GBRAIN_PGLITE"
    fi
  fi

  # A credential that exists but is stored too loosely is a finding, not a
  # degradation: it is refused rather than used, so the run fails. The
  # configuration planes still read fine, so it is not a broken plane either: it
  # withholds only the one row whose answer needed that exact credential, which
  # is why the refused main-brain credential is remembered by name here.
  local plane refused_main_brain_secret=""
  for plane in think main_brain; do
    secret_name=$(shared_str ".$plane.secret")
    [ -n "$secret_name" ] || continue
    rc=0
    fm_gbrain_read_secret "$FM_HOME" "$secret_name" || rc=$?
    FM_GBRAIN_SECRET=""
    case $rc in
      0) check_row "secret:$secret_name" ok "mode 0600" ;;
      1) check_row "secret:$secret_name" absent "not installed" ;;
      *)
        check_row "secret:$secret_name" failed "$FM_GBRAIN_ERROR"; hard=1
        if [ "$plane" = main_brain ]; then refused_main_brain_secret=$secret_name; fi
        ;;
    esac
  done

  # docs/gbrain.md owns the rule. A violation is a hard configuration finding;
  # an unreadable plane is unknown rather than a silent pass. It fails the run
  # without setting plane_broken: both planes were read, so every row below is
  # still answerable and the operator reading the violation keeps the context
  # that tells them which home is serving.
  fm_gbrain_serving_credential_state "$FM_HOME"
  case $FM_GBRAIN_SERVING_CREDENTIAL_STATE in
    ok) check_row serving-credential ok "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL" ;;
    serving-with-credential)
      check_row serving-credential failed "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL"; hard=1 ;;
    unknown) check_row serving-credential unknown "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL" ;;
  esac

  # Everything below is reachability. Local retrieval does not depend on the
  # main brain or on MiniMax, so neither can turn this run into a failure.
  url=$(shared_str '.local.embedding_base_url')
  if [ -n "$url" ]; then
    if probe_url "${url%/}/models"; then
      check_row embedding ok "$url"
    else
      check_row embedding degraded "no answer at $url; embedding and hybrid search are unavailable until it returns"
    fi
  fi
  url=$(shared_str '.local.reranker_base_url')
  if [ -n "$url" ]; then
    if probe_url "${url%/}/models"; then
      check_row reranker ok "$url"
    else
      check_row reranker degraded "no answer at $url; search falls back to non-reranked ordering"
    fi
  fi
  # Each row states what this run established and nothing else: the home that
  # owns the main brain reads it directly rather than minting a token to
  # itself, a home that was never granted a client has no outage to report, a
  # mint this run refused to attempt names the credential that blocked it
  # rather than blaming a brain it never called, and only a home that holds a
  # usable client can call an unanswered mint degraded.
  url=$(shared_str '.main_brain.mcp_url')
  if [ -n "$url" ]; then
    if [ "$plane_broken" -ne 0 ]; then
      check_row main-brain skipped "local plane must be fixed first"
    elif fm_gbrain_is_main_brain_owner "$FM_HOME"; then
      check_row main-brain ok "this home owns the main brain at $url and reads its own index directly"
    elif [ -z "$(fm_gbrain_json_str "$local_file" '.client_id')" ]; then
      check_row main-brain absent "this home holds no read-only client for $url; run grant-read from the home that owns it"
    elif [ -n "$refused_main_brain_secret" ]; then
      check_row main-brain skipped "secret:$refused_main_brain_secret must be fixed before a read-only token can be minted"
    elif mint_token >/dev/null 2>&1; then
      check_row main-brain ok "read-only token issued for $url"
    else
      check_row main-brain degraded "no read-only access to $url right now; this home's own search is unaffected"
    fi
  fi
  url=$(shared_str '.think.base_url')
  if [ -n "$url" ]; then
    secret_name=$(shared_str '.think.secret')
    rc=1
    if [ -n "$secret_name" ]; then
      rc=0
      fm_gbrain_read_secret "$FM_HOME" "$secret_name" || rc=$?
      FM_GBRAIN_SECRET=""
    fi
    if [ "$rc" -ne 0 ]; then
      check_row think degraded "no usable key for $url; synthesis is unavailable and local search is unaffected"
    elif probe_url "${url%/}/models"; then
      check_row think ok "$url"
    else
      check_row think degraded "no answer at $url; synthesis is unavailable and local search is unaffected"
    fi
  fi

  local row name state detail
  if [ "$json_mode" -eq 1 ]; then
    for row in "${CHECK_ROWS[@]+"${CHECK_ROWS[@]}"}"; do
      name=${row%%|*}; detail=${row#*|}; state=${detail%%|*}; detail=${detail#*|}
      jq -cn --arg n "$name" --arg s "$state" --arg d "$detail" \
        '{check: $n, state: $s, detail: $d}'
    done | jq -s '.'
  else
    for row in "${CHECK_ROWS[@]+"${CHECK_ROWS[@]}"}"; do
      name=${row%%|*}; detail=${row#*|}; state=${detail%%|*}; detail=${detail#*|}
      printf '%-24s %-9s %s\n' "$name" "$state" "$detail"
    done
  fi
  return "$hard"
}

# --- serving-credential rule alarm ------------------------------------------
#
# docs/gbrain.md owns the rule. This read-only entry point prints one diagnostic
# line for a violation or unknown verdict and stays silent when clear, so
# bootstrap can run it without network or GBrain process access.
cmd_serving_check() {
  fm_gbrain_serving_credential_state "$FM_HOME"
  case $FM_GBRAIN_SERVING_CREDENTIAL_STATE in
    ok) ;;
    *) printf 'GBRAIN_SERVING_CREDENTIAL: %s\n' "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL" ;;
  esac
  return 0
}

# --- granting and revoking the read-only share ------------------------------

write_secret_file() {  # <target-home> <name> <value>
  local home=$1 name=$2 value=$3 dir path tmp
  dir="$(fm_gbrain_config_dir "$home")/$FM_GBRAIN_SECRETS_DIR"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  path="$dir/$name"
  tmp=$(umask 077 && mktemp "$dir/.fm-gbrain.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

# Install an already-computed home-local plane. The merge that produced it runs
# first and in full, so a jq that cannot read the existing file leaves that file
# exactly as it was instead of truncating it to nothing.
install_local_plane() {  # <target-home> <json>
  local home=$1 json=$2 path tmp dir
  path=$(fm_gbrain_local_path "$home")
  dir=${path%/*}
  mkdir -p "$dir" || return 1
  tmp=$(umask 077 && mktemp "$dir/.fm-gbrain-local.XXXXXX") || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

write_local_client_id() {  # <target-home> <client-id>
  local home=$1 client_id=$2 path json
  path=$(fm_gbrain_local_path "$home")
  fm_gbrain_validate_local "$path" || return 1
  if [ -f "$path" ]; then
    json=$(jq --arg c "$client_id" '.version = 1 | .client_id = $c' "$path") || return 1
  else
    json=$(jq -n --arg c "$client_id" '{version: 1, client_id: $c}') || return 1
  fi
  install_local_plane "$home" "$json"
}

mark_main_brain_owner() {  # <home>
  local home=$1 path json
  path=$(fm_gbrain_local_path "$home")
  fm_gbrain_validate_local "$path" || return 1
  if [ -f "$path" ]; then
    json=$(jq '.version = 1 | .main_brain_owner = true' "$path") || return 1
  else
    json=$(jq -n '{version: 1, main_brain_owner: true}') || return 1
  fi
  install_local_plane "$home" "$json"
}

gbrain_call() {  # <args...> - run gbrain against THIS home's brain
  GBRAIN_HOME="$FM_GBRAIN_HOME_DIR" "$GBRAIN_BIN" "$@"
}

# Registering and revoking a client are database writes, and a PGLite brain is
# single-writer: while `gbrain serve` is up it holds an exclusive lock and every
# CLI write is refused. That refusal is safe - nothing is half-applied - but the
# raw message does not say what an operator has to do, so name it here.
#
# Every other failure shape has no friendlier phrasing to offer, so --with-cause
# carries gbrain's own words through instead of dropping them. Revocation output
# names a client id and a status and can carry no credential; registration output
# can, which is why its caller does not pass the flag.
explain_gbrain_failure() {  # <captured-output> <action> [--with-cause]
  local out=$1 action=$2 mode=${3:-} cause
  case $out in
    *'already open through'* | *.gbrain-lock*)
      die "the main brain is currently being served, and its index takes one writer at a time; stop the served main brain, $action, then start it again"
      ;;
  esac
  if [ "$mode" = --with-cause ]; then
    cause=$(printf '%s' "$out" | tr -s '[:space:]' ' ')
    cause=${cause# }
    cause=${cause% }
    [ -z "$cause" ] || die "gbrain refused to $action: $cause"
  fi
  die "gbrain refused to $action"
}

cmd_grant_read() {
  local label="" target="" replace=0
  while [ $# -gt 0 ]; do
    case $1 in
      --home) target=${2:-}; shift 2 ;;
      --replace) replace=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [ -n "$label" ] && die "unexpected argument: $1"; label=$1; shift ;;
    esac
  done
  [ -n "$label" ] || die "usage: fm-gbrain.sh grant-read <label> --home <target-home>"
  [ -n "$target" ] || die "grant-read needs --home <target-home>"
  [ -d "$target" ] || die "target home does not exist: $target"
  require_tool jq
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || die "gbrain is not installed (set FM_GBRAIN_BIN)"
  resolve_or_die

  local secret_name previous target_local
  secret_name=$(shared_str '.main_brain.secret')
  [ -n "$secret_name" ] || die "this fleet's $FM_GBRAIN_SHARED_FILE sets no main_brain.secret name"
  # Refused before anything is registered or written: a local plane that cannot
  # be read is one whose existing client id cannot be seen either, so rewriting
  # it blind would both hide a live client and drop that home's brain_root.
  target_local=$(fm_gbrain_local_path "$target")
  fm_gbrain_validate_local "$target_local" || die "$target: $FM_GBRAIN_ERROR"
  previous=$(fm_gbrain_json_str "$target_local" '.client_id')
  if [ -n "$previous" ] && [ "$replace" -eq 0 ]; then
    die "$target already reads the main brain as $previous; pass --replace to rotate"
  fi

  # The scope is fixed at "read" here and refused anywhere else by
  # fm_gbrain_validate_shared, so no caller can widen this registration.
  local out client_id client_secret rc=0
  out=$(gbrain_call auth register-client "$label" --scopes read --grant-types client_credentials 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || explain_gbrain_failure "$out" "register the read-only client"
  client_id=$(printf '%s\n' "$out" | awk '/Client ID:/{print $NF}')
  client_secret=$(printf '%s\n' "$out" | awk '/Client Secret:/{print $NF}')
  [ -n "$client_id" ] || die "could not read the new client id from gbrain's output"
  case $client_secret in
    gbrain_cs_*) ;;
    *) die "gbrain issued no client secret; a public client cannot read the main brain unattended" ;;
  esac

  write_secret_file "$target" "$secret_name" "$client_secret" \
    || die "could not install the credential into $target"
  write_local_client_id "$target" "$client_id" \
    || die "could not record the client id in $target"
  unset client_secret

  printf 'granted read-only access to the main brain\n'
  printf '  home       %s\n' "$target"
  printf '  client id  %s\n' "$client_id"
  printf '  credential %s\n' "$(fm_gbrain_secret_path "$target" "$secret_name")"

  # Recorded only now: a registration this home's brain accepted is what makes
  # it the main brain for whoever reads it. Claiming ownership any earlier would
  # survive a refused registration and leave `check` reporting a relationship
  # that was never established.
  local followup=0
  if mark_main_brain_owner "$FM_HOME"; then
    printf '  owner      this home is recorded as the main brain\n'
  else
    printf '  owner      WARNING: could not record this home as the main brain: %s\n' \
      "${FM_GBRAIN_ERROR:-write failed}"
    followup=1
  fi
  # docs/gbrain.md owns the rule. Reuse the shared verdict so grant-read warns
  # exactly when registration creates the forbidden configuration - and, like
  # every other surface, never reports a verdict it could not reach as a pass.
  fm_gbrain_serving_credential_state "$FM_HOME"
  case $FM_GBRAIN_SERVING_CREDENTIAL_STATE in
    serving-with-credential)
      printf '\n'
      printf '  *** WARNING: this home now SERVES its brain and hosted synthesis is\n'
      printf '      reachable on it. Since GBrain v0.42.76.0 a read-only holder reaches\n'
      printf '      think on the serving home, so the share is read-only for retrieval\n'
      printf '      but NOT for synthesis: a reader can run synthesis here under this\n'
      printf '      home model and credential. Remove the hosted synthesis credential\n'
      printf '      (and think.secret) before relying on the share, or do not serve\n'
      printf '      this brain.\n'
      printf '      %s\n' "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL"
      followup=1
      ;;
    unknown)
      printf '\n'
      printf '  *** WARNING: this home now SERVES its brain, and whether hosted\n'
      printf '      synthesis is reachable on it could not be determined:\n'
      printf '      %s.\n' "$FM_GBRAIN_SERVING_CREDENTIAL_DETAIL"
      printf '      Resolve that and re-run "fm-gbrain.sh check" before relying on the\n'
      printf '      share; a verdict this command could not reach is not a clean one.\n'
      followup=1
      ;;
  esac
  if [ -n "$previous" ]; then
    if gbrain_call auth revoke-client "$previous" >/dev/null 2>&1; then
      printf '  rotated    revoked the previous client %s\n' "$previous"
    else
      printf '  rotated    WARNING: the previous client %s could not be revoked; revoke it before trusting the rotation\n' "$previous"
      followup=1
    fi
  fi
  return "$followup"
}

cmd_revoke_read() {
  local client_id=${1:-}
  [ -n "$client_id" ] || die "usage: fm-gbrain.sh revoke-read <client-id>"
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || die "gbrain is not installed (set FM_GBRAIN_BIN)"
  resolve_or_die
  local out rc=0
  out=$(gbrain_call auth revoke-client "$client_id" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || explain_gbrain_failure "$out" "revoke $client_id" --with-cause
  printf '%s\n' "$out"
}

# Retirement removes only what this tool creates: the retiring home's credential
# directory and the runtime/, pglite/, and archive/ children it derives under
# that home's brain root. The root itself is never removed, because brain_root
# may point at a GBrain deployment this tool did not create and whose siblings
# are not ours to delete. Every path is resolved from the named home, and a
# revocation that fails stops the retirement with nothing removed, because a
# home whose local credential record is gone while its client still reads the
# main brain leaves access no one can find again.
cmd_retire() {
  local target="" yes=0
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [ -n "$target" ] && die "unexpected argument: $1"; target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "usage: fm-gbrain.sh retire <target-home> [--yes]"
  [ -d "$target" ] || die "target home does not exist: $target"
  require_tool jq

  local client_id target_local secrets_dir brain_root dir
  target_local=$(fm_gbrain_local_path "$target")
  fm_gbrain_validate_local "$target_local" || die "$target: $FM_GBRAIN_ERROR"
  client_id=$(fm_gbrain_json_str "$target_local" '.client_id')
  fm_gbrain_resolve_paths "$target" || die "$FM_GBRAIN_ERROR"
  secrets_dir="$(fm_gbrain_config_dir "$target")/$FM_GBRAIN_SECRETS_DIR"
  brain_root=$FM_GBRAIN_BRAIN_ROOT
  local derived=("$FM_GBRAIN_HOME_DIR" "$FM_GBRAIN_PGLITE" "$FM_GBRAIN_ARCHIVE")

  if [ "$yes" -eq 0 ]; then
    printf 'retiring %s would:\n' "$target"
    [ -n "$client_id" ] && printf '  revoke its main-brain client %s\n' "$client_id"
    printf '  remove its credentials at %s\n' "$secrets_dir"
    for dir in "${derived[@]}"; do
      printf '  remove %s\n' "$dir"
    done
    printf '  leave the brain root %s itself in place\n' "$brain_root"
    die "this destroys that home's brain; re-run with --yes once the captain has approved"
  fi

  # Nothing is removed until every path is one this tool would have created, so
  # a refusal leaves the home as it was and the command can simply be re-run.
  for dir in "$secrets_dir" "${derived[@]}"; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    [ -d "$dir" ] && [ ! -L "$dir" ] \
      || die "refusing to remove $dir: it is not a directory this command created"
  done

  if [ -n "$client_id" ]; then
    command -v "$GBRAIN_BIN" >/dev/null 2>&1 \
      || die "cannot revoke $client_id: gbrain is not installed (set FM_GBRAIN_BIN); revoke it on the main brain, then re-run"
    fm_gbrain_resolve_paths "$FM_HOME" || die "$FM_GBRAIN_ERROR"
    local out rc=0
    out=$(gbrain_call auth revoke-client "$client_id" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || explain_gbrain_failure "$out" "revoke $client_id" --with-cause
    printf 'revoked %s\n' "$client_id"
  fi

  rm -rf "$secrets_dir"
  for dir in "${derived[@]}"; do
    rm -rf "$dir"
  done
  printf 'retired the brain and credentials for %s\n' "$target"
  printf '  left in place %s\n' "$brain_root"
}

# --- dispatch ---------------------------------------------------------------

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    paths) cmd_paths "$@" ;;
    config) cmd_config "$@" ;;
    env) cmd_env "$@" ;;
    check) cmd_check "$@" ;;
    token) cmd_token "$@" ;;
    grant-read) cmd_grant_read "$@" ;;
    revoke-read) cmd_revoke_read "$@" ;;
    retire) cmd_retire "$@" ;;
    serving-check) cmd_serving_check "$@" ;;
    -h | --help | help | '') usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
