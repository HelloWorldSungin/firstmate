# shellcheck shell=bash
# Wire shape, identity, and redaction for GBrain task-knowledge capture.
# Usage: . bin/fm-gbrain-capture-lib.sh   (sources bin/fm-gbrain-lib.sh)
#
# This library owns three things and nothing else: the deterministic identity a
# captured document carries, the redaction pass every body goes through BEFORE
# it reaches disk, and the outbox record's wire shape. bin/fm-gbrain-capture.sh
# is the operator and lifecycle surface over it, and docs/gbrain-capture.md owns
# the contract the two implement.
#
# Two ordering rules are load-bearing and are properties of this file rather
# than of its caller:
#
#   Redaction happens before ENQUEUE, not before delivery. Once a body reaches
#   the outbox it is on disk, so the redaction pass and its residual guard run
#   inside fm_gbrain_capture_item_build, and a body that fails the guard is
#   never written anywhere.
#
#   Identity is derived, not assigned. A document's logical identity is the
#   home, the source, and the schema version; its content version is a hash of
#   the redacted body. Recapturing a changed body updates the SAME page rather
#   than creating a second one, which is what makes delivery idempotent.
#
#   A cut body says so, in the body. The cap is a bound on what reaches the
#   outbox, so a body that hits it is incomplete, and an incomplete body that
#   reads as complete is worse than no body at all. The cut appends a marker the
#   reader of the page sees and records .truncated on the record so an audit can
#   count cut documents without parsing prose.

_FM_GBRAIN_CAPTURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_GBRAIN_CAPTURE_LIB_DIR="."
if ! declare -F fm_gbrain_resolve_paths >/dev/null 2>&1; then
  # shellcheck source=bin/fm-gbrain-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_GBRAIN_CAPTURE_LIB_DIR/fm-gbrain-lib.sh"
fi

FM_GBRAIN_CAPTURE_SCHEMA=fm-gbrain-capture.v1
FM_GBRAIN_CAPTURE_OUTBOX_SUBDIR="gbrain-outbox"

# A body is capped so an enqueue on teardown's critical path costs a bounded
# read and a bounded write no matter how large a report grew. The cap is the ONE
# decision point for truncation: the composer reads its sources under the same
# bound, but only the whole-body cut here marks the record and the page.
FM_GBRAIN_CAPTURE_MAX_BYTES=${FM_GBRAIN_CAPTURE_MAX_BYTES:-65536}
# Bounded retry: an item that has failed this many times stops being retried by
# an ordinary process run and waits for --force, so a permanently broken item
# cannot consume every later run's budget.
FM_GBRAIN_CAPTURE_MAX_ATTEMPTS=${FM_GBRAIN_CAPTURE_MAX_ATTEMPTS:-5}

FM_GBRAIN_CAPTURE_ERROR=""

fm_gbrain_capture_fail() {
  FM_GBRAIN_CAPTURE_ERROR=$1
  return 1
}

# --- identity ---------------------------------------------------------------

fm_gbrain_capture_sha256() {  # <  content
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{printf "%08x%08x\n", $1, $2}'
  fi
}

# The fingerprint of what a record was captured FROM, as distinct from what this
# pipeline wrote about it. It hashes the durable source bytes exactly as they
# sit on disk: before composition, before redaction, before the cap.
#
# The two versions answer different questions and must not be conflated. The
# content version answers "does the page need rewriting", so it correctly moves
# whenever anything in the composed body moves - the truncation marker, a
# redaction placeholder, the schema string in the front matter, the front-matter
# rendering, the heading and its bullet list, the section headings, and
# yaml_scalar's escaping are all ours, and every one of them would otherwise
# read as the source having changed. This version answers "did the thing we
# captured actually change", so only it may back a claim about the source.
# Manifest-derived values stay source-derived either way, because the manifest's
# own bytes are hashed here.
#
# Each part is framed by name and byte length so one part's content cannot be
# read as the next part's frame, and an absent part is hashed as absent rather
# than skipped, so a report that is deleted is a change rather than a silence.
# Nothing is printed when no part exists at all: there is no source to fingerprint.
fm_gbrain_capture_source_version() {  # <path>... -> sha256:<hex>
  local path present=0 digest
  for path in "$@"; do
    if [ -f "$path" ] && [ ! -L "$path" ]; then present=1; fi
  done
  [ "$present" -eq 1 ] || return 1
  digest=$(
    for path in "$@"; do
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        printf '%s %s\n' "${path##*/}" "$(wc -c < "$path" 2>/dev/null | tr -cd '0-9')"
        cat "$path" 2>/dev/null || true
      else
        printf '%s absent\n' "${path##*/}"
      fi
    done | fm_gbrain_capture_sha256
  ) || return 1
  [ -n "$digest" ] || return 1
  printf 'sha256:%s\n' "$digest"
}

# The home tag discriminates BRAINS, so it hashes the resolved home path - the
# same thing bin/fm-gbrain-lib.sh derives a brain root from. It deliberately
# does not reuse bin/fm-backend-hometag-lib.sh, which hashes the CODE root to
# discriminate panes in a backend-global namespace: two homes sharing one code
# root must still be two brains.
fm_gbrain_capture_home_tag() {  # <home>
  local home=$1 real base hash
  real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || real=$home
  base=$(printf '%s' "${real##*/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  while [ -n "$base" ] && [ "${base%-}" != "$base" ]; do base=${base%-}; done
  [ -n "$base" ] || base=home
  hash=$(printf '%s' "$real" | fm_gbrain_capture_sha256 | cut -c1-8)
  printf '%s-%s\n' "${base:0:24}" "$hash"
}

fm_gbrain_capture_kind_valid() {  # <kind>
  case $1 in
    task | note ) return 0 ;;
  esac
  return 1
}

# A source id must be safe as both a path component and a slug component, which
# is the same character class task ids already satisfy (bin/fm-pr-lib.sh).
fm_gbrain_capture_source_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    '' | .* | *[!A-Za-z0-9._-]* ) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

# The logical page address. Stable across content versions, so recapturing a
# changed body updates this page instead of adding another.
fm_gbrain_capture_slug() {  # <home-tag> <kind> <source-id>
  printf 'firstmate/%s/%s/%s\n' "$1" "$2" "$3"
}

# The outbox record's name and the document's LOGICAL identity: schema version,
# home, kind, and source. Content version is deliberately not part of it,
# because a new version of a document is not a new document - that is what makes
# repeated delivery update one page instead of accumulating copies.
fm_gbrain_capture_document_id() {  # <home-tag> <kind> <source-id>
  printf 'v1.%s.%s.%s\n' "$1" "$2" "$3"
}

# An operator can name a document id on the command line, and that id becomes a
# path component, so it is shape-checked exactly as a source id is rather than
# interpolated as given: an id outside this class can address a file outside the
# outbox, and a record read from there would be written back to it.
fm_gbrain_capture_document_id_valid() {  # <document-id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    v1.?* ) ;;
    * ) return 1 ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._-]* ) return 1 ;;
  esac
  [ "${#id}" -le 200 ]
}

# The full identity INCLUDING the content version: one exact revision of one
# logical document. It names what a given delivery actually carried, so a
# receipt can be compared against a later body without reading the page.
fm_gbrain_capture_revision_id() {  # <document-id> <content-version>
  printf 'rev-%s\n' "$(printf '%s\n%s' "$1" "$2" | fm_gbrain_capture_sha256 | cut -c1-16)"
}

fm_gbrain_capture_outbox_dir() {  # <data-dir>
  printf '%s/%s\n' "$1" "$FM_GBRAIN_CAPTURE_OUTBOX_SUBDIR"
}

fm_gbrain_capture_item_path() {  # <data-dir> <document-id>
  printf '%s/%s.json\n' "$(fm_gbrain_capture_outbox_dir "$1")" "$2"
}

fm_gbrain_capture_receipt_path() {  # <state-dir> <id>
  printf '%s/%s.gbrain\n' "$1" "$2"
}

# The marker a cut body carries. It is appended AFTER redaction so the redactor
# can never rewrite it and the residual detector reads it as the ordinary prose
# it is. It names the byte count rather than the source size, because the cap
# bounds the read as well: at the point of the cut the only known fact is how
# much was kept.
fm_gbrain_capture_truncation_marker() {  # <captured-bytes>
  printf '\n---\n\n**Capture truncated at %s bytes.** This page carries the beginning of a longer record; the rest of it was never captured. Read the durable source this page names for the remainder.\n' "$1"
}

# --- redaction --------------------------------------------------------------
#
# The redactor rewrites credential-shaped material in place and reports what it
# rewrote. The detector then runs over the REDACTED body: anything it still
# finds means the rewrite did not cover that occurrence, and the item is
# rejected rather than stored. The one case that reaches the detector by design
# is an unterminated private-key block - without an END marker there is no way
# to know where the key material stops, so the block is not rewritten at all and
# the whole document is refused.
#
# Both passes are POSIX awk with no interval expressions, so they behave the
# same under gawk, mawk, and BSD awk.

_fm_gbrain_capture_awk_patterns() {
  cat <<'AWK'
function classes(   i) {
  npat = 0
  add("gbrain-client-secret", "gbrain_cs_[A-Za-z0-9_-]+")
  add("github-token", "github_pat_[A-Za-z0-9_]+")
  add("github-token", "gh[pousr]_[A-Za-z0-9]+")
  add("slack-token", "xox[abprs]-[A-Za-z0-9-]+")
  add("aws-access-key", "(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]+")
  add("jwt", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")
  add("api-key", "sk-[A-Za-z0-9_-]+")
}
function add(cls, pat) {
  npat++
  pcls[npat] = cls
  ppat[npat] = pat
}
# True when <pat> matches at a token boundary, the same rule the rewrite uses,
# so the detector can never refuse a body over a match the rewrite deliberately
# left alone.
function boundary_match(s, pat,   st, prev) {
  while (match(s, pat)) {
    st = RSTART
    prev = (st > 1) ? substr(s, st - 1, 1) : ""
    if (prev == "" || prev !~ /[A-Za-z0-9_]/) return 1
    s = substr(s, st + 1)
  }
  return 0
}
AWK
}

# stdin -> redacted body on stdout, "<class> <count>" lines on <counts-file>.
# Returns 0 always; refusal is the detector's job, not this pass's.
fm_gbrain_capture_redact() {  # <counts-file>  < body
  local counts=$1
  awk -v countfile="$counts" '
'"$(_fm_gbrain_capture_awk_patterns)"'
# Rewrite the VALUE half of every match of <pat>, keeping the key half. The cut
# point comes from <sep>, the separator <pat> itself uses, rather than from
# whichever separator character happens to appear first in the match: a value
# like a base64 token ending in "=" padding, or a password containing ":", would
# otherwise be kept verbatim as if it were part of the key. A separator that
# does not appear at all cuts nothing, so the whole match is replaced.
function redact_assign(s, pat, sep, cls,   out, m, st, ln, keep) {
  out = ""
  while (match(s, pat)) {
    st = RSTART; ln = RLENGTH
    m = substr(s, st, ln)
    out = out substr(s, 1, st - 1)
    if (match(m, sep)) keep = RSTART + RLENGTH - 1
    else keep = 0
    out = out substr(m, 1, keep) "[redacted:" cls "]"
    counts[cls]++
    s = substr(s, st + ln)
  }
  return out s
}
# Rewrite every match of <pat> that starts at a token boundary. A pattern like
# "sk-..." must not fire inside an ordinary word - "task-x1" contains "sk-x1" -
# and POSIX ERE has no word-boundary assertion, so the boundary is checked
# against the preceding character instead of expressed in the pattern.
function redact_boundary(s, pat, cls,   out, st, ln, prev) {
  out = ""
  while (match(s, pat)) {
    st = RSTART; ln = RLENGTH
    prev = (st > 1) ? substr(s, st - 1, 1) : ""
    if (prev != "" && prev ~ /[A-Za-z0-9_]/) {
      out = out substr(s, 1, st)
      s = substr(s, st + 1)
      continue
    }
    out = out substr(s, 1, st - 1) "[redacted:" cls "]"
    counts[cls]++
    s = substr(s, st + ln)
  }
  return out s
}
function scrub(line,   i, n, m, st, ln, scheme, rest) {
  for (i = 1; i <= npat; i++) {
    line = redact_boundary(line, ppat[i], pcls[i])
  }
  n = gsub(/:\/\/[^\/@ \t]+:[^\/@ \t]+@/, "://[redacted:url-userinfo]@", line)
  if (n > 0) counts["url-userinfo"] += n
  if (match(line, /[Aa]uthorization[ \t]*:[ \t]*/)) {
    st = RSTART; ln = RLENGTH
    rest = substr(line, st + ln)
    scheme = ""
    if (match(rest, /^([Bb]earer|[Bb]asic|[Tt]oken|[Dd]igest)[ \t]+/)) {
      scheme = substr(rest, 1, RLENGTH)
    }
    if (length(rest) > length(scheme)) {
      line = substr(line, 1, st + ln - 1) scheme "[redacted:authorization]"
      counts["authorization"]++
    }
  }
  n = gsub(/[Bb]earer[ \t]+[A-Za-z0-9._~+\/=-][A-Za-z0-9._~+\/=-][A-Za-z0-9._~+\/=-][A-Za-z0-9._~+\/=-][A-Za-z0-9._~+\/=-][A-Za-z0-9._~+\/=-]+/, "Bearer [redacted:bearer-token]", line)
  if (n > 0) counts["bearer-token"] += n
  line = redact_assign(line, "[A-Z][A-Z0-9_]*(TOKEN|KEY|SECRET|PASSWORD|PASSWD|CREDENTIAL|CREDENTIALS|PAT)[ \t]*=[ \t]*[^ \t][^ \t][^ \t][^ \t][^ \t][^ \t]+", "[ \t]*=[ \t]*", "env-value")
  line = redact_assign(line, "(--)?([Aa]pi[-_]?[Kk]ey|[Aa]ccess[-_]?[Tt]oken|[Cc]lient[-_]?[Ss]ecret|[Pp]rivate[-_]?[Kk]ey|[Pp]assword|[Pp]asswd|[Ss]ecret|[Tt]oken)[ \t]*[=:][ \t]*[^ \t][^ \t][^ \t][^ \t][^ \t][^ \t]+", "[ \t]*[=:][ \t]*", "credential-assignment")
  line = redact_assign(line, "--([Aa]pi[-_]?[Kk]ey|[Aa]ccess[-_]?[Tt]oken|[Cc]lient[-_]?[Ss]ecret|[Pp]assword|[Pp]asswd|[Ss]ecret|[Tt]oken)[ \t]+[^ \t][^ \t][^ \t][^ \t][^ \t][^ \t]+", "[ \t]+", "credential-argument")
  return line
}
BEGIN { classes() }
{ lines[NR] = $0 }
END {
  # A BEGIN marker is rewritten only when its matching END is known, so an
  # unterminated block is left intact for the detector to refuse.
  for (i = 1; i <= NR; i++) {
    if (lines[i] ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
      close_at = 0
      for (j = i + 1; j <= NR; j++) {
        if (lines[j] ~ /-----END [A-Z ]*PRIVATE KEY-----/) { close_at = j; break }
      }
      if (close_at > 0) {
        print "[redacted:private-key]"
        counts["private-key"]++
        i = close_at
        continue
      }
    }
    print scrub(lines[i])
  }
  for (c in counts) printf "%s %d\n", c, counts[c] > countfile
  close(countfile)
}
'
}

# stdin -> one class name per line for every credential shape that survived.
# Empty output means the body is clean.
#
# Placeholders are masked before matching: "://[redacted:url-userinfo]@" is
# itself userinfo-shaped, so a detector that read its own output would refuse
# every body it had just cleaned.
fm_gbrain_capture_residual() {  # < redacted-body
  awk '
'"$(_fm_gbrain_capture_awk_patterns)"'
BEGIN { classes() }
{ line = $0; gsub(/\[redacted:[a-z-]+\]/, "REDACTED", line); lines[NR] = line }
END {
  for (i = 1; i <= NR; i++) {
    if (lines[i] ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
      close_at = 0
      for (j = i + 1; j <= NR; j++) {
        if (lines[j] ~ /-----END [A-Z ]*PRIVATE KEY-----/) { close_at = j; break }
      }
      if (close_at == 0) found["private-key-unterminated"] = 1
    }
    for (k = 1; k <= npat; k++) {
      if (boundary_match(lines[i], ppat[k])) found[pcls[k]] = 1
    }
    if (lines[i] ~ /:\/\/[^\/@ \t]+:[^\/@ \t]+@/) found["url-userinfo"] = 1
  }
  for (c in found) print c
}
' | sort
}

# --- outbox records ---------------------------------------------------------

fm_gbrain_capture_now_iso() {
  if [ -n "${FM_GBRAIN_CAPTURE_NOW_ISO:-}" ]; then
    printf '%s\n' "$FM_GBRAIN_CAPTURE_NOW_ISO"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Every stored record is validated on the way in and on the way out, so a
# truncated or hand-edited file is reported rather than silently believed.
fm_gbrain_capture_item_valid() {  # <json>
  printf '%s' "$1" | jq -e --arg schema "$FM_GBRAIN_CAPTURE_SCHEMA" '
    type == "object"
    and .schema == $schema
    and (.document_id | type == "string" and length > 0)
    and (.slug | type == "string" and length > 0 and length <= 200)
    and (.home | type == "string" and length > 0)
    and (.source | type == "object" and (.kind | IN("task","note")) and (.id | type == "string" and length > 0))
    and (.content_version | type == "string" and test("^sha256:[0-9a-f]+$"))
    and (.revision_id | type == "string" and test("^rev-[0-9a-f]+$"))
    and (.status | IN("pending","captured","failed"))
    and (.attempts | type == "number" and . >= 0)
    and (.last_error == null or (.last_error | type == "string"))
    and (.gbrain_document == null or (.gbrain_document | type == "string" and length > 0))
    and (.delivered_version == null or (.delivered_version | type == "string" and test("^sha256:[0-9a-f]+$")))
    and (.source_version == null or (.source_version | type == "string" and test("^sha256:[0-9a-f]+$")))
    and (.delivered_source_version == null or (.delivered_source_version | type == "string" and test("^sha256:[0-9a-f]+$")))
    and (.redactions | type == "array")
    and (.body | type == "string")
    and (.truncated == null or (.truncated | type == "boolean"))
    and (.captured_bytes == null or (.captured_bytes | type == "number" and . >= 0))
  ' >/dev/null 2>&1
}

fm_gbrain_capture_item_read() {  # <data-dir> <document-id>
  local path doc
  path=$(fm_gbrain_capture_item_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  doc=$(cat "$path" 2>/dev/null) || return 1
  fm_gbrain_capture_item_valid "$doc" || return 2
  printf '%s\n' "$doc"
}

# Atomic by construction: a crash mid-write leaves the previous complete record
# or no record, never a half-written one.
fm_gbrain_capture_item_write() {  # <data-dir> <document-id> <json>
  local dir path tmp
  fm_gbrain_capture_item_valid "$3" || return 1
  dir=$(fm_gbrain_capture_outbox_dir "$1")
  mkdir -p "$dir" || return 1
  path=$(fm_gbrain_capture_item_path "$1" "$2")
  tmp=$(mktemp "$dir/.fm-gbrain-capture.XXXXXX") || return 1
  printf '%s\n' "$3" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Compose a record from an already-composed RAW body. Redaction and the residual
# guard both run here, before any byte reaches disk: FM_GBRAIN_CAPTURE_ERROR
# names the refusal when the guard rejects the body.
#
# The record goes to <out-file> rather than to stdout so a caller can read
# FM_GBRAIN_CAPTURE_ERROR afterwards: a command substitution would run this in a
# subshell and lose the reason for every refusal it is supposed to report.
# Returns 1 on refusal, 2 on an internal failure.
fm_gbrain_capture_item_build() {  # <home> <kind> <source-id> <title> <raw-body-file> <out-file> [<previous-json>] [<source-version>]
  local home=$1 kind=$2 source_id=$3 title=$4 raw=$5 out=$6 previous=${7:-} source_version=${8:-}
  local tag doc_id slug counts redacted residual now version attempts prev_status
  local raw_bytes truncated captured_bytes
  # Cleared for the caller, which reads it after a refusal return.
  # shellcheck disable=SC2034
  FM_GBRAIN_CAPTURE_ERROR=""
  fm_gbrain_capture_kind_valid "$kind" || { fm_gbrain_capture_fail "unknown capture kind \"$kind\""; return 2; }
  fm_gbrain_capture_source_id_valid "$source_id" || { fm_gbrain_capture_fail "unsafe capture source id \"$source_id\""; return 2; }
  tag=$(fm_gbrain_capture_home_tag "$home")
  doc_id=$(fm_gbrain_capture_document_id "$tag" "$kind" "$source_id")
  slug=$(fm_gbrain_capture_slug "$tag" "$kind" "$source_id")

  counts=$(mktemp) || return 2
  redacted=$(mktemp) || { rm -f "$counts"; return 2; }
  # The composed body is measured before it is cut, so a body that hit the cap
  # is known to be incomplete rather than inferred to be from its stored length.
  raw_bytes=$(wc -c < "$raw" 2>/dev/null | tr -cd '0-9')
  [ -n "$raw_bytes" ] || raw_bytes=0
  truncated=false
  [ "$raw_bytes" -le "$FM_GBRAIN_CAPTURE_MAX_BYTES" ] || truncated=true
  head -c "$FM_GBRAIN_CAPTURE_MAX_BYTES" "$raw" \
    | fm_gbrain_capture_redact "$counts" > "$redacted" || { rm -f "$counts" "$redacted"; return 2; }
  # Appended after redaction and before the residual guard: the redactor cannot
  # rewrite it, the guard reads it as the ordinary prose it is, and the content
  # version below covers it, so a body that starts hitting the cap is a new
  # revision rather than an unchanged one.
  if [ "$truncated" = true ]; then
    fm_gbrain_capture_truncation_marker "$FM_GBRAIN_CAPTURE_MAX_BYTES" >> "$redacted" \
      || { rm -f "$counts" "$redacted"; return 2; }
  fi
  residual=$(fm_gbrain_capture_residual < "$redacted" | tr '\n' ' ')
  residual=${residual% }
  if [ -n "$residual" ]; then
    rm -f "$counts" "$redacted"
    fm_gbrain_capture_fail "refusing to store $doc_id: credential-shaped content survived redaction ($residual)"
    return 1
  fi
  if [ ! -s "$redacted" ]; then
    rm -f "$counts" "$redacted"
    fm_gbrain_capture_fail "refusing to store $doc_id: nothing to capture"
    return 1
  fi

  captured_bytes=$(wc -c < "$redacted" 2>/dev/null | tr -cd '0-9')
  [ -n "$captured_bytes" ] || captured_bytes=0
  version="sha256:$(fm_gbrain_capture_sha256 < "$redacted")"
  now=$(fm_gbrain_capture_now_iso)
  attempts=0
  prev_status=
  if [ -n "$previous" ]; then
    prev_status=$(printf '%s' "$previous" | jq -r '.content_version // ""')
    if [ "$prev_status" = "$version" ]; then
      # Same content: keep the record's history rather than resetting a
      # captured document back to pending on a re-run. The source fingerprint
      # is still a fresh measurement of what is on disk right now, so it is
      # recorded here; a record written before this field existed also learns
      # what its served page was built from, because a byte-identical body is
      # proof that this source is the one that produced it.
      rm -f "$counts" "$redacted"
      printf '%s\n' "$previous" | jq --arg sv "$source_version" '
        .source_version = (if $sv == "" then .source_version else $sv end)
        | .delivered_source_version = (.delivered_source_version
            // (if .status == "captured" then .source_version else null end))' > "$out" || return 2
      return 0
    fi
  fi

  local doc revision
  revision=$(fm_gbrain_capture_revision_id "$doc_id" "$version")
  doc=$(jq -n \
    --arg schema "$FM_GBRAIN_CAPTURE_SCHEMA" \
    --arg document_id "$doc_id" \
    --arg revision "$revision" \
    --arg slug "$slug" \
    --arg home "$home" \
    --arg kind "$kind" \
    --arg source_id "$source_id" \
    --arg title "$title" \
    --arg version "$version" \
    --arg source_version "$source_version" \
    --arg now "$now" \
    --argjson attempts "$attempts" \
    --argjson truncated "$truncated" \
    --argjson captured_bytes "$captured_bytes" \
    --rawfile body "$redacted" \
    --rawfile counts "$counts" '
      {
        schema: $schema,
        document_id: $document_id,
        revision_id: $revision,
        slug: $slug,
        home: $home,
        source: {kind: $kind, id: $source_id, title: (if $title == "" then null else $title end)},
        content_version: $version,
        status: "pending",
        attempts: $attempts,
        last_error: null,
        gbrain_document: null,
        delivered_version: null,
        source_version: (if $source_version == "" then null else $source_version end),
        delivered_source_version: null,
        redactions: ($counts | split("\n") | map(select(length > 0) | split(" ") | {class: .[0], count: (.[1] | tonumber)}) | sort_by(.class)),
        truncated: $truncated,
        captured_bytes: $captured_bytes,
        created_at: $now,
        updated_at: $now,
        captured_at: null,
        body: $body
      }') || { rm -f "$counts" "$redacted"; return 2; }
  rm -f "$counts" "$redacted"
  # A rebuild resets status, gbrain_document and captured_at, so without this
  # the record would forget that its page had ever been delivered at all - and
  # a refresh whose first delivery failed could never be told from a first
  # capture afterwards. Both delivered versions therefore survive the rebuild
  # the same way created_at does, and only a landed delivery moves them.
  #
  # The source one deliberately does NOT fall back to the previous content
  # version: a record written before this field existed has no recorded source
  # for its served page, and inventing one would let this change's own body
  # rewrites read as reports somebody edited.
  if [ -n "$previous" ]; then
    doc=$(printf '%s' "$doc" | jq --argjson prev "$previous" '
      .created_at = ($prev.created_at // .created_at)
      | .delivered_version = ($prev.delivered_version
          // (if $prev.status == "captured" then $prev.content_version else null end))
      | .delivered_source_version = ($prev.delivered_source_version
          // (if $prev.status == "captured" then $prev.source_version else null end))') || return 2
  fi
  printf '%s\n' "$doc" > "$out" || return 2
}
