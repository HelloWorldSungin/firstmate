#!/usr/bin/env bash
set -u

usage() {
  echo "usage: fm-submit-ack-hook.sh install|remove <cursor|agy> <worktree> <state-dir> <task-id>" >&2
  echo "       fm-submit-ack-hook.sh event <cursor|agy> <state-dir> <task-id>" >&2
  echo "       fm-submit-ack-hook.sh prepare <state-dir> <task-id>" >&2
  echo "       fm-submit-ack-hook.sh confirmed <state-dir> <task-id> <nonce>" >&2
  echo "       fm-submit-ack-hook.sh clear <state-dir> <task-id>" >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

valid_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

validate_state_id() {
  case "$1" in /*) : ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] && valid_id "$2"
}

pending_path() {
  printf '%s/%s.submit-pending' "$1" "$2"
}

ack_path() {
  printf '%s/%s.submit-ack' "$1" "$2"
}

clear_pending() {
  local state=$1 id=$2 pending ack
  validate_state_id "$state" "$id" || return 1
  pending=$(pending_path "$state" "$id")
  ack=$(ack_path "$state" "$id")
  rm -f -- "$ack" || return 1
  if [ -d "$pending" ] && [ ! -L "$pending" ]; then
    rm -f -- "$pending/message" "$pending/nonce" || return 1
    rmdir "$pending" 2>/dev/null || return 1
  elif [ -e "$pending" ] || [ -L "$pending" ]; then
    return 1
  fi
}

prepare_pending() {
  local state=$1 id=$2 pending temp nonce old_umask
  validate_state_id "$state" "$id" || return 1
  clear_pending "$state" "$id" || return 1
  pending=$(pending_path "$state" "$id")
  old_umask=$(umask)
  umask 077
  temp=$(mktemp -d "$state/.$id.submit-pending.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  nonce="n$(date +%s).${BASHPID:-$$}.${RANDOM:-0}"
  if ! { printf '%s\n' "$nonce" > "$temp/nonce" && cat > "$temp/message" && mv "$temp" "$pending"; }; then
    rm -f -- "$temp/nonce" "$temp/message"
    rmdir "$temp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  printf '%s\n' "$nonce"
}

pending_confirmed() {
  local state=$1 id=$2 nonce=$3 ack recorded lines
  validate_state_id "$state" "$id" || return 1
  valid_id "$nonce" || return 1
  ack=$(ack_path "$state" "$id")
  [ -f "$ack" ] && [ ! -L "$ack" ] || return 1
  recorded=
  IFS= read -r recorded < "$ack" || [ -n "$recorded" ] || return 1
  [ "$recorded" = "$nonce" ] || return 1
  lines=$(wc -l < "$ack") || return 1
  [ "$lines" -eq 1 ]
}

write_ack() {
  local harness=$1 state=$2 id=$3 pending ack input nonce temp old_umask
  validate_state_id "$state" "$id" || return 1
  pending=$(pending_path "$state" "$id")
  ack=$(ack_path "$state" "$id")
  [ -d "$pending" ] && [ ! -L "$pending" ] || return 1
  [ -f "$pending/message" ] && [ ! -L "$pending/message" ] || return 1
  [ -f "$pending/nonce" ] && [ ! -L "$pending/nonce" ] || return 1
  nonce=
  IFS= read -r nonce < "$pending/nonce" || [ -n "$nonce" ] || return 1
  valid_id "$nonce" || return 1
  input=$(mktemp "$pending/.input.XXXXXXXX") || return 1
  case "$harness" in
    cursor)
      jq -jr 'if (.prompt? | type) == "string" then .prompt else empty end' > "$input" 2>/dev/null || {
        rm -f -- "$input"
        return 1
      }
      ;;
    agy)
      jq -jr '
        if (.lastUserInput? | type) == "string" then .lastUserInput
        elif (.common?.lastUserInput? | type) == "string" then .common.lastUserInput
        else empty
        end
      ' > "$input" 2>/dev/null || {
        rm -f -- "$input"
        return 1
      }
      ;;
    *) rm -f -- "$input"; return 1 ;;
  esac
  if ! cmp -s "$pending/message" "$input"; then
    rm -f -- "$input"
    return 1
  fi
  rm -f -- "$input"
  old_umask=$(umask)
  umask 077
  temp=$(mktemp "$state/.$id.submit-ack.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  if ! { printf '%s\n' "$nonce" > "$temp" && mv -f "$temp" "$ack"; }; then
    rm -f -- "$temp"
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

install_wiring() {
  local harness=$1 worktree=$2 state=$3 id=$4 plugin command hook_file manifest_file
  case "$worktree" in /*) : ;; *) return 1 ;; esac
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  validate_state_id "$state" "$id" || return 1
  command="$(shell_quote "$0") event $harness $(shell_quote "$state") $(shell_quote "$id")"
  case "$harness" in
    cursor)
      plugin="$state/$id.cursor-submit-ack-plugin"
      [ ! -e "$plugin" ] && [ ! -L "$plugin" ] || return 1
      mkdir -p "$plugin/.cursor-plugin" "$plugin/hooks" || return 1
      manifest_file="$plugin/.cursor-plugin/plugin.json"
      hook_file="$plugin/hooks/hooks.json"
      if ! { jq -n '{name:"firstmate-submit-ack",version:"1.0.0",hooks:"./hooks/hooks.json"}' > "$manifest_file" &&
        jq -n --arg command "$command" \
          '{version:1,hooks:{beforeSubmitPrompt:[{type:"command",command:$command,timeout:5}]}}' \
          > "$hook_file" && chmod 700 "$plugin" "$plugin/.cursor-plugin" "$plugin/hooks" &&
        chmod 600 "$manifest_file" "$hook_file"; }; then
        rm -f -- "$manifest_file" "$hook_file"
        rmdir "$plugin/.cursor-plugin" "$plugin/hooks" "$plugin" 2>/dev/null || true
        return 1
      fi
      ;;
    agy)
      plugin="$worktree/.agents/plugins/fm-submit-ack-$id"
      [ ! -L "$worktree/.agents" ] && [ ! -L "$worktree/.agents/plugins" ] || return 1
      [ ! -e "$plugin" ] && [ ! -L "$plugin" ] || return 1
      mkdir -p "$plugin" || return 1
      manifest_file="$plugin/plugin.json"
      hook_file="$plugin/hooks.json"
      if ! { jq -n '{name:"firstmate-submit-ack"}' > "$manifest_file" &&
        jq -n --arg name "fm-submit-ack-$id" --arg command "$command" \
          '{($name):{PreInvocation:[{type:"command",command:$command,timeout:5}]}}' \
          > "$hook_file" && chmod 700 "$plugin" && chmod 600 "$manifest_file" "$hook_file"; }; then
        rm -f -- "$manifest_file" "$hook_file"
        rmdir "$plugin" 2>/dev/null || true
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$plugin"
}

remove_wiring() {
  local harness=$1 worktree=$2 state=$3 id=$4 plugin
  validate_state_id "$state" "$id" || return 1
  clear_pending "$state" "$id" || return 1
  case "$harness" in
    cursor)
      plugin="$state/$id.cursor-submit-ack-plugin"
      if [ ! -e "$plugin" ] && [ ! -L "$plugin" ]; then
        return 0
      fi
      [ -d "$plugin" ] && [ ! -L "$plugin" ] || return 1
      [ ! -L "$plugin/.cursor-plugin" ] && [ ! -L "$plugin/hooks" ] || return 1
      rm -f -- "$plugin/.cursor-plugin/plugin.json" "$plugin/hooks/hooks.json"
      rmdir "$plugin/.cursor-plugin" "$plugin/hooks" "$plugin" 2>/dev/null || {
        [ ! -e "$plugin" ] && [ ! -L "$plugin" ] || return 1
      }
      ;;
    agy)
      case "$worktree" in /*) : ;; *) return 1 ;; esac
      plugin="$worktree/.agents/plugins/fm-submit-ack-$id"
      [ ! -L "$worktree/.agents" ] && [ ! -L "$worktree/.agents/plugins" ] || return 1
      if [ ! -e "$plugin" ] && [ ! -L "$plugin" ]; then
        return 0
      fi
      [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
      [ -d "$plugin" ] && [ ! -L "$plugin" ] || return 1
      rm -f -- "$plugin/plugin.json" "$plugin/hooks.json"
      rmdir "$plugin" 2>/dev/null || {
        [ ! -e "$plugin" ] && [ ! -L "$plugin" ] || return 1
      }
      ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  install)
    [ "$#" -eq 5 ] || usage
    install_wiring "$2" "$3" "$4" "$5"
    ;;
  remove)
    [ "$#" -eq 5 ] || usage
    remove_wiring "$2" "$3" "$4" "$5"
    ;;
  event)
    [ "$#" -eq 4 ] || usage
    write_ack "$2" "$3" "$4" >/dev/null 2>&1 || true
    printf '{}\n'
    ;;
  prepare)
    [ "$#" -eq 3 ] || usage
    prepare_pending "$2" "$3"
    ;;
  confirmed)
    [ "$#" -eq 4 ] || usage
    pending_confirmed "$2" "$3" "$4"
    ;;
  clear)
    [ "$#" -eq 3 ] || usage
    clear_pending "$2" "$3"
    ;;
  *) usage ;;
esac
