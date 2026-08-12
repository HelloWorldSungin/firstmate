#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The failure this retry loop exists to absorb is a transient release-CDN blip -
# an HTTP 503, or curl exit 56 when the connection dies mid-transfer - and those
# blips outlast a few seconds. The retry budget must therefore be measured in
# wall time, not attempt count: three attempts one and two seconds apart spent
# the whole budget within ~3s of the first 503 and failed the "Behavior portable
# serial 4" lane on infra noise. Backoff doubles from 2s, so five attempts keep
# trying across ~30s of waiting.
#
# Each attempt is also time-bounded. A transient blip can stall a connection
# instead of dropping it, and an unbounded curl would then hold the whole lane
# until the job timeout; --max-time is far above the ~1MB asset's real transfer
# cost, so it only ever fires on a stall. A fresh curl per attempt is what
# recovers from a dead connection, so curl's own --retry is deliberately not
# stacked on top of this loop.
DOWNLOAD_ATTEMPTS=5
DOWNLOAD_BACKOFF_SECONDS=2
CONNECT_TIMEOUT_SECONDS=10
TRANSFER_TIMEOUT_SECONDS=60
download_attempt=1
download_backoff=$DOWNLOAD_BACKOFF_SECONDS
while :; do
  curl_status=0
  curl -fsSL --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
    --max-time "$TRANSFER_TIMEOUT_SECONDS" "$URL" -o "$TMP/$ARCHIVE" || curl_status=$?
  if [ "$curl_status" -eq 0 ]; then
    break
  fi
  if [ "$download_attempt" -ge "$DOWNLOAD_ATTEMPTS" ]; then
    printf 'fm-install-shellcheck.sh: download failed after %s attempts (curl exit %s)\n' \
      "$DOWNLOAD_ATTEMPTS" "$curl_status" >&2
    exit 1
  fi
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying in %ss (curl exit %s)\n' \
    "$download_attempt" "$download_backoff" "$curl_status" >&2
  sleep "$download_backoff"
  download_backoff=$((download_backoff * 2))
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
