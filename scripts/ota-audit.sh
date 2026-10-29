#!/usr/bin/env bash
#
# Audit Apple's OTA catalog for unexpected archive structure — cheaply.
#
#   scripts/ota-audit.sh [--platform ios|macos|...] [--device <dev>] [--pull] [--all]
#
# An OTA zip is range-readable, so the complete file listing can be had from
# the archive's central directory alone: ~300KB and ~2s per OTA instead of
# downloading 8-17GB. That makes it affordable to list EVERY published OTA and
# diff its top-level layout against what Apple normally ships.
#
# The point is to catch the day Apple ships something that isn't normally
# there — the canonical example being a `Symbols/` tree (a symbol-bearing
# dyld_shared_cache) left attached to a build cut from an internal branch.
# Measured against the full iOS catalog (545 archives / 2,394,349 entries,
# iOS 5.1.1 -> 27.2) the only top-level AssetData/* dirs that ever appear are
# boot, payload and payloadv2. Anything else is new information.
#
# State lives in $OTA_AUDIT_DIR (default ipsw_diffs/ota-audit):
#   seen.tsv          build+url already reported, so re-runs stay quiet
#   listings/<id>.txt full file listing of every OTA scanned (kept; small)
#   anomalies.tsv     append-only log of every finding
#
# With --pull, an anomalous OTA is downloaded for real analysis. That is a
# 7-17GB fetch, so it is bounded: see PULL SAFETY below.

set -euo pipefail

PLATFORM="ios"
DEVICE=""
PULL=0
SCAN_ALL=0
JOBS="${OTA_AUDIT_JOBS:-10}"

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:?}"; shift 2 ;;
    --device)   DEVICE="${2:?}";   shift 2 ;;
    --pull)     PULL=1; shift ;;
    --all)      SCAN_ALL=1; shift ;;
    --jobs)     JOBS="${2:?}"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "[ERROR] unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_DIR="${OTA_AUDIT_DIR:-${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}/ota-audit}"
LISTING_DIR="$AUDIT_DIR/listings"
SEEN="$AUDIT_DIR/seen.tsv"
ANOMALIES="$AUDIT_DIR/anomalies.tsv"
mkdir -p "$LISTING_DIR"
touch "$SEEN" "$ANOMALIES"

# ---- PULL SAFETY ----
# A pull is the only expensive thing here and it is triggered by untrusted
# input (whatever Apple published), so it is capped three ways: at most
# PULL_MAX_COUNT archives per run, nothing larger than PULL_MAX_GIB, and only
# while the target filesystem keeps PULL_MIN_FREE_GIB free.
PULL_DIR="${OTA_AUDIT_PULL_DIR:-$AUDIT_DIR/pulled}"
PULL_MAX_GIB="${OTA_AUDIT_PULL_MAX_GIB:-20}"
PULL_MAX_COUNT="${OTA_AUDIT_PULL_MAX_COUNT:-1}"
PULL_MIN_FREE_GIB="${OTA_AUDIT_PULL_MIN_FREE_GIB:-100}"

# Top-level AssetData/* dirs Apple is known to ship, per platform. Everything
# else is reported. Keep these tight — a false positive costs one listing read,
# a false negative is the thing we are trying to prevent.
#
# Baselines measured across Apple's full published catalogs:
#   ios      545 archives / 2,394,349 entries -> boot, payload, payloadv2 only
#   watchos   94 archives                     -> same three
#   tvos     183 archives / 3,059,670 entries -> adds Firmware (dfu/, all_flash/)
#   macos      7 archives /    17,761 entries -> adds Restore (BootabilityBundle)
#                                                and usr (standalone ramdisks)
case "$PLATFORM" in
  macos)        DEFAULT_TOPS="boot,payload,payloadv2,Restore,usr" ;;
  tvos)         DEFAULT_TOPS="boot,payload,payloadv2,Firmware" ;;
  ios|watchos|audioos|accessory|recovery)
                DEFAULT_TOPS="boot,payload,payloadv2" ;;
  *)            DEFAULT_TOPS="boot,payload,payloadv2" ;;
esac
KNOWN_TOPS="${OTA_AUDIT_KNOWN_TOPS:-$DEFAULT_TOPS}"

command -v ipsw >/dev/null || { echo "[ERROR] ipsw not found" >&2; exit 1; }

# ---- 1. Enumerate the catalog ----
# OTA_AUDIT_CATALOG replays a saved `ipsw download ota --json` envelope instead
# of querying Apple: useful for re-auditing a past catalog with updated rules,
# and for testing this script without the network.
CAT="$AUDIT_DIR/.catalog.json"
if [ -n "${OTA_AUDIT_CATALOG:-}" ]; then
  echo "[*] using supplied catalog: $OTA_AUDIT_CATALOG"
  cp "$OTA_AUDIT_CATALOG" "$CAT"
else
  echo "[*] enumerating $PLATFORM OTAs${DEVICE:+ for $DEVICE}..."
  # shellcheck disable=SC2086
  if ! ipsw download ota --platform "$PLATFORM" ${DEVICE:+--device "$DEVICE"} --json \
       > "$CAT" 2>/dev/null; then
    echo "[ERROR] could not enumerate OTAs (network? platform name?)" >&2
    exit 1
  fi
fi

python3 - "$CAT" "$AUDIT_DIR/targets.tsv" "$SCAN_ALL" <<'PY'
import json, sys
cat, out, scan_all = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
d = json.load(open(cat))
otas = d.get("otas", [])
seen_urls, rows = set(), []
for o in otas:
    u = o.get("url") or ""
    if not u or u in seen_urls:
        continue
    seen_urls.add(u)
    enc = (o.get("encryption") or {}).get("encrypted", False)
    # Only plain zips can be listed from the central directory. AEA archives
    # are encrypted end to end: ipsw refuses remote extraction on them and the
    # header carries key metadata only, no paths. They are counted, not read.
    rows.append("\t".join([
        f"{o.get('os','?')}-{o.get('version','?')}-{o.get('build','?')}-{o.get('delivery','?')}",
        u, "aea" if (enc or u.endswith(".aea")) else "zip",
    ]))
with open(out, "w") as f:
    f.write("\n".join(rows) + ("\n" if rows else ""))
print(f"    catalog entries={len(otas)} unique_urls={len(rows)}")
PY

ZIP_N=$(awk -F'\t' '$3=="zip"' "$AUDIT_DIR/targets.tsv" | wc -l | tr -d ' ')
AEA_N=$(awk -F'\t' '$3=="aea"' "$AUDIT_DIR/targets.tsv" | wc -l | tr -d ' ')
echo "    listable (zip)=$ZIP_N  opaque (aea, skipped)=$AEA_N"

# Default to only unseen URLs; --all re-reads everything.
if [ "$SCAN_ALL" = 1 ]; then
  awk -F'\t' '$3=="zip"' "$AUDIT_DIR/targets.tsv" > "$AUDIT_DIR/queue.tsv"
else
  # Load seen URLs with getline rather than the NR==FNR idiom: on the first
  # run seen.tsv is empty, and with an empty first file NR==FNR stays true for
  # every line of the second file, so the whole queue would be swallowed and
  # the audit would silently scan nothing.
  awk -F'\t' -v seenfile="$SEEN" '
    BEGIN { while ((getline line < seenfile) > 0) { split(line, a, "\t"); s[a[2]] = 1 } }
    $3 == "zip" && !($2 in s)
  ' "$AUDIT_DIR/targets.tsv" > "$AUDIT_DIR/queue.tsv"
fi
QN=$(wc -l < "$AUDIT_DIR/queue.tsv" | tr -d ' ')
echo "[*] to scan: $QN"
[ "$QN" -gt 0 ] || { echo "[*] nothing new."; exit 0; }

# ---- 2. Read each archive's exact central directory ----
# A fixed-size tail read is NOT enough: on large/old OTAs the central directory
# runs to tens of MB and a truncated read silently yields a partial listing
# that looks like a clean result. Measured: a 400KB tail covered only 196 of
# 545 iOS archives (iOS 7.1.2 showed 2,684 of 62,860 entries). So locate the
# EOCD first, then fetch the central directory by its real offset and length,
# and verify the parsed count against the archive's declared total.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ota-audit-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export WORK LISTING_DIR KNOWN_TOPS

cat > "$WORK/scan_one.sh" <<'SH'
#!/usr/bin/env bash
lbl="$1"; url="$2"; idx="$3"
res="$WORK/r.$idx"; tmp="$WORK/t.$idx"

# EOCD lives in the last bytes; 100KB covers the comment field comfortably.
curl -sfL --max-time 120 --range -100000 "$url" -o "$tmp.e" 2>/dev/null || {
  printf '%s\t%s\tERR-HEAD\t\t\t\t\n' "$lbl" "$url" > "$res"; exit 0; }

read -r CDOFF CDSZ TOT < <(python3 - "$tmp.e" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.rfind(b'PK\x06\x06')          # ZIP64 end of central directory
if i >= 0:
    print(int.from_bytes(d[i+48:i+56], 'little'),
          int.from_bytes(d[i+40:i+48], 'little'),
          int.from_bytes(d[i+32:i+40], 'little'))
else:
    i = d.rfind(b'PK\x05\x06')      # classic EOCD
    if i >= 0:
        print(int.from_bytes(d[i+16:i+20], 'little'),
              int.from_bytes(d[i+12:i+16], 'little'),
              int.from_bytes(d[i+10:i+12], 'little'))
    else:
        print(0, 0, 0)
PY
)
rm -f "$tmp.e"
[ "${CDSZ:-0}" -gt 0 ] 2>/dev/null || {
  printf '%s\t%s\tERR-NOCD\t\t\t\t\n' "$lbl" "$url" > "$res"; exit 0; }

curl -sfL --max-time 300 --range "$CDOFF-$((CDOFF+CDSZ-1))" "$url" -o "$tmp.c" 2>/dev/null || {
  printf '%s\t%s\tERR-CD\t\t\t\t\n' "$lbl" "$url" > "$res"; exit 0; }

python3 - "$lbl" "$url" "$tmp.c" "$TOT" "$idx" > "$res" <<'PY'
import os, re, sys
lbl, url, path, tot, idx = sys.argv[1:6]
d = open(path, 'rb').read()
names = []
for m in re.finditer(b'PK\x01\x02', d):
    o = m.start()
    nl = int.from_bytes(d[o+28:o+30], 'little')
    n = d[o+46:o+46+nl].decode('utf-8', 'replace')
    if n:
        names.append(n)

# Persist the full listing; it is the artifact that makes a finding checkable.
safe = re.sub(r'[^A-Za-z0-9._-]', '_', lbl)
with open(os.path.join(os.environ['LISTING_DIR'], f"{safe}.{idx}.txt"), 'w') as f:
    f.write("\n".join(names) + "\n")

# Top-level DIRECTORIES, at archive root and under AssetData/. A name only
# counts as a directory when something follows it, so `AssetData/Info.plist`
# and the various *.bom / *.manifest files at that level are not mistaken for
# structure — otherwise every OTA reports a dozen "unexpected" entries and the
# signal is lost.
tops = set()
for n in names:
    parts = [p for p in n.split('/') if p]
    if not parts:
        continue
    if parts[0] == 'AssetData':
        if len(parts) > 2:
            tops.add(parts[1])
    elif parts[0] != 'META-INF' and len(parts) > 1:
        tops.add(parts[0])

known = {t for t in os.environ['KNOWN_TOPS'].split(',') if t}
unknown = sorted(tops - known)

# A short read means the listing is incomplete — report it as such rather than
# letting it pass as "no anomaly found".
complete = tot.isdigit() and len(names) >= int(tot)
status = 'OK' if complete else 'PARTIAL'
print("\t".join([lbl, url, status, tot, str(len(names)),
                 ",".join(sorted(tops)), ",".join(unknown)]))
PY
rm -f "$tmp.c"
SH
chmod +x "$WORK/scan_one.sh"

awk -F'\t' '{print $1"\t"$2"\t"NR}' "$AUDIT_DIR/queue.tsv" \
  | xargs -P "$JOBS" -n3 "$WORK/scan_one.sh" 2>/dev/null || true

cat "$WORK"/r.* 2>/dev/null > "$WORK/results.tsv" || true
[ -s "$WORK/results.tsv" ] || { echo "[ERROR] no results produced" >&2; exit 1; }

# ---- 3. Report ----
OK=$(awk -F'\t' '$3=="OK"'      "$WORK/results.tsv" | wc -l | tr -d ' ')
PART=$(awk -F'\t' '$3=="PARTIAL"' "$WORK/results.tsv" | wc -l | tr -d ' ')
ERR=$(awk -F'\t' '$3 ~ /^ERR/'  "$WORK/results.tsv" | wc -l | tr -d ' ')
ENTRIES=$(awk -F'\t' '$3=="OK"{t+=$5} END{print t+0}' "$WORK/results.tsv")
echo "[*] scanned=$((OK+PART+ERR))  complete=$OK  partial=$PART  errors=$ERR  entries=$ENTRIES"

# Anomaly = complete listing containing a top-level dir not on the known list.
awk -F'\t' '$3=="OK" && $7!=""' "$WORK/results.tsv" > "$WORK/anom.tsv" || true
AN=$(wc -l < "$WORK/anom.tsv" | tr -d ' ')

# Record everything scanned so the next run is quiet, but only mark an OK
# read as seen: a PARTIAL or ERR must be retried, not silently accepted.
awk -F'\t' '$3=="OK"{print $1"\t"$2}' "$WORK/results.tsv" >> "$SEEN"
sort -u -o "$SEEN" "$SEEN"

if [ "$PART" -gt 0 ] || [ "$ERR" -gt 0 ]; then
  echo "[WARN] $PART partial + $ERR failed read(s) — not marked seen, will retry:" >&2
  awk -F'\t' '$3!="OK"{printf "    %s  %s\n", $3, $1}' "$WORK/results.tsv" | head -10 >&2
fi

if [ "$AN" = 0 ]; then
  echo "[*] no structural anomalies. Known top-level dirs only ($KNOWN_TOPS)."
  exit 0
fi

echo
echo "=============================================="
echo "  $AN OTA(s) WITH UNEXPECTED STRUCTURE"
echo "=============================================="
while IFS=$'\t' read -r lbl url status tot n tops unknown; do
  echo "  $lbl"
  echo "      unexpected: $unknown"
  echo "      all tops  : $tops"
  echo "      entries   : $n"
  echo "      url       : $url"
  printf '%s\t%s\t%s\t%s\n' "$lbl" "$unknown" "$tops" "$url" >> "$ANOMALIES"
done < "$WORK/anom.tsv"
echo

# ---- 4. Auto-pull ----
if [ "$PULL" != 1 ]; then
  echo "[*] --pull not set; not downloading. Re-run with --pull to fetch these."
  exit 0
fi

mkdir -p "$PULL_DIR"
pulled=0
while IFS=$'\t' read -r lbl url status tot n tops unknown; do
  if [ "$pulled" -ge "$PULL_MAX_COUNT" ]; then
    echo "[*] pull cap reached ($PULL_MAX_COUNT); skipping the rest." \
         "Raise OTA_AUDIT_PULL_MAX_COUNT to fetch more."
    break
  fi

  SZ=$(curl -sfIL --max-time 60 "$url" \
       | awk 'tolower($1)=="content-length:"{gsub(/\r/,"");v=$2} END{print v+0}')
  GIB=$(( SZ / 1073741824 ))
  if [ "$SZ" -le 0 ]; then
    echo "[WARN] $lbl: could not determine size; skipping pull." >&2
    continue
  fi
  if [ "$GIB" -gt "$PULL_MAX_GIB" ]; then
    echo "[WARN] $lbl: ${GIB}GiB exceeds OTA_AUDIT_PULL_MAX_GIB=$PULL_MAX_GIB; skipping." >&2
    continue
  fi
  FREE_GIB=$(df -g "$PULL_DIR" 2>/dev/null | awk 'NR==2{print $4+0}')
  if [ "${FREE_GIB:-0}" -lt "$PULL_MIN_FREE_GIB" ]; then
    echo "[WARN] only ${FREE_GIB}GiB free on $PULL_DIR;" \
         "need OTA_AUDIT_PULL_MIN_FREE_GIB=$PULL_MIN_FREE_GIB. Skipping pull." >&2
    continue
  fi

  DEST="$PULL_DIR/$lbl.zip"
  if [ -s "$DEST" ]; then
    echo "[*] $lbl already pulled: $DEST"
    pulled=$((pulled + 1)); continue
  fi

  echo "[*] pulling $lbl (${GIB}GiB) -> $DEST"
  if curl -fL --retry 3 --continue-at - "$url" -o "$DEST.part"; then
    mv "$DEST.part" "$DEST"
    echo "[*] pulled: $DEST"
    # Extract just the unexpected trees, so the finding is actionable without
    # unpacking the whole archive.
    for u in ${unknown//,/ }; do
      OUT="$PULL_DIR/$lbl.$u"
      mkdir -p "$OUT"
      echo "[*] extracting '$u/' -> $OUT"
      # Two patterns because the tree may sit at the root or under AssetData/.
      # Judge success by what actually landed, not by unzip's exit status: it
      # returns 11 ("filename not matched") whenever one of several patterns
      # matches nothing, even though the other extracted fine.
      unzip -o -q "$DEST" "*/$u/*" "$u/*" -d "$OUT" 2>/dev/null || true
      GOT=$(find "$OUT" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [ "$GOT" -gt 0 ]; then
        echo "[*] extracted $GOT file(s) under $OUT"
      else
        echo "[WARN] nothing extracted for '$u'" >&2
      fi
    done
    pulled=$((pulled + 1))
  else
    rm -f "$DEST.part"
    echo "[ERROR] pull failed for $lbl" >&2
  fi
done < "$WORK/anom.tsv"

echo "[*] done. anomaly log: $ANOMALIES"
