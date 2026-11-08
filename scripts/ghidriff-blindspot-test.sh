#!/usr/bin/env bash
#
# Reproducible harness for a ghidriff blind spot: operand-only changes.
#
#   scripts/ghidriff-blindspot-test.sh [workdir]
#
# Builds four tiny binaries from one source and diffs each against the
# baseline, so the only variable is the kind of change:
#
#   const   a bounds constant   (n > 64   -> n > 32)        same __text size
#   stack   a buffer size       (buf[256] -> buf[128])      same __text size
#   struct  an added statement  (extra if)                  size changes
#
# `stack` is the Blaster/MS03-026 shape: the fix was a stack buffer size
# change, which is the canonical patch-diffing example and exactly what a
# mnemonic-level comparison cannot see.
#
# EXPECTED RESULT (ghidriff 1.x, as measured):
#   const   modified_funcs_len = 0   MISSED
#   stack   modified_funcs_len = 0   MISSED
#   struct  modified_funcs_len = 1   detected
#
# WHY, precisely. In ghidra_diff_engine.py the 'code' diff type is gated on:
#
#     if len(only_code_diff) > 0 and (mnemonics_ratio < 1.0 or blocks_ratio < 1.0):
#
# `instructions` is str(code_unit) and keeps operands ("cmp x0, #0x40").
# `mnemonics` is code_unit.getMnemonicString() and drops them ("cmp").
# An operand-only edit therefore leaves mnemonics_ratio and blocks_ratio at
# 1.0, the guard is False, 'code' is never appended, and when no other
# diff_type fires the function is dropped by `if len(diff_type) == 0: continue`
# — it does not even appear in the report.
#
# `instructions_ratio` is already computed one line earlier and would be < 1.0
# for exactly these cases, but is not consulted. The candidate fix is to add
# it to the guard:
#
#     if len(only_code_diff) > 0 and (instructions_ratio < 1.0
#                                     or mnemonics_ratio < 1.0
#                                     or blocks_ratio < 1.0):
#
# Re-run this harness after any such change: const and stack should flip to 1
# while struct stays 1. Baseline-vs-itself is also diffed as a control, and
# must stay 0 — a fix that reports changes on identical input is worse than
# the blind spot.
#
# Inputs are given distinct basenames because ghidriff keys its decompiler
# pool on prog.name; identical names make the old side decompile against the
# new side's bytes.

set -uo pipefail

WORK="${1:-${TMPDIR:-/tmp}/ghidriff-blindspot}"
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK" || exit 1

command -v ghidriff >/dev/null || { echo "[ERROR] ghidriff not on PATH" >&2; exit 2; }
command -v cc >/dev/null || { echo "[ERROR] no C compiler" >&2; exit 2; }

cat > base.c <<'EOF'
#include <string.h>
int check(const char *in, char *out) {
    char scratch[256];           /* STACKSIZE */
    size_t n = strlen(in);
    if (n > 64) return -1;       /* BOUND */
    memcpy(scratch, in, n);
    memcpy(out, scratch, n);
    return (int)n;
}
int main(int c, char **v) { char b[512]; return check(v[0], b); }
EOF

sed 's/n > 64/n > 32/'             base.c > const.c
sed 's/scratch\[256\]/scratch[128]/' base.c > stack.c
sed 's|memcpy(scratch, in, n);|if (!out) return -2;\n    memcpy(scratch, in, n);|' base.c > struct.c

for v in base const stack struct; do
  cc -O1 -o "bin.$v" "$v.c" 2>/dev/null || { echo "[ERROR] compile failed: $v" >&2; exit 2; }
done

txt() { ipsw macho info "$1" 2>/dev/null | awk '/__TEXT\.__text /{split($1,a,"=");print a[2];exit}'; }

echo "=== __text sizes (const/stack must match base to be the interesting case) ==="
for v in base const stack struct; do printf "  %-7s %s\n" "$v" "$(txt "bin.$v")"; done
echo

printf "  %-8s %-10s %-10s %s\n" CASE SAME_SIZE MODIFIED VERDICT
for v in base const stack struct; do
  out="out.$v"; rm -rf "$out"
  # base-vs-base is the control: it must report nothing.
  ghidriff --min-func-len 1 -o "$out" "bin.base" "bin.$v" >/dev/null 2>&1

  j=$(find "$out/json" -name '*.ghidriff.json' -print -quit 2>/dev/null)
  if [ -z "$j" ]; then
    printf "  %-8s %-10s %-10s %s\n" "$v" "?" "?" "ghidriff produced no json"
    continue
  fi
  mod=$(python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['stats'].get('modified_funcs_len','?'))" "$j" 2>/dev/null)
  same=$([ "$(txt "bin.base")" = "$(txt "bin.$v")" ] && echo yes || echo no)

  # base must report exactly 0; the others must report at least 1. More than
  # one is fine and expected — a changed constant also shifts the C runtime
  # entry stub, so the fixed engine reports 2. Demanding exactly 1 would fail
  # a correct result.
  case "$v" in
    base)   label="control, must be 0"
            [ "$mod" = "0" ] && verdict="ok ($label)" || verdict="REGRESSION ($label)" ;;
    struct) label="structural, must detect"
            [ "${mod:-0}" -ge 1 ] 2>/dev/null && verdict="ok ($label)" || verdict="FAIL ($label)" ;;
    *)      label="operand-only"
            [ "${mod:-0}" -ge 1 ] 2>/dev/null && verdict="ok ($label, fix present)" \
              || verdict="BLIND SPOT ($label, unpatched)" ;;
  esac
  printf "  %-8s %-10s %-10s %s\n" "$v" "$same" "$mod" "$verdict"
done

echo
echo "  workdir: $WORK"
