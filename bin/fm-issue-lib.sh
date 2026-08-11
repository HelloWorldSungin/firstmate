#!/usr/bin/env bash
# Project-scoped work-item reference resolution across managed forges.
#
# This library is the single owner of two contracts:
#
#   1. The registry tracker declaration. A project in data/projects.md may
#      declare where its issues actually live by adding a tracker= token to the
#      existing bracket annotation:
#
#        - <name> [<mode> +yolo tracker=<forge>:<host>/<path>] - <desc> (added <date>)
#        - <name> [<mode> tracker=none] - <desc> (added <date>)
#
#      <forge> is github, gitlab, or gitea; <host> is the tracker's DNS host;
#      <path> is owner/repository on github and gitea, and the full nested
#      namespace on gitlab. The token is deliberately independent of the git
#      remote: a project may be mirrored on one host while its issues are
#      tracked on another, so the tracker is NEVER inferred from a remote, a
#      clone directory name, or a PR URL. tracker=none declares "this project
#      has no tracker"; an absent token means undeclared. Both refuse to
#      resolve a bare reference, with different reasons.
#
#      The bracket annotation is otherwise owned by bin/fm-project-mode.sh,
#      whose parser reads the leading mode and +yolo and ignores further
#      tokens, so adding tracker= to a line does not disturb delivery posture.
#
#   2. The reference forms accepted at intake, resolved against the task's
#      project rather than against whichever repository a PR happens to land
#      in:
#
#        https://<host>/...            a full canonical issue URL
#        <forge>:https://<host>/...    the same, with the forge stated when the
#                                      URL shape alone cannot identify it
#        <owner>/<repo>#<n>            forge and host from the declared tracker
#        #<n>  or  <n>                 everything from the declared tracker
#
#      A form that needs the declared tracker and has none is refused with a
#      readable reason in FM_ISSUE_ERROR. Nothing is guessed.
#
# The resolved identity is provider-tagged the same way bin/fm-pr-lib.sh tags a
# pull request: forge, url, host, path, number, plus owner/repository for the
# forges addressed that way. Consumers re-derive the identity from the stored
# URL rather than trusting stored parts, so a hand-edited record cannot point a
# lookup somewhere the URL does not.
#
# Storage and transport of these references is issue #18's manifest contract.
# This library populates it; see docs/configuration.md "Project issue trackers".

# These globals are this library's published output: sourcing scripts read them
# after a parse or resolve call, so shellcheck cannot see their consumers.
# shellcheck disable=SC2034
FM_ISSUE_FORGE=
FM_ISSUE_URL=
FM_ISSUE_HOST=
FM_ISSUE_PATH=
FM_ISSUE_OWNER=
FM_ISSUE_REPO=
FM_ISSUE_NUMBER=
FM_ISSUE_ORIGIN=
FM_ISSUE_TRACKER_FORGE=
FM_ISSUE_TRACKER_HOST=
FM_ISSUE_TRACKER_PATH=
FM_ISSUE_ERROR=

# Forges whose issue identity this library can address. Adding one means
# teaching fm_issue_url_build and fm_issue_url_parse its URL shape,
# bin/fm-issue-status.sh its optional enrichment adapter, and, for write-back,
# the adapter set bin/fm-forge-lib.sh declares.
FM_ISSUE_FORGES="github gitlab gitea"

fm_issue_forge_valid() {  # <forge>
  local forge=${1-} candidate
  for candidate in $FM_ISSUE_FORGES; do
    [ "$candidate" = "$forge" ] && return 0
  done
  return 1
}

# A tracker host is accepted only as a lowercase DNS name with no userinfo,
# port, or trailing dot, so one tracker has exactly one canonical spelling.
# Unlike bin/fm-pr-lib.sh's GitLab host rule, github.com is accepted here: it is
# a legitimate tracker host, and the forge is carried explicitly beside it.
fm_issue_host_valid() {  # <host>
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  [ "${#labels[@]}" -ge 2 ] || return 1
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

fm_issue_owner_valid() {  # <owner>
  local owner=${1-}
  local LC_ALL=C
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 64 ] || return 1
  case "$owner" in
    -*|.*|*-|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_issue_repo_valid() {  # <repo>
  local repo=${1-}
  local LC_ALL=C
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$repo" in
    .|..|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# GitLab projects sit at any depth under nested groups, so their identity is a
# whole path rather than an owner/repository pair. "-" is GitLab's reserved
# route separator and can never name a real namespace segment.
fm_issue_gitlab_path_valid() {  # <path>
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# True when <path> is a valid project path for <forge>. github and gitea are
# addressed by exactly owner/repository; gitlab by its nested namespace.
fm_issue_path_valid() {  # <forge> <path>
  local forge=${1-} path=${2-} owner repo
  case "$forge" in
    gitlab) fm_issue_gitlab_path_valid "$path" ;;
    github|gitea)
      case "$path" in
        */*/*|*/) return 1 ;;
        */*) ;;
        *) return 1 ;;
      esac
      owner=${path%%/*}
      repo=${path#*/}
      fm_issue_owner_valid "$owner" && fm_issue_repo_valid "$repo"
      ;;
    *) return 1 ;;
  esac
}

fm_issue_number_valid() {  # <number>
  local number=${1-}
  local LC_ALL=C
  [[ "$number" =~ ^[1-9][0-9]{0,9}$ ]]
}

# Canonical issue URL for a forge identity. Every consumer builds its links
# through this one function so a stored URL and a re-derived one always agree.
fm_issue_url_build() {  # <forge> <host> <path> <number>
  local forge=$1 host=$2 path=$3 number=$4
  case "$forge" in
    github|gitea) printf 'https://%s/%s/issues/%s\n' "$host" "$path" "$number" ;;
    gitlab) printf 'https://%s/%s/-/issues/%s\n' "$host" "$path" "$number" ;;
    *) return 1 ;;
  esac
}

fm_issue_identity_set() {  # <forge> <host> <path> <number>
  local forge=$1 host=$2 path=$3 number=$4 url
  url=$(fm_issue_url_build "$forge" "$host" "$path" "$number") || return 1
  FM_ISSUE_FORGE=$forge
  FM_ISSUE_HOST=$host
  FM_ISSUE_PATH=$path
  FM_ISSUE_NUMBER=$number
  FM_ISSUE_URL=$url
  case "$forge" in
    github|gitea)
      FM_ISSUE_OWNER=${path%%/*}
      FM_ISSUE_REPO=${path#*/}
      ;;
    *)
      FM_ISSUE_OWNER=
      FM_ISSUE_REPO=
      ;;
  esac
}

fm_issue_identity_clear() {
  FM_ISSUE_FORGE=
  FM_ISSUE_URL=
  FM_ISSUE_HOST=
  FM_ISSUE_PATH=
  FM_ISSUE_OWNER=
  FM_ISSUE_REPO=
  FM_ISSUE_NUMBER=
  FM_ISSUE_ORIGIN=
}

# Parse a tracker declaration into FM_ISSUE_TRACKER_*. "none" is a valid
# declaration and clears the parts while succeeding, so a caller can tell
# "declared as having no tracker" from "malformed".
fm_issue_tracker_parse() {  # <forge>:<host>/<path> | none
  local spec=${1-} forge rest host path
  FM_ISSUE_TRACKER_FORGE=
  FM_ISSUE_TRACKER_HOST=
  FM_ISSUE_TRACKER_PATH=
  [ "$spec" = none ] && return 0
  case "$spec" in
    *:*) ;;
    *) return 1 ;;
  esac
  forge=${spec%%:*}
  rest=${spec#*:}
  fm_issue_forge_valid "$forge" || return 1
  case "$rest" in
    */*) ;;
    *) return 1 ;;
  esac
  host=${rest%%/*}
  path=${rest#*/}
  fm_issue_host_valid "$host" || return 1
  fm_issue_path_valid "$forge" "$path" || return 1
  FM_ISSUE_TRACKER_FORGE=$forge
  FM_ISSUE_TRACKER_HOST=$host
  FM_ISSUE_TRACKER_PATH=$path
}

# Read a project's tracker declaration out of a registry file. Prints the raw
# declaration ("<forge>:<host>/<path>" or "none") and returns 0; prints nothing
# and returns 1 when the project is absent or declares no tracker. A malformed
# declaration returns 2 so a typo is reported rather than read as "undeclared",
# printing a one-line detail phrase a caller can quote after its own sentence.
#
# Two tracker= tokens in one entry are malformed for the same reason a typo is:
# an entry that names two trackers has not said which one is authoritative, and
# taking whichever was written first would silently close an issue on the wrong
# tracker. The count is taken across the whole annotation rather than stopping
# at the first match, so the ambiguity is seen instead of resolved by position.
fm_issue_registry_tracker() {  # <registry-file> <project>
  local registry=$1 project=$2 token
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  token=$(awk -v n="$project" '
    $1=="-" && $2==n {
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);
        k = split(s, a, " ");
        count = 0; first = ""; all = "";
        for (j=1; j<=k; j++) if (a[j] ~ /^tracker=/) {
          v = a[j]; sub(/^tracker=/, "", v);
          count++;
          if (count == 1) first = v;
          all = all (all == "" ? "" : ", ") "tracker=" v;
        }
        if (count > 1) { print "tracker-duplicate:" all; exit }
        if (count == 1) { print "tracker-present:" first; exit }
      }
      exit
    }
  ' "$registry")
  case "$token" in
    tracker-duplicate:*)
      printf 'more than one tracker= token in one entry (%s); exactly one is required\n' \
        "${token#tracker-duplicate:}"
      return 2
      ;;
    tracker-present:*) token=${token#tracker-present:} ;;
    *) return 1 ;;
  esac
  if [ -z "$token" ]; then
    echo 'the tracker= token has an empty value'
    return 2
  fi
  if ! fm_issue_tracker_parse "$token"; then
    printf 'tracker=%s is not <forge>:<host>/<path> or none\n' "$token"
    return 2
  fi
  printf '%s\n' "$token"
}

# Parse a full canonical issue URL. The forge is taken from the URL shape where
# the shape is decisive, and otherwise from <hint-forge>. github.com always
# means github and never a self-hosted forge, and the "/-/issues/" route is
# GitLab's alone. The remaining shape, https://<host>/<owner>/<repo>/issues/<n>,
# is what Gitea, self-hosted GitHub, and several other forges all serve, so it
# is resolved only with an explicit hint - never by guessing from the host name.
fm_issue_url_parse() {  # <url> [hint-forge]
  local raw=${1-} hint=${2-} pattern host path number
  local LC_ALL=C
  fm_issue_identity_clear
  pattern='^https://github\.com/([A-Za-z0-9._-]{1,64})/([A-Za-z0-9._-]{1,100})/issues/([1-9][0-9]{0,9})$'
  if [[ "$raw" =~ $pattern ]]; then
    fm_issue_owner_valid "${BASH_REMATCH[1]}" || return 1
    fm_issue_repo_valid "${BASH_REMATCH[2]}" || return 1
    fm_issue_identity_set github github.com \
      "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" || return 1
    [ "$FM_ISSUE_URL" = "$raw" ] || return 1
    return 0
  fi
  # Greedy to the last "/-/issues/", so any earlier reserved separator lands
  # inside the captured path where fm_issue_gitlab_path_valid refuses it.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/issues/([1-9][0-9]{0,9})$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    number=${BASH_REMATCH[3]}
    [ "$host" != github.com ] || return 1
    fm_issue_host_valid "$host" || return 1
    fm_issue_gitlab_path_valid "$path" || return 1
    fm_issue_identity_set gitlab "$host" "$path" "$number" || return 1
    [ "$FM_ISSUE_URL" = "$raw" ] || return 1
    return 0
  fi
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._-]{1,64})/([A-Za-z0-9._-]{1,100})/issues/([1-9][0-9]{0,9})$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  [ "$host" != github.com ] || return 1
  fm_issue_host_valid "$host" || return 1
  fm_issue_owner_valid "${BASH_REMATCH[2]}" || return 1
  fm_issue_repo_valid "${BASH_REMATCH[3]}" || return 1
  case "$hint" in
    github|gitea) ;;
    *) return 1 ;;
  esac
  fm_issue_identity_set "$hint" "$host" \
    "${BASH_REMATCH[2]}/${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" || return 1
  [ "$FM_ISSUE_URL" = "$raw" ]
}

# Resolve one intake reference against a project's tracker declaration.
#
# <tracker> is the raw declaration ("<forge>:<host>/<path>", "none", or empty
# for undeclared) and <project> only names the project in refusal messages.
# On success the FM_ISSUE_* identity is set and FM_ISSUE_ORIGIN is "declared".
# On refusal FM_ISSUE_ERROR carries a reason a captain-facing message can quote.
fm_issue_ref_resolve() {  # <ref> <tracker> <project>
  local ref=${1-} tracker=${2-} project=${3-} forge hint url ref_host owner repo number
  FM_ISSUE_ERROR=
  fm_issue_identity_clear
  if [ -n "$tracker" ]; then
    if ! fm_issue_tracker_parse "$tracker"; then
      FM_ISSUE_ERROR="project \"$project\" has a malformed tracker declaration: $tracker"
      return 1
    fi
  else
    FM_ISSUE_TRACKER_FORGE=
    FM_ISSUE_TRACKER_HOST=
    FM_ISSUE_TRACKER_PATH=
  fi

  # An explicit "<forge>:<url>" prefix states the forge for URL shapes that
  # several forges share, so a cross-host reference never needs a guess.
  case "$ref" in
    *:https://*)
      forge=${ref%%:*}
      url=${ref#*:}
      if ! fm_issue_forge_valid "$forge"; then
        FM_ISSUE_ERROR="reference \"$ref\" names an unsupported forge \"$forge\" (supported: $FM_ISSUE_FORGES)"
        return 1
      fi
      if ! fm_issue_url_parse "$url" "$forge" || [ "$FM_ISSUE_FORGE" != "$forge" ]; then
        FM_ISSUE_ERROR="reference \"$ref\" is not a canonical $forge issue URL"
        return 1
      fi
      FM_ISSUE_ORIGIN=declared
      return 0
      ;;
    https://*)
      hint=
      ref_host=${ref#https://}
      ref_host=${ref_host%%/*}
      if [ -n "$FM_ISSUE_TRACKER_HOST" ] && [ "$ref_host" = "$FM_ISSUE_TRACKER_HOST" ]; then
        hint=$FM_ISSUE_TRACKER_FORGE
      fi
      if fm_issue_url_parse "$ref" "$hint"; then
        FM_ISSUE_ORIGIN=declared
        return 0
      fi
      FM_ISSUE_ERROR="reference \"$ref\" is not a canonical issue URL for a forge this project can identify; prefix it with a forge (e.g. gitea:$ref) or declare the project's tracker"
      return 1
      ;;
  esac

  # Every remaining form needs the declared tracker, so refuse before parsing.
  if [ -z "$tracker" ]; then
    FM_ISSUE_ERROR="reference \"$ref\" needs project \"$project\" to declare its issue tracker; add a tracker= token to its data/projects.md entry or pass a full issue URL"
    return 1
  fi
  if [ "$tracker" = none ]; then
    FM_ISSUE_ERROR="project \"$project\" declares no issue tracker (tracker=none), so reference \"$ref\" cannot be resolved; pass a full issue URL if the work item lives elsewhere"
    return 1
  fi

  case "$ref" in
    */*'#'*)
      case "$ref" in
        *'#'*'#'*)
          FM_ISSUE_ERROR="reference \"$ref\" is malformed; expected <owner>/<repo>#<number>"
          return 1
          ;;
      esac
      owner=${ref%%#*}
      number=${ref##*#}
      repo=${owner#*/}
      owner=${owner%%/*}
      if [ "$FM_ISSUE_TRACKER_FORGE" = gitlab ]; then
        FM_ISSUE_ERROR="reference \"$ref\" uses owner/repo#N, which cannot address a nested GitLab namespace; pass a full issue URL"
        return 1
      fi
      if ! fm_issue_number_valid "$number" \
        || ! fm_issue_path_valid "$FM_ISSUE_TRACKER_FORGE" "$owner/$repo"; then
        FM_ISSUE_ERROR="reference \"$ref\" is malformed; expected <owner>/<repo>#<number>"
        return 1
      fi
      fm_issue_identity_set "$FM_ISSUE_TRACKER_FORGE" "$FM_ISSUE_TRACKER_HOST" \
        "$owner/$repo" "$number" || return 1
      FM_ISSUE_ORIGIN=declared
      return 0
      ;;
  esac

  number=${ref#\#}
  if ! fm_issue_number_valid "$number"; then
    FM_ISSUE_ERROR="reference \"$ref\" is malformed; expected #<number>, <owner>/<repo>#<number>, or a full issue URL"
    return 1
  fi
  fm_issue_identity_set "$FM_ISSUE_TRACKER_FORGE" "$FM_ISSUE_TRACKER_HOST" \
    "$FM_ISSUE_TRACKER_PATH" "$number" || return 1
  FM_ISSUE_ORIGIN=declared
}

# Task-metadata record for one resolved reference: "<origin>|<forge>|<url>".
# The forge travels with the URL because the https://<host>/<owner>/<repo>/issues/<n>
# shape is not self-identifying, and a record that had to consult the registry
# to be read back would stop resolving the moment a declaration changed. Every
# consumer still re-derives host, path, and number from the URL and requires the
# rebuilt URL to equal the stored one, so a hand-edited record cannot redirect a
# lookup.
fm_issue_work_item_format() {  # <origin> <forge> <url>
  printf '%s|%s|%s\n' "$1" "$2" "$3"
}

fm_issue_work_item_parse() {  # <record>
  local record=${1-} origin rest forge url
  fm_issue_identity_clear
  case "$record" in
    declared\|*) origin=declared; rest=${record#declared|} ;;
    derived\|*) origin=derived; rest=${record#derived|} ;;
    *) return 1 ;;
  esac
  case "$rest" in
    *\|https://*) ;;
    *) return 1 ;;
  esac
  forge=${rest%%|*}
  url=${rest#*|}
  fm_issue_forge_valid "$forge" || return 1
  fm_issue_url_parse "$url" "$forge" || return 1
  [ "$FM_ISSUE_FORGE" = "$forge" ] || return 1
  FM_ISSUE_ORIGIN=$origin
}
