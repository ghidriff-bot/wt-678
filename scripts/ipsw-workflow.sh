#!/usr/bin/env bash

set -euo pipefail

trap 'echo "[ERROR] Script exited unexpectedly at line $LINENO with status $?"' ERR
trap 'echo; echo "[!] Caught Ctrl-C, aborting..."; exit 130' INT

# ---- CONFIG ----
OS_TYPE="${1:-macOS}"
DEVICE="${2:-Mac14,3}"
OLD_BUILD="${3:-}"
NEW_BUILD="${4:?NEW_BUILD required}"
DIFF_ONLY="${5:-0}"
FORCE_DIFF="${6:-0}"


# ---- REQUIREMENTS ----
for cmd in ipsw jq unzip plutil curl; do
  if ! command -v "$cmd" >/dev/null; then
    echo "[*] Installing $cmd..."
    brew install "$cmd"
  fi
done

# ---- Function: Get Apple Security Update link ----
get_security_update_link() {
  local ipsw_file="$1"
  local label="$2"


  echo "[*] Extracting ProductVersion and ProductBuildVersion from $(basename "$ipsw_file")..."
  local plist_data
  plist_data=$(unzip -p "$ipsw_file" BuildManifest.plist | plutil -extract "BuildIdentities.0.Info" xml1 -o - - 2>/dev/null || true)

  local product_version build_version
  product_version=$(echo "$plist_data" | plutil -p - | grep ProductVersion | head -n1 | awk -F'"' '{print $4}')
  build_version=$(echo "$plist_data" | plutil -p - | grep ProductBuildVersion | head -n1 | awk -F'"' '{print $4}')

  if [ -z "$product_version" ] || [ -z "$build_version" ]; then
    echo "[!] Could not extract version/build from $ipsw_file"
    return
  fi

  echo "[*] $label ProductVersion: $product_version"
  echo "[*] $label ProductBuildVersion: $build_version"

  echo "[*] Searching Apple Security Updates page for '$product_version'..."
  local search_url="https://support.apple.com/en-us/100100"
  local match
  match=$(curl -s "$search_url" | grep -iA1 "$product_version" | head -n2)

  if [ -n "$match" ]; then
    local title url
    title=$(echo "$match" | head -n1 | sed -E 's/.*>([^<]+)<.*/\1/')
    url=$(echo "$match" | grep -Eo 'href="[^"]+"' | head -n1 | cut -d'"' -f2)
    [[ "$url" != http* ]] && url="https://support.apple.com${url}"
    echo "[*] $label Security update page: $title"
    echo "[*] $label URL: $url"
    {
      echo "$label ProductVersion: $product_version"
      echo "$label ProductBuildVersion: $build_version"
      echo "$label Security Update Title: $title"
      echo "$label Security Update URL: $url"
    } >> "$WORKDIR/metadata/info.txt"
  else
    echo "[!] No matching security update found for $product_version"
  fi
}

# ---- INFER OLD_BUILD IF NOT SUPPLIED ----
if [ -z "$OLD_BUILD" ]; then
  echo "[*] OLD_BUILD not supplied — inferring from NEW_BUILD using ipsw dl --urls..."
  
  # Allow this command to fail without killing the script
  if ! urls=$(ipsw dl ipsw --urls --device "$DEVICE"); then
    echo "ERROR: Failed to fetch URL list for $DEVICE" >&2
    exit 1
  fi

  line_num=$(echo "$urls" | grep -n "$NEW_BUILD" | cut -d: -f1 | head -n1 || true)
  if [ -z "$line_num" ]; then
    echo "ERROR: NEW_BUILD $NEW_BUILD not found in URL list" >&2
    exit 1
  fi

  prev_url=$(echo "$urls" | sed -n "$((line_num+1))p" || true)
  if [ -z "$prev_url" ]; then
    echo "ERROR: No previous build found for $NEW_BUILD" >&2
    exit 1
  fi

  OLD_BUILD=$(basename "$prev_url" | cut -d_ -f3)
  echo "[*] Inferred OLD_BUILD: $OLD_BUILD"
fi


# ---- SET WORKDIR AFTER OLD_BUILD IS KNOWN ----
BASE_DIR="${IPSW_DIFFS_DIR:-$(pwd)/ipsw_diffs}"
IPSW_DIR="$BASE_DIR/IPSWs"
SAFE_DEVICE="${DEVICE//,/_}"
WORKDIR="$BASE_DIR/${SAFE_DEVICE}/${OLD_BUILD}-${NEW_BUILD}"

mkdir -p "$IPSW_DIR"
mkdir -p "$WORKDIR"/{diffs,extracted,metadata,changed,extracted_full}

echo "=== Using parameters ==="
echo "OS Type: $OS_TYPE"
echo "Device: $DEVICE"
echo "OLD_BUILD: ${OLD_BUILD:-(will infer)}"
echo "NEW_BUILD: $NEW_BUILD"
echo "Workdir: $WORKDIR"
echo "IPSW dir: $IPSW_DIR"


# ---- DOWNLOAD IPSWs (skip if already present) ----
echo "[*] Checking for OLD IPSW..."
if find "$IPSW_DIR" -type f -name "*${DEVICE}*_${OLD_BUILD}_Restore.ipsw" ! -name "._*" | grep -q .; then
  echo "[*] OLD IPSW for device $DEVICE and build $OLD_BUILD already exists in $IPSW_DIR — skipping download."
else
  ipsw dl appledb --os "$OS_TYPE" --device "$DEVICE" --build "$OLD_BUILD" --output "$IPSW_DIR" --confirm
fi

echo "[*] Checking for NEW IPSW..."
if find "$IPSW_DIR" -type f -name "*${DEVICE}*_${NEW_BUILD}_Restore.ipsw" ! -name "._*" | grep -q .; then
  echo "[*] NEW IPSW for device $DEVICE and build $NEW_BUILD already exists in $IPSW_DIR — skipping download."
else
  ipsw dl appledb --os "$OS_TYPE" --device "$DEVICE" --build "$NEW_BUILD" --output "$IPSW_DIR" --confirm
fi

# ---- CLEANUP AppleDouble FILES ----
find "$WORKDIR" -type f -name "._*" -delete

# ---- LOCATE IPSWs ----
if [[ "$OS_TYPE" == "macOS" ]]; then
  OLD_IPSW=$(find -L "$IPSW_DIR" -type f -name "UniversalMac_*_${OLD_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
  NEW_IPSW=$(find -L "$IPSW_DIR" -type f -name "UniversalMac_*_${NEW_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
elif [[ "$OS_TYPE" == "visionOS" ]]; then
  OLD_IPSW=$(find -L "$IPSW_DIR" -type f -name "Apple_Vision_Pro_*_${OLD_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
  NEW_IPSW=$(find -L "$IPSW_DIR" -type f -name "Apple_Vision_Pro_*_${NEW_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
elif [[ "$OS_TYPE" == "iPod" ]]; then
  OLD_IPSW=$(find -L "$IPSW_DIR" -type f -name "iPodtouch_7_*_${OLD_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
  NEW_IPSW=$(find -L "$IPSW_DIR" -type f -name "iPodtouch_7_*_${NEW_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
else
  OLD_IPSW=$(find -L "$IPSW_DIR" -type f -name "*${DEVICE}*_${OLD_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
  NEW_IPSW=$(find -L "$IPSW_DIR" -type f -name "*${DEVICE}*_${NEW_BUILD}_Restore.ipsw" ! -name "._*" -print -quit)
fi

# ---- VALIDATE IPSWs ----
if [[ -z "$OLD_IPSW" || -z "$NEW_IPSW" ]]; then
  echo "❌ Missing IPSW file(s):"
  [[ -z "$OLD_IPSW" ]] && echo "  - OLD_IPSW not found for build $OLD_BUILD"
  [[ -z "$NEW_IPSW" ]] && echo "  - NEW_IPSW not found for build $NEW_BUILD"
  exit 1
fi

echo "[*] OLD IPSW filename: $(basename "$OLD_IPSW")"
echo "[*] NEW IPSW filename: $(basename "$NEW_IPSW")"

# ---- RUN DIFF (skip if already present) ----
DIFF_JSON="$WORKDIR/diffs/diff_${SAFE_DEVICE}_${OLD_BUILD}_to_${NEW_BUILD}.json"
ZIP_BASE="${DIFF_JSON%.json}.zip"
ZIP_SPLIT_BASE="${ZIP_BASE%.zip}"

echo "DIFF_JSON=$DIFF_JSON"
echo "ZIP_BASE=$ZIP_BASE"
echo "ZIP_SPLIT_BASE=$ZIP_SPLIT_BASE"
find "$WORKDIR/diffs"  -exec ls -lh {} \; || true



# If JSON exists and not forcing, skip
if [ -f "$DIFF_JSON" ] && [ "${FORCE_DIFF}" != "1" ]; then
  echo "[*] Diff JSON already exists: $DIFF_JSON — skipping ipsw diff."

# If monolithic zip exists, try to extract
elif [ -f "$ZIP_BASE" ]; then
  echo "[*] Found full zip: ${ZIP_BASE}"
  unzip -j -o "${ZIP_BASE}" -d "$(dirname "$DIFF_JSON")"
  if [ -f "$DIFF_JSON" ]; then
    echo "[*] Successfully restored $DIFF_JSON — skipping ipsw diff."
  else
    echo "❌ Failed to restore JSON from full zip, regenerating..."
  fi

# If split zip parts exist, reassemble and extract
elif ls "${ZIP_SPLIT_BASE}".z* >/dev/null 2>&1; then
  echo "[*] Found split zip parts: ${ZIP_SPLIT_BASE}.z*"
  zip -s 0 "${ZIP_SPLIT_BASE}.zip" --out "${ZIP_SPLIT_BASE}-full.zip"
  unzip -j -o "${ZIP_SPLIT_BASE}-full.zip" -d "$(dirname "$DIFF_JSON")"
  if [ -f "$DIFF_JSON" ]; then
    echo "[*] Successfully restored $DIFF_JSON — skipping ipsw diff."
  else
    echo "❌ Failed to restore JSON from split zip, regenerating..."
  fi

# If forcing overwrite or nothing exists, generate new diff
else
  if [ -f "$DIFF_JSON" ] && [ "${FORCE_DIFF}" == "1" ]; then
    echo "[*] Overwriting existing diff file as requested."
  fi
  echo "ipsw diff \"$OLD_IPSW\" \"$NEW_IPSW\" --ent --launchd --json --output \"$WORKDIR/diffs\" --title \"Diff ${SAFE_DEVICE} $OLD_BUILD vs $NEW_BUILD\""

  # Persistent parse cache (ipsw >= 3.1): in chain order each IPSW is parsed once.
  DIFF_CACHE_ARGS=()
  if [ -n "${IPSW_DIFF_CACHE_DIR:-}" ]; then
    DIFF_CACHE_ARGS=(--cache-dir "$IPSW_DIFF_CACHE_DIR" --cache-max-size "${IPSW_DIFF_CACHE_MAX:-100GiB}")
  fi

  ipsw diff --block-list "__TEXT.__info_plist" --ignore-build-timestamps \
    ${DIFF_CACHE_ARGS[@]+"${DIFF_CACHE_ARGS[@]}"} \
    "$OLD_IPSW" "$NEW_IPSW" \
    --ent --launchd --json \
    --output "$WORKDIR/diffs" \
    --title "Diff ${SAFE_DEVICE} $OLD_BUILD vs $NEW_BUILD"

  gen_json=$(find "$WORKDIR/diffs" -name "*.json" -print -quit)
  mv "$gen_json" "$DIFF_JSON"

  # Immediately zip+split so the zip exists for next run
  zip -j -s 99m "$ZIP_BASE" "$DIFF_JSON"

fi



if [ "${DIFF_ONLY}" == "1" ]; then
  echo "[*] --diff-only flag is set. Exiting after diff generation."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "diff_path=${DIFF_JSON}" >> "$GITHUB_OUTPUT"
    echo "old_build=${OLD_BUILD}" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi


# ---- PARSE CHANGED BINARIES ----
# Only consider binaries with code changes: `ipsw diff` prints a `-`/`+` pair
# for a section whose SIZE changed, so "-  __TEXT.__text:" means the code moved.
# (Newer ipsw also emits a "Sections with Same Size but Changed Content" block.
# Measured on iPhone13,3 24A446->24B119 that block never lists __TEXT.__text —
# 146 dylibs and 1776 machos carry it, none for code — so it adds nothing here.
# Worth re-checking if that ever changes: it would be the precise signal for a
# same-size instruction patch.)
#
# dylibs and kexts are keyed flat under .updated/.new/.removed. machos are NOT:
# newer ipsw nests them per volume — .machos.filesystem.updated, plus AppOS,
# SystemOS and (macOS 26+) ExclaveOS. Reading .machos.updated therefore yields
# NOTHING on every modern diff, machos.txt comes out empty, and no standalone
# executable is ever extracted. Measured across 7 pairs on this device set:
# 7568 changed Mach-Os silently dropped (1821 in 24A446->24B119 alone).
# So walk both shapes and dedupe: flat for older diffs, one level down per
# volume for current ones.
jq -r '.kexts.updated // {} | to_entries[] | select(.value | contains("-  __TEXT_EXEC.__text")) | .key' "$DIFF_JSON" > "$WORKDIR/kexts.txt" || true
jq -r '.dylibs.updated // {} | to_entries[] | select(.value | contains("-  __TEXT.__text")) | .key' "$DIFF_JSON" > "$WORKDIR/dylibs.txt" || true
jq -r '
  (.machos // {}) as $m
  | [ ($m.updated // {} | to_entries[]),
      ($m | to_entries[] | select(.value | type == "object") | .value.updated // {} | to_entries[]) ]
  | map(select((.value | type == "string") and (.value | contains("-  __TEXT.__text"))) | .key)
  | unique | .[]
' "$DIFF_JSON" > "$WORKDIR/machos.txt" || true
# ---- EXTRACTION ----
# 1. Build combined MACHO regex (if any)
if [[ -s "$WORKDIR/machos.txt" ]]; then
    echo "[*] Escaping regex metacharacters in machos.txt..."
    # grep -v '^[[:space:]]*$' "$WORKDIR/machos.txt" \
    # | nl -ba \
    # | sed -E 'h; s/[.^$*+?(){}|\\]/\\&/g; G; s/\n/ -> /'
    # echo

  echo "[*] Building MACHO_REGEX..."
  MACHO_REGEX=$(
    grep -v '^[[:space:]]*$' "$WORKDIR/machos.txt" \
    | sed -E 's/[.^$*+?(){}|\\]/\\&/g' \
    | paste -sd'|' -
  )
else
  echo "[WARN] machos.txt is empty — MACHO_REGEX will be unset"
  MACHO_REGEX=""
fi



echo "[INFO] Final MACHO_REGEX: (first 50 chars)"
#printf '%.500s\n' "$MACHO_REGEX"


# 2. Decide which components to extract
EXTRACT_KERNEL_FLAG=""
EXTRACT_DYLD_FLAG=""
EXTRACT_FILES_FLAG=""

[ -s "$WORKDIR/kexts.txt" ] && EXTRACT_KERNEL_FLAG="--kernel"
[ -s "$WORKDIR/dylibs.txt" ] && EXTRACT_DYLD_FLAG="--dyld"
[ -n "$MACHO_REGEX" ] && EXTRACT_FILES_FLAG="--files"

# 3. Extract all needed components in one pass per IPSW (skip if already extracted)
extract_all() {
  local side="$1"
  local ipsw_file="$2"
  local full_dir="$WORKDIR/extracted_full/$side"

  echo "[*] Preparing extraction for $side IPSW..."
  mkdir -p "$full_dir"

  # Function to extract a single arch safely
  extract_arch() {
    local arch="$1"
    local arch_dir="$full_dir/$arch"

    # If we have a MACHO regex, include it
    local pattern_args=()
    if [ -n "$MACHO_REGEX" ] && [ -n "$EXTRACT_FILES_FLAG" ]; then
      pattern_args=(--pattern "$MACHO_REGEX")
    fi

    # Only include --dyld-arch if --dyld is active
    local dyld_arch_args=()
    if [ -n "$EXTRACT_DYLD_FLAG" ]; then
      dyld_arch_args=(--dyld-arch "$arch")
    fi

    # With all three lists empty there is nothing to ask for, and `ipsw extract`
    # with no component flag exits non-zero ("must specify at least one flag").
    # That used to abort the whole pair: 23G83->23G90 (26.6.1 -> 26.6.2) changed
    # no code at all and died at the archive step on a missing changed/ dir.
    # A pair with nothing to extract is a legitimate result, not a failure.
    if [ -z "$EXTRACT_KERNEL_FLAG$EXTRACT_DYLD_FLAG$EXTRACT_FILES_FLAG" ]; then
      echo "    (no changed components to extract for $arch — skipping)"
      return 0
    fi

    echo "    → Extracting $arch dyld..."
    mkdir -p "$arch_dir"
    echo "[*] Running extract for arch: $arch"

    # Run the actual command
    ipsw extract $EXTRACT_KERNEL_FLAG $EXTRACT_DYLD_FLAG $EXTRACT_FILES_FLAG \
      ${dyld_arch_args[@]+"${dyld_arch_args[@]}"} \
      ${pattern_args[@]+"${pattern_args[@]}"} \
      -o "$arch_dir" "$ipsw_file" || echo "    ($arch not found)"
  }


  # Always try arm64e first, then x86_64
  extract_arch arm64e
  extract_arch x86_64

  # Optional: merge unique files into top-level dir for unified browsing
  # rsync -a --ignore-existing "$full_dir"/arm64e/ "$full_dir"/
  # rsync -a --ignore-existing "$full_dir"/x86_64/ "$full_dir"/
}



# 3.5-6. Process each side sequentially to minimize disk usage
# This function extracts and processes one IPSW side at a time
process_side() {
  local side="$1"
  local ipsw_file="$2"
  
  echo ""
  echo "=========================================="
  echo "[*] Processing $side IPSW: $(basename "$ipsw_file")"
  echo "=========================================="
  
  # Extract IPSW
  extract_all "$side" "$ipsw_file"
  
  # Extract KEXTs from kernelcache if needed
  if [ -s "$WORKDIR/kexts.txt" ]; then
    echo "[*] Extracting KEXTs from kernelcache for $side..."
    for arch in arm64e x86_64; do
      KC_DIR="$WORKDIR/extracted_full/$side/$arch"
      KC=$(find "$KC_DIR" -maxdepth 2 -name 'kernelcache.release.*' -print -quit)

      echo
      if [ -n "$KC" ]; then
        OUT_DIR="$KC_DIR/kernelcache_kexts"
        if [ ! -d "$OUT_DIR" ] || [ -z "$(find "$OUT_DIR" -type f -print -quit)" ]; then
          echo "  → Extracting KEXTs from $(basename "$KC")..."
          mkdir -p "$OUT_DIR"
          ipsw kernel extract "$KC" --all --output "$OUT_DIR"
        else
          echo "  → KEXTs already extracted for $side/$arch — skipping."
        fi
      else
        echo "  [ERROR] No kernelcache found for $side/$arch — aborting."
        exit 1
      fi
    done
  fi

  # Copy changed KEXTs for this side
  if [ -s "$WORKDIR/kexts.txt" ]; then
    echo "[*] Copying changed KEXTs for $side..."
    while read -r kext; do
      [ -n "$kext" ] || continue
      src=$(find "$WORKDIR/extracted_full/$side" -type f -path "*/kernelcache_kexts/$kext" -print -quit)
      if [ -f "$src" ]; then
        mkdir -p "$WORKDIR/changed/$side/kexts/$(dirname "$kext")"
        cp "$src" "$WORKDIR/changed/$side/kexts/$kext"
      fi
    done < "$WORKDIR/kexts.txt"
  fi

  # Process dyld_shared_cache for this side
  # `ipsw dyld extract` writes every dylib FLAT into --output by basename only.
  # 166 of Mac14,12's 3452 changed dylibs share a basename, silently overwriting
  # in a flat extract. So batch into a staging dir and move results back under
  # their real cache path. Also batches ~200 dylibs per call (2x faster, reuses
  # symbol cache) grouped by basename-occurrence to avoid collisions.
  #
  # The move back MUST use the dylib's full cache path, not its basename:
  # mkdir'ing the tree and then writing to "$DEST_DIR/$base" re-flattens the
  # output and the empty-dir sweep below erases the evidence. Measured on
  # iPhone13,3 24A446->24B119: 2232 files archived for 2276 changed dylibs,
  # 44 lost across 43 colliding basenames. The full install path is also the
  # key downstream consumers join on, so flattening breaks them twice.
  #
  # `--objc` is cheap (~1.6KB/dylib) and worth it. `--stubs` is NOT: it adds a
  # ~51MB floor to every dylib (libobjc.A.dylib 3.5MB -> 135MB) because each
  # one gets a copy of the cache-wide stub island symbol table. Measured on
  # CoreFoundation from one DSC, with vs without: 11MB -> 62MB and symtab
  # 15,615 -> 932,285 entries, for identical function-name coverage (7865
  # function starts, 7844 named, 99.7% either way). The extra ~917k symbols are
  # cache-wide stub island names, not names for this binary. It buys nothing,
  # cost a 174GB workdir here, and makes symbol counts incomparable across
  # builds, so it stays off.
  if [ -s "$WORKDIR/dylibs.txt" ]; then
    echo "[*] Processing dyld_shared_cache for $side..."
    for arch in arm64e x86_64; do
      echo "  [*] Processing $arch..."
      DSC=""
      SEARCH_DIR="$WORKDIR/extracted_full/$side"

      if [ -d "$SEARCH_DIR" ]; then
        DSC=$(find "$SEARCH_DIR" -name "dyld_shared_cache_$arch" -print -quit 2>/dev/null || true)
      fi

      if [ -z "$DSC" ]; then
        echo "    [WARN] No dyld_shared_cache for $arch found for $side — skipping." >&2
        continue
      fi

      if [ -n "$DSC" ]; then
        DEST_DIR="$WORKDIR/changed/$side/dylibs/$arch"
        mkdir -p "$DEST_DIR"

        # Tag each dylib with how many times its basename has been seen, so group 1
        # holds all first occurrences, group 2 the duplicates, and so on. Every
        # group is basename-unique for batching without collisions.
        TMP="$(mktemp -d "${TMPDIR:-/tmp}/dylibs-$side-$arch-XXXXXX")"
        awk -F/ '{ n[$NF]++; print n[$NF]"\t"$0 }' "$WORKDIR/dylibs.txt" > "$TMP/indexed"
        MAXGRP="$(cut -f1 "$TMP/indexed" | sort -n | tail -1)"
        [ -n "$MAXGRP" ] || MAXGRP=0

        echo "[*] Extracting $(wc -l < "$WORKDIR/dylibs.txt") changed dylibs for side '$side' and arch '$arch' ($MAXGRP basename groups)..."

        for ((GRP = 1; GRP <= MAXGRP; GRP++)); do
          # Extract group GRP in batches of ~200 per call
          awk -F'\t' -v g="$GRP" '$1 == g { print $2 }' "$TMP/indexed" > "$TMP/group"
          N=0
          : > "$TMP/batch"

          while read -r dylib; do
            [ -n "$dylib" ] || continue
            echo "$dylib" >> "$TMP/batch"
            N=$((N + 1))

            if [ "$N" -ge 200 ]; then
              # Flush this batch
              STAGE="$TMP/stage"
              rm -rf "$STAGE"
              mkdir -p "$STAGE"

              tr '\n' '\0' < "$TMP/batch" \
                | xargs -0 ipsw dyld extract "$DSC" --objc --output "$STAGE" \
                >/dev/null 2>&1 || true

              # Move results back under real cache path
              while read -r dylib; do
                [ -n "$dylib" ] || continue
                base="$(basename "$dylib")"
                if [ ! -f "$STAGE/$base" ]; then
                  ipsw dyld extract "$DSC" "$dylib" --objc --output "$STAGE" \
                    >/dev/null 2>&1 || true
                fi
                if [ -f "$STAGE/$base" ]; then
                  mkdir -p "$DEST_DIR/$(dirname "$dylib")"
                  mv -f "$STAGE/$base" "$DEST_DIR/$dylib"
                else
                  echo "    [WARN] Failed to extract $dylib"
                fi
              done < "$TMP/batch"

              rm -rf "$STAGE"
              : > "$TMP/batch"
              N=0
            fi
          done < "$TMP/group"

          # Flush any remaining dylibs in the batch
          if [ -s "$TMP/batch" ]; then
            STAGE="$TMP/stage"
            rm -rf "$STAGE"
            mkdir -p "$STAGE"

            tr '\n' '\0' < "$TMP/batch" \
              | xargs -0 ipsw dyld extract "$DSC" --objc --output "$STAGE" \
              >/dev/null 2>&1 || true

            while read -r dylib; do
              [ -n "$dylib" ] || continue
              base="$(basename "$dylib")"
              if [ ! -f "$STAGE/$base" ]; then
                ipsw dyld extract "$DSC" "$dylib" --objc --output "$STAGE" \
                  >/dev/null 2>&1 || true
              fi
              if [ -f "$STAGE/$base" ]; then
                mkdir -p "$DEST_DIR/$(dirname "$dylib")"
                mv -f "$STAGE/$base" "$DEST_DIR/$dylib"
              else
                echo "    [WARN] Failed to extract $dylib"
              fi
            done < "$TMP/batch"

            rm -rf "$STAGE"
          fi
        done

        rm -rf "$TMP"
      fi
    done
  fi

  # Copy changed MACHOs for this side
  if [ -s "$WORKDIR/machos.txt" ]; then
    echo "[*] Copying changed MACHOs for $side..."
    while read -r macho; do
      [ -n "$macho" ] || continue
      found=0

      for arch in arm64e x86_64; do
        src=$(resolve_macho_path "$side" "$arch" "$macho") || continue

        dest="$WORKDIR/changed/$side/machos/$arch/$macho"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "$side:$arch:$macho -> $src" >> "$WORKDIR/metadata/macho_copy_map.txt"
        found=1
        break
      done

      [ "$found" -eq 0 ] && echo "[WARN] $macho not found for $side in any arch dir"
    done < "$WORKDIR/machos.txt"
  fi
  
  # Cleanup: Remove extracted_full for this side to free disk space
  echo ""
  echo "[*] Cleaning up extracted files for $side to free disk space..."
  rm -rf "$WORKDIR/extracted_full/$side"
  echo "[*] $side processing complete."
}

# MACHO path resolution helper
resolve_macho_path() {
  local side="$1" arch="$2" macho="$3"
  local src="" try="" build_dir=""
  local base_dir="$WORKDIR/extracted_full/$side"

  # Try direct arch path first
  try="$base_dir/$arch/$macho"
  [ -f "$try" ] && echo "$try" && return 0

  # Try arch-layered build dirs (e.g. arm64e/25A354__MacOS/)
  for build_dir in "$base_dir/$arch"/*; do
    try="$build_dir/$macho"
    [ -f "$try" ] && echo "$try" && return 0
  done

  # Try flat build dirs (e.g. 23A341__iPhone13,2_3/)
  for build_dir in "$base_dir"/*; do
    try="$build_dir/$arch/$macho"
    [ -f "$try" ] && echo "$try" && return 0

    try="$build_dir/$macho"
    [ -f "$try" ] && echo "$try" && return 0
  done

  return 1
}

# Process old IPSW first, then new
process_side "old" "$OLD_IPSW"
process_side "new" "$NEW_IPSW"



# ---- CLEANUP AppleDouble files from changed output ----
echo "[*] Cleaning up AppleDouble files from changed output..."
find "$WORKDIR/changed" -type f -name "._*" -delete
find "$WORKDIR/changed" -mindepth 1 -type d -empty -delete

# ---- SPLIT FAT BINARIES ----
echo "[*] Scanning for fat/universal binaries in changed output..."
while IFS= read -r bin; do
  if ipsw lipo -info "$bin" 2>/dev/null | grep -q 'architecture'; then
    echo "[*] Found fat binary: $bin"
    base_dir=$(dirname "$bin")
    base_name=$(basename "$bin")

    out_x64="$base_dir/${base_name}.x86_64"
    out_arm="$base_dir/${base_name}.arm64"

    if ipsw lipo -info "$bin" | grep -q 'x86_64'; then
      ipsw lipo "$bin" -thin x86_64 -output "$out_x64"
      echo "    → Wrote $out_x64"
    fi
    if ipsw lipo -info "$bin" | grep -q 'arm64'; then
      ipsw lipo "$bin" -thin arm64 -output "$out_arm"
      echo "    → Wrote $out_arm"
    fi
  fi
done < <(find "$WORKDIR/changed" -type f ! -name "._*" -perm -111)


# ---- APPEND VERSION + ARCH INFO TO BINARIES ----
echo "[*] Appending version and arch info to binaries and dylibs..."

# Set to 1 if you want 0.13(.0) -> 013 style compaction
COMPACT_ZERO_PREFIX="${COMPACT_ZERO_PREFIX:-1}"

extract_version() {
  tr -d '\r' \
  | grep 'LC_SOURCE_VERSION' \
  | sed -E 's/.*LC_SOURCE_VERSION[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/' \
  | head -n1
}

extract_arch() {
  awk '1' 2>/dev/null \
  | tr -d '\r' \
  | grep -E '^CPU[[:space:]]*=' \
  | awk '{print tolower($3)}' \
  | sed 's/[,[:space:]]*$//' \
  | head -n1
}


already_renamed() {
  # Args: filename base, build, version, arch
  # Return 0 if name already has our suffix, else 1
  case "$1" in
    *-"${SAFE_DEVICE}"_"$2"_"$3"_"$4") return 0 ;;
    *) return 1 ;;
  esac
}

rename_with_version() {
  local side="$1"   # "old" or "new"
  local build="$2"

  find "$WORKDIR/changed/$side" -type f ! -name "._*" | while read -r bin; do
    [ -f "$bin" ] || continue

    local dir base info version arch newname
    dir=$(dirname "$bin")
    base=$(basename "$bin")

    info=$(ipsw macho info "$bin" 2>/dev/null || true)
    version=$(printf '%s\n' "$info" | extract_version)
    arch=$(printf '%s\n' "$info" | extract_arch)

    if [ -z "$version" ] || [ -z "$arch" ]; then
      echo "[SKIP] Missing version or arch for: $base"
      continue
    fi

    version=$(printf '%s' "$version" | sed 's/[[:space:]]\+/_/g; s/[[:punct:]]$//')
    arch=$(printf '%s' "$arch" | sed 's/[[:punct:]]$//')

    if already_renamed "$base" "$build" "$version" "$arch"; then
      echo "[SKIP] Already renamed: $base"
      continue
    fi

    newname="${base}-${version}_${arch}-${SAFE_DEVICE}_${build}"
    mv "$bin" "$dir/$newname"

    mkdir -p "$WORKDIR/metadata"
    echo "$side: $base -> $newname" >> "$WORKDIR/metadata/versions.txt"
  done
}

# TODO: optimise, this step kills builds
# rename_with_version old "$OLD_BUILD"
# rename_with_version new "$NEW_BUILD"


# ---- ClEANUP unmounted disk images ----
# This seems to happen in the course of mounting everything
rm *.aea || true
rm *.dmg || true

# ---- CLEANUP AppleDouble files from changed output ----
echo "[*] Cleaning up AppleDouble files from changed output..."
find "$WORKDIR/changed" -type f -name "._*" -delete
find "$WORKDIR/changed" -mindepth 1 -type d -empty -delete

# ---- METADATA ----
{
  echo "OS Type: $OS_TYPE"
  echo "Device: $DEVICE"
  echo "OLD_BUILD: $OLD_BUILD"
  echo "NEW_BUILD: $NEW_BUILD"
  echo "Workdir: $WORKDIR"
  echo "Old IPSW Filename: $(basename "$OLD_IPSW")"
  echo "New IPSW Filename: $(basename "$NEW_IPSW")"
  echo "Old IPSW URL: $(ipsw dl appledb --os "$OS_TYPE" --device "$DEVICE" --build "$OLD_BUILD" --urls)"
  echo "New IPSW URL: $(ipsw dl appledb --os "$OS_TYPE" --device "$DEVICE" --build "$NEW_BUILD" --urls)"
  echo
} >> "$WORKDIR/metadata/info.txt"

# ---- ARCHIVE ----
echo "[*] Archiving results..."
ARTIFACT_NAME="diff-${SAFE_DEVICE}-${OLD_BUILD}-${NEW_BUILD}"
ARTIFACT_PATH="${ARTIFACT_NAME}.zip"

echo "[*] Creating archive: $ARTIFACT_PATH"
(
  cd "$BASE_DIR" && \
  rm -f "../$ARTIFACT_NAME".zip "../$ARTIFACT_NAME".z* 2>/dev/null || true
  zip -r -s 1900m "../$ARTIFACT_PATH" "${SAFE_DEVICE}/${OLD_BUILD}-${NEW_BUILD}" \
    -x "${SAFE_DEVICE}/${OLD_BUILD}-${NEW_BUILD}/extracted*" \
    -x "${SAFE_DEVICE}/${OLD_BUILD}-${NEW_BUILD}/IPSW*"
)

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "artifact_path=${ARTIFACT_PATH}" >> "$GITHUB_OUTPUT"
  echo "artifact_name=${ARTIFACT_NAME}" >> "$GITHUB_OUTPUT"
fi
