import React, { useEffect, useRef, useState } from 'react';
import {
  AlertTriangle,
  AppWindow,
  ArrowLeft,
  CheckCircle2,
  Download,
  HardDrive,
  LoaderCircle,
  Monitor,
  Play,
  RefreshCw,
  Wrench,
} from 'lucide-react';
import { bridge } from '../../bridge.js';

const DESKTOP_APPS = {
  codex: {
    id: 'codex',
    label: 'Codex 官方桌面',
    shortLabel: 'Codex',
    desc: 'OpenAI 官方 Linux 桌面端（chatgpt）',
    pkg: 'chatgpt',
    pkgLabel: 'Codex 桌面客户端',
    sizeHint: '~1.8 GB',
    display: ':98',
    configDir: '~/.config/agent-vm-codex-desktop',
  },
  claude: {
    id: 'claude',
    label: 'Claude Code 官方桌面',
    shortLabel: 'Claude Code',
    desc: 'Anthropic 官方 Linux 桌面端（claude-desktop）',
    pkg: 'claude-desktop',
    pkgLabel: 'Claude Code 桌面客户端',
    sizeHint: '~200 MB',
    display: ':97',
    configDir: '~/.config/agent-vm-claude-desktop',
  },
};

export default function CodexDesktopPage({
  state,
  codexVMs,
  desktopVM,
  desktopApp = '',
  onSelectDesktopApp,
  sidebarCollapsed,
  modalOpen,
  onOpenPicker,
  onResizeDisk,
  onNavigateTab,
}) {
  const [logsOpen, setLogsOpen] = useState(false);

  const slotRef = useRef(null);
  const installLogRef = useRef(null);
  const lastSlotKeyRef = useRef('');
  const lastResizeRef = useRef({ w: 0, h: 0 });

  const appMeta = desktopApp ? DESKTOP_APPS[desktopApp] : null;
  const stateKey = desktopVM && appMeta ? `${desktopVM}::${appMeta.id}` : '';
  const desktop = (stateKey && state.codexDesktops?.[stateKey]) || {};
  const isReady = !!appMeta && desktop.status === 'ready';
  const autoResize = desktop.autoResize !== false;

  const codexState = desktopVM ? state.codexDesktops?.[`${desktopVM}::codex`] || {} : {};
  const claudeState = desktopVM ? state.codexDesktops?.[`${desktopVM}::claude`] || {} : {};
  const anyInstalling = !!codexState.installing || !!claudeState.installing;

  // Check both apps' status (read-only) whenever desktopVM is active
  useEffect(() => {
    if (!desktopVM || modalOpen) return;
    bridge('codexDesktopCheck', { name: desktopVM, app: 'codex' });
    bridge('codexDesktopCheck', { name: desktopVM, app: 'claude' });
  }, [desktopVM, modalOpen]);

  // If user is on hub (no app selected) and one app is already ready/installing, don't force switch unless user clicks.
  // If an app IS selected and already ready, sync native selection.
  useEffect(() => {
    if (!desktopVM || !appMeta || modalOpen) return;
    const st = state.codexDesktops?.[`${desktopVM}::${appMeta.id}`]?.status;
    if (st === 'ready') {
      bridge('codexDesktopSelect', { name: desktopVM, app: appMeta.id });
    }
  }, [desktopVM, appMeta?.id, modalOpen]);

  useEffect(() => {
    if (desktop.installing && installLogRef.current) {
      installLogRef.current.scrollTop = installLogRef.current.scrollHeight;
    }
  }, [desktop.installOutput, desktop.installing]);

  // Sync native WKWebView slot geometry to fill 100% of the container
  useEffect(() => {
    const el = slotRef.current;
    const showNative = !modalOpen && !logsOpen && !!desktopVM && !!appMeta && isReady;

    const sendSlot = payload => {
      const key = JSON.stringify(payload);
      if (lastSlotKeyRef.current === key) return;
      lastSlotKeyRef.current = key;
      bridge('codexDesktopSlot', payload);
    };

    const sync = () => {
      if (!showNative || !el) {
        sendSlot({ visible: false, x: 0, y: 0, width: 0, height: 0 });
        return;
      }
      const r = el.getBoundingClientRect();
      const w = Math.round(r.width);
      const h = Math.round(r.height);
      sendSlot({
        visible: w > 20 && h > 20,
        x: Math.round(r.left),
        y: Math.round(r.top),
        width: w,
        height: h,
      });
      if (
        autoResize &&
        w >= 400 &&
        h >= 300 &&
        (w !== lastResizeRef.current.w || h !== lastResizeRef.current.h)
      ) {
        lastResizeRef.current = { w, h };
        bridge('codexDesktopResize', { name: desktopVM, app: appMeta.id, width: w, height: h });
      }
    };

    sync();
    if (!showNative || !el) return;
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    window.addEventListener('resize', sync);
    return () => {
      ro.disconnect();
      window.removeEventListener('resize', sync);
      sendSlot({ visible: false, x: 0, y: 0, width: 0, height: 0 });
    };
  }, [modalOpen, logsOpen, desktopVM, appMeta?.id, sidebarCollapsed, isReady, autoResize]);

  if (codexVMs.length === 0) {
    return (
      <div className="codex-desktop-pure">
        <div className="empty" style={{ flex: 1, margin: 20 }}>
          <AppWindow size={28} />
          <strong>暂无运行中的虚拟机</strong>
          <button className="primary" onClick={() => onNavigateTab?.('vms')}>前往虚拟机</button>
        </div>
      </div>
    );
  }

  if (!desktopVM) {
    return (
      <div className="codex-desktop-pure">
        <div className="empty" style={{ flex: 1, margin: 20 }}>
          <AppWindow size={28} />
          <strong>官方桌面</strong>
          <button className="primary" onClick={onOpenPicker}>
            <Monitor size={15} /> 选择虚拟机
          </button>
        </div>
      </div>
    );
  }

  const currentVM = codexVMs.find(v => v.name === desktopVM) || (state.vms || []).find(v => v.name === desktopVM);
  const vmLabel = currentVM?.displayName || desktopVM;
  const diskAvailMB = codexState.diskAvailMB || claudeState.diskAvailMB || 0;
  const lowDisk = diskAvailMB > 0 && diskAvailMB < 2400;

  const launchApp = appId => {
    const r = slotRef.current?.getBoundingClientRect();
    onSelectDesktopApp?.(appId);
    bridge('codexDesktopOpen', {
      name: desktopVM,
      app: appId,
      width: Math.round(r?.width || 1280),
      height: Math.round(r?.height || 800),
    });
  };

  const installApp = appId => {
    const r = slotRef.current?.getBoundingClientRect();
    onSelectDesktopApp?.(appId);
    bridge('codexDesktopInstall', {
      name: desktopVM,
      app: appId,
      width: Math.round(r?.width || 1280),
      height: Math.round(r?.height || 800),
    });
  };

  // Selection Hub: let user explicitly choose Codex or Claude Code to install / open
  if (!appMeta) {
    return (
      <div className="codex-desktop-pure">
        <div ref={slotRef} className="codex-desktop-slot">
          <div className="codex-desktop-setup" style={{ maxWidth: 680, width: '100%' }}>
            <div className="flex-between" style={{ width: '100%' }}>
              <div className="codex-desktop-setup-head">
                <div className="codex-empty-badge" style={{ marginBottom: 0 }}>
                  <AppWindow size={22} />
                </div>
                <div>
                  <strong>选择官方桌面应用</strong>
                  <span>当前虚拟机：{vmLabel} · 按需单独安装或启动，互不干扰</span>
                </div>
              </div>
              <div className="heading-actions">
                {codexVMs.length > 1 && (
                  <button type="button" className="secondary" onClick={onOpenPicker}>
                    <Monitor size={14} /> 切换虚拟机
                  </button>
                )}
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12, width: '100%' }}>
              {Object.values(DESKTOP_APPS).map(item => {
                const st = item.id === 'codex' ? codexState : claudeState;
                const missing = st.missing || [];
                const pkgMissing = !st.installed || missing.includes(item.pkg);
                const readyToOpen = st.checked && st.installed && missing.length === 0;
                const badgeText = st.installing
                  ? '安装中…'
                  : st.status === 'ready' || st.appRunning
                    ? '运行中'
                    : !st.checked
                      ? '检查中…'
                      : readyToOpen
                        ? '已安装'
                        : st.installed
                          ? '待补齐组件'
                          : '未安装';

                return (
                  <div
                    key={item.id}
                    className="panel"
                    style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 10, justifyContent: 'space-between' }}
                  >
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      <div className="flex-between">
                        <strong>{item.label}</strong>
                        <span className="picker-vm-badge">{badgeText}</span>
                      </div>
                      <span className="muted" style={{ fontSize: 12 }}>{item.desc}</span>
                      <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                        {st.appVersion
                          ? `版本 v${st.appVersion}`
                          : pkgMissing
                            ? `预计占用 ${item.sizeHint}`
                            : '客户端已就绪'}
                      </div>
                    </div>

                    <div className="heading-actions" style={{ marginTop: 4 }}>
                      {st.installing ? (
                        <button type="button" className="primary" onClick={() => onSelectDesktopApp?.(item.id)}>
                          <LoaderCircle size={14} className="spin" /> 查看安装进度
                        </button>
                      ) : readyToOpen || st.status === 'ready' || st.appRunning ? (
                        <button type="button" className="primary" onClick={() => launchApp(item.id)}>
                          <Play size={14} /> 打开 {item.shortLabel}
                        </button>
                      ) : (
                        <button
                          type="button"
                          className="primary"
                          disabled={anyInstalling}
                          onClick={() => installApp(item.id)}
                        >
                          <Download size={14} /> 安装并启动 {item.shortLabel}
                        </button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>

            {diskAvailMB > 0 && (
              <div className="flex-between" style={{ width: '100%', fontSize: 12, color: lowDisk ? 'var(--bad)' : 'var(--muted)' }}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                  <HardDrive size={14} />
                  虚拟机可用磁盘空间：{(diskAvailMB / 1024).toFixed(1)} GB
                  {lowDisk ? '（建议扩容至 2.5 GB 以上）' : ''}
                </span>
                {onResizeDisk && currentVM && (
                  <button type="button" className="small-button" onClick={() => onResizeDisk(currentVM)}>
                    <HardDrive size={12} /> 扩容磁盘
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }

  const stages = [
    { id: 'checking', label: '检查组件' },
    { id: 'display', label: `虚拟显示 ${appMeta.display}` },
    { id: 'app', label: appMeta.label },
    { id: 'vnc', label: 'noVNC 连接' },
  ];
  const stageIdx = stages.findIndex(s => s.id === desktop.stage);
  const missing = desktop.missing || [];

  return (
    <div className="codex-desktop-pure">
      {logsOpen ? (
        <div className="browser-logs-panel" style={{ margin: 14 }}>
          <div className="flex-between" style={{ marginBottom: 10 }}>
            <strong>{appMeta.label}运行日志（{appMeta.configDir}）</strong>
            <div className="heading-actions">
              <button type="button" className="small-button" onClick={() => bridge('codexDesktopFetchLogs', { name: desktopVM, app: appMeta.id })}>
                <RefreshCw size={12} /> 刷新日志
              </button>
              <button type="button" className="small-button" onClick={() => setLogsOpen(false)}>
                返回
              </button>
            </div>
          </div>
          <pre className="browser-logs-pre">{desktop.logs || '正在读取日志…'}</pre>
        </div>
      ) : (
        <div ref={slotRef} className={'codex-desktop-slot' + (isReady ? ' ready' : '')}>
          {desktop.installing ? (
            <div className="codex-desktop-setup">
              <div className="flex-between" style={{ width: '100%' }}>
                <div className="codex-desktop-setup-head">
                  <LoaderCircle size={22} className="spin" color="var(--blue)" />
                  <div>
                    <strong>正在安装 {appMeta.label}</strong>
                    <span>仅安装 {appMeta.shortLabel} 及所需显示组件</span>
                  </div>
                </div>
                <button type="button" className="small-button" onClick={() => onSelectDesktopApp?.('')}>
                  <ArrowLeft size={12} /> 返回选择
                </button>
              </div>
              <pre ref={installLogRef} className="codex-desktop-install-log">
                {desktop.installOutput || '正在连接虚拟机并准备 apt 软件源…'}
              </pre>
            </div>
          ) : desktop.status === 'missing' ? (
            <div className="codex-desktop-setup">
              <div className="flex-between" style={{ width: '100%' }}>
                <div className="codex-desktop-setup-head">
                  <div className="codex-empty-badge" style={{ marginBottom: 0 }}>
                    <AppWindow size={22} />
                  </div>
                  <div>
                    <strong>安装 {appMeta.label}</strong>
                  </div>
                </div>
                <button type="button" className="small-button" onClick={() => onSelectDesktopApp?.('')}>
                  <ArrowLeft size={12} /> 返回选择
                </button>
              </div>

              <div className="codex-desktop-checks">
                <div className="check-line">
                  {missing.includes(appMeta.pkg) ? <AlertTriangle size={14} color="var(--warn)" /> : <CheckCircle2 size={14} color="var(--ok)" />}
                  <span>{appMeta.pkgLabel}</span>
                  <span className="muted">{missing.includes(appMeta.pkg) ? `待安装 (${appMeta.sizeHint})` : '已就绪'}</span>
                </div>
                <div className="check-line">
                  {missing.some(x => x !== appMeta.pkg) ? <AlertTriangle size={14} color="var(--warn)" /> : <CheckCircle2 size={14} color="var(--ok)" />}
                  <span>显示与中文输入</span>
                  <span className="muted">{missing.some(x => x !== appMeta.pkg) ? '待配置' : '已就绪'}</span>
                </div>
                {diskAvailMB > 0 && (
                  <div className="check-line">
                    <HardDrive size={14} color={lowDisk ? 'var(--bad)' : 'var(--muted)'} />
                    <span>可用空间</span>
                    <span className="muted" style={lowDisk ? { color: 'var(--bad)' } : undefined}>
                      {(diskAvailMB / 1024).toFixed(1)} GB
                    </span>
                  </div>
                )}
              </div>

              {lowDisk && (
                <div className="notice error" style={{ marginBottom: 0 }}>
                  <AlertTriangle size={15} />
                  <span>可用空间不足 2.5 GB</span>
                </div>
              )}

              <div className="heading-actions">
                <button
                  type="button"
                  className="primary"
                  disabled={anyInstalling}
                  onClick={() => installApp(appMeta.id)}
                >
                  <Download size={14} /> 一键安装并启动 {appMeta.shortLabel}
                </button>
                {onResizeDisk && currentVM && (
                  <button type="button" className="secondary" onClick={() => onResizeDisk(currentVM)}>
                    <HardDrive size={14} /> 扩容磁盘
                  </button>
                )}
              </div>
            </div>
          ) : desktop.status === 'error' ? (
            <div className="codex-desktop-setup">
              <div className="flex-between" style={{ width: '100%' }}>
                <div className="codex-desktop-setup-head">
                  <AlertTriangle size={24} color="var(--bad)" />
                  <div>
                    <strong>无法打开 {appMeta.label}</strong>
                    <span>{desktop.error}</span>
                  </div>
                </div>
                <button type="button" className="small-button" onClick={() => onSelectDesktopApp?.('')}>
                  <ArrowLeft size={12} /> 返回选择
                </button>
              </div>
              {desktop.installOutput && (
                <pre className="codex-desktop-install-log" style={{ height: 190 }}>
                  {desktop.installOutput}
                </pre>
              )}
              <div className="heading-actions">
                {!desktop.installed && (
                  <button
                    type="button"
                    className="primary"
                    disabled={anyInstalling}
                    onClick={() => installApp(appMeta.id)}
                  >
                    <Download size={14} /> 重新安装 {appMeta.shortLabel}
                  </button>
                )}
                <button
                  type="button"
                  className={desktop.installed ? 'primary' : 'secondary'}
                  onClick={() => launchApp(appMeta.id)}
                >
                  <Wrench size={14} /> 重试启动
                </button>
                <button
                  type="button"
                  className="secondary"
                  onClick={() => {
                    setLogsOpen(true);
                    bridge('codexDesktopFetchLogs', { name: desktopVM, app: appMeta.id });
                  }}
                >
                  查看日志
                </button>
              </div>
            </div>
          ) : !isReady ? (
            <div className="empty" style={{ border: 0, maxWidth: 540 }}>
              <LoaderCircle size={28} className="spin" color="var(--blue)" />
              <strong>正在启动 {appMeta.label}</strong>
              <span>{desktop.stageMessage || `正在虚拟机内初始化虚拟显示、${appMeta.label}与 noVNC…`}</span>
              <div className="browser-stages">
                {stages.map((st, idx) => {
                  const done = stageIdx > idx;
                  const cur = stageIdx === idx || (stageIdx < 0 && idx === 0);
                  return (
                    <div key={st.id} className={'browser-stage-pill' + (done ? ' done' : cur ? ' current' : '')}>
                      {done ? <CheckCircle2 size={12} /> : cur ? <LoaderCircle size={12} className="spin" /> : <span className="stage-num">{idx + 1}</span>}
                      <span>{st.label}</span>
                    </div>
                  );
                })}
              </div>
              <button type="button" className="secondary" style={{ marginTop: 8 }} onClick={() => onSelectDesktopApp?.('')}>
                <ArrowLeft size={14} /> 返回选择
              </button>
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}
