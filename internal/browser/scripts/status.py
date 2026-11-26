import json, os, shutil, socket, pathlib

chromium = shutil.which('chromium') or shutil.which('chromium-browser') or shutil.which('google-chrome')
websockify = shutil.which('websockify')
xtigervnc = shutil.which('Xtigervnc')
xvfb = shutil.which('Xvfb')
x11vnc = shutil.which('x11vnc')
openbox = shutil.which('openbox')
missing = []
if not chromium: missing.append('chromium')
if not xtigervnc and (not xvfb or not x11vnc):
    if not xvfb: missing.append('xvfb')
    if not x11vnc: missing.append('x11vnc')
if not openbox: missing.append('openbox')
if not websockify or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')

app_running = False
browser_pid = 0
browser_rss_mb = 0
browser_cpu_seconds = 0.0
for d in os.listdir('/proc'):
    if not d.isdigit(): continue
    try:
        if os.stat('/proc/' + d).st_uid != os.getuid(): continue
        raw = open(f'/proc/{d}/cmdline', 'rb').read().decode(errors='ignore')
        args = [x for x in raw.split('\0') if x]
        if any('chromium' in x or 'chrome' in x for x in args[:2]) and '--remote-debugging-port=9222' in args:
            app_running = True
            browser_pid = int(d)
            try:
                for line in open(f'/proc/{d}/status'):
                    if line.startswith('VmRSS:'):
                        browser_rss_mb = int(line.split()[1]) // 1024
                        break
                ticks = os.sysconf('SC_CLK_TCK')
                raw_stat = open(f'/proc/{d}/stat').read().rsplit(')', 1)[1].split()
                browser_cpu_seconds = round((int(raw_stat[11]) + int(raw_stat[12])) / ticks, 2)
            except (OSError, ValueError, IndexError): pass
            break
    except Exception:
        pass

# Account for Chromium's renderer, GPU and utility processes. This is
# observational only; no automatic suspension or termination is performed.
tree_rss_kb = 0
tree_count = 0
if browser_pid:
    parent = {}
    rss = {}
    for d in os.listdir('/proc'):
        if not d.isdigit(): continue
        try:
            if os.stat('/proc/' + d).st_uid != os.getuid(): continue
            stat = open('/proc/' + d + '/stat').read().rsplit(')', 1)[1].split()
            parent[int(d)] = int(stat[1])
            for line in open('/proc/' + d + '/status'):
                if line.startswith('VmRSS:'):
                    rss[int(d)] = int(line.split()[1])
                    break
        except (OSError, ValueError, IndexError):
            continue
    descendants = {browser_pid}
    changed = True
    while changed:
        expanded = descendants | {pid for pid, ppid in parent.items() if ppid in descendants}
        changed = len(expanded) != len(descendants)
        descendants = expanded
    tree_count = len(descendants)
    tree_rss_kb = sum(rss.get(pid, 0) for pid in descendants)

cdp_available = False
if app_running:
    try:
        with socket.create_connection(('127.0.0.1', 9222), timeout=0.4):
            cdp_available = True
    except OSError:
        pass

print(json.dumps({
    'installed': chromium is not None,
    'appRunning': app_running,
    'browserPID': browser_pid,
    'browserRSSMB': browser_rss_mb,
    'browserTreeRSSMB': tree_rss_kb // 1024,
    'browserProcessCount': tree_count,
    'browserCPUSeconds': browser_cpu_seconds,
    'cdpAvailable': cdp_available,
    'mcpInstalled': (pathlib.Path.home() / '.config/agent-vm-browser/agent_vm_browser_mcp.py').is_file(),
    'missing': missing
}))
