import os, pathlib, signal, time
import fcntl
_browser_dir = pathlib.Path.home() / '.config/agent-vm-browser'
_browser_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
_browser_lock = open(_browser_dir / 'lifecycle.lock', 'a')
fcntl.flock(_browser_lock, fcntl.LOCK_EX)

def proc_running(match):
    pids = []
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            args = [x for x in (proc / 'cmdline').read_bytes().decode(errors='ignore').split('\0') if x]
            if match(args): pids.append(int(proc.name))
        except OSError:
            pass
    return pids

def stop_procs(match, wait_sec=3.0):
    pids = proc_running(match)
    if not pids: return
    for pid in pids:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    deadline = time.time() + wait_sec
    while time.time() < deadline:
        if not proc_running(match): return
        time.sleep(0.15)
    for pid in proc_running(match):
        try: os.kill(pid, signal.SIGKILL)
        except OSError: pass

# Stop the managed service first, then clean up any legacy detached browser.
import subprocess, shutil
if shutil.which('systemctl'):
    subprocess.run(['systemctl', '--user', 'stop', 'agent-vm-chromium.service'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)
stop_procs(lambda a: any('websockify' in x for x in a[:3]) and '127.0.0.1:5999' in a)
stop_procs(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a))
stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a)
stop_procs(lambda a: any(('Xtigervnc' in x or 'Xvfb' in x) for x in a[:2]) and ':99' in a)
try:
    in_use_shm = set()
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit(): continue
        try:
            for fd in (p / 'fd').iterdir():
                try:
                    t = os.readlink(fd)
                    if t.startswith('/tmp/.org.chromium.Chromium.'):
                        in_use_shm.add(t)
                except OSError:
                    pass
        except OSError:
            pass
    for item in pathlib.Path('/tmp').glob('.org.chromium.Chromium.*'):
        if str(item) not in in_use_shm:
            try: item.unlink()
            except OSError: pass
except Exception:
    pass
