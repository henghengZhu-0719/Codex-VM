import React, { useEffect, useRef } from 'react';
import { AppWindow, Monitor, MoreHorizontal, Play, Square, Terminal, Globe } from 'lucide-react';
import { bridge, agentLabel } from '../bridge.js';

export function IconButton({ title, children, onClick, disabled = false, danger = false }) {
  return (
    <button
      className={'icon-button ' + (danger ? 'danger' : '')}
      title={title}
      aria-label={title}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}

export function MoreMenu({ children }) {
  const menu = useRef(null);
  useEffect(() => {
    const closeOutside = event => {
      if (menu.current?.open && !menu.current.contains(event.target)) menu.current.open = false;
    };
    const closeEscape = event => {
      if (event.key === 'Escape' && menu.current?.open) {
        menu.current.open = false;
        menu.current.querySelector('summary')?.focus();
      }
    };
    document.addEventListener('pointerdown', closeOutside, true);
    document.addEventListener('keydown', closeEscape);
    return () => {
      document.removeEventListener('pointerdown', closeOutside, true);
      document.removeEventListener('keydown', closeEscape);
    };
  }, []);
  const closeAction = event => {
    const button = event.target.closest('button');
    if (button && !button.disabled) menu.current.open = false;
  };
  return (
    <details ref={menu} className="card-more">
      <summary title="更多操作" aria-label="更多操作">
        <MoreHorizontal size={17} />
      </summary>
      <div className="more-menu" onClick={closeAction}>
        {children}
      </div>
    </details>
  );
}

export function KV({ name, value }) {
  return (
    <div className="key-value">
      <span>{name}</span>
      <strong>{value ?? '—'}</strong>
    </div>
  );
}

export function QuotaBar({ label, window: win }) {
  const left = win ? Math.max(0, Math.min(100, 100 - (win.used_percent ?? 100))) : null;
  return (
    <div className="quota-bar">
      <div className="flex-between">
        <span>{label}</span>
        <strong>{left === null ? '未知' : left + '%'}</strong>
      </div>
      <div className="bar">
        <div style={{ width: (left ?? 0) + '%' }} className={left !== null && left <= 15 ? 'low' : ''} />
      </div>
      <small>{win?.reset_after_seconds ? '约 ' + Math.ceil(win.reset_after_seconds / 3600) + ' 小时后重置' : ''}</small>
    </div>
  );
}

export function QuotaChip({ label, win, compact = false }) {
  const left = win ? Math.max(0, Math.min(100, 100 - (win.used_percent ?? 100))) : null;
  const tone = left === null ? '' : left <= 15 ? 'low' : left <= 35 ? 'mid' : 'ok';
  return (
    <div className={'quota-chip ' + tone + (compact ? ' compact' : '')}>
      <div className="quota-chip-top">
        <span>{label}</span>
        <strong>{left === null ? '—' : left + '%'}</strong>
      </div>
      <div className="quota-chip-bar">
        <div style={{ width: (left ?? 0) + '%' }} />
      </div>
    </div>
  );
}

export function SectionTitle({ title, sub, children }) {
  return (
    <div className="heading">
      <div>
        <h1>{title}</h1>
        {sub ? <p>{sub}</p> : null}
      </div>
      <div className="heading-actions">{children}</div>
    </div>
  );
}

const QUOTA_APPS = ['codex', 'agy', 'claude'];

export function quotaStatusText(q) {
  if (!q) return '查询中…';
  if (q.status === 'not_logged_in') return '未登录';
  if (q.status === 'unauthorized') return '登录已过期';
  if (q.status === 'api_key') return q.plan_type ? `${q.plan_type}（按量）` : 'API Key';
  if (q.status === 'error') return q.error || '查询失败';
  return '';
}

export function VMCard({ vm, state, select }) {
  const running = vm.status === 'Running';
  const editor = state.editors?.[vm.name];
  const agentQuotas = state.agentQuotas?.[vm.name] || {};
  const legacyQuota = state.quotas[vm.name];
  const usage = state.usage[vm.name];
  const rawAgents = state.agents?.[vm.name];
  const hasAgents = Array.isArray(rawAgents);
  const quotaApps = hasAgents
    ? QUOTA_APPS.filter(a => rawAgents.includes(a))
    : Object.keys(agentQuotas).filter(a => QUOTA_APPS.includes(a));
  const hasCodex = quotaApps.includes('codex');
  const hasClaude = quotaApps.includes('claude');
  const hasAgy = quotaApps.includes('agy');
  const agentBusy = (state.codex?.runningVMs || []).includes(vm.name);
  const name = vm.displayName || vm.name;
  const routeNode = state.vmProxyRoutes?.[vm.name]
    ? (state.proxy?.sources || []).flatMap(s => s.nodes || []).find(n => n.id === state.vmProxyRoutes[vm.name])?.name ||
      state.vmProxyRoutes[vm.name]
    : '';

  return (
    <article className="vm-card">
      <div className="vm-head">
        <div className="vm-glyph">
          <Monitor size={18} />
        </div>
        <div className="vm-name">
          <strong title={name}>{name}</strong>
          {!vm.standalone && vm.projectPath && <span title={vm.projectPath}>{vm.projectPath}</span>}
        </div>
        <div className={'status ' + (running ? 'running' : '')}>
          <span className="status-dot" />
          {running ? (agentBusy ? '执行中' : '运行中') : vm.status === 'Stopped' ? '已停止' : vm.status}
        </div>
      </div>

      <div className="metrics metrics-3">
        <div>
          <span>CPU</span>
          <strong>{running && usage ? usage.cpu.toFixed(1) + '%' : '—'}</strong>
        </div>
        <div>
          <span>内存</span>
          <strong>{running && usage ? Math.round(usage.used) + '/' + Math.round(usage.total) + ' MB' : '—'}</strong>
        </div>
        <div>
          <span>存储</span>
          <button
            type="button"
            className="metric-action"
            onClick={() => select({ type: 'resizeDisk', vm })}
            disabled={state.busy}
            title="扩容磁盘"
          >
            <strong>{vm.disk || '—'}</strong>
            <small>扩容</small>
          </button>
        </div>
      </div>

      {quotaApps.length > 0 && (
        <div className="vm-quota-list">
          {quotaApps.map(app => {
            const q =
              agentQuotas[app] ||
              (app === 'codex' && legacyQuota
                ? {
                    ...legacyQuota,
                    windows: [
                      legacyQuota.five_hour ? { label: '5h', ...legacyQuota.five_hour } : null,
                      legacyQuota.weekly ? { label: '7d', ...legacyQuota.weekly } : null,
                    ].filter(Boolean),
                  }
                : null);
            const wins = q?.status === 'ok' ? q.windows || [] : [];
            return (
              <div className="quota-inline" key={app}>
                <span className="vm-meta-agents">{agentLabel(app)}</span>
                {wins.length > 0 ? (
                  <div className="quota-chips">
                    {wins.map((w, idx) => (
                      <QuotaChip
                        key={w.label || idx}
                        label={w.label === '5 小时' ? '5h' : w.label === '每周' ? '7d' : w.label || String(idx + 1)}
                        win={w}
                        compact
                      />
                    ))}
                  </div>
                ) : (
                  <span className="muted text-xs">{running ? quotaStatusText(q) : '已停止'}</span>
                )}
              </div>
            );
          })}
        </div>
      )}

      {((running && (editor?.status === 'ready' || editor?.status === 'error')) || routeNode) && (
        <div className="vm-sub-links">
          {running && editor?.status === 'ready' && (
            <button className="web-code-link" onClick={() => bridge('codeOpen', { name: vm.name })}>
              {editor.url}
            </button>
          )}
          {running && editor?.status === 'error' && (
            <button className="web-code-retry" title={editor.error} onClick={() => bridge('codeRetry', { name: vm.name })}>
              Web Code 重试
            </button>
          )}
          {routeNode && (
            <button className="web-code-link" onClick={() => select({ type: 'proxyRoute', vm })}>
              出口 · {routeNode}
            </button>
          )}
        </div>
      )}

      <div className="card-actions">
        {hasCodex && (
          <button
            className="primary"
            style={{ padding: '7px 11px', minHeight: '31px' }}
            onClick={() => select({ type: 'codexDesktopOpen', vm })}
            disabled={!running}
          >
            <AppWindow size={14} /> Codex 桌面
          </button>
        )}
        <button
          className={hasCodex ? 'secondary' : 'primary'}
          style={hasCodex ? undefined : { padding: '7px 11px', minHeight: '31px' }}
          onClick={() => select({ type: 'browserOpen', vm })}
          disabled={!running || state.browsers?.[vm.name]?.status === 'starting'}
          title="在应用内打开 Linux 浏览器"
        >
          <Globe size={15} /> {state.browsers?.[vm.name]?.status === 'starting' ? '启动中…' : '浏览器'}
        </button>
        <button className="secondary" onClick={() => bridge('terminal', { name: vm.name })} disabled={!running}>
          <Terminal size={15} /> 终端
        </button>
        <div className="flex-fill" />
        <MoreMenu>
          <button disabled={!running || editor?.status !== 'ready'} onClick={() => bridge('codeOpen', { name: vm.name })}>
            打开 Web Code
          </button>
          {hasCodex && (
            <button disabled={!running} onClick={() => bridge('resume', { name: vm.name, agent: 'codex' })}>
              恢复 Codex 终端会话
            </button>
          )}
          {hasClaude && (
            <button disabled={!running} onClick={() => bridge('resume', { name: vm.name, agent: 'claude' })}>
              恢复 Claude 终端会话
            </button>
          )}
          {hasAgy && (
            <button disabled={!running} onClick={() => bridge('resume', { name: vm.name, agent: 'agy' })}>
              打开 Antigravity
            </button>
          )}
          <button onClick={() => select({ type: 'rename', vm })}>修改名称</button>
          <button onClick={() => select({ type: 'resizeDisk', vm })} disabled={state.busy}>
            调整磁盘容量
          </button>
          <button onClick={() => select({ type: 'mounts', vm })}>管理共享文件夹</button>
          <button onClick={() => select({ type: 'proxyRoute', vm })}>代理出口</button>
          {quotaApps.length > 0 && (
            <button onClick={() => bridge('quota', { name: vm.name })} disabled={!running}>
              刷新额度
            </button>
          )}
          <button className="danger-text" onClick={() => select({ type: 'delete', vm })} disabled={state.busy}>
            删除虚拟机
          </button>
        </MoreMenu>
        <IconButton
          title={running ? '停止虚拟机' : '启动虚拟机'}
          disabled={state.busy || (!running && vm.status !== 'Stopped')}
          onClick={() => select({ type: running ? 'stop' : 'start', vm })}
        >
          {running ? <Square size={16} /> : <Play size={16} />}
        </IconButton>
      </div>
    </article>
  );
}
