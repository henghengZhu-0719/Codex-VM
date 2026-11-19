import React, { useEffect, useRef } from 'react';
import {
  AlertTriangle,
  CheckCircle2,
  Globe,
  LoaderCircle,
  Monitor,
  RefreshCw,
  Wrench,
} from 'lucide-react';
import { bridge } from '../../bridge.js';

const STAGES = [
  { id: 'checking', label: '检查组件' },
  { id: 'display', label: '虚拟显示 :99' },
  { id: 'chromium', label: 'Chromium' },
  { id: 'vnc', label: 'noVNC 连接' },
];

export default function BrowserPage({
  state,
  running,
  browserVM,
  sidebarCollapsed,
  modalOpen,
  onOpenPicker,
  onNavigateTab,
}) {
  const slotRef = useRef(null);
  const lastSlotKeyRef = useRef('');
  const lastResizeRef = useRef({ w: 0, h: 0 });
  const lastShortcutNonceRef = useRef('');

  const browser = state.browsers?.[browserVM] || {};
  const isReady = browser.status === 'ready';
  const autoResize = browser.autoResize !== false;

  // Open or select VM browser when browserVM is set
  useEffect(() => {
    lastResizeRef.current = { w: 0, h: 0 };
    if (!browserVM || modalOpen) return;
    const el = slotRef.current;
    const rect = el ? el.getBoundingClientRect() : { width: 1280, height: 800 };
    const st = state.browsers?.[browserVM]?.status;
    if (!st || st === 'idle') {
      bridge('browserOpen', {
        name: browserVM,
        width: Math.round(rect.width) || 1280,
        height: Math.round(rect.height) || 800,
      });
    } else {
      bridge('browserSelect', { name: browserVM });
      if (st === 'ready') {
        bridge('browserInspect', { name: browserVM });
      }
    }
  }, [browserVM, modalOpen]);

  // Handle native WKWebView shortcuts (Cmd+R, Cmd+T, Cmd+[, Cmd+])
  useEffect(() => {
    const sig = state.browserShortcut;
    if (!sig?.nonce || sig.nonce === lastShortcutNonceRef.current) return;
    lastShortcutNonceRef.current = sig.nonce;
    if (!browserVM) return;
    switch (sig.action) {
      case 'reload':
        bridge('browserPageReload', { name: browserVM, tabId: browser.activeTabId || '' });
        break;
      case 'newTab':
        bridge('browserNewTab', { name: browserVM, url: 'about:blank' });
        break;
      case 'back':
        bridge('browserBack', { name: browserVM, tabId: browser.activeTabId || '' });
        break;
      case 'forward':
        bridge('browserForward', { name: browserVM, tabId: browser.activeTabId || '' });
        break;
    }
  }, [state.browserShortcut?.nonce]);

  // Sync native WKWebView slot geometry + auto-resize resolution
  useEffect(() => {
    const el = slotRef.current;
    const showNative = !modalOpen && !!browserVM && isReady;

    const sendSlot = payload => {
      const key = JSON.stringify(payload);
      if (lastSlotKeyRef.current === key) return;
      lastSlotKeyRef.current = key;
      bridge('browserSlot', payload);
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
        bridge('browserResize', { name: browserVM, width: w, height: h });
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
  }, [modalOpen, browserVM, sidebarCollapsed, isReady, autoResize]);

  if (running.length === 0) {
    return (
      <div className="codex-desktop-pure">
        <div className="empty" style={{ flex: 1, margin: 20 }}>
          <Globe size={28} />
          <strong>暂无运行中的虚拟机</strong>
          <button className="primary" onClick={() => onNavigateTab?.('vms')}>前往虚拟机</button>
        </div>
      </div>
    );
  }

  if (!browserVM) {
    return (
      <div className="codex-desktop-pure">
        <div className="empty" style={{ flex: 1, margin: 20 }}>
          <Globe size={28} />
          <strong>浏览器</strong>
          <button className="primary" onClick={onOpenPicker}>
            <Monitor size={15} /> 选择虚拟机
          </button>
        </div>
      </div>
    );
  }

  const stageIdx = STAGES.findIndex(s => s.id === browser.stage);
  const missing = browser.missing || [];
  const needsInstall = missing.length > 0 || (browser.error || '').includes('缺少') || (browser.error || '').includes('尚未安装');

  return (
    <div className="codex-desktop-pure">
      <div role="toolbar" aria-label="浏览器服务管理" style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 14px', borderBottom: '1px solid var(--border, #d0d0d0)', flexShrink: 0 }}>
        <Globe size={16} />
        <strong style={{ fontSize: 13 }}>Linux Chromium</strong>
        <span style={{ fontSize: 12, opacity: .7 }}>{isReady ? '已连接' : browser.appRunning ? '浏览器进程运行中' : '未连接'}</span>
        <span style={{ fontSize: 12, opacity: .6 }}>{browser.tabs?.length ? `${browser.tabs.length} 个标签页` : ''}</span>
        <span style={{ fontSize: 12, opacity: .7 }} title="仅 Chromium 主进程 RSS，不包含子进程">{browser.browserRSSMB > 0 ? `主进程 ${browser.browserRSSMB} MiB` : ''}</span>
        <span style={{ fontSize: 12, opacity: .7 }} title="Chrome DevTools Protocol（虚拟机回环地址）">{browser.cdpAvailable ? 'CDP 就绪' : 'CDP 未连接'}</span>
        <span style={{ flex: 1 }} />
        <button type="button" className="secondary" title="刷新浏览器状态" onClick={() => bridge('browserInspect', { name: browserVM })}>
          <RefreshCw size={14} /> 刷新状态
        </button>
        <button type="button" className="secondary" onClick={() => bridge('browserInstallMCP', { name: browserVM })} title="安装虚拟机内的本地 MCP 服务端">安装 MCP</button>
        <button type="button" className="secondary" onClick={() => bridge('browserRestart', { name: browserVM })} disabled={!browser.appRunning} title="重启 Chromium，保留用户资料">重启</button>
        <button type="button" className="secondary" onClick={() => {
          if (window.confirm('停止该虚拟机中的 Chromium 与画面服务？正在运行的浏览器自动化任务会中断。')) {
            bridge('browserStopService', { name: browserVM });
          }
        }} disabled={!browser.appRunning} title="停止浏览器服务">停止</button>
        <button type="button" className="secondary" onClick={onOpenPicker}>切换环境</button>
      </div>
      <div ref={slotRef} className={'codex-desktop-slot' + (isReady ? ' ready' : '')}>
        {browser.installing ? (
          <div className="empty" style={{ border: 0, maxWidth: 460 }}>
            <LoaderCircle size={26} className="spin" color="var(--blue)" />
            <strong>正在安装浏览器组件</strong>
          </div>
        ) : browser.status === 'error' ? (
          <div className="empty" style={{ border: 0, maxWidth: 480, padding: 24 }}>
            <AlertTriangle size={26} color="var(--bad)" />
            <strong>无法打开浏览器</strong>
            <span style={{ textAlign: 'center', lineHeight: 1.55 }}>{browser.error}</span>
            <div className="heading-actions" style={{ marginTop: 8 }}>
              {needsInstall && (
                <button
                  type="button"
                  className="primary"
                  onClick={() => bridge('browserInstallComponents', { name: browserVM })}
                >
                  <Wrench size={14} /> 一键安装组件
                </button>
              )}
              <button
                type="button"
                className={needsInstall ? 'secondary' : 'primary'}
                onClick={() => {
                  const r = slotRef.current?.getBoundingClientRect();
                  bridge('browserOpen', {
                    name: browserVM,
                    width: Math.round(r?.width || 1280),
                    height: Math.round(r?.height || 800),
                  });
                }}
              >
                重试
              </button>
              {running.length > 1 && (
                <button type="button" className="secondary" onClick={onOpenPicker}>
                  切换虚拟机
                </button>
              )}
            </div>
          </div>
        ) : !isReady ? (
          <div className="empty" style={{ border: 0, maxWidth: 520 }}>
            <LoaderCircle size={26} className="spin" color="var(--blue)" />
            <strong>正在启动浏览器</strong>
            <span>{browser.stageMessage || '正在准备 Chromium 与画面连接…'}</span>
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
    </div>
  );
}
