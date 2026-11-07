#!/usr/bin/env bash
#
# Run ipsw-workflow.sh over a chain of builds, oldest NEW build first.
#
#   scripts/run-chain.sh iOS iPhone13,3 23G71 23G83 23G90 24A437 24A446
#
# becomes the consecutive pairs 23G71->23G83, 23G83->23G90, 23G90->24A437,
# 24A437->24A446 and runs them one at a time. Chain order matters because
# adjacent pairs share an IPSW side: run them in order and each build is
# downloaded once and used twice. (`ipsw diff`'s cache DB is keyed per build
# PAIR, so it makes a re-run of the same pair cheap but carries nothing
# between adjacent pairs.)
#
# A pair whose diff JSON is already in the workdir is still run: the workflow
# skips the expensive `ipsw diff` and goes straight to extraction. That is the
# intended path for re-extracting a pair whose binaries were produced by an
# older, buggier version of the extractor.
#
# Env:
#   IPSW_DIFFS_DIR        base dir for workdirs (and the IPSWs symlink)
#   IPSW_DIFF_CACHE_DIR   persistent `ipsw diff` parse cache
#   IPSW_LOG_DIR          per-pair logs (default $IPSW_DIFFS_DIR/../logs)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OS_TYPE="${1:?os_type required (iOS|macOS)}"
DEVICE="${2:?device required (e.g. iPhone13,3)}"
shift 2
[ "$#" -ge 2 ] || { echo "❌ need at least two builds to form a pair" >&2; exit 1; }

BUILDS=("$@")
SAFE_DEVICE="${DEVICE//,/_}"
BASE_DIR="${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}"
LOG_DIR="${IPSW_LOG_DIR:-$BASE_DIR/../logs}"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

# Run from a snapshot, not from the tree. These runs take hours and bash reads
# a script incrementally by byte offset: editing the file in place mid-run
# shifts every later offset and the running shell resumes mid-statement. The
# failure looks like a nonsense syntax error on a line that is blank in the
# version actually on disk.
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/ipsw-chain-XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
cp "$REPO_ROOT/scripts/ipsw-workflow.sh" "$SNAP/"
chmod +x "$SNAP/ipsw-workflow.sh"

echo "=== chain: $DEVICE ($OS_TYPE) ==="
echo "    builds: ${BUILDS[*]}"
echo "    pairs:  $(( ${#BUILDS[@]} - 1 ))"
echo "    base:   $BASE_DIR"
echo "    logs:   $LOG_DIR"
echo "    script: $SNAP/ipsw-workflow.sh ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))"
echo

# ---- KEEP_IPSW=0: reclaim each IPSW once the chain is past it ----
# A full backfill downloads ~2.1TB of IPSWs to produce ~400GB of diffs. The
# IPSWs are the recoverable half — Apple still serves every build back to
# iOS 14, including the 31 that ipsw.me delisted (appledb has live URLs) — so
# deleting them as the chain advances turns a 2.5TB job into ~450GB peak.
#
# In chain order each build is used by exactly two pairs: as NEW, then as OLD.
# So once pair i succeeds, BUILDS[i] has served both and is free. BUILDS[i+1]
# is NOT, because it is the OLD of pair i+1.
#
# Deletion happens only after a pair exits 0, which means it cleared the
# completeness gate — a failed or short extraction keeps its input so the pair
# can be retried without a re-download.
KEEP_IPSW="${KEEP_IPSW:-1}"
IPSW_POOL="$BASE_DIR/IPSWs"

# The pool is usually a symlink to a directory shared with other repos
# (wf-at56 points at the same one), so a delete here is NOT local to this
# chain. Resolve it and say so rather than quietly removing another workspace's
# inputs.
if [ "$KEEP_IPSW" = 0 ]; then
  real_pool="$(cd "$IPSW_POOL" 2>/dev/null && pwd -P || echo "$IPSW_POOL")"
  echo "[!] KEEP_IPSW=0 — IPSWs will be deleted as the chain advances"
  echo "    pool: $real_pool"
  [ "$real_pool" != "$IPSW_POOL" ] && \
    echo "    ⚠ this is a SHARED pool ($IPSW_POOL -> $real_pool); other repos use it"
  echo
fi

reclaim_ipsw() {            # $1 = build no longer needed by this chain
  local build="$1" f
  [ "$KEEP_IPSW" = 0 ] || return 0
  # -L so a symlinked pool is followed; print -quit to stop at the first hit.
  f="$(find -L "$IPSW_POOL" -maxdepth 1 -type f \
        -name "*_${build}_Restore.ipsw" ! -name '._*' -print -quit 2>/dev/null)"
  if [ -n "$f" ]; then
    echo "    [reclaim] rm $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
    rm -f "$f"
  fi
}

failed=()
for ((i = 0; i < ${#BUILDS[@]} - 1; i++)); do
  OLD="${BUILDS[i]}"; NEW="${BUILDS[i+1]}"
  LOG="$LOG_DIR/${SAFE_DEVICE}-${OLD}-${NEW}.log"
  echo "--- [$((i+1))/$(( ${#BUILDS[@]} - 1 ))] $OLD -> $NEW  ($(date +%H:%M:%S)) ---"
  echo "    log: $LOG"
  if "$SNAP/ipsw-workflow.sh" "$OS_TYPE" "$DEVICE" "$OLD" "$NEW" >>"$LOG" 2>&1; then
    d="$BASE_DIR/${SAFE_DEVICE}/${OLD}-${NEW}"
    echo "    ✅ done — changed=$(find "$d/changed" -type f 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$d" 2>/dev/null | cut -f1)"
    reclaim_ipsw "$OLD"
  else
    echo "    ❌ FAILED — see $LOG"
    echo "       last lines:"
    tail -5 "$LOG" 2>/dev/null | sed 's/^/         /'
    failed+=("$OLD->$NEW")
  fi
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "=== ${#failed[@]} pair(s) failed: ${failed[*]} ==="
  exit 1
fi
echo "=== chain complete ($(date +%H:%M:%S)) ==="
