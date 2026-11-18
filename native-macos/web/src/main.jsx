import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  ChartNoAxesCombined,
  CheckCircle2,
  FolderOpen,
  Globe,
  LoaderCircle,
  Monitor,
  Network,
  PanelLeft,
  Plus,
  RefreshCw,
  Search,
  Settings2,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
} from 'lucide-react';
import './style.css';
import {
  agentLabel,
  bridge,
  formatSubUsage,
  getRemoteToken,
  isRemoteWeb,
} from './bridge.js';
import { IconButton, KV, QuotaBar, SectionTitle, VMCard } from './components/SharedUI.jsx';
import ToastStack from './components/ToastStack.jsx';
import ChatPage from './features/chat/ChatPage.jsx';
import BrowserPage from './features/browser/BrowserPage.jsx';

const blank = {
  vms: [],
  busy: false,
  proxy: null,
  quotas: {},
  usage: {},
  editors: {},
  browsers: {},
  mounts: {},
  agents: {},
  vmProxyRoutes: {},
  remoteWorkbench: { enabled: false, port: 18080, token: '', urls: [], error: '' },
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
  { id: 'codex', label: 'Agent 对话', icon: Sparkles },
  { id: 'browser', label: '浏览器', icon: Globe },
  { id: 'proxy', label: '网络代理', icon: Network },
  { id: 'quota', label: 'AI 额度', icon: ChartNoAxesCombined },
  { id: 'settings', label: '设置', icon: Settings2 },
];

function App() {
  const [state, setState] = useState(window.__agentVMInitial || blank);
  const [page, setPage] = useState(isRemoteWeb ? 'codex' : 'vms');
  const [remoteToken, setRemoteToken] = useState(() => (isRemoteWeb ? getRemoteToken() : ''));
  const [remoteTokenInput, setRemoteTokenInput] = useState('');
  const [remoteAuthFailed, setRemoteAuthFailed] = useState(false);
  const [remotePortInput, setRemotePortInput] = useState('18080');
  const [modal, setModal] = useState(null);
  const [filter, setFilter] = useState('');
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
  const [nodeFilter, setNodeFilter] = useState('');
  const [showAllNodes, setShowAllNodes] = useState(false);
  const [nodesExpanded, setNodesExpanded] = useState(false);
  const [codexVM, setCodexVM] = useState('');
  const [browserVM, setBrowserVM] = useState('');
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
        fetch('/api/state?token=' + encodeURIComponent(remoteToken))
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

  // Handle cross-page navigation requests from Swift (e.g. screenshot to chat)
  useEffect(() => {
    const req = state.requestedPage;
    if (!req?.nonce || req.nonce === lastRequestedNonceRef.current) return;
    lastRequestedNonceRef.current = req.nonce;
    if (req.vm) {
      setCodexVM(req.vm);
      setBrowserVM(req.vm);
    }
    if (req.page) setPage(req.page);
  }, [state.requestedPage?.nonce]);

  const vms = useMemo(() => state.vms.filter(v => v.name !== 'base' && v.name !== 'base-building'), [state.vms]);
  const visible = vms.filter(v => (v.displayName || v.name).toLowerCase().includes(filter.toLowerCase()));
  const running = useMemo(() => vms.filter(v => v.status === 'Running'), [vms]);

  useEffect(() => {
    if (running.length && (!codexVM || !running.some(v => v.name === codexVM))) {
      setCodexVM(running[0].name);
    }
    if (running.length && (!browserVM || !running.some(v => v.name === browserVM))) {
      setBrowserVM(running[0].name);
    }
  }, [running, codexVM, browserVM]);

  // Global keyboard shortcuts (Cmd+1..6, Cmd+N)
  useEffect(() => {
    if (isRemoteWeb) return;
    const onKey = e => {
      if (!e.metaKey || e.ctrlKey || e.altKey) return;
      const num = Number(e.key);
      if (num >= 1 && num <= tabs.length) {
        e.preventDefault();
        setPage(tabs[num - 1].id);
        return;
      }
      if (e.key.toLowerCase() === 'n' && page === 'codex' && codexVM) {
        e.preventDefault();
        bridge('codexNewSession', { vm: codexVM });
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [page, codexVM]);

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

  const runningTaskCount = (state.codex?.runningSessions || []).length;
  const refreshAction = page === 'proxy' ? 'proxyRefresh' : page === 'quota' ? 'refreshQuotas' : 'refresh';

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
      setBrowserVM(targetVM);
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
            try { localStorage.setItem('agentvm.remoteToken', t); } catch {}
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
          <div className="brand">
            <div className="brand-icon"><Monitor size={19} /></div>
            <div className="brand-text">
              <strong>Agent VM</strong>
              <span>DESKTOP</span>
            </div>
          </div>
          <div className="nav-label">工作空间</div>
          <nav>
            {tabs.map((t, idx) => (
              <button
                key={t.id}
                title={`${t.label} (⌘${idx + 1})`}
                className={'nav-item ' + (page === t.id ? 'selected' : '')}
                onClick={() => setPage(t.id)}
              >
                <t.icon size={17} />
                <span className="nav-text">{t.label}</span>
                {t.id === 'vms' && <span className="nav-count">{vms.length}</span>}
                {t.id === 'codex' && runningTaskCount > 0 && (
                  <span className="nav-count nav-count-live">{runningTaskCount}</span>
                )}
              </button>
            ))}
          </nav>
          <div className="sidebar-bottom">
            <div className="sidebar-separator" />
            <div className="small-label">运行概览</div>
            <div className="side-status">
              <span className="status-dot active" />
              <span>{running.length} 台虚拟机运行中</span>
            </div>
            {runningTaskCount > 0 && (
              <div className="side-status">
                <LoaderCircle size={12} className="spin" color="var(--blue)" />
                <span>{runningTaskCount} 个 Agent 任务运行中</span>
              </div>
            )}
            <div className="side-status">
              <span className={'status-dot ' + (proxy?.use_proxy ? 'active' : '')} />
              <span>代理 {proxy?.use_proxy ? '已配置' : '未启用'}</span>
            </div>
            <button className="sidebar-refresh" onClick={() => bridge('refresh')}>
              <RefreshCw size={14} /> 刷新状态
            </button>
          </div>
        </aside>
      )}

      <main className="main">
        {!isRemoteWeb && (
          <div className="topbar">
            <div className="top-left">
              <IconButton title={sidebarCollapsed ? '展开侧边栏' : '收起侧边栏'} onClick={toggleSidebar}>
                <PanelLeft size={16} />
              </IconButton>
              <div className="breadcrumbs">
                工作空间 <span>/</span> {tabs.find(x => x.id === page)?.label}
              </div>
            </div>
            <div className="top-right">
              <span className="live-marker">
                <span className="status-dot active" /> 本地运行
              </span>
              <IconButton
                title="刷新当前页面"
                disabled={state.busy || state.proxyBusy}
                onClick={() => bridge(refreshAction)}
              >
                <RefreshCw size={15} className={state.busy || state.proxyBusy ? 'spin' : ''} />
              </IconButton>
            </div>
          </div>
        )}

        <div className={'content' + (page === 'codex' ? ' codex-content' : page === 'browser' ? ' browser-content' : '')}>
          {!isRemoteWeb && page === 'vms' && (
            <>
              <SectionTitle title="虚拟机" sub="隔离运行 AI Agent，统一管理资源、会话与项目环境。">
                <button className="primary" onClick={() => setModal({ type: 'create' })}>
                  <Plus size={17} /> 新建虚拟机
                </button>
              </SectionTitle>
              <div className="stat-grid">
                <div className="stat">
                  <span>虚拟机总数</span>
                  <strong>{vms.length}</strong>
                  <small>已创建实例</small>
                </div>
                <div className="stat">
                  <span>正在运行</span>
                  <strong>{running.length}</strong>
                  <small>活跃工作环境</small>
                </div>
                <div className="stat">
                  <span>已停止</span>
                  <strong>{vms.length - running.length}</strong>
                  <small>不运行来宾进程</small>
                </div>
              </div>
              <div className="section-row">
                <h2>
                  所有虚拟机 <span>{visible.length}</span>
                </h2>
                <label className="search">
                  <Search size={15} />
                  <input value={filter} onChange={e => setFilter(e.target.value)} placeholder="搜索虚拟机" />
                </label>
              </div>
              {visible.length ? (
                <div className="vm-grid">
                  {visible.map(v => (
                    <VMCard
                      key={v.name}
                      vm={v}
                      state={state}
                      select={({ type, vm }) => {
                        if (type === 'rename') {
                          setRenameText(vm.displayName === vm.name ? '' : vm.displayName);
                          setModal({ type, vm });
                        } else if (type === 'mounts' || type === 'proxyRoute') {
                          setNodeFilter('');
                          setModal({ type, vm });
                        } else if (type === 'chatOpen') {
                          setCodexVM(vm.name);
                          setPage('codex');
                        } else if (type === 'browserOpen') {
                          setBrowserVM(vm.name);
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
                  <Monitor size={30} />
                  <strong>暂无匹配的虚拟机</strong>
                  <span>点击「新建虚拟机」开始创建。</span>
                </div>
              )}
              {state.buildStarted && (
                <div className="notice">
                  <LoaderCircle size={16} /> {state.buildComplete ? '创建完成' : '正在准备虚拟机 · 阶段 ' + state.buildStage}
                </div>
              )}
            </>
          )}

          {(isRemoteWeb || page === 'codex') && (
            <ChatPage
              state={state}
              running={running}
              codexVM={codexVM}
              setCodexVM={setCodexVM}
              onNavigateTab={navigateTab}
            />
          )}

          {!isRemoteWeb && page === 'browser' && (
            <BrowserPage
              state={state}
              running={running}
              browserVM={browserVM}
              setBrowserVM={setBrowserVM}
              sidebarCollapsed={sidebarCollapsed}
              modalOpen={!!modal}
              onNavigateTab={navigateTab}
            />
          )}

          {page === 'quota' && (
            <>
              <SectionTitle title="AI 额度" sub="查看运行中虚拟机的 AI 额度与已安装工具状态（当前支持 Codex 额度查询）。">
                <button className="secondary" onClick={() => bridge('refreshQuotas')}>
                  <RefreshCw size={16} /> 刷新额度
                </button>
              </SectionTitle>
              <div className="info-strip">
                <Activity size={17} /> 数据从各虚拟机内部查询；登录状态、网络和服务限制可能影响结果。
              </div>
              <div className="quota-grid">
                {vms.map(vm => {
                  const q = state.quotas[vm.name];
                  const agents = state.agents?.[vm.name];
                  const hasAgents = Array.isArray(agents);
                  const hasCodex = !hasAgents || agents.includes('codex');
                  const badge = q?.plan_type
                    ? q.plan_type.toUpperCase()
                    : hasAgents && agents.length
                      ? agents.map(agentLabel).join(' / ')
                      : 'Codex';
                  return (
                    <section className="panel" key={vm.name}>
                      <div className="flex-between">
                        <strong>{vm.displayName || vm.name}</strong>
                        <span className="muted">{badge}</span>
                      </div>
                      {q?.status === 'ok' ? (
                        <>
                          <QuotaBar label="5 小时窗口" window={q.five_hour} />
                          <QuotaBar label="每周窗口" window={q.weekly} />
                          <p className="muted text-xs">查询于 {q.fetchedAt || '最近一次刷新'}</p>
                        </>
                      ) : (
                        <p className="muted">
                          {!hasCodex && vm.status === 'Running'
                            ? agents.length
                              ? `当前仅安装了 ${agents.map(agentLabel).join(' / ')}，暂无可查询额度`
                              : '未检测到 Codex，暂无可查询额度'
                            : q?.error || (vm.status === 'Running' ? '正在等待额度数据' : '虚拟机已停止')}
                        </p>
                      )}
                      {hasCodex && (
                        <button
                          className="small-button"
                          disabled={vm.status !== 'Running'}
                          onClick={() => bridge('quota', { name: vm.name })}
                        >
                          <RefreshCw size={13} /> 刷新该实例
                        </button>
                      )}
                    </section>
                  );
                })}
              </div>
            </>
          )}

          {page === 'proxy' && (
            <>
              <SectionTitle title="网络代理" sub="按配置、节点、检查、连接的顺序管理代理出口。" />
              {state.proxyError && (
                <div className="notice error">
                  <AlertTriangle size={17} />
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
                  <h2>01 · 网关配置</h2>
                  <span className={'status ' + (proxy?.running ? 'running' : '')}>
                    {proxy?.running ? '核心运行中' : '核心未运行'}
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
                  <h2>02 · 节点与路由</h2>
                  <div className="inline-actions" style={{ marginTop: 0 }}>
                    <span className="muted">
                      {filteredNodes.length === nodes.length
                        ? `${nodes.length} 个节点`
                        : `${filteredNodes.length} / ${nodes.length} 个节点`}
                    </span>
                    {nodes.length > 0 && (
                      <button className="small-button" onClick={() => setNodesExpanded(x => !x)}>
                        {nodesExpanded ? '收起节点' : `展开节点 (${nodes.length})`}
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
                    <h2>03 · 安全自检</h2>
                    <button className="secondary" onClick={() => bridge('proxyProbe')} disabled={state.proxyBusy}>
                      <ShieldCheck size={16} /> 运行检查
                    </button>
                  </div>
                  <KV name="探测出口 IP" value={proxy?.last_probe?.exit_ip || '未获得'} />
                  <KV name="网络门禁" value={(proxy?.gates || []).map(g => g.state).join(' / ') || '无运行中的托管实例'} />
                  <div className="check-list">
                    {(proxy?.last_probe?.report?.checks || []).map(c => (
                      <div className="check-line" key={c.id}>
                        {c.state === 'passed' ? (
                          <CheckCircle2 size={15} color="var(--ok)" />
                        ) : (
                          <ShieldAlert size={15} color="var(--warn)" />
                        )}
                        <span>{c.id}</span>
                        <span className="muted">{c.state}</span>
                      </div>
                    ))}
                  </div>
                  <p className="muted text-xs">主机检测不能证明虚拟机完全隔离；未知项不会被视为通过。</p>
                  <button className="small-button" onClick={() => setModal({ type: 'closeGate' })}>
                    关闭网络门禁
                  </button>
                </section>
                <section className="panel">
                  <div className="section-row">
                    <h2>04 · 代理连接</h2>
                    <button className="secondary" onClick={() => bridge('proxyConnections')}>
                      <RefreshCw size={15} /> 更新连接
                    </button>
                  </div>
                  <KV name="累计上行" value={((state.proxyUploadTotal || 0) / 1048576).toFixed(2) + ' MB'} />
                  <KV name="累计下行" value={((state.proxyDownloadTotal || 0) / 1048576).toFixed(2) + ' MB'} />
                  {(state.proxyConnections || []).slice(0, 30).map(c => (
                    <div key={c.id} className="connection-row">
                      <span>
                        {c.host}:{c.port}
                      </span>
                      <small>
                        {c.network} · ↑{Math.round(c.upload / 1024)}KB ↓{Math.round(c.download / 1024)}KB
                      </small>
                    </div>
                  ))}
                  {(!state.proxyConnections || state.proxyConnections.length === 0) && (
                    <p className="muted">暂无活跃代理连接。</p>
                  )}
                </section>
              </div>
            </>
          )}

          {!isRemoteWeb && page === 'settings' && (
            <>
              <SectionTitle title="设置" sub="原生应用与当前工作环境。" />
              <section className="panel">
                <h2>手机远程工作台</h2>
                <p className="muted">
                  开启后可通过 EasyTier 或局域网 IP 在手机浏览器中直接使用工作台聊天（仅开放工作台对话与状态，需口令鉴权）。
                </p>
                <div className="form-grid">
                  <label className="checkbox">
                    <span>启用远程工作台</span>
                    <input
                      type="checkbox"
                      checked={!!state.remoteWorkbench?.enabled}
                      onChange={e => bridge('remoteWorkbenchToggle', { enabled: e.target.checked })}
                    />
                  </label>
                  <label>
                    监听端口
                    <div className="inline-actions">
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
                        应用端口
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
                    <div className="small-label" style={{ marginBottom: 6 }}>
                      远程访问链接（含 EasyTier / 局域网 IP）
                    </div>
                    {(state.remoteWorkbench.urls || []).map(u => (
                      <div key={u} className="web-code-row">
                        <span>{u}</span>
                      </div>
                    ))}
                  </div>
                )}
              </section>
              <section className="panel">
                <h2>桌面集成</h2>
                <KV name="窗口框架" value="SwiftUI + WKWebView" />
                <KV name="内部界面" value="React" />
                <KV name="核心引擎" value="Go · Lima" />
                <KV name="会话持久化" value="~/.agent-vm/sessions" />
                <KV name="共享工作区" value="~/AgentVM-Shared" />
                <div className="inline-actions">
                  <button className="secondary" onClick={() => bridge('doctor')}>
                    运行环境诊断
                  </button>
                  <button className="secondary" onClick={() => bridge('openShared')}>
                    <FolderOpen size={15} /> 打开共享文件夹
                  </button>
                </div>
              </section>
              <section className="panel">
                <h2>安全原则</h2>
                <p className="muted">
                  所有虚拟机、代理和文件操作都由 Swift 原生桥接校验并交给已有 Go 核心。React 不直接接触宿主机文件和认证凭据。
                </p>
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
            setCodexVM(vmName);
            setPage('codex');
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
                <p className="muted">默认使用 Agent VM 共享目录，无需额外挂载项目。</p>
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
                <h2>修改虚拟机名称</h2>
                <p className="muted">仅更改界面显示名称，不影响实例 ID 与共享目录。</p>
                <label className="dialog-field">
                  显示名称
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

            {modal.type === 'mounts' && (
              <>
                <h2>共享文件夹</h2>
                <p className="muted">
                  虚拟机：{modal.vm.displayName || modal.vm.name}。挂载变更需要重新启动虚拟机才能生效。
                </p>
                <div className="mount-list">
                  <div className="mount-entry">
                    <span>~/AgentVM-Shared</span>
                    <small>所有虚拟机共享 · 读写</small>
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
