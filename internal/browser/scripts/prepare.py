import os, pathlib, socket, subprocess, time, json, shutil, hashlib, signal
import fcntl
_browser_dir = pathlib.Path.home() / '.config/agent-vm-browser'
_browser_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
_browser_lock = open(_browser_dir / 'lifecycle.lock', 'a')
fcntl.flock(_browser_lock, fcntl.LOCK_EX)

def emit(obj):
    print(json.dumps(obj), flush=True)

def proc_running(match):
    pids = []
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            args = [x for x in (proc/'cmdline').read_bytes().decode(errors='ignore').split('\0') if x]
            if match(args): pids.append((int(proc.name), args))
        except OSError:
            pass
    return pids

def stop_procs(match, wait_sec=3.5):
    targets = proc_running(match)
    if not targets: return
    for pid, _ in targets:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    deadline = time.time() + wait_sec
    while time.time() < deadline:
        if not proc_running(match): return
        time.sleep(0.15)
    for pid, _ in proc_running(match):
        try: os.kill(pid, signal.SIGKILL)
        except OSError: pass
    time.sleep(0.2)

def ensure_download_prefs(profile_dir):
    try:
        dl = pathlib.Path('/mnt/agent-vm-shared/Downloads')
        dl.mkdir(parents=True, exist_ok=True)
        default_dir = profile_dir / 'Default'
        default_dir.mkdir(parents=True, exist_ok=True)
        pref_path = default_dir / 'Preferences'
        prefs = {}
        if pref_path.exists():
            try: prefs = json.loads(pref_path.read_text())
            except Exception: prefs = {}
        prefs.setdefault('download', {})['default_directory'] = str(dl)
        prefs.setdefault('download', {})['prompt_for_download'] = False
        pref_path.write_text(json.dumps(prefs))
    except Exception:
        pass

try:
    emit({'stage': 'checking', 'message': '正在检查 Chromium 与 VNC 组件…'})
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
    if missing:
        msg = '此虚拟机缺少浏览器组件：' + ', '.join(missing)
        emit({'error': msg, 'missing': missing})
        raise SystemExit(1)

    scale = max(1.0, min(2.0, float(settings.get('scale', 2.0))))
    w = max(800, min(4096, int(settings.get('width', 2560)) // 2 * 2))
    h = max(500, min(2560, int(settings.get('height', 1600)) // 2 * 2))
    restart_app = bool(settings.get('restartApp', False))

    log_dir = pathlib.Path.home() / '.config/agent-vm-browser'
    log_dir.mkdir(parents=True, exist_ok=True)
    profile_dir = log_dir / 'profile'
    profile_dir.mkdir(parents=True, exist_ok=True)
    # Chromium profiles contain authenticated sessions. Never expose them to other guest users.
    os.chmod(log_dir, 0o700)
    os.chmod(profile_dir, 0o700)
    ensure_download_prefs(profile_dir)
    try:
        fc_dir = pathlib.Path.home() / '.config/fontconfig'
        fc_file = fc_dir / 'fonts.conf'
        existing_fc = fc_file.read_text(errors='ignore') if fc_file.exists() else ''
        if 'Noto Sans CJK SC' not in existing_fc or 'hintslight' not in existing_fc or 'rgba' not in existing_fc:
            fc_dir.mkdir(parents=True, exist_ok=True)
            fc_file.write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>none</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>
  </match>
  <alias><family>sans-serif</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Noto Serif CJK SC</family><family>DejaVu Serif</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Noto Sans Mono CJK SC</family><family>DejaVu Sans Mono</family></prefer></alias>
</fontconfig>
''')
            subprocess.run(['fc-cache', '-f'], capture_output=True)
    except Exception:
        pass
    env = dict(os.environ, DISPLAY=':99', LANG='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
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
    shared_cwd = None
    try:
        shared_dir = pathlib.Path('/mnt/agent-vm-shared')
        if shared_dir.is_dir():
            shared_cwd = str(shared_dir)
            for link_name in ('共享文件夹', 'Shared'):
                link = pathlib.Path.home() / link_name
                if not link.exists() and not link.is_symlink():
                    link.symlink_to(shared_dir)
            bm_entries = [f'file://{shared_dir} 共享文件夹']
            mnt_root = pathlib.Path('/mnt')
            if mnt_root.is_dir():
                for child in sorted(mnt_root.iterdir()):
                    if child.name in ('agent-vm-shared', 'lima-cidata') or not child.is_dir():
                        continue
                    bm_entries.append(f'file://{child} {child.name}')
            for gtk_ver in ('gtk-3.0', 'gtk-4.0'):
                bm_dir = pathlib.Path.home() / '.config' / gtk_ver
                bm_dir.mkdir(parents=True, exist_ok=True)
                bm_file = bm_dir / 'bookmarks'
                existing_bm = bm_file.read_text(errors='ignore').splitlines() if bm_file.exists() else []
                existing_bm = [line for line in existing_bm if line.strip() and not line.startswith('file:///mnt/')]
                bm_file.write_text('\n'.join(bm_entries + existing_bm) + '\n')
    except Exception:
        pass

    use_tiger = bool(xtigervnc)
    if use_tiger and proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a):
        stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)
        stop_procs(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a))
        stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a)
        stop_procs(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a)

    if restart_app:
        if shutil.which('systemctl'):
            subprocess.run(['systemctl', '--user', 'stop', 'agent-vm-chromium.service'],
                           capture_output=True, timeout=8)
        stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)

    emit({'stage': 'display', 'message': f'正在启动虚拟显示 ({w}×{h})…'})
    if use_tiger:
        if not proc_running(lambda a: any('Xtigervnc' in x for x in a[:2]) and ':99' in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen([
                    xtigervnc, ':99', '-localhost', '-rfbport', '5999',
                    '-SecurityTypes', 'None', '-geometry', f'{w}x{h}', '-depth', '24',
                    '-dpi', str(int(round(scale * 96))), '-FrameRate=60', '-CompareFB=1',
                    '-AcceptSetDesktopSize=1', '-AlwaysShared=1'
                ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.45)
    elif not proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a):
        with open(log_dir / 'xvfb.log', 'ab') as f:
            subprocess.Popen(['Xvfb', ':99', '-screen', '0', f'{w}x{h}x24', '-nolisten', 'tcp', '+extension', 'RANDR'],
                             stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.45)

    if not proc_running(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a)):
        ob_rc = log_dir / 'openbox-rc.xml'
        ob_rc.write_text('''<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
''')
        with open(log_dir / 'openbox.log', 'ab') as f:
            subprocess.Popen(['openbox', '--config-file', str(ob_rc)], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.25)

    emit({'stage': 'chromium', 'message': '正在启动 Chromium 浏览器…'})
    if not proc_running(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a):
        with open(log_dir / 'chromium.log', 'ab') as f:
            browser_args = [
                chromium, '--no-sandbox', '--test-type', '--disable-dev-shm-usage',
                '--disable-gpu', '--ozone-platform=x11',
                f'--force-device-scale-factor={scale:g}',
                # Keep active agent pages alive, but allow Chromium to throttle idle tabs.
                '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
                '--no-first-run', '--no-default-browser-check',
                # CDP is a privileged browser-control interface: bind only inside the guest.
                '--remote-debugging-address=127.0.0.1',
                '--remote-debugging-port=9222',
                '--user-data-dir=' + str(profile_dir),
                f'--window-size={w},{h}',
                '--start-maximized'
            ]
            # A transient user service survives workbench disconnections and provides
            # restart-on-failure. When the user manager is unavailable (minimal guests),
            # retain the previous detached-process implementation.
            systemd_run = shutil.which('systemd-run')
            managed = False
            if systemd_run and pathlib.Path('/run/user/' + str(os.getuid()) + '/bus').exists():
                service_cmd = [
                    systemd_run, '--user', '--unit=agent-vm-chromium',
                    '--collect', '--property=Restart=on-failure',
                    '--property=RestartSec=3s',
                    '--property=TimeoutStopSec=8s',
                    '--setenv=DISPLAY=:99',
                    '--setenv=LANG=en_US.UTF-8',
                ] + ([f'--working-directory={shared_cwd}'] if shared_cwd else []) + [
                    '--'
                ] + browser_args
                attempt = subprocess.run(service_cmd, env=env, capture_output=True, text=True, timeout=8)
                managed = attempt.returncode == 0
                if not managed:
                    f.write(('systemd-run fallback: ' + attempt.stderr + '\\n').encode())
            if not managed:
                subprocess.Popen(browser_args, env=env, cwd=shared_cwd, stdin=subprocess.DEVNULL,
                                 stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.8)

    emit({'stage': 'vnc', 'message': '正在启动 noVNC 画面服务…'})
    if not use_tiger and not proc_running(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a):
        with open(log_dir / 'x11vnc.log', 'ab') as f:
            subprocess.Popen([
                'x11vnc', '-display', ':99', '-localhost', '-rfbport', '5999',
                '-forever', '-shared', '-nopw', '-quiet',
                '-xrandr', 'resize', '-noxdamage', '-wait', '10', '-defer', '10'
            ], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.25)

    port = None
    existing = proc_running(lambda a: any('websockify' in x for x in a[:3]) and '127.0.0.1:5999' in a)
    if existing:
        for arg in existing[0][1]:
            if arg.startswith('127.0.0.1:') and arg != '127.0.0.1:5999':
                try:
                    port = int(arg.split(':', 1)[1])
                    break
                except ValueError:
                    pass

    if port is None:
        number = int(hashlib.sha256(settings['name'].encode()).hexdigest()[:4], 16)
        for candidate in range(21000 + number % 9991, 21010 + number % 9991):
            with socket.socket() as probe:
                try: probe.bind(('127.0.0.1', candidate))
                except OSError: continue
            port = candidate
            break
        if port is None:
            raise RuntimeError('没有可用的浏览器端口。')
        with open(log_dir / 'novnc.log', 'ab') as f:
            subprocess.Popen([
                websockify, '--web=/usr/share/novnc',
                '127.0.0.1:' + str(port), '127.0.0.1:5999'
            ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)

    for _ in range(40):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.3):
                break
        except OSError:
            time.sleep(0.25)
    else:
        raise RuntimeError('noVNC 启动超时。')

    emit({'port': port, 'resolution': f'{w}x{h}'})
except SystemExit:
    raise
except Exception as error:
    emit({'error': str(error)})
    raise SystemExit(1)
