import React, { useEffect, useRef, useState } from 'react';
import {
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  Camera,
  CheckCircle2,
  Download,
  FileText,
  FolderOpen,
  Globe,
  Keyboard,
  LoaderCircle,
  Monitor,
  Plus,
  RefreshCw,
  RotateCw,
  Send,
  Wrench,
  X,
  Zap,
} from 'lucide-react';
import { bridge } from '../../bridge.js';

const STAGES = [
  { id: 'checking', label: '检查组件' },
  { id: 'display', label: '虚拟显示' },
  { id: 'chromium', label: 'Chromium' },
  { id: 'vnc', label: 'noVNC 连接' },
];

export default function BrowserPage({
  state,
  running,
  browserVM,
  setBrowserVM,
  sidebarCollapsed,
  modalOpen,
  onNavigateTab,
}) {
  const [addr, setAddr] = useState('');
  const [addrFocused, setAddrFocused] = useState(false);
  const [imeOpen, setImeOpen] = useState(false);
  const [imeText, setImeText] = useState('');
  const [logsOpen, setLogsOpen] = useState(false);
  const [autoResize, setAutoResize] = useState(() => {
    try { return localStorage.getItem('agentvm.browserAutoResize') !== '0'; } catch { return true; }
  });

  const slotRef = useRef(null);
  const addrRef = useRef(null);
  const imeRef = useRef(null);
  const lastSlotKeyRef = useRef('');
  const lastResizeRef = useRef({ w: 0, h: 0 });
  const lastShortcutNonceRef = useRef('');

  const browser = state.browsers?.[browserVM] || {};
  const isReady = browser.status === 'ready';
  const tabs = browser.tabs || [];
  const devPorts = browser.devPorts || [];
  const qualityMode = browser.qualityMode || 'balanced';

  // Keep address bar synced with active tab URL when user isn't typing
  useEffect(() => {
    if (!addrFocused && browser.activeURL !== undefined) {
      setAddr(browser.activeURL || '');
    }
  }, [browser.activeURL, browserVM, addrFocused]);

  // Open or select VM browser when entering page or switching VM
  useEffect(() => {
    if (!browserVM) return;
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
    }
  }, [browserVM]);

  // Periodic CDP inspect while on browser page (syncs tabs & dev ports)
  useEffect(() => {
    if (!browserVM || !isReady) return;
    const t = setInterval(() => {
      bridge('browserInspect', { name: browserVM });
    }, 3500);
    return () => clearInterval(t);
  }, [browserVM, isReady]);

  // Handle native WKWebView shortcuts (Cmd+L, Cmd+R, Cmd+T, Cmd+[, Cmd+])
  useEffect(() => {
    const sig = state.browserShortcut;
    if (!sig?.nonce || sig.nonce === lastShortcutNonceRef.current) return;
    lastShortcutNonceRef.current = sig.nonce;
    if (!browserVM) return;
    switch (sig.action) {
      case 'focusAddress':
        addrRef.current?.focus();
        addrRef.current?.select();
        break;
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

  // Sync native WKWebView slot geometry + auto-resize Xvfb resolution
  useEffect(() => {
    const el = slotRef.current;
    const showNative = !modalOpen && !logsOpen && !!browserVM && isReady;

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
        (Math.abs(w - lastResizeRef.current.w) > 28 || Math.abs(h - lastResizeRef.current.h) > 28)
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
  }, [modalOpen, logsOpen, browserVM, sidebarCollapsed, isReady, autoResize, imeOpen, devPorts.length, tabs.length]);

  const submitAddr = e => {
    e.preventDefault();
    if (!browserVM || !addr.trim()) return;
    bridge('browserNavigate', { name: browserVM, url: addr.trim(), tabId: browser.activeTabId || '' });
    addrRef.current?.blur();
  };

  const sendImeText = e => {
    e.preventDefault();
    if (!browserVM || !imeText) return;
    bridge('browserInsertText', { name: browserVM, text: imeText, tabId: browser.activeTabId || '' });
    setImeText('');
  };

  const toggleAutoResize = checked => {
    setAutoResize(checked);
    try { localStorage.setItem('agentvm.browserAutoResize', checked ? '1' : '0'); } catch {}
    if (checked && slotRef.current && isReady) {
      const r = slotRef.current.getBoundingClientRect();
      bridge('browserResize', { name: browserVM, width: Math.round(r.width), height: Math.round(r.height) });
    }
  };

  if (running.length === 0) {
    return (
      <div className="browser-page">
        <div className="empty" style={{ flex: 1 }}>
          <Globe size={30} />
          <strong>暂无运行中的虚拟机</strong>
          <span>请先在「虚拟机」页面启动至少一台虚拟机。</span>
          <button className="primary" onClick={() => onNavigateTab?.('vms')}>前往虚拟机列表</button>
        </div>
      </div>
    );
  }

  const stageIdx = STAGES.findIndex(s => s.id === browser.stage);

  return (
    <div className="browser-page">
      {/* Row 1: VM picker + Browser Tabs */}
      <div className="browser-tabs-bar">
        <label className="codex-pill browser-vm-pill">
          <Monitor size={13} />
          <select
            value={browserVM}
            onChange={e => {
              const v = e.target.value;
              setBrowserVM(v);
              const r = slotRef.current?.getBoundingClientRect();
              bridge('browserOpen', {
                name: v,
                width: Math.round(r?.width || 1280),
                height: Math.round(r?.height || 800),
              });
            }}
          >
            {running.map(v => (
              <option key={v.name} value={v.name}>{v.displayName || v.name}</option>
            ))}
          </select>
        </label>

        <div className="browser-tabs-strip">
          {tabs.map(t => (
            <div
              key={t.id}
              className={'browser-tab' + (t.active ? ' active' : '')}
              onClick={() => bridge('browserActivateTab', { name: browserVM, tabId: t.id })}
              title={t.url || t.title}
            >
              <Globe size={12} />
              <span>{t.title || t.url || '新标签页'}</span>
              {tabs.length > 1 && (
                <button
                  type="button"
                  className="browser-tab-close"
                  aria-label="关闭标签页"
                  onClick={e => {
                    e.stopPropagation();
                    bridge('browserCloseTab', { name: browserVM, tabId: t.id });
                  }}
                >
                  <X size={11} />
                </button>
              )}
            </div>
          ))}
          {isReady && (
            <button
              type="button"
              className="browser-newtab-btn"
              title="新建标签页 (⌘T)"
              onClick={() => bridge('browserNewTab', { name: browserVM, url: 'about:blank' })}
            >
              <Plus size={14} />
            </button>
          )}
        </div>

        <div className="browser-top-meta">
          {browser.resolution && <span className="browser-meta-pill">{browser.resolution}</span>}
          <label className="browser-meta-check" title="窗口大小变化时自动调整虚拟显示分辨率">
            <input type="checkbox" checked={autoResize} onChange={e => toggleAutoResize(e.target.checked)} />
            <span>自适应</span>
          </label>
          <select
            className="browser-quality-select"
            value={qualityMode}
            title="画面清晰度与流畅度"
            onChange={e => bridge('browserSetQuality', { name: browserVM, qualityMode: e.target.value })}
          >
            <option value="sharp">高清画质</option>
            <option value="balanced">均衡画质</option>
            <option value="smooth">流畅优先</option>
          </select>
        </div>
      </div>

      {/* Row 2: Navigation & Address Bar + Agent/IME tools */}
      <div className="browser-nav-bar">
        <div className="browser-nav-btns">
          <button
            type="button"
            className="icon-button"
            title="后退 (⌘[)"
            disabled={!isReady}
            onClick={() => bridge('browserBack', { name: browserVM, tabId: browser.activeTabId || '' })}
          >
            <ArrowLeft size={15} />
          </button>
          <button
            type="button"
            className="icon-button"
            title="前进 (⌘])"
            disabled={!isReady}
            onClick={() => bridge('browserForward', { name: browserVM, tabId: browser.activeTabId || '' })}
          >
            <ArrowRight size={15} />
          </button>
          <button
            type="button"
            className="icon-button"
            title="刷新当前网页 (⌘R)"
            disabled={!isReady}
            onClick={() => bridge('browserPageReload', { name: browserVM, tabId: browser.activeTabId || '' })}
          >
            <RotateCw size={14} />
          </button>
        </div>

        <form className="browser-addr-form" onSubmit={submitAddr}>
          <input
            ref={addrRef}
            value={addr}
            disabled={!isReady}
            onFocus={() => setAddrFocused(true)}
            onBlur={() => setAddrFocused(false)}
            onChange={e => setAddr(e.target.value)}
            placeholder="输入网址或 localhost:3000（⌘L 聚焦）"
          />
        </form>

        <button
          type="button"
          className={'small-button' + (imeOpen ? ' is-active' : '')}
          disabled={!isReady}
          title="使用 macOS 中文输入法输入文字并直接发送到浏览器焦点输入框"
          onClick={() => {
            const next = !imeOpen;
            setImeOpen(next);
            if (next) setTimeout(() => imeRef.current?.focus(), 50);
          }}
        >
          <Keyboard size={13} /> 中文输入
        </button>

        <button
          type="button"
          className="small-button"
          disabled={!isReady}
          title="截取当前页面发送到 Agent 对话附件"
          onClick={() => bridge('browserScreenshotToChat', { name: browserVM, tabId: browser.activeTabId || '', jump: true })}
        >
          <Camera size={13} /> 截图提问
        </button>

        <button
          type="button"
          className="small-button"
          title="打开下载文件夹 (~/AgentVM-Shared/Downloads)"
          onClick={() => bridge('browserOpenDownloads')}
        >
          <FolderOpen size={13} /> 下载
        </button>

        <button
          type="button"
          className="small-button"
          disabled={browser.status === 'starting'}
          title="重连 VNC 画面"
          onClick={() => {
            if (isReady) bridge('browserReload');
            else {
              const r = slotRef.current?.getBoundingClientRect();
              bridge('browserOpen', {
                name: browserVM,
                width: Math.round(r?.width || 1280),
                height: Math.round(r?.height || 800),
              });
            }
          }}
        >
          <RefreshCw size={13} /> {isReady ? '重连画面' : '重新启动'}
        </button>

        <button
          type="button"
          className={'small-button' + (logsOpen ? ' is-active' : '')}
          onClick={() => {
            const next = !logsOpen;
            setLogsOpen(next);
            if (next) bridge('browserFetchLogs', { name: browserVM });
          }}
        >
          <FileText size={13} /> 日志
        </button>
      </div>

      {/* Optional Row: Discovered VM listening ports */}
      {isReady && devPorts.length > 0 && (
        <div className="browser-ports-bar">
          <span className="ports-label"><Zap size={12} /> 虚拟机运行端口</span>
          {devPorts.map(port => (
            <button
              key={port}
              type="button"
              className="port-chip"
              onClick={() => bridge('browserNavigate', { name: browserVM, url: `http://localhost:${port}`, tabId: browser.activeTabId || '' })}
            >
              localhost:{port}
            </button>
          ))}
        </div>
      )}

      {/* Optional Row: Chinese IME Bridge Input */}
      {imeOpen && isReady && (
        <form className="browser-ime-bar" onSubmit={sendImeText}>
          <Keyboard size={14} />
          <input
            ref={imeRef}
            value={imeText}
            onChange={e => setImeText(e.target.value)}
            placeholder="在此使用 macOS 中文输入法打字，按 Enter 直接填入虚拟机网页当前输入框…"
          />
          <button type="submit" className="primary" style={{ minHeight: 28, padding: '4px 10px' }} disabled={!imeText}>
            <Send size={12} /> 发送输入
          </button>
          <button type="button" className="icon-button" style={{ width: 28, height: 28 }} onClick={() => setImeOpen(false)}>
            <X size={13} />
          </button>
        </form>
      )}

      {/* Main Viewport Slot (or Logs Drawer / Starting Progress / Missing Components) */}
      {logsOpen ? (
        <div className="browser-logs-panel">
          <div className="flex-between" style={{ marginBottom: 10 }}>
            <strong>浏览器运行日志（~/.config/agent-vm-browser）</strong>
            <div className="heading-actions">
              <button type="button" className="small-button" onClick={() => bridge('browserFetchLogs', { name: browserVM })}>
                <RefreshCw size={12} /> 刷新日志
              </button>
              <button type="button" className="small-button" onClick={() => setLogsOpen(false)}>
                返回浏览器画面
              </button>
            </div>
          </div>
          <pre className="browser-logs-pre">{browser.logs || '正在读取日志…'}</pre>
        </div>
      ) : (
        <div ref={slotRef} className="browser-host-slot">
          {browser.status === 'error' ? (
            <div className="empty" style={{ border: 0, maxWidth: 520, padding: 24 }}>
              <AlertTriangle size={28} color="var(--bad)" />
              <strong>无法打开 Linux 浏览器</strong>
              <span style={{ textAlign: 'center', lineHeight: 1.6 }}>{browser.error}</span>
              <div className="heading-actions" style={{ marginTop: 8 }}>
                {(browser.missing?.length > 0 || (browser.error || '').includes('尚未安装') || (browser.error || '').includes('缺少')) && (
                  <button
                    type="button"
                    className="primary"
                    disabled={browser.installing}
                    onClick={() => bridge('browserInstallComponents', { name: browserVM })}
                  >
                    {browser.installing ? <><LoaderCircle size={14} className="spin" /> 正在安装组件…</> : <><Wrench size={14} /> 一键安装浏览器组件</>}
                  </button>
                )}
                <button
                  type="button"
                  className="secondary"
                  onClick={() => {
                    const r = slotRef.current?.getBoundingClientRect();
                    bridge('browserOpen', {
                      name: browserVM,
                      width: Math.round(r?.width || 1280),
                      height: Math.round(r?.height || 800),
                    });
                  }}
                >
                  重试启动
                </button>
                <button
                  type="button"
                  className="secondary"
                  onClick={() => {
                    setLogsOpen(true);
                    bridge('browserFetchLogs', { name: browserVM });
                  }}
                >
                  查看日志
                </button>
              </div>
            </div>
          ) : !isReady ? (
            <div className="empty" style={{ border: 0, maxWidth: 540 }}>
              <LoaderCircle size={28} className="spin" color="var(--blue)" />
              <strong>{browser.installing ? '正在安装浏览器组件…' : '正在启动 Linux 浏览器'}</strong>
              <span>{browser.stageMessage || '正在初始化 Xvfb、Chromium 与 noVNC…'}</span>
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
