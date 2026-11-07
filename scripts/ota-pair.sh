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
#   1. pull image_patches/cryptex-system-arm64e out of the OTA  (RIDIFF10)
#   2. ipsw ota patch rsr --cryptex <RIDIFF>                    (reconstruct)
#   3. mount the resulting DMG and diff its dyld_shared_cache
#
# The patch is RIDIFF10, not BXDIFF50, so `ipsw ota patch bxdiff` cannot read
# it ("patch has invalid BXDIFF50 magic"); its finder also only scans
# AssetData/payloadv2/(patches|basesystem_patches)/*.dmg, which is why it
# reported "no BXDIFF patches found" against image_patches/.
#
# RIDIFF10 turns out to be SELF-CONTAINED rather than a true delta: running
# the reconstruction in an empty directory with no base DMG present yields a
# byte-identical 4.9GB image (same sha256). So the old build is not needed as
# a patch base at all — `--cryptex` takes neither --input nor --output and
# simply writes <patch>.dmg beside itself.
#
# Verified on 23H128: 1.3GB patch -> 4.9GB DMG whose SystemVersion.plist reads
# ProductVersion 26.7.2 / ProductBuildVersion 23H128, carrying a valid
# dyld_shared_cache_arm64e with 4306 images.
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

# ---- 2. Reconstruct the NEW system cryptex from the OTA ----
# The system content is a single RIDIFF10 blob under image_patches/. It is
# self-contained, so no base image and no old IPSW are required.
CRYPTEX_REL="AssetData/payloadv2/image_patches/cryptex-system-arm64e"
CX_DIR="$WORKDIR/cryptex"
mkdir -p "$CX_DIR"

if [ -z "$(find "$CX_DIR" -name 'cryptex-system-*' ! -name '*.dmg' -print -quit 2>/dev/null)" ]; then
  echo "[*] extracting $CRYPTEX_REL from OTA..."
  ipsw ota extract "$OTA" "$CRYPTEX_REL" --output "$CX_DIR"
fi

PATCH="$(find "$CX_DIR" -name 'cryptex-system-*' ! -name '*.dmg' -print -quit 2>/dev/null)"
[ -n "$PATCH" ] || { echo "[ERROR] no system cryptex in $OTA" >&2; exit 1; }

# Reject anything that is not RIDIFF10 rather than silently producing nothing.
MAGIC="$(head -c 8 "$PATCH" 2>/dev/null)"
if [ "$MAGIC" != "RIDIFF10" ]; then
  echo "[ERROR] unexpected cryptex patch magic '$MAGIC' (expected RIDIFF10)." >&2
  echo "        BXDIFF50 blobs go through 'ipsw ota patch bxdiff' instead." >&2
  exit 1
fi

NEW_DMG="$PATCH.dmg"
if [ -s "$NEW_DMG" ]; then
  echo "[*] reconstructed image already present ($(du -h "$NEW_DMG" | cut -f1))"
else
  echo "[*] reconstructing system image from RIDIFF (no base needed)..."
  # --cryptex accepts neither --input nor --output; it writes <patch>.dmg
  # beside the patch, so run from that directory.
  ( cd "$(dirname "$PATCH")" && ipsw ota patch rsr --cryptex "./$(basename "$PATCH")" )
fi
[ -s "$NEW_DMG" ] || { echo "[ERROR] reconstruction produced no image" >&2; exit 1; }

echo "[*] reconstructed: $NEW_DMG ($(du -h "$NEW_DMG" | cut -f1))"

# ---- 3. Confirm the image really is the build we asked for ----
# A patch that applied cleanly but produced the wrong build would otherwise
# be diffed as if it were correct.
# The mountpoint must NOT live on the Vault: that volume is mounted
# `noowners`, and hdiutil refuses to attach there ("Permission denied") even
# though the image itself is readable. Use a temp dir on the boot volume.
MNT="$(mktemp -d "${TMPDIR:-/tmp}/otapair-mnt-XXXXXX")"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
mounted=0
if hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$NEW_DMG" >/dev/null 2>&1; then
  mounted=1
  GOT_BUILD="$(plutil -extract ProductBuildVersion raw \
    "$MNT/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)"
  GOT_VER="$(plutil -extract ProductVersion raw \
    "$MNT/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)"
  echo "[*] image reports: $GOT_VER ($GOT_BUILD)"
  if [ -n "$GOT_BUILD" ] && [ "$GOT_BUILD" != "$NEW_BUILD" ]; then
    echo "[ERROR] image is $GOT_BUILD, expected $NEW_BUILD" >&2
    hdiutil detach "$MNT" -quiet 2>/dev/null || true
    exit 1
  fi
  {
    echo "OS Type: $OS_TYPE"
    echo "Device: $DEVICE"
    echo "OLD_BUILD: $OLD_BUILD"
    echo "NEW_BUILD: $NEW_BUILD  (OTA-only, no IPSW published)"
    echo "OTA URL: $OTA_URL"
    echo "Reconstructed: $GOT_VER ($GOT_BUILD) from RIDIFF10 cryptex"
    echo "Source: ipsw ota patch rsr --cryptex (self-contained, no base IPSW)"
  } > "$WORKDIR/metadata/info.txt"
  hdiutil detach "$MNT" -quiet 2>/dev/null || true
else
  echo "[WARN] could not mount to verify build identity" >&2
fi

echo
echo "[*] system image for $NEW_BUILD is ready:"
echo "      $NEW_DMG"
echo "    Its dyld_shared_cache lives at"
echo "      <mount>/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
echo "    Diff it against the OLD build's cache to produce a normal pair."
