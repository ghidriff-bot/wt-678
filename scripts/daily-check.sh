#!/usr/bin/env bash
#
# Daily read-only health check. Audits new OTAs, refreshes the status
# snapshot, and reports gaps. Does NOT download IPSWs or run diffs.
#
#   scripts/daily-check.sh
#
# Deliberately read-only. Two failures this week were invisible for hours —
# a chain that died to system sleep with nothing logged, and three pairs that
# printed "done" while extracting zero machos — so the value here is noticing,
# not acting. Backfilling 136 missing pairs is a multi-day, multi-TB job and
# has no business starting unattended from a timer; this prints the exact
# run-chain.sh command instead and leaves the decision to a human.
#
# Cost per run: ~2s per new OTA for the structure audit (central-directory
# reads only, ~300KB each) plus ~12s for the status walk. No large downloads.
#
# Exit status is always 0 unless the script itself breaks: a gap or an
# anomaly is information, not an error, and a non-zero exit would just make
# the scheduler look broken.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Load the local environment (Vault paths) if present. Without it everything
# below silently targets the in-repo ipsw_diffs/ and reports a corpus that
# looks almost entirely missing.
if [ -f scripts/env.local.sh ]; then
  # shellcheck disable=SC1091
  . scripts/env.local.sh
fi

DEVICES="${DAILY_DEVICES:-iOS:iPhone13,3 macOS:Mac14,12}"
LOG_DIR="${IPSW_LOG_DIR:-${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}/../logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

echo "=== daily check $(date -u +%FT%TZ) ==="
echo

# ---- 1. Is anything running, and is it alive? ----
if pgrep -f 'ipsw-workflow' >/dev/null 2>&1; then
  newest="$(find "$LOG_DIR" -name '*.log' -type f -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null | head -1)"
  age=""
  if [ -n "$newest" ]; then
    mt=$(stat -f %m "$newest" 2>/dev/null || echo 0)
    [ "$mt" -gt 0 ] && age=$(( $(date +%s) - mt ))
  fi
  echo "[chain] RUNNING  (newest log ${age:-?}s old: $(basename "${newest:-none}"))"
  # A live process whose log has not moved in 30min is the shape of a hung
  # mount or a stalled download, which is worth saying out loud.
  if [ -n "$age" ] && [ "$age" -gt 1800 ]; then
    echo "[chain] ⚠ log has not advanced in $((age / 60))m — possible stall"
  fi
else
  echo "[chain] idle"
fi
echo

# ---- 2. OTA structure audit ----
# Only scans OTAs not seen before, so a quiet day costs almost nothing.
for spec in $DEVICES; do
  plat="${spec%%:*}"
  case "$plat" in iOS) p=ios ;; macOS) p=macos ;; *) p="$(echo "$plat" | tr 'A-Z' 'a-z')" ;; esac
  echo "[audit] $p"
  ./scripts/ota-audit.sh --platform "$p" 2>&1 \
    | grep -E 'to scan|scanned=|anomal|UNEXPECTED|nothing new|ERROR|WARN' \
    | sed 's/^/    /'
done
echo

# ---- 3. Refresh the status snapshot ----
echo "[status]"
./scripts/status.sh 2>&1 | sed 's/^/    /'
echo

# ---- 4. Gaps, with the command to close them ----
for spec in $DEVICES; do
  os_type="${spec%%:*}"; device="${spec#*:}"
  echo "[gaps] $device"
  summary="$(./scripts/find-gaps.sh "$os_type" "$device" 2>/dev/null | grep '^device=')"
  echo "    ${summary:-(could not enumerate)}"

  # The head pair is the one that matters day to day: a new release landing
  # shows up here first.
  head_missing="$(./scripts/find-gaps.sh "$os_type" "$device" 2>/dev/null \
                  | grep -vE '^(device=|PAIR|$)' | tail -1)"
  case "$head_missing" in
    *missing*|*INCOMPLETE*) echo "    ⚠ newest pair not done: $head_missing" ;;
  esac

  builds="$(./scripts/find-gaps.sh "$os_type" "$device" --builds 2>/dev/null | tr '\n' ' ')"
  if [ -n "${builds// /}" ]; then
    echo "    to backfill the longest contiguous run:"
    echo "      ./scripts/run-chain.sh $os_type $device $builds"
  fi
done

echo
echo "=== done $(date -u +%FT%TZ) ==="
exit 0
