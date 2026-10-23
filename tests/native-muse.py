"""Offline native adapter and production gate tests; no live secrets, HTTP or preference writes.
Normal Store is used only with explicit fake home/cache/source overrides. Legacy tests use preview Store.
All source copies redirect Paths.cache explicitly. Credentials and URLSession are injected fixtures.
"""
from pathlib import Path
import json, subprocess, tempfile, sys
root = Path(__file__).resolve().parents[1]

def four_only(app):
    """Production gates; normal Store with explicit fake home/cache and no live source."""
    with tempfile.TemporaryDirectory(prefix='limitbar-four-') as temp:
        temp = Path(temp).resolve()
        sources = temp/'sources'; sources.mkdir()
        cache = temp/'cache'; cache.mkdir(mode=0o700)
        for name in ('Model', 'Spawn', 'Fetchers', 'Local', 'Muse', 'Store'):
            source = (root/f'Sources/LimitBar/{name}.swift').read_text()
            if name == 'Spawn':
                source = source.replace('static let home = FileManager.default.homeDirectoryForCurrentUser.path', 'static let home = '+json.dumps(str(temp/'home')))
            if name == 'Fetchers':
                start = source.index('    static let cache: String = {')
                end = source.index('    }()', start) + len('    }()')
                source = source[:start] + '    static let cache: String = '+json.dumps(str(cache))+source[end:]
            if name == 'Store':
                source = source.replace('private var museClient = MuseNative.Client()', 'private var museClient = gateClient')
                source = source.replace('UserDefaults.standard.set($0, forKey: "museDirectQuota")', '_ in gateWrites += 1')
                source += """
extension Store {
    func gatePoll(_ force: Bool, _ hover: Double?) -> Bool { shouldPoll(.muse, force: force, olderThan: hover) }
    func gateSchedule() { schedule(.muse, force: true) }
    func gateArm() { museActionsAllowed = true; museSource = .direct; snaps[.muse] = MuseNative.setup }
}
"""
            (sources/f'{name}.swift').write_text(source)
        (sources/'main.swift').write_text(r'''
import AppKit
import Foundation
var gateReads = 0, gateHTTP = 0, gateWrites = 0, failures = 0, checks = 0
let gateClient = MuseNative.Client(credential: { _ in gateReads += 1; throw MuseNative.Failure(.missingLogin,.keychain) }, network: { _ in gateHTTP += 1; return (500,Data()) })
func check(_ label: String, _ ok: Bool) { checks += 1; if !ok { failures += 1 }; print((ok ? "ok   " : "FAIL ")+label) }
check("active vendors are exactly four; allCases retains five", Vendor.activeVendors == [.claude,.gemini,.codex,.cursor] && Vendor.allCases.count == 5)
check("legacy defaults enabled in argument domain", UserDefaults.standard.bool(forKey:"museDirectQuota") && UserDefaults.standard.bool(forKey:"museHost"))
let all = Dictionary(uniqueKeysWithValues: Vendor.allCases.map { ($0.rawValue,Snapshot(vendor:$0)) })
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
try! enc.encode(all).write(to:URL(fileURLWithPath:Paths.cache+"/state.json"))
let store = Store()
check("normal startup ignores existing Muse cache", store.snaps[.muse] == nil && !store.installed.contains(.muse))
store.refresh(); store.refresh(olderThan:90); store.refresh(force:true)
let nc = NSWorkspace.shared.notificationCenter
nc.post(name:NSWorkspace.willSleepNotification,object:nil)
nc.post(name:NSWorkspace.didWakeNotification,object:nil)
store.connectMuse(); store.gateSchedule()
check("startup hover force wake and schedule never queue Muse", !store.busy.contains(.muse) && !store.gatePoll(true,nil) && !store.gatePoll(false,90))
store.gateArm(); store.connectMuse(); store.gateSchedule()
let deadline = Date().addingTimeInterval(1)
while Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
check("manual Connect remains inert even with synthetic enabled internal state", gateReads == 0 && gateHTTP == 0 && gateWrites == 0 && !store.busy.contains(.muse))
let preview = Store(preview:[.muse:MuseNative.setup])
check("preview drops parked snapshots and has four tray candidates", preview.snaps.isEmpty && preview.installed == Vendor.activeVendors)
let missing = Store(preview:Dictionary(uniqueKeysWithValues:Vendor.allCases.map { ($0,Snapshot.status($0,.missing)) }))
check("missing rows are restricted to four active vendors", missing.installed.isEmpty && Vendor.activeVendors.filter { !missing.installed.contains($0) } == [.claude,.gemini,.codex,.cursor])
print("PASS: \(checks) four-provider Store checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
''')
        binary = temp/'gate'
        build = subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','5',*map(str,sources.glob('*.swift')),'-o',str(binary)],capture_output=True,text=True,timeout=120)
        if build.returncode: print(build.stderr); sys.exit(1)
        overrides = ['-claudePath','/nonexistent/claude','-agyPath','/nonexistent/agy','-codexPath','/nonexistent/codex','-cursorUsagePath',str(temp/'absent.json'),'-musePath','/nonexistent/muse','-museHost','YES','-museDirectQuota','YES','-usageMeterCollector','off']
        result = subprocess.run([str(binary),*overrides],capture_output=True,text=True,timeout=15)
        print(result.stdout,end='')
        if result.returncode: print(result.stderr); sys.exit(result.returncode)
        if app:
            executable = str(Path(app).resolve()/'Contents/MacOS/LimitBar')
            probe = subprocess.run([executable,'--probe',*overrides],capture_output=True,text=True,timeout=30)
            snapshots = json.loads(probe.stdout)
            ok = probe.returncode == 0 and set(snapshots) == {'claude','gemini','codex','cursor'}
            print(('ok   ' if ok else 'FAIL ')+'normal probe has four sources despite enabled legacy defaults')
            if not ok: sys.exit(1)
            # Byte-identical offscreen output proves parked states cannot add a panel, tray or Connect row.
            for missing in (False,True):
                fixture = {v:{'vendor':v,'state':'missing' if missing else 'ok','plan':'','windows':[],'notes':[]} for v in ('claude','gemini','codex','cursor')}
                control = None
                for state in (None,'ok','setup','permissionNeeded','missing'):
                    value = dict(fixture)
                    if state: value['muse'] = {'vendor':'muse','state':state,'plan':'','windows':[],'notes':[]}
                    inp=temp/'preview.json'; inp.write_text(json.dumps(value)); png=temp/'preview.png'
                    rendered=subprocess.run([executable,'--render-preview',str(inp),str(png)],capture_output=True,timeout=30)
                    image=png.read_bytes() if rendered.returncode == 0 else None
                    if state is None: control=image
                    ok=image is not None and image==control
                    print(('ok   ' if ok else 'FAIL ')+('missing' if missing else 'four')+' offscreen unchanged with parked '+str(state))
                    if not ok: sys.exit(1)

four_only(sys.argv[1] if len(sys.argv)>1 else None)
if '--four-only' in sys.argv: sys.exit(0)
with tempfile.TemporaryDirectory(prefix='limitbar-native-') as tmp:
    tmp = Path(tmp).resolve()
    sources = tmp / 'sources'; sources.mkdir()
    for name in ('Model', 'Spawn', 'Fetchers', 'Local', 'Muse', 'Store'):
        text = (root / f'Sources/LimitBar/{name}.swift').read_text()
        if name == 'Model':
            text = text.replace('static let activeVendors: [Vendor] = [.claude, .gemini, .codex, .cursor]', 'static let activeVendors: [Vendor] = Vendor.allCases')
        if name == 'Fetchers':
            start = text.index('    static let cache: String = {')
            end = text.index('    }()', start) + len('    }()')
            text = text[:start] + '    static let cache: String = ' + json.dumps(str(tmp/'cache')) + text[end:]
        if name == 'Store':
            text += '''
extension Store {
    func fixtureNative(_ client: MuseNative.Client, persist: @escaping (Bool) -> Void) {
        museActionsAllowed = true; museClient = client; persistMuse = persist
    }
    func fixtureFloor(_ age: Double?) { lastMuseCompletion = age.map { ProcessInfo.processInfo.systemUptime - $0 } }
    func fixtureSource() -> Bool { museSource == .direct }
    func fixtureShouldPoll(_ force: Bool, _ hover: Double?) -> Bool { shouldPoll(.muse, force: force, olderThan: hover) }
    func fixtureBackground() -> Snapshot {
        queue.sync { fetch(.muse, prev: nil, force: true, collectorNote: nil, museEnabled: museSource == .direct) }
    }
    func fixtureApply(_ snapshot: Snapshot) { apply(.muse, snapshot) }
}
'''
        (sources/f'{name}.swift').write_text(text)
    (sources/'main.swift').write_text((root/'tests/native-muse.swift').read_text())
    build = subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','5',*map(str,sources.glob('*.swift')),'-o',str(tmp/'test')],capture_output=True,text=True,timeout=120)
    if build.returncode:
        print(build.stderr); sys.exit(1)
    result = subprocess.run([str(tmp/'test'),str(tmp)],capture_output=True,text=True,timeout=120)
    # Only fixed check labels leave this harness; synthetic secret/identity markers are never printed.
    if any(x in result.stdout+result.stderr for x in ('NATIVE_FAKE_TOKEN', 'NATIVE_FAKE_EMAIL', 'NATIVE_FAKE_KEY')):
        print('FAIL output contains synthetic private marker'); sys.exit(1)
    print(result.stdout,end='')
    if result.returncode: print('FAIL native harness exit',result.returncode)
    if result.returncode: sys.exit(result.returncode)
    if len(sys.argv) > 1:
        app = Path(sys.argv[1]).resolve() / 'Contents/MacOS/LimitBar'
        cmd = [str(app), '--probe', '-claudePath', '/nonexistent/claude', '-agyPath', '/nonexistent/agy',
               '-codexPath', '/nonexistent/codex', '-cursorUsagePath', str(tmp/'absent-usage.json'),
               '-musePath', '/nonexistent/muse', '-museHost', 'YES', '-museDirectQuota', 'YES']
        probe = subprocess.run(cmd,capture_output=True,text=True,timeout=30)
        try:
            snaps = json.loads(probe.stdout)
            ok = (probe.returncode == 0 and set(snaps) == {'claude','codex','gemini','cursor'}
                  and all(snaps[v]['state'] == 'missing' for v in snaps))
        except Exception: ok = False
        print(('ok   ' if ok else 'FAIL ') + 'default probe ignores native/host opt-ins with every source overridden')
        if not ok: sys.exit(1)
    sys.exit(0)
