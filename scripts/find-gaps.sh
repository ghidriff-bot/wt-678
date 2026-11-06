#!/usr/bin/env bash
#
# Report which consecutive build pairs are missing from the local corpus.
#
#   scripts/find-gaps.sh iOS iPhone13,3            # human-readable
#   scripts/find-gaps.sh iOS iPhone13,3 --builds   # just the build list
#
# Apple's catalog is the source of truth for what COULD be diffed; the
# workdirs under $IPSW_DIFFS_DIR say what has been. The difference is the
# backfill queue.
#
# --builds prints a chain-ordered build list suitable for feeding straight to
# run-chain.sh. It emits a CONTIGUOUS run only: run-chain.sh turns a list into
# consecutive pairs, so handing it a list with holes would fabricate pairs that
# skip builds (e.g. "A C D" would diff A->C, which is not a real update path).
# When gaps are non-contiguous it prints the longest run and notes the rest.
#
# A pair counts as present only if its diff JSON (or zip) exists AND its
# extraction passed the completeness gate. A gated failure is reported as
# "incomplete" and re-queued: that is the state the macOS 27 --device and
# MACHO_REGEX bugs produced, and it looked identical to success from the
# outside.

set -euo pipefail

OS_TYPE="${1:?os_type required (iOS|macOS)}"
DEVICE="${2:?device required (e.g. iPhone13,3)}"
MODE="${3:-report}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}"
SAFE_DEVICE="${DEVICE//,/_}"
DEV_DIR="$BASE_DIR/$SAFE_DEVICE"

# ---- Apple's served build list, newest first ----
# `ipsw dl ipsw --urls` is the signed/served set. appledb knows more (31 extra
# builds for iPhone13,3) but not all of those have fetchable URLs, so the
# served list is the honest definition of "available".
urls="$(ipsw dl ipsw --device "$DEVICE" --urls 2>/dev/null \
        | sed -r 's/\x1B\[[0-9;]*[mGKH]//g' | grep '^https' || true)"
[ -n "$urls" ] || { echo "[ERROR] no builds returned for $DEVICE" >&2; exit 1; }

# Build list oldest-first, which is the order chains must run in.
builds="$(printf '%s\n' "$urls" \
  | grep -oE '_[0-9A-Z]+_Restore\.ipsw$' \
  | sed -E 's/^_//; s/_Restore\.ipsw$//' \
  | tail -r 2>/dev/null || printf '%s\n' "$urls" \
  | grep -oE '_[0-9A-Z]+_Restore\.ipsw$' | sed -E 's/^_//; s/_Restore\.ipsw$//' | tac)"

# read -a rather than mapfile: macOS ships bash 3.2, which has no mapfile.
B=(); while IFS= read -r _b; do [ -n "$_b" ] && B+=("$_b"); done <<< "$builds"
TOTAL=$(( ${#B[@]} - 1 ))

pair_state() {           # echoes: done | incomplete | nodiff
  local old="$1" new="$2" d="$DEV_DIR/$old-$new"
  if [ ! -e "$d/diffs/diff_${SAFE_DEVICE}_${old}_to_${new}.json" ] \
     && [ ! -e "$d/diffs/diff_${SAFE_DEVICE}_${old}_to_${new}.zip" ]; then
    echo nodiff; return
  fi
  # The gate writes this on every run; a SHORTFALL line means the archive was
  # refused, so the pair is not usable even though a diff exists.
  if [ -f "$d/metadata/extraction_report.txt" ] \
     && grep -q 'SHORTFALL' "$d/metadata/extraction_report.txt"; then
    echo incomplete; return
  fi
  if [ -d "$d/changed" ] && [ -n "$(find "$d/changed" -type f -print -quit 2>/dev/null)" ]; then
    echo done; return
  fi
  echo incomplete
}

missing=()
if [ "$MODE" != "--builds" ]; then
  printf '%-18s %s\n' "PAIR" "STATE"
fi
for ((i = 0; i < TOTAL; i++)); do
  old="${B[i]}"; new="${B[i+1]}"
  st="$(pair_state "$old" "$new")"
  [ "$st" != done ] && missing+=("$old-$new")
  if [ "$MODE" != "--builds" ]; then
    case "$st" in
      done)       printf '%-18s %s\n' "$old->$new" "ok" ;;
      incomplete) printf '%-18s %s\n' "$old->$new" "INCOMPLETE (re-extract)" ;;
      nodiff)     printf '%-18s %s\n' "$old->$new" "missing" ;;
    esac
  fi
done

if [ "$MODE" != "--builds" ]; then
  echo
  echo "device=$DEVICE  pairs=$TOTAL  missing=${#missing[@]}"
  [ "${#missing[@]}" -gt 0 ] && printf '  %s\n' "${missing[@]}"
  exit 0
fi

# ---- --builds: longest contiguous run of missing pairs ----
[ "${#missing[@]}" -gt 0 ] || exit 0
best_s=0; best_n=0; cur_s=0; cur_n=0; prev_new=""
for m in "${missing[@]}"; do
  old="${m%-*}"; new="${m#*-}"
  if [ "$old" = "$prev_new" ]; then
    cur_n=$((cur_n + 1))
  else
    cur_s="$old"; cur_n=1
  fi
  if [ "$cur_n" -gt "$best_n" ]; then best_n="$cur_n"; best_s="$cur_s"; fi
  prev_new="$new"
done

# Re-walk to emit the builds of the best run in order.
out=(); collecting=0; n=0
for m in "${missing[@]}"; do
  old="${m%-*}"; new="${m#*-}"
  if [ "$collecting" = 0 ] && [ "$old" = "$best_s" ]; then
    collecting=1; out+=("$old")
  fi
  if [ "$collecting" = 1 ] && [ "$n" -lt "$best_n" ]; then
    out+=("$new"); n=$((n + 1))
  fi
done
printf '%s\n' "${out[@]}"
if [ "$best_n" -lt "${#missing[@]}" ]; then
  echo "[note] emitted $best_n of ${#missing[@]} missing pairs (longest contiguous run);" \
       "re-run after this chain for the rest" >&2
fi
