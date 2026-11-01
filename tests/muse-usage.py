"""Muse CLI allowance fixtures. No real CLI, credentials, network or preference writes."""
import copy
import datetime
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
binary = app / 'Contents/MacOS/LimitBar'
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
ms = lambda dt: int(dt.timestamp() * 1000)
marker = 'SYNTHETIC_MUSE_PRIVATE_IDENTIFIER'
base = {'schemaVersion': 1, 'allowance': {
    'asOfMs': ms(now), 'tier': 'everyday',
    'window': {'usedPercent': 37, 'resetsAtMs': ms(now + datetime.timedelta(hours=2))},
    'weekly': {'usedPercent': 87, 'resetsAtMs': ms(now + datetime.timedelta(days=3))},
    'account': marker}, 'email': marker}
checks = 0


def check(label, ok):
    global checks
    checks += 1
    print(('ok   ' if ok else 'FAIL ') + label, flush=True)
    if not ok:
        raise SystemExit(1)


with tempfile.TemporaryDirectory(prefix='limitbar-muse-usage-') as folder:
    folder = Path(folder).resolve()
    fake = folder / 'muse'
    overrides = ['-claudePath', '/nonexistent/claude', '-agyPath', '/nonexistent/agy',
                 '-codexPath', '/nonexistent/codex', '-cursorUsagePath', str(folder/'absent.json'),
                 '-musePath', str(fake), '-museDirectQuota', 'YES', '-museHost', 'YES']

    def probe(payload, code=0, raw=None):
        # Exact arguments prove that legacy defaults cannot select a model, host or native API.
        response = json.dumps(payload) if raw is None else raw
        fake.write_text('#!/bin/bash\n[[ "$#" == 2 && "$1" == usage && "$2" == --json ]] || exit 72\n'
                        + 'printf "%s\\n" ' + shlex.quote(response) + '\nexit ' + str(code) + '\n')
        fake.chmod(0o755)
        result = subprocess.run([str(binary), '--probe', *overrides], capture_output=True,
                                text=True, timeout=30)
        check('private fields never leave the parser', marker not in result.stdout + result.stderr)
        check('probe succeeds with exactly five active providers', result.returncode == 0 and
              set(json.loads(result.stdout)) == {'claude', 'gemini', 'codex', 'cursor', 'muse'})
        return json.loads(result.stdout)['muse']

    s = probe(base)
    check('native usage command supplies five-hour then weekly quota', s['state'] == 'ok' and
          [(w['label'], w['short'], w.get('used')) for w in s['windows']] ==
          [('5-hour', '5h', 37), ('Week', 'w', 87)])
    check('observation timestamp is retained', s['measuredAt'] == now.strftime('%Y-%m-%dT%H:%M:%SZ'))
    check('safe plan and reset values retained', s['plan'] == 'Everyday' and
          s['windows'][0]['resetsAt'] == (now+datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))

    for name, value in [('zero', 0), ('exhausted', 100), ('over quota', 130)]:
        d = copy.deepcopy(base); d['allowance']['window']['usedPercent'] = value
        s = probe(d)
        check(name+' remains an observed quota', s['windows'][0].get('used') == min(value, 100))

    for name, value in [('boolean', True), ('string', '12'), ('negative', -1), ('huge', 1e308), ('null', None)]:
        d = copy.deepcopy(base); d['allowance']['window']['usedPercent'] = value
        s = probe(d)
        check(name+' is unknown while weekly remains usable',
              s['windows'][0].get('used') is None and s['windows'][1].get('used') == 87)

    d = copy.deepcopy(base); del d['allowance']['window']; s = probe(d)
    check('missing five-hour window is unknown, not zero or omitted',
          len(s['windows']) == 2 and s['windows'][0].get('used') is None)
    d = copy.deepcopy(base); del d['allowance']['weekly']; s = probe(d)
    check('missing weekly window is unknown, not zero or omitted',
          len(s['windows']) == 2 and s['windows'][1].get('used') is None)

    invalid = []
    for field, value in [('schemaVersion', 2), ('schemaVersion', True), ('reason', marker), ('hint', marker),
                         ('allowance', None), ('allowance', {})]:
        d = copy.deepcopy(base); d[field] = value; invalid.append((field+' invalid', d))
    for name, value in [('missing', None), ('boolean', True), ('huge', 1e308),
                        ('future', ms(now+datetime.timedelta(minutes=10))),
                        ('stale', ms(now-datetime.timedelta(minutes=46)))]:
        d = copy.deepcopy(base); d['allowance']['asOfMs'] = value; invalid.append((name+' observation', d))
    d = copy.deepcopy(base); d['allowance']['window'] = {}; d['allowance']['weekly'] = {}
    invalid.append(('absent quota', d))
    for name, d in invalid:
        s = probe(d)
        check(name+' fails with no invented quota', s['state'] == 'failed' and not s.get('windows'))
    check('malformed JSON fails closed', probe({}, raw='not JSON '+marker)['state'] == 'failed')
    check('nonzero command exit fails closed', probe(base, code=1)['state'] == 'failed')
    d = copy.deepcopy(base); d['allowance']['window']['resetsAtMs'] = ms(now-datetime.timedelta(minutes=1))
    s = probe(d)
    check('passed reset is retained for awaiting-update display',
          s['windows'][0]['resetsAt'] < now.strftime('%Y-%m-%dT%H:%M:%SZ'))

print('PASS: '+str(checks)+' Muse usage checks')
