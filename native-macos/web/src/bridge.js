export const isRemoteWeb =
  typeof window !== 'undefined' &&
  !window.webkit?.messageHandlers?.agentVM &&
  window.location.protocol.startsWith('http');

export const getRemoteToken = () => {
  try {
    const q = new URLSearchParams(window.location.search).get('token');
    if (q) {
      sessionStorage.setItem('agentvm.remoteToken', q);
      // Remove legacy token links from address bar and browser history.
      const clean = new URL(window.location.href);
      clean.searchParams.delete('token');
      window.history.replaceState(null, '', clean.pathname + clean.search + clean.hash);
      return q;
    }
    return sessionStorage.getItem('agentvm.remoteToken') || '';
  } catch {
    return '';
  }
};

export const bridge = (action, payload = {}) => {
  const host = window.webkit?.messageHandlers?.agentVM;
  if (host) {
    host.postMessage({ action, payload });
    return;
  }
  if (isRemoteWeb) {
    const token = getRemoteToken();
    if (!token) return;
    fetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
      body: JSON.stringify({ action, payload }),
    })
      .then(r => {
        if (r.status === 401) {
          try {
            sessionStorage.removeItem('agentvm.remoteToken');
          } catch {}
          window.__agentVMRemoteAuthFail?.();
          return;
        }
        if (!r.ok) {
          return r.text().then(t => {
            window.__agentVMRemoteError?.(`操作失败 (${r.status}): ${t || action}`);
          });
        }
        window.__agentVMRemotePull?.();
      })
      .catch(err => {
        window.__agentVMRemoteError?.(`网络请求失败: ${err?.message || '无法连接'}`);
      });
    return;
  }
  console.info('Preview mode:', action, payload);
};

export const agentLabels = {
  codex: 'Codex',
  claude: 'Claude Code',
  agy: 'Antigravity',
  opencode: 'OpenCode',
  vibe: 'Vibe',
  pi: 'Pi',
};

export const agentLabel = id => agentLabels[id] || id;

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let idx = 0;
  let val = bytes;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx++;
  }
  return val.toFixed(idx >= 3 ? 2 : idx >= 1 ? 1 : 0) + ' ' + units[idx];
}

export function formatSubUsage(usage) {
  if (!usage || !usage.includes('total=')) return usage;
  const map = {};
  for (const part of usage.split(';')) {
    const [k, v] = part.split('=').map(s => s.trim());
    if (k && v) map[k] = Number(v);
  }
  const used = (map.upload || 0) + (map.download || 0);
  const total = map.total || 0;
  const parts = [];
  if (total > 0) parts.push(`已用 ${formatBytes(used)} / ${formatBytes(total)}`);
  if (map.expire > 0) {
    const d = new Date(map.expire * 1000);
    if (!Number.isNaN(d.getTime())) parts.push(`到期 ${d.toISOString().slice(0, 10)}`);
  }
  return parts.length ? parts.join(' · ') : usage;
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '';
  const s = Math.floor(seconds);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  if (m < 60) return `${m}m ${rem}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

export function formatRelativeTime(ts) {
  if (!ts) return '';
  const diff = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (diff < 60) return '刚刚';
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  const d = new Date(ts * 1000);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

export async function copyText(text) {
  if (!text) return false;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      return true;
    } catch {
      return false;
    }
  }
}
