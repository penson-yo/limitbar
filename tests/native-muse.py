"""Current CLI gate plus isolated legacy native adapter fixtures; never real credentials/network."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
app = sys.argv[1]
subprocess.run([sys.executable, '-I', '-B', str(root/'tests/muse-usage.py'), app], check=True)
with tempfile.TemporaryDirectory(prefix='limitbar-legacy-muse-') as folder:
    folder = Path(folder).resolve()
    sources = folder/'sources'; sources.mkdir()
    for name in ('Model', 'Spawn', 'Fetchers', 'Local', 'Muse'):
        text = (root/f'Sources/LimitBar/{name}.swift').read_text()
        if name == 'Fetchers':
            start = text.index('    static let cache: String = {')
            end = text.index('    }()', start) + len('    }()')
            text = text[:start]+'    static let cache: String = '+json.dumps(str(folder/'cache'))+text[end:]
        (sources/f'{name}.swift').write_text(text)
    (sources/'main.swift').write_text((root/'tests/native-muse.swift').read_text())
    build = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', *map(str,sources.glob('*.swift')), '-o', str(folder/'test')], capture_output=True, text=True, timeout=120)
    if build.returncode:
        print(build.stderr); sys.exit(1)
    result = subprocess.run([str(folder/'test'), str(folder)], capture_output=True, text=True, timeout=120)
    if any(marker in result.stdout+result.stderr for marker in ('NATIVE_FAKE_TOKEN','NATIVE_FAKE_EMAIL','NATIVE_FAKE_KEY')):
        print('FAIL private fixture marker in output'); sys.exit(1)
    print(result.stdout, end='')
    sys.exit(result.returncode)
