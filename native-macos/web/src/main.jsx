import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import {
  Activity,
  AlertTriangle,
  AppWindow,
  ArrowRight,
  ChartNoAxesCombined,
  CheckCircle2,
  FolderOpen,
  Globe,
  LoaderCircle,
  Monitor,
  Network,
  Package,
  PanelLeft,
  Play,
  Plus,
  RefreshCw,
  Search,
  Settings2,
  ShieldAlert,
  ShieldCheck,
  Square,
} from 'lucide-react';
import './style.css';
import {
  agentLabel,
  bridge,
  formatSubUsage,
  getRemoteToken,
  isRemoteWeb,
} from './bridge.js';
import { IconButton, KV, QuotaBar, SectionTitle, VMCard, quotaStatusText } from './components/SharedUI.jsx';
import ToastStack from './components/ToastStack.jsx';
import ChatPage from './features/chat/ChatPage.jsx';
import BrowserPage from './features/browser/BrowserPage.jsx';
import CodexDesktopPage from './features/codexDesktop/CodexDesktopPage.jsx';

const blank = {
  vms: [],
  busy: false,
  proxy: null,
  quotas: {},
  agentQuotas: {},
  usage: {},
  memoryReclaiming: [],
  smartMemory: {
    balloonEnabled: true,
    autoSleepMinutes: 30,
    guiIdleMinutes: 10,
    pinnedVMs: [],
    pressure: 'normal',
    pressureLabel: '正常',
    idleSeconds: {},
    totalHostFootprintMB: 0,
  },
  editors: {},
  browsers: {},
  codexDesktops: {},
  activeCodexDesktopVM: '',
  activeCodexDesktopApp: 'codex',
  mounts: {},
  agents: {},
  vmProxyRoutes: {},
  remoteWorkbench: { enabled: false, port: 18080, token: '', urls: [], error: '' },
  remoteHosts: [],
  remoteHostStatus: '未连接',
  remoteHostConnectionState: 'disconnected',
  activeRemoteHostID: '',
  cliMonitor: {
    autoUpdate: true,
    checking: false,
    updating: false,
    latest: {},
    latestCheckedAt: 0,
    pendingCount: 0,
    vms: {},
  },
  codex: {
    runningVM: '',
    runningVMs: [],
    runningSessions: [],
    activeSessions: {},
    sessions: {},
    threads: {},
    messages: {},
    stagedAttachments: {},
    gitDiff: {},
  },
  toasts: [],
  requestedPage: {},
  browserShortcut: {},
  error: '',
  proxyError: '',
  proxyMessage: '',
  buildStarted: false,
  buildComplete: false,
  buildStage: 0,
};

const tabs = [
  { id: 'vms', label: '虚拟机', icon: Monitor },
  { id: 'codexDesktop', label: '官方桌面', icon: AppWindow },
  { id: 'browser', label: '浏览器', icon: Globe },
  { id: 'proxy', label: '网络代理', icon: Network },
  { id: 'quota', label: 'AI 额度', icon: ChartNoAxesCombined },
  { id: 'versions', label: '版本监控', icon: Package },
  { id: 'settings', label: '设置', icon: Settings2 },
];

function App() {
  const [state, setState] = useState(window.__agentVMInitial || blank);
  const [page, setPage] = useState(isRemoteWeb ? 'codex' : 'vms');
  const [remoteToken, setRemoteToken] = useState(() => (isRemoteWeb ? getRemoteToken() : ''));
  const [remoteTokenInput, setRemoteTokenInput] = useState('');
  const [remoteAuthFailed, setRemoteAuthFailed] = useState(false);
  const [remotePortInput, setRemotePortInput] = useState('18080');
  const [remoteVMNames, setRemoteVMNames] = useState({});
  const [remoteHostForm, setRemoteHostForm] = useState({
    name: 'Mac Pro', hostname: '', username: '', sshPort: '22', workbenchPort: '18080',
  });
  const [modal, setModal] = useState(null);
  const [filter, setFilter] = useState('');
  const [vmScope, setVmScope] = useState('all');
  const [create, setCreate] = useState({
    name: '',
    cpus: 2,
    memory: 4,
    disk: 20,
    codex: true,
    claude: false,
    browser: false,
    agy: false,
    codeServer: true,
  });
  const [proxyForm, setProxyForm] = useState(null);
  const [proxyDirty, setProxyDirty] = useState(false);
  const [manual, setManual] = useState({ name: '', type: 'socks5', server: '', port: 1080, username: '', password: '' });
  const [importUrl, setImportUrl] = useState('');
  const [renameText, setRenameText] = useState('');
  const [diskTarget, setDiskTarget] = useState(20);
  const [nodeFilter, setNodeFilter] = useState('');
  const [showAllNodes, setShowAllNodes] = useState(false);
  const [nodesExpanded, setNodesExpanded] = useState(false);
  const [codexVM, setCodexVM] = useState('');
  const [desktopVM, setDesktopVM] = useState('');
  const [desktopApp, setDesktopApp] = useState('');
  const [desktopPicked, setDesktopPicked] = useState(false);
  const [browserVM, setBrowserVM] = useState('');
  const [browserPicked, setBrowserPicked] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => {
    try { return localStorage.getItem('agentvm.sidebarCollapsed') === '1'; } catch { return false; }
  });
  const lastRequestedNonceRef = useRef('');

  const toggleSidebar = () =>
    setSidebarCollapsed(v => {
      const n = !v;
      try { localStorage.setItem('agentvm.sidebarCollapsed', n ? '1' : '0'); } catch {}
      return n;
    });

  useEffect(() => {
    if (isRemoteWeb) {
      if (!remoteToken) return;
      const pull = () =>
        fetch('/api/state', { headers: { Authorization: 'Bearer ' + remoteToken } })
          .then(r => {
            if (r.status === 401) {
              setRemoteAuthFailed(true);
              return null;
            }
            return r.ok ? r.json() : null;
          })
          .then(obj => {
            if (obj && obj.vms) setState(old => ({ ...old, ...obj }));
          })
          .catch(() => {});
      window.__agentVMRemotePull = pull;
      window.__agentVMRemoteError = msg => setState(old => ({ ...old, error: msg }));
      window.__agentVMRemoteAuthFail = () => {
        setRemoteAuthFailed(true);
        setRemoteToken('');
      };
      pull();
      const timer = setInterval(pull, 1200);
      const es = new EventSource('/api/events?token=' + encodeURIComponent(remoteToken));
      es.onopen = () => setRemoteAuthFailed(false);
      es.onmessage = ev => {
        try {
          const obj = JSON.parse(ev.data);
          if (obj && typeof obj === 'object') setState(old => ({ ...old, ...obj }));
        } catch {}
      };
      es.onerror = () => {
        if (es.readyState === EventSource.CLOSED) setRemoteAuthFailed(true);
      };
      return () => {
        clearInterval(timer);
        es.close();
        delete window.__agentVMRemotePull;
        delete window.__agentVMRemoteError;
        delete window.__agentVMRemoteAuthFail;
      };
    }
    window.agentVMReceive = obj => setState(old => ({ ...old, ...obj }));
    bridge('ready');
    return () => {
      delete window.agentVMReceive;
    };
  }, [remoteToken]);

  useEffect(() => {
    if (state.remoteWorkbench?.port) setRemotePortInput(String(state.remoteWorkbench.port));
  }, [state.remoteWorkbench?.port]);

  useEffect(() => {
    if (state.proxy && !proxyDirty) {
      setProxyForm({
        proxy_mode: state.proxy.proxy_mode,
        managed_enabled: state.proxy.managed_enabled,
        use_proxy: state.proxy.use_proxy,
        custom_proxy_url: state.proxy.custom_proxy_url,
        dns_url: state.proxy.dns_url,
        port: state.proxy.port,
      });
    }
  }, [state.proxy, proxyDirty]);

  // Handle cross-page navigation requests from Swift (e.g. screenshot to chat, desktop VM picker)
  useEffect(() => {
    const req = state.requestedPage;
    if (!req?.nonce || req.nonce === lastRequestedNonceRef.current) return;
    lastRequestedNonceRef.current = req.nonce;
    if (req.vm) {
      setCodexVM(req.vm);
      setDesktopVM(req.vm);
      setDesktopPicked(true);
      setBrowserVM(req.vm);
      setBrowserPicked(true);
    }
    if (req.page) setPage(req.page);
    if (req.pick) {
      setModal({ type: req.page === 'browser' ? 'browserPick' : 'codexDesktopPick' });
    }
  }, [state.requestedPage?.nonce]);

  const vms = useMemo(() => state.vms.filter(v => v.name !== 'base' && v.name !== 'base-building'), [state.vms]);
  const running = useMemo(() => vms.filter(v => v.status === 'Running'), [vms]);
  const stoppedCount = vms.length - running.length;
  const visible = vms.filter(v => {
    if (vmScope === 'running' && v.status !== 'Running') return false;
    if (vmScope === 'stopped' && v.status === 'Running') return false;
    return (v.displayName || v.name).toLowerCase().includes(filter.toLowerCase());
  });
  const codexVMs = running;

  useEffect(() => {
    if (desktopApp && state.activeCodexDesktopApp && state.activeCodexDesktopApp !== desktopApp) {
      setDesktopApp(state.activeCodexDesktopApp);
    }
  }, [state.activeCodexDesktopApp]);

  useEffect(() => {
    if (running.length && (!codexVM || !running.some(v => v.name === codexVM))) {
      setCodexVM(running[0].name);
    }
    if (codexVMs.length && (!desktopVM || !codexVMs.some(v => v.name === desktopVM))) {
      setDesktopVM(codexVMs[0].name);
      if (codexVMs.length === 1) setDesktopPicked(true);
    }
    if (!codexVMs.length) {
      setDesktopVM('');
      setDesktopPicked(false);
    }
    if (running.length && (!browserVM || !running.some(v => v.name === browserVM))) {
      setBrowserVM(running[0].name);
      if (running.length === 1) setBrowserPicked(true);
    }
    if (!running.length) {
      setBrowserVM('');
      setBrowserPicked(false);
    }
  }, [running, codexVMs, codexVM, desktopVM, browserVM]);

  useEffect(() => {
    if (modal?.type === 'codexDesktopPick') {
      codexVMs.forEach(v => {
        bridge('codexDesktopCheck', { name: v.name, app: 'codex' });
        bridge('codexDesktopCheck', { name: v.name, app: 'claude' });
      });
    } else if (modal?.type === 'browserPick') {
      running.forEach(v => bridge('browserCheck', { name: v.name }));
    }
  }, [modal?.type]);

  const openCodexDesktopTab = () => {
    setPage('codexDesktop');
    codexVMs.forEach(v => {
      bridge('codexDesktopCheck', { name: v.name, app: 'codex' });
      bridge('codexDesktopCheck', { name: v.name, app: 'claude' });
    });
    if (codexVMs.length > 1 && !desktopPicked) {
      setModal({ type: 'codexDesktopPick' });
    } else if (codexVMs.length === 1) {
      setDesktopVM(codexVMs[0].name);
      setDesktopPicked(true);
      setSidebarCollapsed(true);
    } else if (desktopPicked) {
      setSidebarCollapsed(true);
    }
  };

  const openBrowserTab = () => {
    setPage('browser');
    running.forEach(v => bridge('browserCheck', { name: v.name }));
    if (running.length > 1 && !browserPicked) {
      setModal({ type: 'browserPick' });
    } else if (running.length === 1) {
      setBrowserVM(running[0].name);
      setBrowserPicked(true);
      setSidebarCollapsed(true);
    } else if (browserPicked) {
      setSidebarCollapsed(true);
    }
  };

  // Global keyboard shortcuts (Cmd+1..6)
  useEffect(() => {
    if (isRemoteWeb) return;
    const onKey = e => {
      if (!e.metaKey || e.ctrlKey || e.altKey) return;
      const num = Number(e.key);
      if (num >= 1 && num <= tabs.length) {
        e.preventDefault();
        const tid = tabs[num - 1].id;
        if (tid === 'codexDesktop') openCodexDesktopTab();
        else if (tid === 'browser') openBrowserTab();
        else setPage(tid);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [page, codexVMs.length, desktopPicked, running.length, browserPicked]);

  const proxy = state.proxy;
  const nodes = useMemo(
    () => (proxy?.sources || []).flatMap(s => (s.nodes || []).map(n => ({ ...n, source: s.name }))),
    [proxy?.sources]
  );
  const activeNodeId = proxy?.route?.[0] || proxy?.selected || '';
  const activeNode = useMemo(() => nodes.find(n => n.id === activeNodeId) || null, [nodes, activeNodeId]);
  const filteredNodes = useMemo(() => {
    const q = nodeFilter.trim().toLowerCase();
    const list = q
      ? nodes.filter(
          n =>
            (n.name || '').toLowerCase().includes(q) ||
            (n.type || '').toLowerCase().includes(q) ||
            (n.source || '').toLowerCase().includes(q)
        )
      : nodes;
    if (!activeNodeId) return list;
    return [...list].sort((a, b) => (a.id === activeNodeId ? -1 : b.id === activeNodeId ? 1 : 0));
  }, [nodes, nodeFilter, activeNodeId]);
  const displayedNodes = showAllNodes ? filteredNodes : filteredNodes.slice(0, 40);

  const refreshAction =
    page === 'proxy' ? 'proxyRefresh' : page === 'quota' ? 'refreshQuotas' : page === 'versions' ? 'cliCheck' : 'refresh';

  const act = (type, vm) => {
    if (type === 'stop' || type === 'delete') setModal({ type, vm });
    else bridge(type, { name: vm.name });
  };
  const confirm = () => {
    if (modal?.type === 'stop' || modal?.type === 'delete') bridge(modal.type, { name: modal.vm.name });
    if (modal?.type === 'deleteSource') bridge('proxySourceDelete', { id: modal.source.id });
    if (modal?.type === 'closeGate') bridge('proxyGateClose');
    setModal(null);
  };
  const submitCreate = () => {
    bridge('create', { ...create });
    setModal({ type: 'creating' });
  };

  const navigateTab = (targetPage, targetVM) => {
    if (targetVM) {
      setCodexVM(targetVM);
      setDesktopVM(targetVM);
      setDesktopPicked(true);
      setBrowserVM(targetVM);
    }
    if (targetPage === 'codexDesktop' && !targetVM) {
      openCodexDesktopTab();
      return;
    }
    setPage(targetPage);
  };

  if (isRemoteWeb && (!remoteToken || remoteAuthFailed)) {
    return (
      <div className="remote-auth-wrap">
        <form
          className="panel remote-auth-card"
          onSubmit={e => {
            e.preventDefault();
            const t = remoteTokenInput.trim();
            if (!t) return;
            try { sessionStorage.setItem('agentvm.remoteToken', t); } catch {}
            setRemoteAuthFailed(false);
            setRemoteToken(t);
          }}
        >
          <h2>Agent 对话工作台</h2>
          <p className="muted">
            {remoteAuthFailed ? '访问口令无效或已更换，请重新输入。' : '请输入 Mac 桌面端「设置 → 手机远程工作台」中的访问口令。'}
          </p>
          <input
            type="password"
            value={remoteTokenInput}
            onChange={e => setRemoteTokenInput(e.target.value)}
            placeholder="输入访问口令"
            autoFocus
          />
          <button className="primary" type="submit">连接工作台</button>
        </form>
      </div>
    );
  }

  return (
    <div className={'layout' + (isRemoteWeb ? ' remote-web' : '')}>
      {!isRemoteWeb && (
        <aside className={'sidebar' + (sidebarCollapsed ? ' collapsed' : '')}>
          <div
            className="brand"
            onClick={toggleSidebar}
            title={sidebarCollapsed ? '展开侧边栏' : '收起侧边栏'}
            style={{ cursor: 'pointer' }}
          >
            <div className="brand-icon"><Monitor size={18} /></div>
            <div className="brand-text">
              <strong>Agent VM</strong>
            </div>
          </div>
          <nav>
            {tabs.map((t, idx) => (
              <button
                key={t.id}
                title={`${t.label} (⌘${idx + 1})`}
                className={'nav-item ' + (page === t.id ? 'selected' : '')}
                onClick={() => (t.id === 'codexDesktop' ? openCodexDesktopTab() : t.id === 'browser' ? openBrowserTab() : setPage(t.id))}
              >
                <t.icon size={16} />
                <span className="nav-text">{t.label}</span>
                {t.id === 'vms' && <span className="nav-count">{vms.length}</span>}
                {t.id === 'versions' && (state.cliMonitor?.pendingCount || 0) > 0 && (
                  <span className="nav-count nav-count-live">{state.cliMonitor.pendingCount}</span>
                )}
              </button>
            ))}
          </nav>
          <div className="sidebar-bottom">
            <div className="sidebar-separator" />
            <div className="side-status">
              <span className="status-dot active" />
              <span>{running.length} 运行中</span>
            </div>
            <div className="side-status">
              <span className={'status-dot ' + (proxy?.use_proxy ? 'active' : '')} />
              <span>{proxy?.use_proxy ? '代理已开' : '直连'}</span>
            </div>
            <button className="sidebar-refresh" onClick={() => bridge('refresh')}>
              <RefreshCw size={13} /> 刷新
            </button>
          </div>
        </aside>
      )}

      <main className="main">
        <div className={'content' + (isRemoteWeb ? ' codex-content' : page === 'codexDesktop' ? ' codex-desktop-content' : page === 'browser' ? ' browser-content' : '')}>
          {!isRemoteWeb && page === 'vms' && (
            <>
              <SectionTitle title="虚拟机">
                <button className="primary" onClick={() => setModal({ type: 'create' })}>
                  <Plus size={16} /> 新建
                </button>
              </SectionTitle>
              <div className="section-row">
                <div className="mode-segmented" role="tablist" aria-label="状态筛选">
                  <button
                    type="button"
                    className={'mode-seg-btn' + (vmScope === 'all' ? ' active' : '')}
                    onClick={() => setVmScope('all')}
                  >
                    全部 {vms.length}
                  </button>
                  <button
                    type="button"
                    className={'mode-seg-btn' + (vmScope === 'running' ? ' active' : '')}
                    onClick={() => setVmScope('running')}
                  >
                    运行中 {running.length}
                  </button>
                  <button
                    type="button"
                    className={'mode-seg-btn' + (vmScope === 'stopped' ? ' active' : '')}
                    onClick={() => setVmScope('stopped')}
                  >
                    已停止 {stoppedCount}
                  </button>
                </div>
                <label className="search">
                  <Search size={14} />
                  <input value={filter} onChange={e => setFilter(e.target.value)} placeholder="搜索" />
                </label>
              </div>
              {visible.length ? (
                <div className="vm-grid">
                  {visible.map(v => (
                    <VMCard
                      key={v.name}
                      vm={v}
                      state={state}
                      select={({ type, vm, app }) => {
                        if (type === 'rename') {
                          setRenameText(vm.displayName === vm.name ? '' : vm.displayName);
                          setModal({ type, vm });
                        } else if (type === 'resizeDisk') {
                          const cur = parseInt(String(vm.disk || '10'), 10) || 10;
                          setDiskTarget(Math.max(20, cur + 10));
                          setModal({ type, vm });
                        } else if (type === 'mounts' || type === 'proxyRoute') {
                          setNodeFilter('');
                          setModal({ type, vm });
                        } else if (type === 'codexDesktopOpen') {
                          setDesktopVM(vm.name);
                          setDesktopPicked(true);
                          setDesktopApp(app || '');
                          setSidebarCollapsed(true);
                          setPage('codexDesktop');
                          if (app) {
                            bridge('codexDesktopOpen', { name: vm.name, app });
                          }
                        } else if (type === 'browserOpen') {
                          setBrowserVM(vm.name);
                          setBrowserPicked(true);
                          setSidebarCollapsed(true);
                          setPage('browser');
                          bridge('browserOpen', { name: vm.name });
                        } else {
                          act(type, vm);
                        }
                      }}
                    />
                  ))}
                </div>
              ) : (
                <div className="empty">
                  <Monitor size={28} />
                  <strong>暂无虚拟机</strong>
                  <button className="primary" onClick={() => setModal({ type: 'create' })}>
                    <Plus size={15} /> 新建虚拟机
                  </button>
                </div>
              )}
              {state.buildStarted && (
                <div className="notice">
                  <LoaderCircle size={16} /> {state.buildComplete ? '创建完成' : `正在创建 · 阶段 ${state.buildStage}`}
                </div>
              )}
            </>
          )}

          {isRemoteWeb && (
            <section className="panel" aria-label="远程虚拟机管理" style={{ marginBottom: 16 }}>
              <div className="flex-between" style={{ gap: 12, flexWrap: 'wrap' }}>
                <div>
                  <h2>远程虚拟机</h2>
                  <p className="muted">在 Mac Pro 上运行。远程模式目前只支持查看、启动和停止，不开放删除或任意命令。</p>
                </div>
                <button className="secondary" disabled={!!state.busy} onClick={() => bridge('refresh')}>
                  <RefreshCw size={15} /> 刷新
                </button>
              </div>
              {vms.length === 0 ? (
                <div className="muted">远程主机暂无可管理的虚拟机。</div>
              ) : (
                <div className="vm-grid">
                  {vms.map(vm => {
                    const runningVM = vm.status === 'Running';
                    const stoppedVM = vm.status === 'Stopped';
                    return (
                      <div className="panel" key={vm.name} style={{ padding: 14, minWidth: 0 }}>
                        <div className="flex-between" style={{ gap: 8 }}>
                          <strong style={{ overflowWrap: 'anywhere' }}>{vm.displayName || vm.name}</strong>
                          <span className="muted">{runningVM ? '运行中' : stoppedVM ? '已停止' : vm.status}</span>
                        </div>
                        <p className="muted">{vm.cpus} vCPU · {vm.memory} 内存 · {vm.disk} 磁盘</p>
                        <div className="inline-actions">
                          {stoppedVM && <button className="secondary" disabled={!!state.busy}
                            onClick={() => bridge('remoteVMStart', { name: vm.name })}>
                            <Play size={14} /> 启动
                          </button>}
                          {runningVM && <button className="secondary" disabled={!!state.busy}
                            onClick={() => {
                              if (window.confirm(`确定停止远程虚拟机「${vm.displayName || vm.name}」？正在运行的任务可能中断。`)) {
                                bridge('remoteVMStop', { name: vm.name });
                              }
                            }}>
                            <Square size={14} /> 停止
                          </button>}
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>
          )}

          {isRemoteWeb && (
            <ChatPage
              state={state}
              running={running}
              codexVM={codexVM}
              setCodexVM={setCodexVM}
              onNavigateTab={navigateTab}
            />
          )}

          {!isRemoteWeb && page === 'codexDesktop' && (
            <CodexDesktopPage
              state={state}
              codexVMs={codexVMs}
              desktopVM={desktopPicked || codexVMs.length === 1 ? desktopVM : ''}
              desktopApp={desktopApp}
              onSelectDesktopApp={setDesktopApp}
              sidebarCollapsed={sidebarCollapsed}
              modalOpen={!!modal}
              onOpenPicker={() => setModal({ type: 'codexDesktopPick' })}
              onResizeDisk={vm => {
                const cur = parseInt(String(vm.disk || '10'), 10) || 10;
                setDiskTarget(Math.max(20, cur + 10));
                setModal({ type: 'resizeDisk', vm });
              }}
              onNavigateTab={navigateTab}
            />
          )}

          {!isRemoteWeb && page === 'browser' && (
            <BrowserPage
              state={state}
              running={running}
              browserVM={browserPicked || running.length === 1 ? browserVM : ''}
              sidebarCollapsed={sidebarCollapsed}
              modalOpen={!!modal}
              onOpenPicker={() => setModal({ type: 'browserPick' })}
              onNavigateTab={navigateTab}
            />
          )}

          {page === 'quota' && (
            <>
              <SectionTitle title="AI 额度">
                <button className="secondary" onClick={() => bridge('refreshQuotas')}>
                  <RefreshCw size={15} /> 刷新
                </button>
              </SectionTitle>
              <div className="quota-grid">
                {vms.map(vm => {
                  const vmAQ = state.agentQuotas?.[vm.name] || {};
                  const legacyQ = state.quotas[vm.name];
                  const rawAgents = state.agents?.[vm.name];
                  const quotaApps = ['codex', 'agy', 'claude'].filter(a =>
                    Array.isArray(rawAgents) ? rawAgents.includes(a) : !!vmAQ[a]
                  );
                  return (
                    <section className="panel" key={vm.name}>
                      <div className="flex-between">
                        <strong>{vm.displayName || vm.name}</strong>
                        <span className="muted">
                          {vm.status !== 'Running'
                            ? '已停止'
                            : quotaApps.length
                              ? quotaApps.map(agentLabel).join(' · ')
                              : '无额度应用'}
                        </span>
                      </div>
                      {vm.status !== 'Running' ? (
                        <p className="muted">已停止</p>
                      ) : quotaApps.length === 0 ? (
                        <p className="muted">未启用 Codex / Antigravity / Claude</p>
                      ) : (
                        <div className="quota-agent-stack">
                          {quotaApps.map(app => {
                            const q =
                              vmAQ[app] ||
                              (app === 'codex' && legacyQ
                                ? {
                                    ...legacyQ,
                                    windows: [
                                      legacyQ.five_hour ? { label: '5 小时', ...legacyQ.five_hour } : null,
                                      legacyQ.weekly ? { label: '每周', ...legacyQ.weekly } : null,
                                    ].filter(Boolean),
                                  }
                                : null);
                            const wins = q?.status === 'ok' ? q.windows || [] : [];
                            const badge = q?.plan_type ? q.plan_type : quotaStatusText(q);
                            return (
                              <div className="quota-agent-block" key={app}>
                                <div className="flex-between quota-agent-head">
                                  <span>{agentLabel(app)}</span>
                                  {badge && <small className="muted">{badge}</small>}
                                </div>
                                {wins.length > 0 ? (
                                  wins.map((w, idx) => (
                                    <QuotaBar key={w.label || idx} label={w.label || String(idx + 1)} window={w} />
                                  ))
                                ) : (
                                  <p className="muted text-xs" style={{ margin: '6px 0 0' }}>
                                    {quotaStatusText(q)}
                                  </p>
                                )}
                              </div>
                            );
                          })}
                        </div>
                      )}
                      {quotaApps.length > 0 && (
                        <button
                          className="small-button"
                          disabled={vm.status !== 'Running'}
                          onClick={() => bridge('quota', { name: vm.name })}
                        >
                          <RefreshCw size={13} /> 刷新
                        </button>
                      )}
                    </section>
                  );
                })}
              </div>
            </>
          )}

          {!isRemoteWeb && page === 'versions' && (() => {
            const cli = state.cliMonitor || {};
            const cliAuto = cli.autoUpdate !== false;
            const cliChecking = !!cli.checking;
            const cliUpdating = !!cli.updating;
            const latestMap = cli.latest || {};
            const vmStates = cli.vms || {};
            const pendingCount = cli.pendingCount || 0;
            const formatTime = ts => (ts > 0 ? new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '—');
            return (
              <>
                <SectionTitle title="版本监控">
                  <div className="heading-actions">
                    <label className="cli-auto-toggle">
                      <input
                        type="checkbox"
                        checked={cliAuto}
                        onChange={e => bridge('cliSetAutoUpdate', { enabled: e.target.checked })}
                      />
                      <span>自动更新</span>
                    </label>
                    <button
                      className="secondary"
                      disabled={cliChecking || cliUpdating || running.length === 0}
                      onClick={() => bridge('cliCheck')}
                    >
                      <RefreshCw size={14} className={cliChecking ? 'spin' : ''} />
                      {cliChecking ? '检查中' : '检查'}
                    </button>
                    <button
                      className="primary"
                      disabled={cliUpdating || pendingCount === 0}
                      onClick={() => bridge('cliUpdateAll')}
                    >
                      {cliUpdating ? '更新中...' : pendingCount > 0 ? `全部更新 (${pendingCount})` : '全部最新'}
                    </button>
                  </div>
                </SectionTitle>

                <div className="stat-grid">
                  {['codex', 'agy', 'claude'].map(agent => {
                    const latestVer = latestMap[agent] || '—';
                    let outdatedCount = 0;
                    let installedCount = 0;
                    running.forEach(vm => {
                      const rawAgents = state.agents?.[vm.name];
                      if (Array.isArray(rawAgents) && !rawAgents.includes(agent)) return;
                      const entry = vmStates[vm.name]?.entries?.[agent];
                      if (entry?.installed) installedCount += 1;
                      if (entry?.hasUpdate) outdatedCount += 1;
                    });
                    return (
                      <div className="stat" key={agent}>
                        <span>{agentLabel(agent)}</span>
                        <strong>{latestVer}</strong>
                        <small>
                          {cli.latestCheckedAt > 0
                            ? outdatedCount > 0
                              ? `${outdatedCount} 台待更新 · ${installedCount} 台虚拟机`
                              : `${installedCount} 台虚拟机 · 上次 ${formatTime(cli.latestCheckedAt)}`
                            : '待检查'}
                        </small>
                      </div>
                    );
                  })}
                </div>

                {vms.length === 0 ? (
                  <div className="empty">
                    <strong>暂无虚拟机</strong>
                  </div>
                ) : (
                  <div className="quota-grid">
                    {vms.map(vm => {
                      const vst = vmStates[vm.name] || {};
                      const entries = vst.entries || {};
                      const rawAgents = state.agents?.[vm.name];
                      const trackedApps = ['codex', 'agy', 'claude'].filter(a =>
                        Array.isArray(rawAgents) ? rawAgents.includes(a) : !!entries[a]
                      );
                      const rightStatus =
                        vm.status !== 'Running'
                          ? '已停止'
                          : vst.updating
                            ? '更新中'
                            : vst.checking
                              ? '检测中'
                              : vst.checkedAt > 0
                                ? formatTime(vst.checkedAt)
                                : '未检测';
                      return (
                        <section className="panel" key={vm.name}>
                          <div className="flex-between">
                            <strong>{vm.displayName || vm.name}</strong>
                            <span className="muted text-xs">{rightStatus}</span>
                          </div>
                          {vm.status !== 'Running' ? (
                            <p className="muted">已停止</p>
                          ) : trackedApps.length === 0 ? (
                            <p className="muted">未启用 Codex / Antigravity / Claude</p>
                          ) : (
                            <div className="cli-vm-list">
                              {trackedApps.map(agent => {
                                const e = entries[agent];
                                return (
                                  <div className="cli-vm-row" key={agent}>
                                    <span className="cli-agent-name">{agentLabel(agent)}</span>
                                    <span className="cli-ver-text">
                                      {!e
                                        ? '—'
                                        : !e.installed
                                          ? '未安装'
                                          : e.hasUpdate && e.latest
                                            ? `${e.current || '?'} → ${e.latest}`
                                            : e.current || '—'}
                                    </span>
                                    <div className="cli-row-action">
                                      {e?.updating ? (
                                        <span className="cli-pill updating">
                                          <LoaderCircle size={12} className="spin" /> 更新中
                                        </span>
                                      ) : e?.error ? (
                                        <button
                                          className="small-button"
                                          title={e.error}
                                          onClick={() => bridge('cliUpdateOne', { vm: vm.name, agent })}
                                        >
                                          重试
                                        </button>
                                      ) : e?.hasUpdate ? (
                                        <button
                                          className="small-button cli-update-btn"
                                          onClick={() => bridge('cliUpdateOne', { vm: vm.name, agent })}
                                        >
                                          更新
                                        </button>
                                      ) : e?.installed ? (
                                        <span className="cli-pill ok">最新</span>
                                      ) : null}
                                    </div>
                                  </div>
                                );
                              })}
                            </div>
                          )}
                          {vst.error && <p className="muted text-xs" style={{ color: 'var(--bad)', marginBottom: 0 }}>{vst.error}</p>}
                        </section>
                      );
                    })}
                  </div>
                )}
              </>
            );
          })()}

          {page === 'proxy' && (
            <>
              <SectionTitle title="网络代理" />
              {state.proxyError && (
                <div className="notice error">
                  <AlertTriangle size={16} />
                  {state.proxyError}
                </div>
              )}
              {state.proxyMessage && (
                <div className="info-strip">
                  <Activity size={16} />
                  {state.proxyMessage}
                </div>
              )}
              <section className="panel">
                <div className="section-row">
                  <h2>网关</h2>
                  <span className={'status ' + (proxy?.running ? 'running' : '')}>
                    <span className="status-dot" />
                    {proxy?.running ? '运行中' : '未运行'}
                  </span>
                </div>
                {proxyForm && (
                  <div className="form-grid">
                    <label>
                      代理模式
                      <select
                        value={proxyForm.proxy_mode || 'custom'}
                        onChange={e => {
                          setProxyDirty(true);
                          setProxyForm({ ...proxyForm, proxy_mode: e.target.value });
                        }}
                      >
                        <option value="custom">自定义 HTTP / SOCKS5</option>
                        <option value="mihomo">Mihomo 节点</option>
                      </select>
                    </label>
                    <label>
                      DoH 地址
                      <input
                        value={proxyForm.dns_url || ''}
                        onChange={e => {
                          setProxyDirty(true);
                          setProxyForm({ ...proxyForm, dns_url: e.target.value });
                        }}
                      />
                    </label>
                    {proxyForm.proxy_mode === 'custom' && (
                      <label className="form-wide">
                        代理地址
                        <input
                          value={proxyForm.custom_proxy_url || ''}
                          onChange={e => {
                            setProxyDirty(true);
                            setProxyForm({ ...proxyForm, custom_proxy_url: e.target.value });
                          }}
                        />
                      </label>
                    )}
                    <label className="check-row">
                      <input
                        type="checkbox"
                        checked={!!proxyForm.use_proxy}
                        onChange={e => {
                          setProxyDirty(true);
                          setProxyForm({ ...proxyForm, use_proxy: e.target.checked });
                        }}
                      />{' '}
                      启用代理
                    </label>
                    <label className="check-row">
                      <input
                        type="checkbox"
                        checked={!!proxyForm.managed_enabled}
                        onChange={e => {
                          setProxyDirty(true);
                          setProxyForm({ ...proxyForm, managed_enabled: e.target.checked });
                        }}
                      />{' '}
                      托管网络模式（安全验证未完成）
                    </label>
                  </div>
                )}
                <div className="inline-actions">
                  <button
                    className="primary"
                    onClick={() => {
                      bridge('proxyConfig', proxyForm || {});
                      setProxyDirty(false);
                    }}
                    disabled={!proxyForm || state.proxyBusy || !proxyDirty}
                  >
                    保存配置
                  </button>
                  {proxyDirty && (
                    <button
                      className="secondary"
                      onClick={() => {
                        setProxyDirty(false);
                        setProxyForm(null);
                      }}
                    >
                      撤销修改
                    </button>
                  )}
                </div>
              </section>
              <section className="panel">
                <div className="section-row">
                  <h2>节点与路由</h2>
                  <div className="inline-actions" style={{ marginTop: 0 }}>
                    <span className="muted">
                      {nodes.length} 个节点
                    </span>
                    {nodes.length > 0 && (
                      <button className="small-button" onClick={() => setNodesExpanded(x => !x)}>
                        {nodesExpanded ? '收起' : `展开 (${nodes.length})`}
                      </button>
                    )}
                  </div>
                </div>
                <div className="inline-form">
                  <input
                    placeholder="HTTPS 订阅地址"
                    value={importUrl}
                    onChange={e => setImportUrl(e.target.value)}
                  />
                  <button
                    className="secondary"
                    onClick={() => {
                      bridge('proxyImport', { url: importUrl });
                      setImportUrl('');
                    }}
                    disabled={!importUrl.startsWith('https://')}
                  >
                    导入订阅
                  </button>
                  <button className="secondary" onClick={() => setModal({ type: 'manual' })}>
                    添加节点
                  </button>
                </div>
                {(proxy?.sources?.length || 0) > 0 && (
                  <div className="source-list">
                    {(proxy?.sources || []).map(src => (
                      <div className="source-row" key={src.id}>
                        <div>
                          <strong>{src.name}</strong>
                          <small>
                            {src.nodes?.length || 0} 个节点 · {src.error || formatSubUsage(src.usage) || '订阅已导入'}
                          </small>
                        </div>
                        <button
                          className="small-button"
                          disabled={state.proxyBusy}
                          onClick={() => bridge('proxySourceRefresh', { id: src.id })}
                        >
                          <RefreshCw size={13} /> 更新
                        </button>
                        <button
                          className="small-button"
                          disabled={state.proxyBusy}
                          onClick={() => setModal({ type: 'deleteSource', source: src })}
                        >
                          移除
                        </button>
                      </div>
                    ))}
                  </div>
                )}
                {!nodesExpanded && activeNode && (
                  <div
                    className="node active"
                    style={{ border: '1px solid var(--line)', borderRadius: '10px', padding: '10px 12px', margin: '8px 0' }}
                  >
                    <span>
                      <Network size={15} />
                      <span className="node-name" title={activeNode.name}>
                        {activeNode.name}
                      </span>
                      <small>
                        {activeNode.source} · {activeNode.type}
                      </small>
                      <span className="node-badge">当前出口</span>
                    </span>
                    <button className="small-button" onClick={() => setNodesExpanded(true)}>
                      切换节点
                    </button>
                  </div>
                )}
                {nodes.length > 0 && nodesExpanded && (
                  <>
                    <div className="node-toolbar">
                      <label className="search node-search">
                        <Search size={14} />
                        <input
                          value={nodeFilter}
                          onChange={e => {
                            setNodeFilter(e.target.value);
                            setShowAllNodes(false);
                          }}
                          placeholder="搜索节点名称、协议或来源"
                        />
                      </label>
                      {proxy?.proxy_mode === 'mihomo' && (
                        <button
                          className="small-button"
                          disabled={state.proxyBusy}
                          onClick={() => bridge('proxyDelay', {})}
                        >
                          全部测速
                        </button>
                      )}
                    </div>
                    <div className="node-list">
                      {displayedNodes.map(n => {
                        const isActive = n.id === activeNodeId;
                        return (
                          <div key={n.id} className={'node ' + (isActive ? 'active' : '')}>
                            <span>
                              <Network size={15} />
                              <span className="node-name" title={n.name}>
                                {n.name}
                              </span>
                              <small>
                                {n.source} · {n.type}
                              </small>
                              {isActive && <span className="node-badge">当前出口</span>}
                            </span>
                            <div className="node-actions">
                              {proxy?.proxy_mode === 'mihomo' && (
                                <button
                                  onClick={() => bridge('proxyDelay', { id: n.id })}
                                  className="small-button"
                                  disabled={state.proxyBusy}
                                >
                                  测速
                                </button>
                              )}
                              <button
                                onClick={() => bridge('proxyRoute', { id: n.id })}
                                className="small-button"
                                disabled={state.proxyBusy || isActive}
                              >
                                {isActive ? '已启用' : <>设为出口 <ArrowRight size={13} /></>}
                              </button>
                            </div>
                          </div>
                        );
                      })}
                      {displayedNodes.length === 0 && <p className="muted">没有匹配的节点。</p>}
                    </div>
                    {!showAllNodes && filteredNodes.length > 40 && (
                      <div className="node-more">
                        <button className="small-button" onClick={() => setShowAllNodes(true)}>
                          显示全部 {filteredNodes.length} 个节点（当前显示前 40 个）
                        </button>
                      </div>
                    )}
                  </>
                )}
                {nodes.length === 0 && <p className="muted">暂未导入代理节点。</p>}
                <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('proxyStop')}>
                    停止代理核心
                  </button>
                </div>
              </section>
              <div className="proxy-bottom-grid">
                <section className="panel">
                  <div className="section-row">
                    <h2>安全自检</h2>
                    <button className="secondary" onClick={() => bridge('proxyProbe')} disabled={state.proxyBusy}>
                      <ShieldCheck size={15} /> 检查
                    </button>
                  </div>
                  <KV name="出口 IP" value={proxy?.last_probe?.exit_ip || '—'} />
                  <KV name="门禁状态" value={(proxy?.gates || []).map(g => g.state).join(' / ') || '无'} />
                  {(proxy?.last_probe?.report?.checks || []).length > 0 && (
                    <div className="check-list">
                      {(proxy?.last_probe?.report?.checks || []).map(c => (
                        <div className="check-line" key={c.id}>
                          {c.state === 'passed' ? (
                            <CheckCircle2 size={14} color="var(--ok)" />
                          ) : (
                            <ShieldAlert size={14} color="var(--warn)" />
                          )}
                          <span>{c.id}</span>
                          <span className="muted">{c.state}</span>
                        </div>
                      ))}
                    </div>
                  )}
                  <div className="inline-actions">
                    <button className="small-button" onClick={() => setModal({ type: 'closeGate' })}>
                      关闭门禁
                    </button>
                  </div>
                </section>
                <section className="panel">
                  <div className="section-row">
                    <h2>活跃连接</h2>
                    <button className="secondary" onClick={() => bridge('proxyConnections')}>
                      <RefreshCw size={15} /> 刷新
                    </button>
                  </div>
                  <KV name="上行" value={((state.proxyUploadTotal || 0) / 1048576).toFixed(2) + ' MB'} />
                  <KV name="下行" value={((state.proxyDownloadTotal || 0) / 1048576).toFixed(2) + ' MB'} />
                  {(state.proxyConnections || []).slice(0, 30).map(c => (
                    <div key={c.id} className="connection-row">
                      <span>
                        {c.host}:{c.port}
                      </span>
                      <small>
                        {c.network} · ↑{Math.round(c.upload / 1024)}K ↓{Math.round(c.download / 1024)}K
                      </small>
                    </div>
                  ))}
                  {(!state.proxyConnections || state.proxyConnections.length === 0) && (
                    <p className="muted">暂无连接</p>
                  )}
                </section>
              </div>
            </>
          )}

          {!isRemoteWeb && page === 'settings' && (
            <>
              <SectionTitle title="设置" />
              <section className="panel">
                <h2>智能内存管理</h2>
                <KV
                  name="宿主机内存压力"
                  value={state.smartMemory?.pressureLabel || '正常'}
                />
                <KV
                  name="运行中 VM 宿主机总占用"
                  value={
                    state.smartMemory?.totalHostFootprintMB > 0
                      ? `${(state.smartMemory.totalHostFootprintMB / 1024).toFixed(2)} GB`
                      : '0.00 GB'
                  }
                />
                <div className="form-grid" style={{ marginTop: 10 }}>
                  <label className="checkbox">
                    <span>启用 VZ 动态内存气球回收（自动将空闲缓存归还 macOS）</span>
                    <input
                      type="checkbox"
                      checked={state.smartMemory?.balloonEnabled !== false}
                      onChange={e => bridge('smartMemoryConfig', { balloonEnabled: e.target.checked })}
                    />
                  </label>
                  <label>
                    闲置虚拟机自动休眠
                    <select
                      value={state.smartMemory?.autoSleepMinutes ?? 30}
                      onChange={e => bridge('smartMemoryConfig', { autoSleepMinutes: Number(e.target.value) })}
                    >
                      <option value={0}>关闭</option>
                      <option value={15}>15 分钟无活动</option>
                      <option value={30}>30 分钟无活动（推荐）</option>
                      <option value={60}>60 分钟无活动</option>
                    </select>
                  </label>
                  <label>
                    闲置桌面自动休眠（Codex / Claude 桌面端）
                    <select
                      value={state.smartMemory?.guiIdleMinutes ?? 10}
                      onChange={e => bridge('smartMemoryConfig', { guiIdleMinutes: Number(e.target.value) })}
                    >
                      <option value={0}>关闭</option>
                      <option value={5}>5 分钟</option>
                      <option value={10}>10 分钟（推荐）</option>
                      <option value={20}>20 分钟</option>
                    </select>
                  </label>
                </div>
                <div className="inline-actions">
                  <button
                    className="secondary"
                    disabled={(state.memoryReclaiming || []).length > 0}
                    onClick={() => bridge('reclaimAllMemory')}
                  >
                    {(state.memoryReclaiming || []).length > 0 ? '正在回收…' : '一键优化所有运行中 VM 内存'}
                  </button>
                </div>
              </section>
              <section className="panel">
                <h2>远程 VM · SSH 终端</h2>
                <p className="muted">通过 EasyTier 连接 Mac Pro，然后直接进入指定 Linux 虚拟机使用 Claude Code / Codex CLI。无需启动远程网页工作台。请先配置 SSH 密钥和 known_hosts，远端虚拟机必须已运行。</p>
                <div className="form-grid">
                  {[
                    ['name', '主机名称', 'Mac Pro'],
                    ['hostname', 'EasyTier IP / 主机名', '10.126.126.2'],
                    ['username', 'SSH 用户名', 'macuser'],
                    ['sshPort', 'SSH 端口', '22'],
                    ['workbenchPort', '工作台端口', '18080'],
                  ].map(([key, label, placeholder]) => (
                    <label key={key}>{label}
                      <input value={remoteHostForm[key]} placeholder={placeholder}
                        onChange={e => setRemoteHostForm(f => ({ ...f, [key]: e.target.value }))} />
                    </label>
                  ))}
                </div>
                <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('remoteHostAdd', {
                    ...remoteHostForm,
                    sshPort: Number(remoteHostForm.sshPort),
                    workbenchPort: Number(remoteHostForm.workbenchPort),
                  })}>添加远程主机</button>
                </div>
                <div className={state.remoteHostConnectionState === 'error' ? 'notice error' : 'muted'} style={{ margin: '10px 0' }} role="status">
                  {state.remoteHostStatus || '未连接'}
                </div>
                {(state.remoteHosts || []).map(h => (
                  <div className="web-code-row" key={h.id} style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                    <span style={{ flex: 1, minWidth: 160 }}>{h.name} · {h.username}@{h.hostname}:{h.sshPort}</span>
                    <input
                      aria-label={`目标虚拟机名称 - ${h.name}`}
                      placeholder="VM 名称"
                      style={{ width: 155 }}
                      value={remoteVMNames[h.id] || ''}
                      onChange={e => setRemoteVMNames(x => ({ ...x, [h.id]: e.target.value }))}
                    />
                    <button className="primary"
                      disabled={!/^[a-zA-Z0-9._-]{1,80}$/.test(remoteVMNames[h.id] || '')}
                      onClick={() => bridge('remoteVMTerminal', { id: h.id, vmName: remoteVMNames[h.id] })}>
                      <Terminal size={14} /> 连接 VM
                    </button>
                    <button className="secondary" disabled={state.remoteHostConnectionState === 'connecting'}
                      onClick={() => bridge('remoteHostConnect', { id: h.id })}>
                      {state.activeRemoteHostID === h.id ? (state.remoteHostConnectionState === 'connecting' ? '正在连接网页…' : '网页重连') : '网页模式'}
                    </button>
                    {state.activeRemoteHostID === h.id && state.remoteHostConnectionState === 'connected' && (
                      <button className="secondary" onClick={() => bridge('remoteHostOpen')}>打开工作台</button>
                    )}
                    <button className="secondary" onClick={() => {
                      if (window.confirm(`确定移除远程主机「${h.name}」？`)) bridge('remoteHostRemove', { id: h.id });
                    }}>移除</button>
                  </div>
                ))}
                {!!state.activeRemoteHostID && <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('remoteHostDisconnect')}>断开连接</button>
                </div>}
                <p className="muted">输入 Mac Pro 上的虚拟机名称，点击「连接 VM」即可在 Terminal 中打开虚拟机 Shell。网页模式是旧功能，可选；连接 VM 不依赖网页模式。</p>
              </section>
              <section className="panel">
                <h2>本机远程工作台（提供给其他设备连接）</h2>
                <div className="form-grid">
                  <label className="checkbox">
                    <span>启用远程访问</span>
                    <input
                      type="checkbox"
                      checked={!!state.remoteWorkbench?.enabled}
                      onChange={e => bridge('remoteWorkbenchToggle', { enabled: e.target.checked })}
                    />
                  </label>
                  <label>
                    端口
                    <div className="inline-actions" style={{ marginTop: 0 }}>
                      <input
                        type="number"
                        min="1024"
                        max="65535"
                        value={remotePortInput}
                        onChange={e => setRemotePortInput(e.target.value)}
                      />
                      <button
                        className="secondary"
                        onClick={() => bridge('remoteWorkbenchSetPort', { port: Number(remotePortInput) })}
                      >
                        应用
                      </button>
                    </div>
                  </label>
                </div>
                <KV name="访问口令" value={state.remoteWorkbench?.token || '—'} />
                <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('remoteWorkbenchRegenToken')}>
                    重新生成口令
                  </button>
                </div>
                {state.remoteWorkbench?.error && (
                  <div className="notice error" style={{ marginTop: 10 }}>
                    <AlertTriangle size={16} />
                    {state.remoteWorkbench.error}
                  </div>
                )}
                {state.remoteWorkbench?.enabled && (state.remoteWorkbench?.urls || []).length > 0 && (
                  <div style={{ marginTop: 12 }}>
                    {(state.remoteWorkbench.urls || []).map(u => (
                      <div key={u} className="web-code-row">
                        <span>{u}</span>
                      </div>
                    ))}
                  </div>
                )}
              </section>
              <section className="panel">
                <h2>工作区与诊断</h2>
                <KV name="共享工作区" value="~/AgentVM-Shared" />
                <KV name="会话目录" value="~/.agent-vm/sessions" />
                <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('doctor')}>
                    运行诊断
                  </button>
                  <button className="secondary" onClick={() => bridge('openShared')}>
                    <FolderOpen size={15} /> 打开共享文件夹
                  </button>
                </div>
              </section>
            </>
          )}

          {state.error && (
            <div className="notice error">
              <AlertTriangle size={17} />
              {state.error}
            </div>
          )}
        </div>
      </main>

      {!isRemoteWeb && (
        <ToastStack
          toasts={state.toasts || []}
          onNavigateVM={vmName => {
            if (codexVMs.some(v => v.name === vmName)) {
              setDesktopVM(vmName);
              setDesktopPicked(true);
              setSidebarCollapsed(true);
              setPage('codexDesktop');
            } else {
              setPage('vms');
            }
          }}
        />
      )}

      {modal && (
        <div
          className="modal-backdrop"
          onMouseDown={e => {
            if (e.target === e.currentTarget && modal.type !== 'creating') setModal(null);
          }}
        >
          <div className="modal" role="dialog" aria-modal="true">
            {modal.type === 'create' && (
              <>
                <h2>新建虚拟机</h2>
                <div className="form-grid">
                  <label className="form-wide">
                    虚拟机名称
                    <input
                      autoFocus
                      value={create.name}
                      onChange={e => setCreate({ ...create, name: e.target.value })}
                      placeholder="例如：开发环境"
                    />
                  </label>
                  <label>
                    CPU 核数
                    <input
                      type="number"
                      min="1"
                      max="16"
                      value={create.cpus}
                      onChange={e => setCreate({ ...create, cpus: Number(e.target.value) })}
                    />
                  </label>
                  <label>
                    内存（GB）
                    <input
                      type="number"
                      min="2"
                      max="64"
                      value={create.memory}
                      onChange={e => setCreate({ ...create, memory: Number(e.target.value) })}
                    />
                  </label>
                  <label>
                    磁盘（GB）
                    <input
                      type="number"
                      min="10"
                      max="1024"
                      value={create.disk}
                      onChange={e => setCreate({ ...create, disk: Number(e.target.value) })}
                    />
                  </label>
                  <div className="form-wide">
                    <div style={{ fontSize: '12px', fontWeight: 500, color: 'var(--muted)', marginBottom: '8px' }}>
                      附带应用
                    </div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: '14px' }}>
                      <label className="check-row">
                        <input
                          type="checkbox"
                          checked={create.codex}
                          onChange={e => setCreate({ ...create, codex: e.target.checked })}
                        />{' '}
                        Codex
                      </label>
                      <label className="check-row">
                        <input
                          type="checkbox"
                          checked={create.claude}
                          onChange={e =>
                            setCreate({
                              ...create,
                              claude: e.target.checked,
                              browser: e.target.checked ? create.browser : false,
                            })
                          }
                        />{' '}
                        Claude Code
                      </label>
                      <label className="check-row">
                        <input
                          type="checkbox"
                          checked={create.agy}
                          onChange={e => setCreate({ ...create, agy: e.target.checked })}
                        />{' '}
                        Antigravity
                      </label>
                      <label className="check-row">
                        <input
                          type="checkbox"
                          checked={create.codeServer}
                          onChange={e => setCreate({ ...create, codeServer: e.target.checked })}
                        />{' '}
                        code-server
                      </label>
                    </div>
                    {create.claude && (
                      <div
                        style={{
                          marginTop: '10px',
                          padding: '9px 12px',
                          borderRadius: '8px',
                          background: 'var(--bg)',
                          border: '1px solid var(--line)',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'space-between',
                          gap: '12px',
                        }}
                      >
                        <span style={{ fontSize: '12px', color: 'var(--muted)' }}>
                          是否同时为 Claude Code 安装浏览器（Chromium）？
                        </span>
                        <label className="check-row" style={{ margin: 0 }}>
                          <input
                            type="checkbox"
                            checked={create.browser}
                            onChange={e => setCreate({ ...create, browser: e.target.checked })}
                          />{' '}
                          安装浏览器
                        </label>
                      </div>
                    )}
                  </div>
                </div>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    取消
                  </button>
                  <button
                    className="primary"
                    onClick={submitCreate}
                    disabled={
                      state.busy ||
                      !Number.isInteger(create.cpus) ||
                      create.cpus < 1 ||
                      create.cpus > 16 ||
                      !Number.isInteger(create.memory) ||
                      create.memory < 2 ||
                      create.memory > 64 ||
                      !Number.isInteger(create.disk) ||
                      create.disk < 10 ||
                      create.disk > 1024
                    }
                  >
                    创建
                  </button>
                </div>
              </>
            )}

            {modal.type === 'creating' && (
              <>
                <h2>正在准备虚拟机</h2>
                <p className="muted">
                  {state.buildComplete
                    ? '虚拟机创建完成。'
                    : state.error || '创建过程可能包含初始化 Linux 和安装工具。'}
                </p>
                <div className="dialog-actions">
                  <button className="primary" onClick={() => setModal(null)}>
                    返回列表
                  </button>
                </div>
              </>
            )}

            {(modal.type === 'stop' || modal.type === 'delete') && (
              <>
                <h2>{modal.type === 'stop' ? '停止虚拟机？' : '删除虚拟机？'}</h2>
                <p className="muted">
                  {modal.type === 'stop'
                    ? '停止会终止其中运行的 Agent 和终端会话，请先保存工作。'
                    : modal.vm?.status === 'Running'
                      ? '该虚拟机正在运行，删除将先停止它并移除 VM 系统盘内的数据；共享目录不会被删除。'
                      : '删除将移除 VM 系统盘内的数据；共享目录不会被删除。'}
                </p>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    取消
                  </button>
                  <button className="danger-button" onClick={confirm}>
                    {modal.type === 'stop' ? '确认停止' : '确认删除'}
                  </button>
                </div>
              </>
            )}

            {(modal.type === 'deleteSource' || modal.type === 'closeGate') && (
              <>
                <h2>{modal.type === 'closeGate' ? '关闭网络门禁？' : '删除节点来源？'}</h2>
                <p className="muted">
                  {modal.type === 'closeGate'
                    ? '将撤销当前托管连接授权。'
                    : '将删除节点来源「' + modal.source.name + '」及其节点配置。'}
                </p>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    取消
                  </button>
                  <button className="danger-button" onClick={confirm}>
                    确认
                  </button>
                </div>
              </>
            )}

            {modal.type === 'rename' && (
              <>
                <h2>修改名称</h2>
                <label className="dialog-field">
                  名称
                  <input
                    autoFocus
                    maxLength="80"
                    value={renameText}
                    placeholder={modal.vm.displayName || modal.vm.name}
                    onChange={e => setRenameText(e.target.value)}
                  />
                </label>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    取消
                  </button>
                  <button
                    className="primary"
                    onClick={() => {
                      bridge('rename', { name: modal.vm.name, label: renameText });
                      setModal(null);
                    }}
                  >
                    保存
                  </button>
                </div>
              </>
            )}

            {modal.type === 'resizeDisk' &&
              (() => {
                const curDisk = parseInt(String(modal.vm.disk || '10'), 10) || 10;
                const targetNum = Number(diskTarget);
                const validTarget = Number.isInteger(targetNum) && targetNum > curDisk && targetNum <= 1024;
                const presets = [curDisk + 10, 20, 30, 40].filter(
                  (v, i, arr) => v > curDisk && v <= 1024 && arr.indexOf(v) === i
                );
                return (
                  <>
                    <h2>扩容磁盘 · {modal.vm.displayName || modal.vm.name}</h2>
                    <div className="form-grid">
                      <label className="form-wide">
                        目标容量（当前 {modal.vm.disk || curDisk + 'GiB'}，单位 GiB）
                        <input
                          autoFocus
                          type="number"
                          min={curDisk + 1}
                          max="1024"
                          value={diskTarget}
                          onChange={e => setDiskTarget(Number(e.target.value))}
                        />
                      </label>
                    </div>
                    {presets.length > 0 && (
                      <div className="inline-actions" style={{ marginTop: 0, marginBottom: 10 }}>
                        {presets.map(gb => (
                          <button
                            key={gb}
                            type="button"
                            className={targetNum === gb ? 'primary' : 'secondary'}
                            onClick={() => setDiskTarget(gb)}
                          >
                            {gb} GiB
                          </button>
                        ))}
                      </div>
                    )}
                    <p className="muted text-xs" style={{ marginTop: 4 }}>
                      {modal.vm.status === 'Running' ? '将自动重启以扩展分区，数据保留' : '将自动扩展分区，数据保留'}
                      {state.hostDiskAvailGB > 0 ? ` · 宿主机可用 ${state.hostDiskAvailGB} GB` : ''}
                    </p>
                    <div className="dialog-actions">
                      <button className="secondary" onClick={() => setModal(null)}>
                        取消
                      </button>
                      <button
                        className="primary"
                        disabled={!validTarget || state.busy}
                        onClick={() => {
                          bridge('resizeDisk', { name: modal.vm.name, disk: targetNum });
                          setModal(null);
                        }}
                      >
                        扩容
                      </button>
                    </div>
                  </>
                );
              })()}

            {modal.type === 'mounts' && (
              <>
                <h2>共享文件夹 · {modal.vm.displayName || modal.vm.name}</h2>
                <div className="mount-list">
                  <div className="mount-entry">
                    <span>~/AgentVM-Shared</span>
                    <small>共享 · 读写</small>
                  </div>
                  {(state.mounts[modal.vm.name] || []).map(m => (
                    <div className="mount-entry" key={m.path + ':' + m.mode}>
                      <span title={m.path}>{m.path}</span>
                      <small>{m.mode === 'rw' ? '读写' : '只读'}</small>
                      <button
                        className="small-button"
                        onClick={() => setModal({ type: 'removeMount', vm: modal.vm, mount: m })}
                      >
                        移除
                      </button>
                    </div>
                  ))}
                </div>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => bridge('mount', { name: modal.vm.name, writable: false })}>
                    添加只读
                  </button>
                  <button className="secondary" onClick={() => bridge('mount', { name: modal.vm.name, writable: true })}>
                    添加读写
                  </button>
                  <button className="primary" onClick={() => setModal(null)}>
                    完成
                  </button>
                </div>
              </>
            )}

            {modal.type === 'removeMount' && (
              <>
                <h2>移除文件夹挂载？</h2>
                <p className="muted">
                  {modal.mount.path} · {modal.mount.mode === 'rw' ? '读写' : '只读'}。不会删除宿主机文件。
                </p>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal({ type: 'mounts', vm: modal.vm })}>
                    返回
                  </button>
                  <button
                    className="danger-button"
                    onClick={() => {
                      bridge('removeMount', { name: modal.vm.name, path: modal.mount.path, mode: modal.mount.mode });
                      setModal({ type: 'mounts', vm: modal.vm });
                    }}
                  >
                    移除挂载
                  </button>
                </div>
              </>
            )}

            {modal.type === 'proxyRoute' &&
              (() => {
                const vmRoute = state.vmProxyRoutes?.[modal.vm.name] || '';
                const list = nodeFilter.trim()
                  ? nodes.filter(
                      n =>
                        (n.name || '').toLowerCase().includes(nodeFilter.trim().toLowerCase()) ||
                        (n.type || '').toLowerCase().includes(nodeFilter.trim().toLowerCase()) ||
                        (n.source || '').toLowerCase().includes(nodeFilter.trim().toLowerCase())
                    )
                  : nodes;
                return (
                  <>
                    <h2>代理出口 · {modal.vm.displayName || modal.vm.name}</h2>
                    <p className="muted">
                      默认与全局出口保持一致；设为独立节点后，首次生效需重启该虚拟机，之后可在独立节点间即时切换。
                    </p>
                    {proxy?.proxy_mode !== 'mihomo' ? (
                      <p className="muted">当前未启用 Mihomo 节点模式，请先在「网络代理」中切换到 Mihomo 节点模式。</p>
                    ) : nodes.length === 0 ? (
                      <p className="muted">暂未导入代理节点，请先在「网络代理」中导入订阅或添加节点。</p>
                    ) : (
                      <>
                        <div className="node-toolbar">
                          <label className="search node-search">
                            <Search size={14} />
                            <input
                              value={nodeFilter}
                              onChange={e => setNodeFilter(e.target.value)}
                              placeholder="搜索节点名称、协议或来源"
                            />
                          </label>
                        </div>
                        <div className="node-list" style={{ maxHeight: '300px' }}>
                          <div className={'node ' + (!vmRoute ? 'active' : '')}>
                            <span>
                              <Network size={15} />
                              <span className="node-name">跟随全局默认</span>
                              <small>{activeNode ? activeNode.name : '未选择全局节点'}</small>
                              {!vmRoute && <span className="node-badge">当前</span>}
                            </span>
                            <button
                              className="small-button"
                              disabled={!vmRoute}
                              onClick={() => {
                                bridge('vmProxyRoute', { name: modal.vm.name, nodeId: '' });
                                setModal(null);
                              }}
                            >
                              {!vmRoute ? '已启用' : '使用全局'}
                            </button>
                          </div>
                          {list.slice(0, 80).map(n => {
                            const isSel = vmRoute === n.id;
                            return (
                              <div key={n.id} className={'node ' + (isSel ? 'active' : '')}>
                                <span>
                                  <Network size={15} />
                                  <span className="node-name" title={n.name}>
                                    {n.name}
                                  </span>
                                  <small>
                                    {n.source} · {n.type}
                                  </small>
                                  {isSel && <span className="node-badge">独立出口</span>}
                                </span>
                                <button
                                  className="small-button"
                                  disabled={isSel}
                                  onClick={() => {
                                    bridge('vmProxyRoute', { name: modal.vm.name, nodeId: n.id });
                                    setModal(null);
                                  }}
                                >
                                  {isSel ? '已启用' : '设为出口'}
                                </button>
                              </div>
                            );
                          })}
                        </div>
                      </>
                    )}
                    <div className="dialog-actions">
                      <button className="primary" onClick={() => setModal(null)}>
                        关闭
                      </button>
                    </div>
                  </>
                );
              })()}

            {modal.type === 'codexDesktopPick' && (
              <>
                <h2>选择虚拟机</h2>
                <div className="picker-vm-list">
                  {codexVMs.map(v => {
                    const dc = state.codexDesktops?.[`${v.name}::codex`];
                    const dl = state.codexDesktops?.[`${v.name}::claude`];
                    const isCur = desktopPicked && desktopVM === v.name;
                    const name = v.displayName || v.name;
                    const parts = [];
                    if (dc?.status === 'ready' || dc?.appRunning) parts.push('Codex 运行中');
                    else if (dc?.installed) parts.push('Codex 已装');
                    if (dl?.status === 'ready' || dl?.appRunning) parts.push('Claude 运行中');
                    else if (dl?.installed) parts.push('Claude 已装');
                    const badge = parts.length ? parts.join(' · ') : (!dc?.checked && !dl?.checked ? '检查中…' : '未安装');
                    return (
                      <button
                        key={v.name}
                        type="button"
                        className={'picker-vm-item' + (isCur ? ' active' : '')}
                        onClick={() => {
                          setDesktopVM(v.name);
                          setDesktopPicked(true);
                          setDesktopApp('');
                          setModal(null);
                        }}
                      >
                        <Monitor size={16} />
                        <div className="picker-vm-info">
                          <strong>{name}</strong>
                          {!v.standalone && v.projectPath && <span>{v.projectPath}</span>}
                        </div>
                        <span className="picker-vm-badge">{badge}</span>
                      </button>
                    );
                  })}
                </div>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    关闭
                  </button>
                </div>
              </>
            )}

            {modal.type === 'browserPick' && (
              <>
                <h2>选择浏览器虚拟机</h2>
                <div className="picker-vm-list">
                  {running.map(v => {
                    const b = state.browsers?.[v.name];
                    const isCur = browserPicked && browserVM === v.name;
                    const name = v.displayName || v.name;
                    return (
                      <button
                        key={v.name}
                        type="button"
                        className={'picker-vm-item' + (isCur ? ' active' : '')}
                        onClick={() => {
                          setBrowserVM(v.name);
                          setBrowserPicked(true);
                          setModal(null);
                          setSidebarCollapsed(true);
                          bridge('browserOpen', { name: v.name });
                        }}
                      >
                        <Globe size={16} />
                        <div className="picker-vm-info">
                          <strong>{name}</strong>
                          {!v.standalone && v.projectPath && <span>{v.projectPath}</span>}
                        </div>
                        <span className="picker-vm-badge">
                          {b?.status === 'ready' || b?.appRunning
                            ? '运行中'
                            : !b?.checked
                              ? '检查中…'
                              : b?.installed && (b?.missing || []).length === 0
                                ? '已安装'
                                : b?.installed
                                  ? '待补齐'
                                  : '需安装'}
                        </span>
                      </button>
                    );
                  })}
                </div>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    关闭
                  </button>
                </div>
              </>
            )}

            {modal.type === 'manual' && (
              <>
                <h2>添加代理节点</h2>
                <div className="form-grid">
                  <label>
                    名称
                    <input value={manual.name} onChange={e => setManual({ ...manual, name: e.target.value })} />
                  </label>
                  <label>
                    协议
                    <select value={manual.type} onChange={e => setManual({ ...manual, type: e.target.value })}>
                      <option>socks5</option>
                      <option>http</option>
                    </select>
                  </label>
                  <label>
                    服务器 IP
                    <input value={manual.server} onChange={e => setManual({ ...manual, server: e.target.value })} />
                  </label>
                  <label>
                    端口
                    <input
                      type="number"
                      value={manual.port}
                      onChange={e => setManual({ ...manual, port: Number(e.target.value) })}
                    />
                  </label>
                  <label>
                    用户名
                    <input value={manual.username} onChange={e => setManual({ ...manual, username: e.target.value })} />
                  </label>
                  <label>
                    密码
                    <input
                      type="password"
                      value={manual.password}
                      onChange={e => setManual({ ...manual, password: e.target.value })}
                    />
                  </label>
                </div>
                <div className="dialog-actions">
                  <button className="secondary" onClick={() => setModal(null)}>
                    取消
                  </button>
                  <button
                    className="primary"
                    onClick={() => {
                      bridge('proxyManual', manual);
                      setManual({ ...manual, password: '' });
                      setModal(null);
                    }}
                    disabled={!manual.name || !manual.server || manual.port < 1}
                  >
                    添加
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

createRoot(document.getElementById('root')).render(<App />);
