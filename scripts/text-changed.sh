#!/usr/bin/env bash
#
# Decide whether two builds of the same binary differ in CODE, when the
# __TEXT.__text section is the same size in both.
#
#   scripts/text-changed.sh <old-macho> <new-macho>        # exit 0 = changed
#   scripts/text-changed.sh <old> <new> --show             # print the diff
#
# WHY THIS EXISTS
# ---------------
# ipsw-workflow.sh selects binaries whose __TEXT.__text SIZE changed, because
# that is cheap and rebase-invariant. It cannot see an in-place patch that
# keeps the section the same size — exactly the shape of a surgical security
# fix.
#
# `ipsw diff` does emit a "Sections with Same Size but Changed Content" block,
# but it never lists __TEXT.__text: across 19,402 such blocks spanning this
# whole corpus the section never appears once. Only data, string and ObjC
# sections do.
#
# The reason is that raw __text bytes pulled out of a dyld_shared_cache are
# not comparable between builds. The cache bakes in branch-island targets,
# stub addresses and pointer-auth fixups, so the same unchanged dylib
# extracted from two caches differs substantially. Measured on 23G90 vs
# 23H128, dylibs with an IDENTICAL version string differed by 1.8%-16.9% of
# their __text bytes — overlapping the range seen for dylibs that really did
# change. Extracting without --objc/--slide does not help; ARKit still
# differed by 14.2%.
#
# So the comparison has to happen at the instruction level, with anything
# address-derived normalised away:
#
#   * drop the leading "0xADDR:" and the raw instruction bytes
#   * drop trailing "; symbol" annotations (they embed cache addresses)
#   * replace every hex literal with a placeholder
#   * replace loc_/sub_/func_ labels with a placeholder
#
# Validated both directions on 23G90 -> 23H128:
#   ARKit (version identical in both caches)  -> 329 vs 329 instructions,
#                                                streams IDENTICAL
#   MediaAnalysisGeneration (version bumped)  -> 2 instructions changed,
#                                                `ldr x0, [x8, #N]` becoming
#                                                `ldr x0, [x8]`
#
# KNOWN LIMITATION
# ----------------
# Masking every hex literal also masks immediates, so a change that only
# alters a constant (a bounds value, a size, a flag) is invisible here. The
# obvious refinement — keep short immediates, mask only wide cache addresses —
# was tried and rejected: it let 66 lines of rebase noise back into the ARKit
# control, which would produce false positives on unchanged binaries. A sound
# "no" is worth more than a sensitive "maybe", so this stays conservative:
# it under-reports rather than inventing changes.
#
# WHY NOT JUST MASK BYTES (it would be ~1000x faster)
# ---------------------------------------------------
# Disassembling is slow: CoreAudio's __text is 5.3M instructions and takes
# minutes. ARM64 is fixed-width, so the obvious optimisation is to mask the
# address-bearing opcodes (B, BL, B.cond, CBZ/TBZ, ADR/ADRP, LDR-literal) and
# compare the remaining bytes in milliseconds. That was built and it FAILS the
# control: ARKit, byte-identical in code, still reported 33 differing words.
#
# Inspecting them shows why:
#     0xf947e900 -> 0xf947f100    ldr  x0, [x8, #imm12]
#     0x910ca042 -> 0x91124042    add  x2, x2, #imm12
#
# Cache rebasing shifts ordinary immediate offsets in LDR/ADD too, not just
# PC-relative branch targets, because those immediates index GOT and data that
# moved. At the byte level such a shift is indistinguishable from a genuine
# constant change, which is also why normalising every hex literal (above) is
# required rather than merely convenient — and why a pure-constant change is
# fundamentally unrecoverable from a cache-extracted binary, not just missed
# by this script.
#
# Needs --force on disassembly, because a dylib extracted without slide info
# has stub pointers that fall outside its own segments.

set -uo pipefail

OLD="${1:?old macho required}"
NEW="${2:?new macho required}"
SHOW="${3:-}"

for f in "$OLD" "$NEW"; do
  [ -f "$f" ] || { echo "[ERROR] no such file: $f" >&2; exit 2; }
done

norm() {
  local f="$1" sz addr
  sz=$(ipsw macho info "$f" 2>/dev/null \
       | awk '/__TEXT\.__text /{split($1,a,"=");print a[2];exit}')
  addr=$(ipsw macho info "$f" 2>/dev/null \
       | awk '/__TEXT\.__text /{split($3,x,"=");split(x[2],r,"-");print r[1];exit}')
  [ -n "$addr" ] && [ -n "$sz" ] || return 1
  [ "$((sz))" -gt 0 ] || return 1
  ipsw macho disass --vaddr "$addr" --count $(( $((sz)) / 4 )) --force "$f" 2>/dev/null \
    | sed -E 's/^[[:space:]]*0x[0-9a-f]+:[[:space:]]*//' \
    | sed -E 's/^([0-9a-f]{2} ){3}[0-9a-f]{2}[[:space:]]*//' \
    | sed -E 's/[[:space:]]*;.*$//' \
    | sed -E 's/0x[0-9a-f]+/ADDR/g; s/(loc|sub|func)_[0-9a-f]+/LBL/g' \
    | grep -vE '^[[:space:]]*$|^[_a-zA-Z0-9]+:$'
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/textchg-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The two sides are independent and disassembly dominates the runtime —
# measured on Bom, 12s of a 17s run is one side alone — so run them
# concurrently. Exit status is captured per side rather than read from the
# pipeline, otherwise a failed disassembly would look like an empty section
# and be reported as "unchanged".
norm "$OLD" > "$TMP/old.txt" & pid_o=$!
norm "$NEW" > "$TMP/new.txt" & pid_n=$!
wait "$pid_o"; rc_o=$?
wait "$pid_n"; rc_n=$?
[ "$rc_o" -eq 0 ] || { echo "[ERROR] no __TEXT.__text in $OLD" >&2; exit 2; }
[ "$rc_n" -eq 0 ] || { echo "[ERROR] no __TEXT.__text in $NEW" >&2; exit 2; }

no=$(wc -l < "$TMP/old.txt" | tr -d ' ')
nn=$(wc -l < "$TMP/new.txt" | tr -d ' ')

# An empty stream on either side means the disassembly failed rather than
# that the code matched; saying "unchanged" there would be a false negative.
if [ "$no" -eq 0 ] || [ "$nn" -eq 0 ]; then
  echo "[ERROR] disassembly produced no instructions (old=$no new=$nn)" >&2
  exit 2
fi

if cmp -s "$TMP/old.txt" "$TMP/new.txt"; then
  echo "unchanged  ($no instructions)"
  exit 1
fi

changed=$(diff "$TMP/old.txt" "$TMP/new.txt" | grep -c '^[<>]')
echo "CHANGED  ($changed of $no instructions)"
[ "$SHOW" = "--show" ] && diff "$TMP/old.txt" "$TMP/new.txt" | head -40
exit 0
