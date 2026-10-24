"""LimitBar's usage-meter refresh helper (local addition, see LOCAL-ADAPTERS.md).

Does what the SwiftBar plugin `usage-meter.5m.py` does, minus the menu-bar text: imports the user's own
usage-meter `collect.py`, then `collect_snapshot()` + `write_snapshot()`, so the agents' usage.json keeps its
exact paths and shape. Two guards reduce redundant work and coordinate helper invocations only:

- fresh-skip: when the newest existing usage.json was checked less than --min-age seconds ago, nothing runs;
- locked-skip: an exclusive lock (--lock) is held for the whole run.

The legacy SwiftBar plugin uses neither guard. Disable it FIRST and wait for its in-flight collection
before enabling this helper; fresh-skip and this lock cannot prevent overlap with that plugin.

Prints one JSON line: {"status": <word>, "written": <n>, "known_pools": <n>}. Never paths, percentages,
identifiers or anything the collector says; the collector's own stdout and stderr go to /dev/null.
Run with `python3 -I -B` (LimitBar does): no user site, no PYTHONPATH, no bytecode written.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import datetime
import errno
import fcntl
import importlib.util
import json
import os
import stat
import sys


def acl_grants_write(path: str) -> bool:
    """Darwin extended ALLOW write/delete/security ACLs, matching CLI.aclGrantsWrite (fail closed)."""
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        ptr = ctypes.c_void_p
        libc.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
        libc.acl_get_link_np.restype = ptr
        libc.acl_free.argtypes = [ptr]
        libc.acl_get_entry.argtypes = [ptr, ctypes.c_int, ctypes.POINTER(ptr)]
        libc.acl_get_tag_type.argtypes = [ptr, ctypes.POINTER(ctypes.c_int)]
        libc.acl_get_permset.argtypes = [ptr, ctypes.POINTER(ptr)]
        libc.acl_get_perm_np.argtypes = [ptr, ctypes.c_uint32]
        ctypes.set_errno(0)
        acl = libc.acl_get_link_np(os.fsencode(path), 0x100)  # ACL_TYPE_EXTENDED
        if not acl:
            return ctypes.get_errno() != errno.ENOENT  # Darwin sets ENOENT when no extended ACL exists
        try:
            entry, which = ptr(), 0  # ACL_FIRST_ENTRY; ACL_NEXT_ENTRY = -1
            while True:
                ctypes.set_errno(0)
                rc = libc.acl_get_entry(acl, which, ctypes.byref(entry))
                if rc != 0:
                    return not (rc == -1 and ctypes.get_errno() == errno.EINVAL)
                if not entry:
                    return True
                which = -1
                tag, perms = ctypes.c_int(), ptr()
                if libc.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                    return True
                if tag.value != 1:  # ACL_EXTENDED_ALLOW
                    continue
                if libc.acl_get_permset(entry, ctypes.byref(perms)) != 0 or not perms:
                    return True
                for bit in (2, 4, 5, 6, 8, 10, 12, 13):
                    result = libc.acl_get_perm_np(perms, 1 << bit)
                    if result != 0:
                        return True
        finally:
            libc.acl_free(acl)
    except (OSError, AttributeError):
        return True


@contextlib.contextmanager
def quiet_collector():
    """Suppress Python, os.write and inherited subprocess output; restore only for our fixed JSON."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved = [os.dup(1), os.dup(2)]
    try:
        with open(os.devnull, "w") as sink:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
            with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                yield
    finally:
        for fd, original in zip((1, 2), saved):
            os.dup2(original, fd)
            os.close(original)


def say(status: str, **extra: int) -> int:
    print(json.dumps(dict(status=status, **extra)))
    return 0 if status in ("refreshed", "fresh-skip", "locked-skip") else 1


def safe_node(path: str, uid: int) -> bool:
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if st.st_uid not in (uid, 0):
        return False
    if st.st_mode & stat.S_IWOTH:
        return False
    if st.st_mode & stat.S_IWGRP and st.st_gid not in (0, 80):   # 80 = admin, as in LimitBar's CLI.safeNode
        return False
    return not acl_grants_write(path)


def trusted_collector(path: str) -> bool:
    """A regular file of this user that nobody else can change, in folders nobody else can change."""
    uid = os.getuid()
    if not os.path.isabs(path):
        return False
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if (not stat.S_ISREG(st.st_mode) or st.st_uid != uid
            or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH) or acl_grants_write(path)):
        return False
    cur = os.path.dirname(path)
    while True:
        if not safe_node(cur, uid):
            return False
        if cur == "/":
            return True
        cur = os.path.dirname(cur)


def checked_age(paths: list, now: float) -> float | None:
    """Age in seconds of the newest valid `checked_at` among the existing snapshot files."""
    best = None
    for p in paths:
        try:
            with open(p, encoding="utf-8") as handle:
                data = json.load(handle)
            text = data.get("checked_at")
            if not isinstance(text, str):
                continue
            at = datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
        except (OSError, ValueError, AttributeError, TypeError):
            continue
        age = now - at
        if best is None or age < best:
            best = age
    return best


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--collector", required=True)
    ap.add_argument("--min-age", type=float, default=240)
    ap.add_argument("--lock", required=True)
    args = ap.parse_args(argv)
    sys.dont_write_bytecode = True

    collector = os.path.realpath(args.collector)
    if (os.path.basename(collector) != "collect.py" or not trusted_collector(args.collector)
            or not trusted_collector(collector)):
        return say("untrusted")

    fd = os.open(args.lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return say("locked-skip")
        with quiet_collector():
            try:
                spec = importlib.util.spec_from_file_location("collect", collector)
                module = importlib.util.module_from_spec(spec)
                sys.modules["collect"] = module
                spec.loader.exec_module(module)
                paths = [str(p) for p in module.USAGE_JSON_PATHS]
            except Exception:
                status = "import-failed"
            else:
                age = checked_age(paths, datetime.datetime.now(datetime.timezone.utc).timestamp())
                if age is not None and 0 <= age < args.min_age:
                    status = "fresh-skip"
                else:
                    try:
                        module._ensure_path()
                        snapshot = module.collect_snapshot()
                    except Exception:
                        status = "collect-failed"
                    else:
                        try:
                            written = module.write_snapshot(snapshot)
                        except Exception:
                            status = "write-failed"
                        else:
                            pools = snapshot.get("pools") or {}
                            known = sum(1 for v in pools.values() if isinstance(v, dict) and v.get("used_percent") is not None)
                            status = "refreshed" if written else "write-failed"
                            counts = dict(written=len(written), known_pools=known)
        return say(status, **(counts if status == "refreshed" else {}))
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
