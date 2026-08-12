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
# an HTTP 503, or curl exit 56 when the connection dies mid-transfer - and the
# budget that absorbs it is wall time, not a count of attempts. Two CI failures
# on the "Behavior portable serial 4" lane measured how long such a blip lasts.
# The first loop stopped three attempts in, giving up ~3s after the opening 503.
# The five-attempt loop that replaced it expressed its budget as a count again
# and gave up 31s in, while the same run's six other ShellCheck installs
# downloaded the asset without trouble - a blip local to one runner, outlasted
# only by waiting longer. So the loop below spends a declared retry budget:
# it keeps trying until it has waited DOWNLOAD_RETRY_BUDGET_SECONDS in total,
# which is 4 minutes, roughly eight times the outage actually observed.
#
# Backoff doubles from 2s but is capped, so a long blip is probed repeatedly
# rather than slept through, and the last wait is trimmed to whatever is left of
# the budget so the constant above is the real span and not an approximation.
#
# Each attempt is also time-bounded. A transient blip can stall a connection
# instead of dropping it, and an unbounded curl would hold the whole lane;
# --max-time is far above the ~1MB asset's real transfer cost, so it only ever
# fires on a stall. Both CI blips failed in well under a second, so the retry
# budget dominates the step's runtime in practice; only a total outage that
# stalls every single attempt could run long enough for a lane's own hang
# tripwire to fire, and that is a failure the lane should take. A fresh curl per
# attempt is what recovers from a dead connection, so curl's own --retry is
# deliberately not stacked on top of this loop.
DOWNLOAD_RETRY_BUDGET_SECONDS=240
DOWNLOAD_BACKOFF_SECONDS=2
DOWNLOAD_BACKOFF_CAP_SECONDS=60
CONNECT_TIMEOUT_SECONDS=10
TRANSFER_TIMEOUT_SECONDS=60
download_attempt=1
download_backoff=$DOWNLOAD_BACKOFF_SECONDS
download_waited=0
while :; do
  curl_status=0
  curl -fsSL --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
    --max-time "$TRANSFER_TIMEOUT_SECONDS" "$URL" -o "$TMP/$ARCHIVE" || curl_status=$?
  if [ "$curl_status" -eq 0 ]; then
    break
  fi
  download_remaining=$((DOWNLOAD_RETRY_BUDGET_SECONDS - download_waited))
  if [ "$download_remaining" -le 0 ]; then
    printf 'fm-install-shellcheck.sh: download failed after %s attempts spanning %ss of retries (curl exit %s)\n' \
      "$download_attempt" "$download_waited" "$curl_status" >&2
    exit 1
  fi
  download_wait=$download_backoff
  [ "$download_wait" -le "$download_remaining" ] || download_wait=$download_remaining
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying in %ss (curl exit %s)\n' \
    "$download_attempt" "$download_wait" "$curl_status" >&2
  sleep "$download_wait"
  download_waited=$((download_waited + download_wait))
  download_backoff=$((download_backoff * 2))
  [ "$download_backoff" -le "$DOWNLOAD_BACKOFF_CAP_SECONDS" ] \
    || download_backoff=$DOWNLOAD_BACKOFF_CAP_SECONDS
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
