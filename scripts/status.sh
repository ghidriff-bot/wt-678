#!/usr/bin/env bash
#
# Emit a machine-readable snapshot of the corpus: what is diffed, what is
# missing, what failed its completeness gate, and whether a chain is alive.
#
#   scripts/status.sh                      # write docs/status.json
#   scripts/status.sh --print              # to stdout instead
#
# Everything here is derived from state the pipeline already writes — the
# per-pair *.txt want-lists, metadata/extraction_report.txt from the gate, and
# the diff JSONs — so this never needs its own bookkeeping to drift out of
# sync with reality.
#
# The point is the failure modes that looked like success: a chain that died
# to system sleep with no error logged, and three pairs that reported
# "✅ done" while extracting zero machos. Both were invisible for hours
# because nothing compared intent against result. This does.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${IPSW_DIFFS_DIR:-$REPO_ROOT/ipsw_diffs}"
OUT="${STATUS_OUT:-$REPO_ROOT/docs/status.json}"
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

# Devices to report, as "os:device" pairs. Override to add more.
DEVICES="${STATUS_DEVICES:-iOS:iPhone13,3 macOS:Mac14,12}"

# Timestamps are passed in rather than taken inside the generator so a re-run
# over unchanged data produces an identical file apart from this one field.
NOW="$(date -u +%FT%TZ)"

# Is a chain running right now, and how stale is the newest log?
RUNNING=false
pgrep -f 'ipsw-workflow' >/dev/null 2>&1 && RUNNING=true
LOG_DIR="${IPSW_LOG_DIR:-$BASE_DIR/../logs}"
NEWEST_LOG_AGE=null
if [ -d "$LOG_DIR" ]; then
  newest="$(find "$LOG_DIR" -name '*.log' -type f -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null | head -1 || true)"
  if [ -n "$newest" ]; then
    mt=$(stat -f %m "$newest" 2>/dev/null || echo 0)
    [ "$mt" -gt 0 ] && NEWEST_LOG_AGE=$(( $(date +%s) - mt ))
  fi
fi

mkdir -p "$(dirname "$OUT")"

BASE_DIR="$BASE_DIR" NOW="$NOW" RUNNING="$RUNNING" \
NEWEST_LOG_AGE="$NEWEST_LOG_AGE" DEVICES="$DEVICES" REPO_ROOT="$REPO_ROOT" \
python3 - > "$OUT.tmp" <<'PY'
import json, os, re, subprocess, glob

base   = os.environ['BASE_DIR']
now    = os.environ['NOW']
devs   = os.environ['DEVICES'].split()

def served_builds(device):
    """Oldest-first list of builds Apple still serves for this device."""
    try:
        out = subprocess.run(['ipsw', 'dl', 'ipsw', '--device', device, '--urls'],
                             capture_output=True, text=True, timeout=180).stdout
    except Exception:
        return []
    out = re.sub(r'\x1B\[[0-9;]*[mGKH]', '', out)
    b = re.findall(r'_([0-9A-Z]+)_Restore\.ipsw', out)
    return list(reversed(b))          # ipsw lists newest first

def count(d, cls):
    n = 0
    for root, _, files in os.walk(os.path.join(d, 'changed')):
        if f'/{cls}/' in root + '/':
            n += sum(1 for f in files if not f.startswith('._'))
    return n

def wantcount(d, cls):
    p = os.path.join(d, f'{cls}.txt')
    if not os.path.exists(p):
        return 0
    with open(p) as f:
        return sum(1 for ln in f if ln.strip())

def dirsize(d):
    t = 0
    for root, _, files in os.walk(d):
        for f in files:
            try: t += os.path.getsize(os.path.join(root, f))
            except OSError: pass
    return t

report = {'generated': now,
          'chain_running': os.environ['RUNNING'] == 'true',
          'newest_log_age_seconds': (None if os.environ['NEWEST_LOG_AGE'] == 'null'
                                     else int(os.environ['NEWEST_LOG_AGE'])),
          'devices': []}

for spec in devs:
    os_type, device = spec.split(':', 1)
    safe = device.replace(',', '_')
    builds = served_builds(device)
    pairs = []
    for i in range(len(builds) - 1):
        old, new = builds[i], builds[i + 1]
        d = os.path.join(base, safe, f'{old}-{new}')
        js = os.path.join(d, 'diffs', f'diff_{safe}_{old}_to_{new}.json')
        zp = js[:-5] + '.zip'
        has_diff = os.path.exists(js) or os.path.exists(zp)

        rep = os.path.join(d, 'metadata', 'extraction_report.txt')
        shortfall = False
        if os.path.exists(rep):
            shortfall = 'SHORTFALL' in open(rep, errors='replace').read()

        changed = os.path.join(d, 'changed')
        nfiles = 0
        if os.path.isdir(changed):
            for root, _, files in os.walk(changed):
                nfiles += sum(1 for f in files if not f.startswith('._'))

        if not has_diff:
            state = 'missing'
        elif shortfall:
            state = 'incomplete'
        elif nfiles > 0:
            state = 'done'
        else:
            state = 'incomplete'

        entry = {'old': old, 'new': new, 'state': state}
        if has_diff:
            entry['counts'] = {
                c: {'want': wantcount(d, c), 'got': count(d, c)}
                for c in ('kexts', 'dylibs', 'machos')
            }
            entry['files'] = nfiles
            entry['bytes'] = dirsize(d) if nfiles else 0
            dj = js if os.path.exists(js) else zp
            try: entry['diff_bytes'] = os.path.getsize(dj)
            except OSError: pass
        pairs.append(entry)

    done = sum(1 for p in pairs if p['state'] == 'done')
    inc  = sum(1 for p in pairs if p['state'] == 'incomplete')
    report['devices'].append({
        'os': os_type, 'device': device,
        'builds_served': len(builds),
        'pairs_possible': max(0, len(builds) - 1),
        'pairs_done': done,
        'pairs_incomplete': inc,
        'pairs_missing': len(pairs) - done - inc,
        'head_build': builds[-1] if builds else None,
        'bytes_total': sum(p.get('bytes', 0) for p in pairs),
        'pairs': pairs,
    })

# Structural anomalies found by ota-audit, if it has ever run.
anom = []
for f in glob.glob(os.path.join(base, 'ota-audit', 'anomalies.tsv')):
    for ln in open(f, errors='replace'):
        parts = ln.rstrip('\n').split('\t')
        if len(parts) >= 2:
            anom.append({'label': parts[0], 'unexpected': parts[1]})
report['ota_anomalies'] = anom

print(json.dumps(report, indent=2))
PY

mv "$OUT.tmp" "$OUT"

if [ "$PRINT" = 1 ]; then
  cat "$OUT"
else
  python3 - "$OUT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"generated {r['generated']}  chain_running={r['chain_running']}")
for d in r['devices']:
    print(f"  {d['device']:<12} {d['pairs_done']}/{d['pairs_possible']} done"
          f"  incomplete={d['pairs_incomplete']}  missing={d['pairs_missing']}"
          f"  head={d['head_build']}  {d['bytes_total']/2**30:.1f}GiB")
if r['ota_anomalies']:
    print(f"  ota anomalies: {len(r['ota_anomalies'])}")
PY
  echo "wrote $OUT"
fi
