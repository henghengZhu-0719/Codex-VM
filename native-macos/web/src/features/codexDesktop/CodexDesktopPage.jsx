import React, { useEffect, useRef, useState } from 'react';
import {
  AlertTriangle,
  AppWindow,
  CheckCircle2,
  Download,
  HardDrive,
  LoaderCircle,
  Monitor,
  RefreshCw,
  Wrench,
} from 'lucide-react';
import { bridge } from '../../bridge.js';

const STAGES = [
  { id: 'checking', label: '检查组件' },
  { id: 'display', label: '虚拟显示 :98' },
  { id: 'app', label: 'Codex 官方桌面' },
  { id: 'vnc', label: 'noVNC 连接' },
];

export default function CodexDesktopPage({
  state,
  codexVMs,
  desktopVM,
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

  const desktop = state.codexDesktops?.[desktopVM] || {};
  const isReady = desktop.status === 'ready';
  const autoResize = desktop.autoResize !== false;

  // Auto-open or check when desktopVM is selected
  useEffect(() => {
    if (!desktopVM || modalOpen) return;
    const el = slotRef.current;
    const rect = el ? el.getBoundingClientRect() : { width: 1280, height: 800 };
    const st = state.codexDesktops?.[desktopVM]?.status;
    if (!st || st === 'idle') {
      bridge('codexDesktopOpen', {
        name: desktopVM,
        width: Math.round(rect.width) || 1280,
        height: Math.round(rect.height) || 800,
      });
    } else if (st === 'ready') {
      bridge('codexDesktopSelect', { name: desktopVM });
    } else if (st === 'missing') {
      bridge('codexDesktopCheck', { name: desktopVM });
    }
  }, [desktopVM, modalOpen]);

  useEffect(() => {
    if (desktop.installing && installLogRef.current) {
      installLogRef.current.scrollTop = installLogRef.current.scrollHeight;
    }
  }, [desktop.installOutput, desktop.installing]);

  // Sync native WKWebView slot geometry to fill 100% of the container
  useEffect(() => {
    const el = slotRef.current;
    const showNative = !modalOpen && !logsOpen && !!desktopVM && isReady;

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
        (Math.abs(w - lastResizeRef.current.w) > 20 || Math.abs(h - lastResizeRef.current.h) > 20)
      ) {
        lastResizeRef.current = { w, h };
        bridge('codexDesktopResize', { name: desktopVM, width: w, height: h });
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
  }, [modalOpen, logsOpen, desktopVM, sidebarCollapsed, isReady, autoResize]);

  if (codexVMs.length === 0) {
    return (
      <div className="codex-desktop-pure">
        <div className="empty" style={{ flex: 1, margin: 20 }}>
          <AppWindow size={28} />
          <strong>暂无运行中的 Codex 虚拟机</strong>
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
          <strong>Codex 官方桌面</strong>
          <button className="primary" onClick={onOpenPicker}>
            <Monitor size={15} /> 选择虚拟机
          </button>
        </div>
      </div>
    );
  }

  const stageIdx = STAGES.findIndex(s => s.id === desktop.stage);
  const missing = desktop.missing || [];
  const lowDisk = desktop.diskAvailMB > 0 && desktop.diskAvailMB < 2400;
  const currentVM = codexVMs.find(v => v.name === desktopVM) || (state.vms || []).find(v => v.name === desktopVM);

  return (
    <div className="codex-desktop-pure">
      {logsOpen ? (
        <div className="browser-logs-panel" style={{ margin: 14 }}>
          <div className="flex-between" style={{ marginBottom: 10 }}>
            <strong>官方 Codex 桌面端运行日志（~/.config/agent-vm-codex-desktop）</strong>
            <div className="heading-actions">
              <button type="button" className="small-button" onClick={() => bridge('codexDesktopFetchLogs', { name: desktopVM })}>
                <RefreshCw size={12} /> 刷新日志
              </button>
              <button type="button" className="small-button" onClick={() => setLogsOpen(false)}>
                返回桌面画面
              </button>
            </div>
          </div>
          <pre className="browser-logs-pre">{desktop.logs || '正在读取日志…'}</pre>
        </div>
      ) : (
        <div ref={slotRef} className={'codex-desktop-slot' + (isReady ? ' ready' : '')}>
          {desktop.installing ? (
            <div className="codex-desktop-setup">
              <div className="codex-desktop-setup-head">
                <LoaderCircle size={22} className="spin" color="var(--blue)" />
                <div>
                  <strong>正在安装 Codex 官方桌面端</strong>
                </div>
              </div>
              <pre ref={installLogRef} className="codex-desktop-install-log">
                {desktop.installOutput || '正在连接虚拟机并准备 apt 软件源…'}
              </pre>
            </div>
          ) : desktop.status === 'missing' ? (
            <div className="codex-desktop-setup">
              <div className="codex-desktop-setup-head">
                <div className="codex-empty-badge" style={{ marginBottom: 0 }}>
                  <AppWindow size={22} />
                </div>
                <div>
                  <strong>安装 Codex 官方桌面端</strong>
                </div>
              </div>

              <div className="codex-desktop-checks">
                <div className="check-line">
                  {missing.includes('chatgpt') ? <AlertTriangle size={14} color="var(--warn)" /> : <CheckCircle2 size={14} color="var(--ok)" />}
                  <span>Codex 桌面客户端</span>
                  <span className="muted">{missing.includes('chatgpt') ? '待安装 (~1.8 GB)' : '已就绪'}</span>
                </div>
                <div className="check-line">
                  {missing.some(x => x !== 'chatgpt') ? <AlertTriangle size={14} color="var(--warn)" /> : <CheckCircle2 size={14} color="var(--ok)" />}
                  <span>显示与中文输入</span>
                  <span className="muted">{missing.some(x => x !== 'chatgpt') ? '待配置' : '已就绪'}</span>
                </div>
                {desktop.diskAvailMB > 0 && (
                  <div className="check-line">
                    <HardDrive size={14} color={lowDisk ? 'var(--bad)' : 'var(--muted)'} />
                    <span>可用空间</span>
                    <span className="muted" style={lowDisk ? { color: 'var(--bad)' } : undefined}>
                      {(desktop.diskAvailMB / 1024).toFixed(1)} GB
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
                  onClick={() => {
                    const r = slotRef.current?.getBoundingClientRect();
                    bridge('codexDesktopInstall', {
                      name: desktopVM,
                      width: Math.round(r?.width || 1280),
                      height: Math.round(r?.height || 800),
                    });
                  }}
                >
                  <Download size={14} /> 一键安装并启动
                </button>
                {onResizeDisk && currentVM && (
                  <button type="button" className="secondary" onClick={() => onResizeDisk(currentVM)}>
                    <HardDrive size={14} /> 扩容磁盘
                  </button>
                )}
                {codexVMs.length > 1 && (
                  <button type="button" className="secondary" onClick={onOpenPicker}>
                    <Monitor size={14} /> 切换虚拟机
                  </button>
                )}
              </div>
            </div>
          ) : desktop.status === 'error' ? (
            <div className="codex-desktop-setup">
              <div className="codex-desktop-setup-head">
                <AlertTriangle size={24} color="var(--bad)" />
                <div>
                  <strong>无法打开官方 Codex 桌面端</strong>
                  <span>{desktop.error}</span>
                </div>
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
                    onClick={() => {
                      const r = slotRef.current?.getBoundingClientRect();
                      bridge('codexDesktopInstall', {
                        name: desktopVM,
                        width: Math.round(r?.width || 1280),
                        height: Math.round(r?.height || 800),
                      });
                    }}
                  >
                    <Download size={14} /> 重新安装
                  </button>
                )}
                <button
                  type="button"
                  className={desktop.installed ? 'primary' : 'secondary'}
                  onClick={() => {
                    const r = slotRef.current?.getBoundingClientRect();
                    bridge('codexDesktopOpen', {
                      name: desktopVM,
                      width: Math.round(r?.width || 1280),
                      height: Math.round(r?.height || 800),
                    });
                  }}
                >
                  <Wrench size={14} /> 重试启动
                </button>
                <button
                  type="button"
                  className="secondary"
                  onClick={() => {
                    setLogsOpen(true);
                    bridge('codexDesktopFetchLogs', { name: desktopVM });
                  }}
                >
                  查看日志
                </button>
                {codexVMs.length > 1 && (
                  <button type="button" className="secondary" onClick={onOpenPicker}>
                    切换虚拟机
                  </button>
                )}
              </div>
            </div>
          ) : !isReady ? (
            <div className="empty" style={{ border: 0, maxWidth: 540 }}>
              <LoaderCircle size={28} className="spin" color="var(--blue)" />
              <strong>正在启动官方 Codex 桌面端</strong>
              <span>{desktop.stageMessage || '正在虚拟机内初始化 Xvfb、ChatGPT / Codex 桌面端与 noVNC…'}</span>
              <div className="browser-stages">
                {STAGES.map((st, idx) => {
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
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}
