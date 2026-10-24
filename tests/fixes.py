"""Targeted safety regressions: synthetic files/processes only, no normal Store or real account reads.

Foundation cache isolation is EXPLICIT: replace Paths.cache in temporary source copies before compiling.
HOME does not redirect Foundation paths. The temporary harness uses Store(preview:), never Store().
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
APP = Path(sys.argv[1]).resolve()
HELPER = APP / "Contents/Resources/usage-meter-refresh.py"
failed = 0


def check(name, ok):
    global failed
    print(("ok   " if ok else "FAIL ") + name, flush=True)
    failed += not ok


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=120, **kw)


with tempfile.TemporaryDirectory(prefix="limitbar-fixes-") as temp:
    temp = Path(temp).resolve()  # canonical per-user temp, never world-writable /private/tmp
    cache = temp / "cache"
    cache.mkdir(mode=0o700)
    sources = temp / "sources"
    sources.mkdir()
    for name in ("Model", "Spawn", "Fetchers", "Local", "Muse", "Store"):
        text = (ROOT / f"Sources/LimitBar/{name}.swift").read_text()
        if name == "Model":
            text = text.replace("static let activeVendors: [Vendor] = [.claude, .gemini, .codex, .cursor]", "static let activeVendors: [Vendor] = Vendor.allCases")
        if name == "Fetchers":
            start = text.index("    static let cache: String = {")
            end = text.index("    }()", start) + len("    }()")
            text = text[:start] + "    static let cache: String = " + json.dumps(str(cache)) + text[end:]
        if name == "Local":
            text += "\nextension Collector { static func fixtureTrusted(_ p: String) -> Bool { isReadableData(p) } }\n"
        if name == "Store":
            text += '''
extension Store {
    func fixtureLoadCache() { loadCache() }
    func fixturePoll(age: Double?, force: Bool, olderThan: Double?, state: VendorState = .ok,
                     resetPassed: Bool = false, isBusy: Bool = false) -> Bool {
        museSource = .direct
        lastMuseCompletion = age.map { ProcessInfo.processInfo.systemUptime - $0 }
        lastPoll[.muse] = Date().addingTimeInterval(-(age ?? 1e6))
        lastActivity[.muse] = .distantPast
        snaps[.muse] = Snapshot(vendor: .muse, state: state,
            windows: resetPassed ? [Window(label: "Week", short: "w", used: 50, resetsAt: .distantPast)] : [])
        busy = isBusy ? [.muse] : []
        return shouldPoll(.muse, force: force, olderThan: olderThan)
    }
    func fixtureCapturedNote() -> Bool {
        lastCollector = Collector.Result(at: Date(), status: "untrusted")
        let note = collectorNote
        lastCollector = Collector.Result(at: Date(), status: "refreshed")
        let result = queue.sync { fetch(.cursor, prev: nil, force: false, collectorNote: note) }
        return collectorNote == nil && result.notes.contains(note ?? "never")
    }
}
'''
        (sources / f"{name}.swift").write_text(text)
    (sources / "main.swift").write_text((ROOT / "tests/fixes.swift").read_text())
    harness = temp / "harness"
    build = run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", *map(str, sources.glob("*.swift")), "-o", str(harness)])
    if build.returncode:
        # Compiler diagnostics contain source locations, not fixtures/credentials.
        print(build.stderr)
        sys.exit(1)
    fixture = temp / "usage.json"
    fixture.write_text('{"checked_at":"2026-01-01T00:00:00Z","pools":{}}')
    result = run([str(harness), str(temp), "-cursorUsagePath", str(fixture), "-usageMeterCollector", str(temp / "collect.py")])
    print(result.stdout, end="", flush=True)
    check("actual-source isolated Swift harness exits successfully", result.returncode == 0)

    def collector(name, body):
        folder = temp / name
        folder.mkdir(mode=0o700)
        path = folder / "collect.py"
        path.write_text(body)
        path.chmod(0o600)
        return path

    def command(path):
        return ["/usr/bin/python3", "-I", "-B", str(HELPER), "--collector", str(path), "--min-age", "240", "--lock", str(temp / "lock")]

    base = '''
from pathlib import Path
import datetime,json
BASE=Path(__file__).parent
USAGE_JSON_PATHS=[BASE/'usage.json']
def _ensure_path(): pass
def collect_snapshot():
    return {"checked_at":datetime.datetime.now(datetime.timezone.utc).isoformat(), "pools":{}}
def write_snapshot(s):
    USAGE_JSON_PATHS[0].write_text(json.dumps(s)); return [USAGE_JSON_PATHS[0]]
'''
    # Apply ACLs ONLY to disposable synthetic fixtures, then test both actual Swift trust and helper.
    clean = collector("clean", base)
    check("Swift collector accepts private synthetic control", run([str(harness), "trust", str(clean)]).stdout.strip() == "trusted")
    for where, permission in (("file", "write"), ("parent", "add_file"), ("ancestor", "delete_child")):
        path = collector("acl-" + where, base)
        if where == "ancestor":
            nested = path.parent / "nested"
            nested.mkdir(mode=0o700)
            path.rename(nested / "collect.py")
            path = nested / "collect.py"
        target = path if where == "file" else path.parent if where == "parent" else path.parent.parent
        acl = run(["/bin/chmod", "+a", "everyone allow " + permission, str(target)])
        check("synthetic extended ACL applied: " + where, acl.returncode == 0)
        check("Swift refuses ACL-writable " + where, run([str(harness), "trust", str(path)]).stdout.strip() == "untrusted")
        response = run(command(path))
        check("standalone helper refuses ACL-writable " + where, response.returncode == 1 and json.loads(response.stdout) == {"status": "untrusted"})
        check("ACL fixture was never executed: " + where, not (path.parent / "usage.json").exists())

    read_acl = collector("acl-read-only", base)
    acl = run(["/bin/chmod", "+a", "everyone allow read", str(read_acl)])
    check("synthetic read-only extended ACL applied", acl.returncode == 0)
    check("Swift accepts read-only ACL after normal iteration end", run([str(harness), "trust", str(read_acl)]).stdout.strip() == "trusted")
    response = run(command(read_acl))
    check("standalone helper accepts read-only ACL after normal iteration end", response.returncode == 0 and json.loads(response.stdout)["status"] == "refreshed")

    import ctypes, errno, importlib.util
    spec = importlib.util.spec_from_file_location("um_helper", str(HELPER))
    um_helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(um_helper)

    class FakeFn:
        def __init__(self, fn):
            self.fn = fn
        def __call__(self, *a):
            return self.fn(*a)

    def make_fake_cdll(get_acl, get_entry, get_tag=None, get_permset=None, get_perm=None):
        class FakeLib:
            def __init__(self):
                self.freed = 0
                self.acl_get_link_np = FakeFn(get_acl)
                self.acl_free = FakeFn(lambda a: setattr(self, "freed", self.freed + 1) or 0)
                self.acl_get_entry = FakeFn(get_entry)
                self.acl_get_tag_type = FakeFn(get_tag or (lambda e, t: 0))
                self.acl_get_permset = FakeFn(get_permset or (lambda e, p: 0))
                self.acl_get_perm_np = FakeFn(get_perm or (lambda p, b: 0))
        return FakeLib()

    real_cdll = ctypes.CDLL
    try:
        # 1. Normal no-ACL: NULL + ENOENT -> False (safe)
        lib = make_fake_cdll(lambda p, t: (ctypes.set_errno(errno.ENOENT), None)[1], lambda a, w, e: -1)
        ctypes.CDLL = lambda *a, **k: lib
        check("helper ACL NULL + ENOENT is normal no-ACL", um_helper.acl_grants_write(str(clean)) is False)

        # 2. Injected NULL + EACCES -> True (fail closed) and trusted_collector rejects
        lib = make_fake_cdll(lambda p, t: (ctypes.set_errno(errno.EACCES), None)[1], lambda a, w, e: -1)
        ctypes.CDLL = lambda *a, **k: lib
        check("helper ACL NULL + EACCES fails closed", um_helper.acl_grants_write(str(clean)) is True and um_helper.trusted_collector(str(clean)) is False)

        # 3. Normal iteration end: 1 read-only ALLOW entry, then -1 + EINVAL -> False (safe)
        def entry_normal(a, w, e):
            if w == 0:
                ctypes.cast(e, ctypes.POINTER(ctypes.c_void_p))[0] = 0x2000
                return 0
            ctypes.set_errno(errno.EINVAL)
            return -1
        def tag_allow(e, t):
            ctypes.cast(t, ctypes.POINTER(ctypes.c_int))[0] = 1
            return 0
        def permset_ok(e, p):
            ctypes.cast(p, ctypes.POINTER(ctypes.c_void_p))[0] = 0x3000
            return 0
        lib = make_fake_cdll(lambda p, t: 0x1000, entry_normal, get_tag=tag_allow, get_permset=permset_ok, get_perm=lambda p, b: 0)
        ctypes.CDLL = lambda *a, **k: lib
        check("helper ACL normal iteration end (-1 + EINVAL) is allowed", um_helper.acl_grants_write(str(clean)) is False and lib.freed == 1)

        # 4. Iteration error: -1 + EIO -> True (fail closed) and trusted_collector rejects
        def entry_err(a, w, e):
            ctypes.set_errno(errno.EIO)
            return -1
        lib = make_fake_cdll(lambda p, t: 0x1000, entry_err)
        ctypes.CDLL = lambda *a, **k: lib
        check("helper ACL iteration error (-1 + EIO) fails closed", um_helper.acl_grants_write(str(clean)) is True and um_helper.trusted_collector(str(clean)) is False and lib.freed >= 1)
    finally:
        ctypes.CDLL = real_cdll

    noisy = collector("fd-noise", '''
import os,subprocess,sys
os.write(1,b'SYNTHETIC_IMPORT_FD_MARKER\\n'); os.write(2,b'SYNTHETIC_IMPORT_ERR_MARKER\\n')
subprocess.run([sys.executable,'-I','-B','-c',"import os;os.write(1,b'SYNTHETIC_CHILD_MARKER');os.write(2,b'SYNTHETIC_CHILD_ERR_MARKER')"])
''' + base.replace('def collect_snapshot():', '''def collect_snapshot():
    os.write(1,b'SYNTHETIC_COLLECT_FD_MARKER'); os.write(2,b'SYNTHETIC_COLLECT_ERR_MARKER')'''))
    response = run(command(noisy))
    check("helper suppresses import, os.write and subprocess descriptors", response.returncode == 0 and response.stderr == "" and response.stdout.strip() == '{"status": "refreshed", "written": 1, "known_pools": 0}')

    # Exact legacy plugin collect/write sequence, deliberately WITHOUT helper lock. Barrier guarantees
    # the old snapshot remains old until both callers started; this asserts honest overlap expectations.
    overlapping = collector("overlap", base.replace('def collect_snapshot():', '''def collect_snapshot():
    import time
    with (BASE/'events').open('a') as f: f.write('start\\n')
    deadline=time.monotonic()+8
    while not (BASE/'release').exists() and time.monotonic()<deadline: time.sleep(.01)'''))
    plugin = subprocess.Popen(["/usr/bin/python3", "-I", "-B", "-c", "import runpy,sys;m=runpy.run_path(sys.argv[1]);m['_ensure_path']();m['write_snapshot'](m['collect_snapshot']())", str(overlapping)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    helper = None
    def started(count):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            events = overlapping.parent / "events"
            if events.exists() and len(events.read_text().splitlines()) >= count:
                return True
            time.sleep(.01)
        return False
    try:
        first = started(1)
        helper = subprocess.Popen(command(overlapping), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        both = started(2)
        (overlapping.parent / "release").touch()
        plugin.wait(timeout=15)
        output, errors = helper.communicate(timeout=15)
        check("legacy plugin and helper CAN overlap; helper lock is not shared", first and both and helper.returncode == 0 and not errors and json.loads(output)["status"] == "refreshed")
        # The legacy invocation is drained; no further plugin invocation is made after disablement.
        response = run(command(overlapping))
        check("disable/drain first plus recent snapshot: helper fresh-skips, no extra collection", response.returncode == 0 and json.loads(response.stdout)["status"] == "fresh-skip" and len((overlapping.parent / "events").read_text().splitlines()) == 2)
    finally:
        (overlapping.parent / "release").touch()
        if plugin.poll() is None:
            plugin.terminate(); plugin.wait(timeout=5)
        if helper is not None and helper.poll() is None:
            helper.terminate(); helper.wait(timeout=5)

print("PASS: targeted fixes" if not failed else "targeted fixes FAILED", flush=True)
sys.exit(bool(failed))
