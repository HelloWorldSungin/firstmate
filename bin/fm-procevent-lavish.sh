#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html | source-id>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, artifact-missing, or unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# source-id  Print the canonical source id for an artifact. When the artifact is
#            gone, the longest existing ancestor is canonicalized and the deleted
#            tail resolved against it lexically, so the id matches the one
#            computed while the file existed; arm still refuses a file that is
#            not there to poll.
# retire     Drop the Lavish source. Accepts an artifact path or its source id,
#            and stays retirable after the artifact is deleted: a path whose file
#            is gone resolves to its registered id, an explicit id retires
#            directly, and a repeat retire by that gone path stays idempotent
#            once a result has been captured for it. Retirement never
#            acknowledges a captured result; only `fm-procevent.sh handled` does.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<decision-key>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# hold, records no decision, and closes nothing: a captain answer is not special to
# Lavish, so every rule about what a keyed answer DOES belongs to the one intake in
# bin/fm-decision-hold.sh, which the runner feeds. A Lavish review is just an
# ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Print every leading comment line after the shebang, so help stays correct as
# the header grows instead of depending on a hardcoded line range.
usage() {
  awk 'NR==1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
#
# A registration can outlive its file - a review published from a disposable
# worktree disappears when the worktree returns to the pool. The id must still
# be derivable then, so identity resolution canonicalizes the longest existing
# ancestor and resolves the deleted tail against it lexically: `.` is dropped,
# `..` pops a component and clamps at the root. That is exactly what realpath
# would have produced, so the id matches the one computed while the file
# existed as long as no symlink lay in the deleted portion - and nothing that
# still exists is resolved lexically, since the ancestor walk stops at the
# longest path the filesystem can canonicalize. arm still requires the file to
# be there, because a source can only poll an artifact that exists.
canonical_artifact_path() {  # <path>: print the canonical path, exit 1 if none resolves
  local p=${1-}
  case "$p" in *$'\n'*) return 1 ;; esac
  perl -e '
    use strict; use warnings;
    use Cwd qw(realpath abs_path);
    my $p = $ARGV[0];
    exit 1 unless defined $p && length $p;
    my $real = realpath($p);
    if (defined $real) { print "$real\n"; exit 0; }
    $p =~ s{//+}{/}g;
    $p =~ s{/$}{};
    exit 1 unless length $p;
    my $absolute = ($p =~ m{^/});
    my @parts = split(m{/}, $p, -1);
    shift @parts if $absolute;
    my $n = scalar @parts;
    my ($base, @rest);
    for (my $i = $n; $i >= 0; $i--) {
      my $candidate = $absolute
        ? ($i == 0 ? "/" : "/" . join("/", @parts[0..$i-1]))
        : ($i == 0 ? "." : join("/", @parts[0..$i-1]));
      my $abs = abs_path($candidate);
      if (defined $abs) { $base = $abs; @rest = @parts[$i..$n-1]; last; }
    }
    exit 1 unless defined $base;
    my @stack = grep { length } split(m{/}, $base);
    for my $part (@rest) {
      next if !length($part) || $part eq ".";
      if ($part eq "..") { pop @stack; next; }
      push @stack, $part;
    }
    print "/" . join("/", @stack) . "\n";
    exit 0;
  ' -- "$p"
}

# Hash a canonical path into the lavish source id prefix this adapter uses.
lavish_id_of_path() {  # <canonical-path>
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

# A lavish source id is always `lavish-` followed by sixteen lowercase hex chars.
is_lavish_source_id() {  # <arg>
  [[ "${1-}" =~ ^lavish-[0-9a-f]{16}$ ]]
}

lavish_state_dir() { printf '%s\n' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }

# Whether a Lavish source is registered in this home. Retire-by-path uses this
# to confirm a derived id is real before retiring it, so a path that no longer
# resolves never silently retires nothing.
lavish_source_is_registered() {  # <id>
  local reg
  reg=$(fm_procevent_registry_dir "$(lavish_state_dir)")
  [ -f "$reg/$1.source" ] && [ ! -L "$reg/$1.source" ]
}

# Whether this home ever captured a result for a source. A captured result is
# durable proof the id was a real registration here, which is what lets a retire
# by a gone path stay idempotent after the registration itself is gone.
lavish_source_has_results() {  # <id>
  local inbox result
  inbox=$(fm_procevent_inbox_dir "$(lavish_state_dir)")
  for result in "$inbox/$1".*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] && return 0
  done
  return 1
}

cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(canonical_artifact_path "$artifact") || die "cannot resolve the artifact path: $artifact"
  lavish_id_of_path "$real"
}

cmd_arm() {
  local artifact=${1-} real id
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(canonical_artifact_path "$artifact") || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  id=$(lavish_id_of_path "$real")
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- lavish-axi poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local arg=${1-} id real gone=0
  [ -n "$arg" ] || usage
  if is_lavish_source_id "$arg" && [ ! -e "$arg" ] && [ ! -L "$arg" ]; then
    # An explicit source id retires directly and stays idempotent, the way the
    # wake text and `fm-procevent.sh list` surface it when the artifact is gone.
    id=$arg
  else
    case "$arg" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
    if [ ! -e "$arg" ] && [ ! -L "$arg" ]; then gone=1; fi
    real=$(canonical_artifact_path "$arg" 2>/dev/null) \
      || die "cannot resolve the artifact path: $arg"
    id=$(lavish_id_of_path "$real")
    # When the artifact is gone the derived id is only a candidate, so retire it
    # only on evidence that this home really owns that source: a live
    # registration, or a captured result, which is durable proof the source was
    # registered here and has since retired. The second case is what keeps a
    # re-run of the same gone-path retire idempotent - the handler is told to
    # retire an artifact-missing source, and a repeat wake asks it to do so
    # again - matching retire by an id and by a path that still resolves.
    if [ "$gone" = 1 ] && ! lavish_source_is_registered "$id" \
      && ! lavish_source_has_results "$id"; then
      die "no Lavish source is registered for: $arg
The artifact is gone and nothing was ever captured for it in this home, so
this path matches nothing here. Retire by source id instead - find it with
'fm-procevent.sh list' or in the wake text 'procevent lavish <id> <seq>'."
    fi
  fi
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  # A deleted artifact shows up as lavish-axi failing to realpath the file, so
  # the message carries the OS file-not-found signal AND the `realpath` keyword
  # from that fs.realpath call. Require both: an unrelated lavish-axi internal
  # ENOENT (its own config/state, say) has no `realpath` and must NOT match,
  # because the handler is told to retire an artifact-missing source. If a
  # future lavish-axi rephrases this, it degrades to `unknown` (honest), never
  # to a wrong retire.
  elif { [[ "$error_message" == *ENOENT* ]] || [[ "$error_message" == *"no such file or directory"* ]]; } \
    && [[ "$error_message" == *realpath* ]]; then
    printf 'artifact-missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result and an artifact-missing
# result - keeps the source armed. A missing artifact is deliberately not
# terminal: a file can reappear, for instance under an editor that rewrites it
# in place, so retiring one is the handler's call, not the adapter's.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print `key<TAB>answer<TAB>label` for every structured choice the captain
# submitted in a captured result. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and an `answer` inside its `Context data:` block is skipped, so a deck that does
# not key its forms by decision key simply yields nothing.
cmd_answers() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @out;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      next unless $ctx =~ /"question"\s*:\s*"((?:[^"\\]|\\.)*)"/;
      my $key = $1;
      next unless $ctx =~ /"answer"\s*:\s*"((?:[^"\\]|\\.)*)"/;
      my $answer = $1;
      $_ =~ s/\\(.)/$1/g for ($key, $answer);
      next unless $key =~ /\A[A-Za-z0-9._-]{1,64}\z/;
      next unless length $answer && length($answer) <= 512;
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
      $label = substr($label, 0, 512);
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  ' "$file"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
