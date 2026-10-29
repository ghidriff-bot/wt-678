#!/usr/bin/env bash
#
# Build a Ghidra-importable symbol map for a kernelcache.
#
#   scripts/kernel-symbols.sh <KERNELCACHE> <OUTPUT_DIR> [KEXTS_TXT]
#
# Emits into OUTPUT_DIR:
#   <name>.symbols.json   addr -> symbol map (ipsw --lookup can read it back)
#   <name>.syms           flat "0xADDR name" lines, one per symbol
#   <name>.coverage.txt   how many function starts ended up named
#
# SCOPE: one run symbolicates the WHOLE kernelcache — it cannot be narrowed to
# a subset of binaries. What IS scopable is which signature files get fetched:
# xnu.json covers com.apple.kernel, and each other kext needs its own
# kexts/<Name>.json. Pass KEXTS_TXT (the workflow's changed-kext list) to fetch
# only those; omit it to fetch the whole set (~20MB, 224 files for Darwin 24.4).
# Signature filename = the kext id's last dot-component
# (com.apple.driver.AppleAVE2 -> AppleAVE2.json). ~67% of changed kexts have
# one published; the rest simply stay unsymbolicated.
#
# MUST be given the FULL fileset kernelcache, not a kext extracted out of one.
# Signature anchors are cstrings resolved through cross-references, and that
# resolution needs the whole fileset: run against an extracted `com.apple.kernel`
# and every signature misses (measured: 6335 signatures, 0 matches) even though
# 134 of 200 sampled anchor strings are present in the file. So this has to run
# BEFORE the extracted_full cleanup deletes the kernelcache.
#
# Signatures come from github.com/blacktop/symbolicator, keyed by Darwin
# major.minor (macOS 26.6.x and iOS 26.x are both Darwin 25.6). They are NOT in
# the IPSW. Without them you get only the built-in syscall/trap/C++ discovery,
# which lands almost entirely off function starts and is not safe to import.

set -euo pipefail

KC="${1:?kernelcache path required}"
OUT_DIR="${2:?output dir required}"
KEXTS_TXT="${3:-}"

SIG_CACHE="${IPSW_SIG_CACHE_DIR:-${TMPDIR:-/tmp}/ipsw-signatures}"
SIG_BASE_URL="https://raw.githubusercontent.com/blacktop/symbolicator/main/kernel"

[ -f "$KC" ] || { echo "[ERROR] no such file: $KC" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# ---- Refuse a non-fileset input rather than emitting a near-empty map ----
MH_TYPE="$(ipsw macho info "$KC" 2>/dev/null | awk -F'= ' '/^Type/{print $2; exit}')"
if [ "$MH_TYPE" != "FILESET" ]; then
  echo "[ERROR] $(basename "$KC") is '$MH_TYPE', not FILESET." >&2
  echo "        Signature matching needs the full kernelcache; an extracted" >&2
  echo "        kext matches 0 signatures. Point this at kernelcache.release.*" >&2
  exit 1
fi

# ---- Pick the signature set by Darwin version ----
DARWIN="$(ipsw kernel version --json "$KC" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["kernel"]["darwin"])' 2>/dev/null || true)"
if [ -z "$DARWIN" ]; then
  echo "[ERROR] could not read Darwin version from $KC" >&2
  exit 1
fi
SIG_VER="${DARWIN%.*}"   # 24.4.0 -> 24.4
echo "[*] $(basename "$KC"): Darwin $DARWIN -> signatures $SIG_VER"

SIG_DIR="$SIG_CACHE/$SIG_VER"
SIG_JSON="$SIG_DIR/xnu.json"
if [ ! -s "$SIG_JSON" ]; then
  echo "[*] fetching kernel/$SIG_VER/xnu.json ..."
  mkdir -p "$SIG_DIR"
  if ! curl -fsSL "$SIG_BASE_URL/$SIG_VER/xnu.json" -o "$SIG_JSON.part"; then
    rm -f "$SIG_JSON.part"
    echo "[WARN] no signatures published for Darwin $SIG_VER." >&2
    echo "       Continuing unsymbolicated — built-in discovery only." >&2
  else
    mv "$SIG_JSON.part" "$SIG_JSON"
  fi
else
  echo "[*] using cached signatures: $SIG_JSON"
fi

# ---- Per-kext signatures: only the kexts this pair actually changed ----
# Fetched individually rather than cloning the repo: a changed-kext list is
# typically 16 (macOS) to 234 (iOS) entries, and misses are expected, so a 404
# must not fail the run.
if [ -n "$KEXTS_TXT" ] && [ -s "$KEXTS_TXT" ]; then
  mkdir -p "$SIG_DIR/kexts"
  want=0; got=0; absent=0
  while read -r kext; do
    [ -n "$kext" ] || continue
    want=$((want + 1))
    name="${kext##*.}"
    dest="$SIG_DIR/kexts/$name.json"
    if [ -s "$dest" ]; then got=$((got + 1)); continue; fi
    # A sentinel for known-absent signatures, so re-runs don't re-request them.
    if [ -f "$dest.absent" ]; then absent=$((absent + 1)); continue; fi
    if curl -fsSL "$SIG_BASE_URL/$SIG_VER/kexts/$name.json" -o "$dest.part" 2>/dev/null; then
      mv "$dest.part" "$dest"; got=$((got + 1))
    else
      rm -f "$dest.part"; : > "$dest.absent"; absent=$((absent + 1))
    fi
  done < "$KEXTS_TXT"
  echo "[*] kext signatures: $got/$want available ($absent not published)"
fi

SIG_ARGS=()
[ -s "$SIG_JSON" ] && SIG_ARGS=(--signatures "$SIG_CACHE")

# ---- Symbolicate: JSON for lookups, flat for importers ----
# --json and --flat are separate runs; each writes one format.
echo "[*] symbolicating (json)..."
ipsw kernel symbolicate ${SIG_ARGS[@]+"${SIG_ARGS[@]}"} --json \
  --output "$OUT_DIR" "$KC" 2>&1 | grep -E 'STATS|matched|No signatures' || true

echo "[*] symbolicating (flat)..."
ipsw kernel symbolicate ${SIG_ARGS[@]+"${SIG_ARGS[@]}"} --flat \
  --output "$OUT_DIR" "$KC" >/dev/null 2>&1 || true

BASE="$(basename "$KC")"
MAP="$OUT_DIR/$BASE.symbols.json"
[ -f "$MAP" ] || { echo "[ERROR] no symbol map produced" >&2; exit 1; }

# ---- Coverage: only count names that land exactly on a function start ----
# A name at a non-start address is worse than no name: it labels a basic block
# or an epilogue. Built-in (signature-less) output is mostly of that kind, so
# report the honest number rather than the raw map size.
echo "[*] measuring coverage against com.apple.kernel function starts..."
KEXT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kxsym-XXXXXX")"
trap 'rm -rf "$KEXT_TMP"' EXIT
ipsw kernel extract "$KC" com.apple.kernel --output "$KEXT_TMP" >/dev/null 2>&1 || true
KEXT="$KEXT_TMP/com.apple.kernel"

if [ -f "$KEXT" ]; then
  MAP="$MAP" KEXT="$KEXT" BASE="$BASE" DARWIN="$DARWIN" SIG_VER="$SIG_VER" \
  python3 - > "$OUT_DIR/$BASE.coverage.txt" <<'PY'
import json, os, re, subprocess
mp, kext = os.environ['MAP'], os.environ['KEXT']
m = {int(k): v for k, v in json.load(open(mp)).items()}

nm = subprocess.run(['nm', kext], capture_output=True, text=True).stdout
symtab = set()
for line in nm.splitlines():
    p = line.split(maxsplit=2)
    if len(p) >= 3 and p[1] in ('T', 't', 'S', 'D'):
        try: symtab.add(int(p[0], 16))
        except ValueError: pass

out = subprocess.run(['ipsw', 'macho', 'info', '--starts', kext],
                     capture_output=True, text=True).stdout
starts = {int(x, 16) for x in re.findall(r'^0x([0-9a-f]+)', out, re.M)}

new = {a: v for a, v in m.items() if a not in symtab}
at_start = {a: v for a, v in new.items() if a in starts}
unnamed_before = len(starts - symtab)
unnamed_after = unnamed_before - len(at_start)

print(f"kernelcache      : {os.environ['BASE']}")
print(f"darwin           : {os.environ['DARWIN']}  (signatures {os.environ['SIG_VER']})")
print(f"function starts  : {len(starts)}")
print(f"symtab-named     : {len(starts & symtab)}")
print(f"map entries      : {len(m)}")
print(f"new at func start: {len(at_start)}")
print(f"unnamed before   : {unnamed_before}")
print(f"unnamed after    : {unnamed_after}")
if unnamed_before:
    print(f"gap closed       : {100*len(at_start)/unnamed_before:.1f}%")
# Entries that are NOT at a function start: data symbols (vtables, tables) plus
# any mid-function noise. Flagged so a consumer can filter if it only wants
# function labels.
print(f"not-at-start     : {len(new) - len(at_start)}  (data syms + mid-function)")
PY
  cat "$OUT_DIR/$BASE.coverage.txt"
else
  echo "[WARN] could not extract com.apple.kernel — skipping coverage report" >&2
fi

echo "[*] wrote:"
ls -1 "$OUT_DIR/$BASE".* 2>/dev/null | sed 's/^/      /'
