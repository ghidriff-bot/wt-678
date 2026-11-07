#!/usr/bin/env bash
#
# Diff a pair whose NEW side ships only as an OTA.
#
#   scripts/ota-pair.sh iOS iPhone13,3 23G90 23H128
#
# Some Apple security trains have no IPSW on any device — iOS 26.7.2
# (23H128) and macOS 26.7.2 (25G332) are the current examples, released
# 2026-10-26. `ipsw dl appledb --build 23H128` returns nothing for every
# device. They ship OTA-only, which puts them out of reach of
# ipsw-workflow.sh, whose download and locate steps both key on
# *_Restore.ipsw.
#
# These are the pairs worth the most: a security-only train diffed against
# its immediate predecessor (26.6.2 -> 26.7.2) has almost no feature churn,
# so nearly every changed binary is a fix.
#
# WHY THIS IS NOT JUST A PATH SUBSTITUTION
# ----------------------------------------
# `ipsw diff` accepts an OTA as either side, so the obvious move is to hand
# it the OTA and move on. That silently produces a diff with no dylibs in it.
#
# Reading the 23H128 OTA's central directory (~30KB, no download) shows why:
#
#   AssetData/boot/kernelcache.release.iphone13              present
#   AssetData/payloadv2/image_patches/cryptex-system-arm64e  1341 MB
#   dyld_shared_cache                                        0 entries
#
# The asset is marked delivery=full, but on current iOS the system cryptex —
# which holds the shared cache — arrives as a BXDIFF50 patch against the
# PREVIOUS version, not as a full image. Diffing the OTA directly yields the
# kernelcache and standalone machos and zero dylibs, which is worse than
# failing because it looks like a successful pair.
#
# So the new side has to be reconstructed first:
#
#   1. extract the OLD build's filesystem from its IPSW   (base)
#   2. ipsw ota patch bxdiff <OTA> -i base -o patched     (apply the delta)
#   3. ipsw diff <base> <patched> --files                 (directory diff)
#
# Step 3 is the "patched OTA DMG directories" mode in `ipsw diff --help`.
#
# WHAT THE CONSUMER SEES
# ----------------------
# Nothing new. agents/platforms/apple.py keys on paths relative to
# `changed/new/`, and tools/diffing_tool.py takes an old path and a new path.
# An OTA-sourced pair lands in the same changed/old + changed/new layout as
# every other pair, so the correlator and ghidriff need no changes at all.
# The OTA is only a different way to materialise the new side.

set -euo pipefail

OS_TYPE="${1:?os_type required (iOS|macOS)}"
DEVICE="${2:?device required}"
OLD_BUILD="${3:?old build required (must have an IPSW)}"
NEW_BUILD="${4:?new build required (the OTA-only side)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}"
SAFE_DEVICE="${DEVICE//,/_}"
WORKDIR="$BASE_DIR/${SAFE_DEVICE}/${OLD_BUILD}-${NEW_BUILD}"
OTA_DIR="$BASE_DIR/OTAs"
IPSW_DIR="$BASE_DIR/IPSWs"

mkdir -p "$WORKDIR"/{diffs,metadata,base,patched} "$OTA_DIR"

case "$OS_TYPE" in
  iOS)   plat=ios   ;;
  macOS) plat=macos ;;
  *)     plat="$(echo "$OS_TYPE" | tr 'A-Z' 'a-z')" ;;
esac

# ---- 1. Resolve the OTA ----
echo "[*] resolving OTA for $DEVICE $NEW_BUILD..."
OTA_URL="$(ipsw download ota --platform "$plat" --device "$DEVICE" --json 2>/dev/null \
  | python3 -I -c "
import json,sys
want=sys.argv[1]
for o in json.load(sys.stdin).get('otas',[]):
    if o.get('build')==want:
        print(o['url']); break
" "$NEW_BUILD")"

if [ -z "$OTA_URL" ]; then
  echo "[ERROR] no OTA published for $DEVICE $NEW_BUILD" >&2
  exit 1
fi

# An AEA-encrypted OTA cannot be opened: ipsw refuses remote extraction on
# them and the header carries key metadata only. Fail loudly rather than
# producing an empty pair.
case "$OTA_URL" in
  *.aea)
    echo "[ERROR] $NEW_BUILD ships as an encrypted .aea OTA; not supported." >&2
    echo "        (iOS has ~58 of these, covering devices with no plain zip.)" >&2
    exit 1 ;;
esac

OTA="$OTA_DIR/${SAFE_DEVICE}_${NEW_BUILD}.zip"
if [ -s "$OTA" ]; then
  echo "[*] OTA already present: $OTA ($(du -h "$OTA" | cut -f1))"
else
  echo "[*] downloading OTA -> $OTA"
  curl -fL --retry 3 -C - "$OTA_URL" -o "$OTA"
fi

# ---- 2. Locate the OLD IPSW ----
OLD_IPSW="$(find -L "$IPSW_DIR" -maxdepth 1 -type f \
            -name "*_${OLD_BUILD}_Restore.ipsw" ! -name '._*' -print -quit 2>/dev/null)"
if [ -z "$OLD_IPSW" ]; then
  echo "[*] old IPSW not present; downloading $OLD_BUILD..."
  ipsw dl appledb --os "$OS_TYPE" --device "$DEVICE" --build "$OLD_BUILD" \
    --output "$IPSW_DIR" --confirm
  OLD_IPSW="$(find -L "$IPSW_DIR" -maxdepth 1 -type f \
              -name "*_${OLD_BUILD}_Restore.ipsw" ! -name '._*' -print -quit 2>/dev/null)"
fi
[ -n "$OLD_IPSW" ] || { echo "[ERROR] no IPSW for $OLD_BUILD" >&2; exit 1; }
echo "[*] old IPSW: $(basename "$OLD_IPSW")"

# ---- 3. Extract the old filesystem as the patch base ----
# --device for the same reason the main workflow needs it: a macOS 27 IPSW
# carries more than one SystemOS DMG and the files pass refuses to guess.
if [ -z "$(find "$WORKDIR/base" -type f -print -quit 2>/dev/null)" ]; then
  echo "[*] extracting old filesystem (patch base)..."
  ipsw extract --files --device "$DEVICE" -o "$WORKDIR/base" "$OLD_IPSW"
else
  echo "[*] patch base already extracted — skipping."
fi

# ---- 4. Apply the OTA's BXDIFF patches ----
if [ -z "$(find "$WORKDIR/patched" -type f -print -quit 2>/dev/null)" ]; then
  echo "[*] applying BXDIFF patches from OTA..."
  ipsw ota patch bxdiff "$OTA" -i "$WORKDIR/base" -o "$WORKDIR/patched"
else
  echo "[*] patched tree already present — skipping."
fi

# ---- 5. Diff the two directories ----
DIFF_JSON="$WORKDIR/diffs/diff_${SAFE_DEVICE}_${OLD_BUILD}_to_${NEW_BUILD}.json"
if [ -s "$DIFF_JSON" ]; then
  echo "[*] diff already present: $DIFF_JSON"
else
  echo "[*] diffing base vs patched..."
  ipsw diff --block-list "__TEXT.__info_plist" --ignore-build-timestamps \
    "$WORKDIR/base" "$WORKDIR/patched" \
    --files --json --output "$WORKDIR/diffs" \
    --title "Diff ${SAFE_DEVICE} $OLD_BUILD vs $NEW_BUILD (OTA)"
  gen="$(find "$WORKDIR/diffs" -name '*.json' -print -quit)"
  [ -n "$gen" ] && [ "$gen" != "$DIFF_JSON" ] && mv "$gen" "$DIFF_JSON"
fi

{
  echo "OS Type: $OS_TYPE"
  echo "Device: $DEVICE"
  echo "OLD_BUILD: $OLD_BUILD"
  echo "NEW_BUILD: $NEW_BUILD  (OTA-only, no IPSW published)"
  echo "OTA URL: $OTA_URL"
  echo "Old IPSW: $(basename "$OLD_IPSW")"
  echo "Source: reconstructed via ipsw ota patch bxdiff"
} > "$WORKDIR/metadata/info.txt"

echo "[*] done: $DIFF_JSON"
echo "    base=$(du -sh "$WORKDIR/base" 2>/dev/null | cut -f1)" \
     "patched=$(du -sh "$WORKDIR/patched" 2>/dev/null | cut -f1)"
