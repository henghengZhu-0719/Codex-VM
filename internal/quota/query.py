import datetime, json, os, shutil, subprocess, urllib.error, urllib.request

SUPPORTED = ('codex', 'agy', 'claude')
targets = [a for a in [] if a in SUPPORTED]
env_path = os.path.expanduser('~/.local/bin') + ':' + os.path.expanduser('~/.claude/local/bin') + ':' + os.environ.get('PATH', '')

if not targets:
    sel_file = os.path.expanduser('~/.config/agent-vm-selected-agents')
    if os.path.isfile(sel_file):
        try:
            raw = open(sel_file).read().strip()
            targets = [x.strip() for x in raw.split(',') if x.strip() in SUPPORTED]
        except Exception:
            pass
    if not targets:
        has_codex = bool(shutil.which('codex', path=env_path))
        has_agy = bool(shutil.which('agy', path=env_path))
        has_claude = bool(shutil.which('claude', path=env_path))
        if has_codex and (os.path.exists(os.path.expanduser('~/.codex/auth.json')) or (not has_agy and not has_claude)):
            targets.append('codex')
        if has_agy:
            targets.append('agy')
        if has_claude:
            targets.append('claude')

def iso_to_epoch_and_left(iso_str):
    if not iso_str or not isinstance(iso_str, str):
        return None, None
    try:
        dt = datetime.datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        epoch = int(dt.timestamp())
        left = max(0, int(epoch - datetime.datetime.now(datetime.timezone.utc).timestamp()))
        return epoch, left
    except Exception:
        return None, None

def query_codex():
    p = os.path.expanduser('~/.codex/auth.json')
    if not os.path.exists(p):
        return {'status': 'not_logged_in'}
    try:
        d = json.load(open(p))
        tok = d.get('tokens', {}).get('access_token', '')
        acc = d.get('tokens', {}).get('account_id', '')
        if not tok:
            return {'status': 'not_logged_in'}
        req = urllib.request.Request('https://chatgpt.com/backend-api/wham/usage', headers={
            'Authorization': 'Bearer ' + tok,
            'ChatGPT-Account-Id': acc,
            'Accept': 'application/json',
            'User-Agent': 'codex-cli/0.169.0',
        })
        with urllib.request.urlopen(req, timeout=10) as r:
            u = json.loads(r.read().decode())
        rl = u.get('rate_limit', {}) or {}
        windows = []
        for key, label in (('primary_window', '5 小时'), ('secondary_window', '每周')):
            w = rl.get(key)
            if isinstance(w, dict) and w.get('used_percent') is not None:
                windows.append({
                    'label': label,
                    'used_percent': int(round(w['used_percent'])),
                    'reset_after_seconds': w.get('reset_after_seconds'),
                    'reset_at': w.get('reset_at'),
                })
        return {'status': 'ok', 'plan_type': u.get('plan_type'), 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Codex 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': 'quota query failed'}

def query_agy():
    p = os.path.expanduser('~/.gemini/antigravity-cli/antigravity-oauth-token')
    if not os.path.exists(p):
        return {'status': 'not_logged_in'}
    def call_api(tok):
        req = urllib.request.Request(
            'https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels',
            data=b'{}',
            headers={
                'Authorization': 'Bearer ' + tok,
                'Content-Type': 'application/json',
                'User-Agent': 'antigravity/1.5.11 linux/arm64',
            },
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read().decode())
    try:
        d = json.load(open(p))
        tok = (d.get('token') or {}).get('access_token', '')
        if not tok:
            return {'status': 'not_logged_in'}
        try:
            body = call_api(tok)
        except urllib.error.HTTPError as e:
            if e.code == 401 and shutil.which('agy', path=env_path):
                subprocess.run(['agy', 'models'], env=dict(os.environ, PATH=env_path), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12)
                d = json.load(open(p))
                tok = (d.get('token') or {}).get('access_token', '')
                body = call_api(tok)
            else:
                raise
        models = body.get('models') or {}
        windows = []
        for label, prefix_tuple in (('Gemini', ('gemini-',)), ('Claude', ('claude-', 'gpt-'))):
            candidates = []
            for mid, info in models.items():
                if not mid.startswith(prefix_tuple):
                    continue
                qi = info.get('quotaInfo') if isinstance(info, dict) else None
                if isinstance(qi, dict) and qi.get('remainingFraction') is not None:
                    candidates.append(qi)
            if candidates:
                chosen = min(candidates, key=lambda q: float(q.get('remainingFraction', 1.0)))
                rem = max(0.0, min(1.0, float(chosen.get('remainingFraction', 1.0))))
                used_pct = max(0, min(100, int(round((1.0 - rem) * 100))))
                epoch, left = iso_to_epoch_and_left(chosen.get('resetTime'))
                windows.append({
                    'label': label,
                    'used_percent': used_pct,
                    'reset_after_seconds': left,
                    'reset_at': epoch,
                })
        plan = d.get('auth_method')
        return {'status': 'ok', 'plan_type': plan, 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Antigravity 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': 'quota query failed'}

def query_claude():
    cred = os.path.expanduser('~/.claude/.credentials.json')
    tok = ''
    plan = None
    if os.path.exists(cred):
        try:
            cd = json.load(open(cred))
            oauth = cd.get('claudeAiOauth') or {}
            tok = oauth.get('accessToken', '')
            plan = oauth.get('subscriptionType')
        except Exception:
            pass
    if not tok:
        cli = shutil.which('claude', path=env_path)
        if cli:
            try:
                out = subprocess.run([cli, 'auth', 'status'], env=dict(os.environ, PATH=env_path), capture_output=True, text=True, timeout=6)
                if out.returncode == 0 and out.stdout.strip().startswith('{'):
                    st = json.loads(out.stdout)
                    if st.get('loggedIn') and st.get('authMethod') not in (None, '', 'none'):
                        return {'status': 'api_key', 'plan_type': st.get('authMethod'), 'error': 'API Key 鉴权无窗口额度'}
            except Exception:
                pass
        return {'status': 'not_logged_in'}
    try:
        req = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
            'Authorization': 'Bearer ' + tok,
            'anthropic-beta': 'oauth-2025-04-20',
            'Accept': 'application/json',
            'User-Agent': 'claude-code/2.1.0',
        })
        with urllib.request.urlopen(req, timeout=10) as r:
            u = json.loads(r.read().decode())
        windows = []
        for key, label in (('five_hour', '5 小时'), ('seven_day', '每周')):
            w = u.get(key)
            if isinstance(w, dict) and w.get('utilization') is not None:
                epoch, left = iso_to_epoch_and_left(w.get('resets_at'))
                windows.append({
                    'label': label,
                    'used_percent': max(0, min(100, int(round(float(w['utilization']))))),
                    'reset_after_seconds': left,
                    'reset_at': epoch,
                })
        return {'status': 'ok', 'plan_type': plan or 'Claude OAuth', 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Claude 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': 'quota query failed'}

handlers = {'codex': query_codex, 'agy': query_agy, 'claude': query_claude}
out = {t: handlers[t]() for t in targets if t in handlers}
print(json.dumps({'agents': out}))
