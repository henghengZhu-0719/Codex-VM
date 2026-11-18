import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  ArrowDown,
  Camera,
  Check,
  Copy,
  FileCode2,
  FolderOpen,
  Globe,
  LoaderCircle,
  Monitor,
  Paperclip,
  PanelLeft,
  Pencil,
  Plus,
  RefreshCw,
  RotateCcw,
  Search,
  Send,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
  Square,
  Terminal,
  Trash2,
  X,
} from 'lucide-react';
import { agentLabel, bridge, copyText, formatDuration, formatRelativeTime, isRemoteWeb } from '../../bridge.js';
import MarkdownView from '../../components/MarkdownView.jsx';
import DiffView from '../../components/DiffView.jsx';
import { QuotaChip } from '../../components/SharedUI.jsx';

const MODES = [
  { id: 'read-only', label: '只读', hint: '仅读取分析，禁止改文件' },
  { id: 'full-auto', label: '沙盒', hint: '自动在沙盒内执行' },
  { id: 'default', label: '默认', hint: '使用 VM 默认配置' },
  { id: 'bypass', label: '放行', hint: '跳过沙盒与审批（高风险）' },
];

const QUICK_PROMPTS = [
  { title: '分析项目结构', text: '请快速梳理当前工作目录的项目结构、核心模块与运行方式。' },
  { title: '运行测试并修复', text: '运行项目测试套件，如果有失败项请定位原因并修复。' },
  { title: '检查近期改动', text: '检查当前 git status 和近期 diff，总结改动点与潜在风险。' },
  { title: '排查运行环境', text: '检查当前目录依赖、监听端口和常见服务是否正常。' },
];

const SLASH_COMMANDS = [
  { cmd: '/new', desc: '新建对话会话' },
  { cmd: '/readonly', desc: '切换到只读模式' },
  { cmd: '/sandbox', desc: '切换到沙盒模式（推荐）' },
  { cmd: '/diff', desc: '打开代码变更审阅面板' },
  { cmd: '/terminal', desc: '在 macOS 终端接管会话' },
  { cmd: '/browser', desc: '切换到 Linux 浏览器' },
];

function LiveTimer({ startedAt, finishedAt, running }) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    if (!running) return;
    const t = setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => clearInterval(t);
  }, [running]);
  if (!startedAt) return null;
  const end = running ? now : (finishedAt || startedAt);
  return <span className="chat-timer">⏱ {formatDuration(Math.max(0, end - startedAt))}</span>;
}

function StepRow({ item, onInspectFile }) {
  const [expandedOut, setExpandedOut] = useState(false);
  const failed = item.exitCode !== undefined && item.exitCode !== 0;
  const defaultOpen = item.status === 'in_progress' || failed;
  const tagText =
    item.type === 'reasoning' ? '思考' :
    item.type === 'command_execution' ? '命令' :
    item.type === 'file_change' ? '文件' :
    item.type || '步骤';

  const summaryTitle =
    item.command ||
    (item.text ? item.text.replace(/\s+/g, ' ').slice(0, 88) : '') ||
    (item.changes ? `${item.changes.length} 个文件变更` : item.type);

  const output = item.output || '';
  const isLong = output.length > 1800;
  const shownOutput = isLong && !expandedOut ? output.slice(-1800) : output;

  return (
    <details className={'codex-step' + (failed ? ' is-error' : '')} open={defaultOpen}>
      <summary>
        <span className={'codex-step-tag ' + (item.type || '')}>{tagText}</span>
        <span className="codex-step-title">{summaryTitle}</span>
        {item.exitCode !== undefined && (
          <small className={item.exitCode === 0 ? 'ok' : 'bad'}>exit {item.exitCode}</small>
        )}
        {item.status === 'in_progress' && <LoaderCircle size={13} className="spin" />}
      </summary>
      {item.text && <pre className="codex-step-body">{item.text}</pre>}
      {output && (
        <div className="codex-step-output-wrap">
          {isLong && (
            <button type="button" className="step-expand-btn" onClick={() => setExpandedOut(v => !v)}>
              {expandedOut ? '收起长输出' : `显示完整输出（共 ${output.length} 字符）`}
            </button>
          )}
          <pre className="codex-step-body">{shownOutput}</pre>
        </div>
      )}
      {item.changes && (
        <div className="codex-changes">
          {item.changes.map((c, i) => (
            <div key={i} className="codex-change-row">
              <code>{c.kind}</code>
              <button type="button" className="change-file-btn" onClick={() => onInspectFile(c.path)} title="查看该文件 diff">
                {c.path}
              </button>
            </div>
          ))}
        </div>
      )}
    </details>
  );
}

export default function ChatPage({
  state,
  running,
  codexVM,
  setCodexVM,
  onNavigateTab,
}) {
  const [sessionsOpen, setSessionsOpen] = useState(() => !isRemoteWeb && window.innerWidth > 960);
  const [showAllVMSessions, setShowAllVMSessions] = useState(false);
  const [sessionFilter, setSessionFilter] = useState('');
  const [renamingId, setRenamingId] = useState('');
  const [renameValue, setRenameValue] = useState('');
  const [diffOpen, setDiffOpen] = useState(false);
  const [customDir, setCustomDir] = useState(false);
  const [workdirInput, setWorkdirInput] = useState('/mnt/agent-vm-shared');
  const [modeInput, setModeInput] = useState(() => {
    try { return localStorage.getItem('agentvm.chatMode') || 'full-auto'; } catch { return 'full-auto'; }
  });
  const [agentInput, setAgentInput] = useState('codex');
  const [prompt, setPrompt] = useState('');
  const [editingMsgId, setEditingMsgId] = useState('');
  const [editingText, setEditingText] = useState('');
  const [copiedId, setCopiedId] = useState('');
  const [showScrollBottom, setShowScrollBottom] = useState(false);
  const [bypassConfirmTarget, setBypassConfirmTarget] = useState(false);
  const [bypassAckSessions, setBypassAckSessions] = useState(() => new Set());

  const feedRef = useRef(null);
  const endRef = useRef(null);
  const composerRef = useRef(null);
  const stickBottomRef = useRef(true);
  const historyIdxRef = useRef(-1);

  const codexState = state.codex || {};
  const sessionsByVM = codexState.sessions || {};
  const activeSessionByVM = codexState.activeSessions || {};
  const runningSessions = useMemo(() => new Set(codexState.runningSessions || []), [codexState.runningSessions]);

  const vmSessions = useMemo(() => sessionsByVM[codexVM] || [], [sessionsByVM, codexVM]);
  const activeSessionId = activeSessionByVM[codexVM] || vmSessions[0]?.id || '';
  const activeSession = useMemo(
    () => vmSessions.find(s => s.id === activeSessionId) || vmSessions[0] || null,
    [vmSessions, activeSessionId]
  );

  // Sync local controls from activeSession when switching sessions/VMs
  useEffect(() => {
    if (activeSession) {
      setWorkdirInput(activeSession.workdir || '/mnt/agent-vm-shared');
      setModeInput(activeSession.mode || 'full-auto');
      setAgentInput(activeSession.agent || 'codex');
      setCustomDir(false);
    }
    historyIdxRef.current = -1;
    try {
      const savedDraft = localStorage.getItem(`agentvm.draft.${activeSession?.id || codexVM}`);
      setPrompt(savedDraft || '');
    } catch {}
  }, [activeSession?.id, codexVM]);

  // Persist draft per session
  useEffect(() => {
    if (!codexVM) return;
    try {
      const key = `agentvm.draft.${activeSession?.id || codexVM}`;
      if (prompt) localStorage.setItem(key, prompt);
      else localStorage.removeItem(key);
    } catch {}
  }, [prompt, activeSession?.id, codexVM]);

  const selectedVM = running.find(v => v.name === codexVM) || null;
  const vmAgents = state.agents?.[codexVM];
  const vmHasAgents = Array.isArray(vmAgents);
  const supportsChatAgents = useMemo(() => {
    if (!vmHasAgents) return ['codex'];
    const list = vmAgents.filter(a => a === 'codex' || a === 'claude');
    return list;
  }, [vmAgents, vmHasAgents]);

  useEffect(() => {
    if (supportsChatAgents.length && !supportsChatAgents.includes(agentInput)) {
      setAgentInput(supportsChatAgents[0]);
    }
  }, [supportsChatAgents, agentInput]);

  const dirOptions = useMemo(() => {
    const seen = new Set();
    const list = [];
    const add = (path, label) => {
      if (!path || seen.has(path)) return;
      seen.add(path);
      list.push({ path, label });
    };
    for (const m of selectedVM?.guestMounts || []) {
      const gp = m.guestPath || m.location;
      if (!gp) continue;
      if (gp === '/mnt/agent-vm-shared') {
        add(gp, '共享目录 (/mnt/agent-vm-shared)');
      } else {
        const base = (m.location || gp).split('/').filter(Boolean).pop() || gp;
        add(gp, `${base} (${gp} · ${m.writable ? '读写' : '只读'})`);
      }
    }
    add('/mnt/agent-vm-shared', '共享目录 (/mnt/agent-vm-shared)');
    return list;
  }, [selectedVM]);

  useEffect(() => {
    if (!customDir && dirOptions.length && !dirOptions.some(o => o.path === workdirInput)) {
      setWorkdirInput(dirOptions[0].path);
    }
  }, [dirOptions, customDir, workdirInput]);

  const msgs = activeSession?.messages || [];
  const activeRunning = !!(activeSession && runningSessions.has(activeSession.id));
  const threadId = activeSession?.threadId || '';
  const stagedFiles = codexState.stagedAttachments?.[codexVM] || [];
  const quota = state.quotas?.[codexVM];
  const vmBrowser = state.browsers?.[codexVM];

  // Collect all file changes in current session
  const sessionChanges = useMemo(() => {
    const map = new Map();
    for (const m of msgs) {
      for (const it of m.items || []) {
        for (const c of it.changes || []) {
          map.set(c.path, c.kind || 'modify');
        }
      }
    }
    return Array.from(map.entries()).map(([path, kind]) => ({ path, kind }));
  }, [msgs]);

  // All sessions list for left drawer
  const displayedSessions = useMemo(() => {
    const all = showAllVMSessions
      ? Object.values(sessionsByVM).flat().sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
      : vmSessions;
    const q = sessionFilter.trim().toLowerCase();
    if (!q) return all;
    return all.filter(s =>
      (s.title || '').toLowerCase().includes(q) ||
      (s.vmName || '').toLowerCase().includes(q)
    );
  }, [showAllVMSessions, sessionsByVM, vmSessions, sessionFilter]);

  // Smart scroll handling
  const handleFeedScroll = () => {
    const el = feedRef.current;
    if (!el) return;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 90;
    stickBottomRef.current = nearBottom;
    setShowScrollBottom(!nearBottom);
  };

  useEffect(() => {
    if (stickBottomRef.current) {
      endRef.current?.scrollIntoView({ behavior: msgs.length > 2 ? 'smooth' : 'auto' });
    }
  }, [msgs.length, msgs[msgs.length - 1]?.text, msgs[msgs.length - 1]?.items?.length, activeSession?.id]);

  const scrollToBottom = () => {
    stickBottomRef.current = true;
    setShowScrollBottom(false);
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  const applyMode = newMode => {
    if (newMode === 'bypass' && !bypassAckSessions.has(activeSession?.id || codexVM)) {
      setBypassConfirmTarget(true);
      return;
    }
    setModeInput(newMode);
    try { localStorage.setItem('agentvm.chatMode', newMode); } catch {}
    if (activeSession) {
      bridge('codexSetSessionConfig', { vm: codexVM, sessionId: activeSession.id, mode: newMode });
    }
  };

  const confirmBypass = () => {
    const next = new Set(bypassAckSessions);
    next.add(activeSession?.id || codexVM);
    setBypassAckSessions(next);
    setBypassConfirmTarget(false);
    setModeInput('bypass');
    try { localStorage.setItem('agentvm.chatMode', 'bypass'); } catch {}
    if (activeSession) {
      bridge('codexSetSessionConfig', { vm: codexVM, sessionId: activeSession.id, mode: 'bypass' });
    }
  };

  const handleSend = (overrideText = null) => {
    const raw = (overrideText ?? prompt).trim();
    if (!raw || !codexVM || activeRunning) return;

    // Handle slash commands locally
    if (raw === '/new') {
      setPrompt('');
      bridge('codexNewSession', { vm: codexVM, agent: agentInput, workdir: workdirInput, mode: modeInput });
      return;
    }
    if (raw === '/readonly') { setPrompt(''); applyMode('read-only'); return; }
    if (raw === '/sandbox') { setPrompt(''); applyMode('full-auto'); return; }
    if (raw === '/diff') {
      setPrompt('');
      setDiffOpen(true);
      bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput });
      return;
    }
    if (raw === '/terminal' && !isRemoteWeb) {
      setPrompt('');
      bridge('codexTerminal', { vm: codexVM, agent: agentInput });
      return;
    }
    if (raw === '/browser' && !isRemoteWeb) {
      setPrompt('');
      onNavigateTab?.('browser', codexVM);
      return;
    }

    if (!overrideText) setPrompt('');
    historyIdxRef.current = -1;
    stickBottomRef.current = true;
    bridge('codexRun', {
      vm: codexVM,
      sessionId: activeSession?.id,
      workdir: workdirInput,
      prompt: raw,
      mode: modeInput,
      agent: agentInput,
      resume: true,
    });
  };

  const handleKeyDown = e => {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      handleSend();
      return;
    }
    if (e.key === 'ArrowUp' && !prompt.trim()) {
      const userMsgs = msgs.filter(m => m.role === 'user');
      if (!userMsgs.length) return;
      e.preventDefault();
      const nextIdx = historyIdxRef.current < 0 ? userMsgs.length - 1 : Math.max(0, historyIdxRef.current - 1);
      historyIdxRef.current = nextIdx;
      setPrompt(userMsgs[nextIdx].text || '');
    }
  };

  const inspectFileDiff = filePath => {
    setDiffOpen(true);
    bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput, file: filePath || '' });
  };

  const renderErrorRecovery = errText => {
    const low = (errText || '').toLowerCase();
    return (
      <div className="chat-error-actions">
        {(low.includes('login') || low.includes('auth') || low.includes('401') || low.includes('token') || low.includes('登录')) && !isRemoteWeb && (
          <button type="button" className="small-button" onClick={() => bridge('codexTerminal', { vm: codexVM, agent: agentInput })}>
            <Terminal size={13} /> 在终端登录 {agentLabel(agentInput)}
          </button>
        )}
        {(low.includes('quota') || low.includes('limit') || low.includes('429') || low.includes('rate')) && !isRemoteWeb && (
          <button type="button" className="small-button" onClick={() => onNavigateTab?.('quota')}>
            查看 AI 额度
          </button>
        )}
        {(low.includes('network') || low.includes('timeout') || low.includes('connect') || low.includes('proxy') || low.includes('ssh')) && !isRemoteWeb && (
          <button type="button" className="small-button" onClick={() => onNavigateTab?.('proxy')}>
            运行网络自检
          </button>
        )}
      </div>
    );
  };

  const showSlashMenu = prompt.startsWith('/') && !prompt.includes(' ') && !prompt.includes('\n');
  const slashMatches = showSlashMenu
    ? SLASH_COMMANDS.filter(c => c.cmd.startsWith(prompt.trim().toLowerCase()))
    : [];

  if (running.length === 0) {
    return (
      <div className="codex-page">
        <div className="codex-header">
          <div>
            <h1>Agent 对话工作台</h1>
            <p>在运行中的虚拟机内执行任务、查看实时命令与代码变更</p>
          </div>
        </div>
        <div className="empty" style={{ flex: 1 }}>
          <Sparkles size={30} />
          <strong>暂无运行中的虚拟机</strong>
          <span>请先在「虚拟机」页面启动至少一台虚拟机。</span>
          {!isRemoteWeb && (
            <button className="primary" onClick={() => onNavigateTab?.('vms')}>
              前往虚拟机列表
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="codex-page">
      <div className="codex-header">
        <div className="codex-title-wrap">
          <button
            type="button"
            className="icon-button"
            title={sessionsOpen ? '收起会话列表' : '展开会话列表'}
            onClick={() => setSessionsOpen(v => !v)}
          >
            <PanelLeft size={16} />
          </button>
          <div>
            <h1>Agent 对话工作台</h1>
            <p>{selectedVM?.displayName || codexVM} · {workdirInput}</p>
          </div>
        </div>
        <div className="heading-actions">
          {quota?.status === 'ok' && (
            <div className="chat-quota-inline" title="当前虚拟机 Codex 剩余额度">
              <QuotaChip label="5h" win={quota.five_hour} compact />
              <QuotaChip label="7d" win={quota.weekly} compact />
            </div>
          )}
          {!isRemoteWeb && vmBrowser?.status === 'ready' && (
            <button
              type="button"
              className="secondary"
              title={vmBrowser.activeURL || '切换到 Linux 浏览器'}
              onClick={() => onNavigateTab?.('browser', codexVM)}
            >
              <Globe size={14} /> 浏览器
            </button>
          )}
          <button
            type="button"
            className={'secondary ' + (diffOpen ? 'is-active' : '')}
            onClick={() => {
              const next = !diffOpen;
              setDiffOpen(next);
              if (next) bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput });
            }}
          >
            <FileCode2 size={14} /> 变更{sessionChanges.length > 0 ? ` (${sessionChanges.length})` : ''}
          </button>
          <button
            type="button"
            className="secondary"
            onClick={() => bridge('codexNewSession', { vm: codexVM, agent: agentInput, workdir: workdirInput, mode: modeInput })}
          >
            <Plus size={14} /> 新会话
          </button>
          {!isRemoteWeb && (
            <button type="button" className="secondary" onClick={() => bridge('codexTerminal', { vm: codexVM, agent: agentInput })}>
              <Terminal size={14} /> 终端接管
            </button>
          )}
        </div>
      </div>

      <div className="chat-workspace">
        {sessionsOpen && (
          <aside className="chat-sessions-pane">
            <div className="chat-sessions-top">
              <label className="search chat-session-search">
                <Search size={13} />
                <input
                  value={sessionFilter}
                  onChange={e => setSessionFilter(e.target.value)}
                  placeholder="搜索历史会话"
                />
              </label>
              <label className="chat-scope-toggle">
                <input
                  type="checkbox"
                  checked={showAllVMSessions}
                  onChange={e => setShowAllVMSessions(e.target.checked)}
                />
                <span>全部 VM</span>
              </label>
            </div>
            <div className="chat-sessions-list">
              {displayedSessions.length === 0 && (
                <div className="chat-sessions-empty">暂无历史会话，发送第一条消息会自动保存。</div>
              )}
              {displayedSessions.map(s => {
                const isSelected = s.vmName === codexVM && s.id === activeSession?.id;
                const isRunning = runningSessions.has(s.id);
                const lastMsg = s.messages?.[s.messages.length - 1];
                const isErr = lastMsg?.status === 'error';
                const vmObj = running.find(v => v.name === s.vmName);
                const vmLabel = vmObj?.displayName || s.vmName;
                return (
                  <div
                    key={s.id}
                    className={'chat-session-item' + (isSelected ? ' selected' : '')}
                    onClick={() => {
                      if (s.vmName !== codexVM) setCodexVM(s.vmName);
                      bridge('codexSelectSession', { vm: s.vmName, sessionId: s.id });
                      if (window.innerWidth <= 900) setSessionsOpen(false);
                    }}
                  >
                    <div className="chat-session-main">
                      <span className={'chat-session-dot ' + (isRunning ? 'running' : isErr ? 'error' : lastMsg ? 'done' : '')} />
                      {renamingId === s.id ? (
                        <input
                          className="chat-rename-input"
                          autoFocus
                          value={renameValue}
                          onClick={e => e.stopPropagation()}
                          onChange={e => setRenameValue(e.target.value)}
                          onBlur={() => {
                            if (renameValue.trim()) {
                              bridge('codexRenameSession', { vm: s.vmName, sessionId: s.id, title: renameValue });
                            }
                            setRenamingId('');
                          }}
                          onKeyDown={e => {
                            if (e.key === 'Enter') e.currentTarget.blur();
                            if (e.key === 'Escape') setRenamingId('');
                          }}
                        />
                      ) : (
                        <strong title={s.title}>{s.title || '新对话'}</strong>
                      )}
                    </div>
                    <div className="chat-session-meta">
                      <span>{agentLabel(s.agent || 'codex')}{showAllVMSessions ? ` · ${vmLabel}` : ''}</span>
                      <span>{formatRelativeTime(s.updatedAt)}</span>
                    </div>
                    <div className="chat-session-actions" onClick={e => e.stopPropagation()}>
                      <button
                        type="button"
                        title="重命名"
                        onClick={() => {
                          setRenamingId(s.id);
                          setRenameValue(s.title || '');
                        }}
                      >
                        <Pencil size={12} />
                      </button>
                      <button
                        type="button"
                        title="删除会话"
                        disabled={isRunning}
                        onClick={() => bridge('codexDeleteSession', { vm: s.vmName, sessionId: s.id })}
                      >
                        <Trash2 size={12} />
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </aside>
        )}

        <div className="codex-shell">
          <div className="codex-toolbar">
            <label className="codex-pill" title="切换目标虚拟机">
              <Monitor size={13} />
              <select
                value={codexVM}
                onChange={e => {
                  setCodexVM(e.target.value);
                  setCustomDir(false);
                }}
              >
                {running.map(v => (
                  <option key={v.name} value={v.name}>
                    {v.displayName || v.name}{(codexState.runningVMs || []).includes(v.name) ? ' ●' : ''}
                  </option>
                ))}
              </select>
            </label>

            <label className="codex-pill codex-pill-grow" title="工作目录">
              <FolderOpen size={13} />
              <select
                value={customDir ? '__custom__' : workdirInput}
                disabled={activeRunning}
                onChange={e => {
                  if (e.target.value === '__custom__') {
                    setCustomDir(true);
                  } else {
                    setCustomDir(false);
                    setWorkdirInput(e.target.value);
                    if (activeSession) {
                      bridge('codexSetSessionConfig', { vm: codexVM, sessionId: activeSession.id, workdir: e.target.value });
                    }
                  }
                }}
              >
                {dirOptions.map(o => (
                  <option key={o.path} value={o.path}>{o.label}</option>
                ))}
                <option value="__custom__">自定义路径…</option>
              </select>
            </label>

            {customDir && (
              <input
                className="codex-custom-input"
                value={workdirInput}
                disabled={activeRunning}
                onChange={e => setWorkdirInput(e.target.value)}
                onBlur={() => {
                  if (activeSession) {
                    bridge('codexSetSessionConfig', { vm: codexVM, sessionId: activeSession.id, workdir: workdirInput });
                  }
                }}
                placeholder="/mnt/agent-vm-shared/..."
              />
            )}

            {supportsChatAgents.length > 0 && (
              <label className="codex-pill" title="选择对话 Agent">
                <Sparkles size={13} />
                <select
                  value={agentInput}
                  disabled={activeRunning}
                  onChange={e => {
                    setAgentInput(e.target.value);
                    if (activeSession) {
                      bridge('codexSetSessionConfig', { vm: codexVM, sessionId: activeSession.id, agent: e.target.value });
                    }
                  }}
                >
                  {supportsChatAgents.map(a => (
                    <option key={a} value={a}>{agentLabel(a)}</option>
                  ))}
                </select>
              </label>
            )}

            <div className="mode-segmented" role="group" aria-label="权限模式">
              {MODES.map(m => (
                <button
                  key={m.id}
                  type="button"
                  disabled={activeRunning}
                  title={m.hint}
                  className={'mode-seg-btn' + (modeInput === m.id ? ' active' : '') + (m.id === 'bypass' ? ' danger' : '')}
                  onClick={() => applyMode(m.id)}
                >
                  {m.id === 'bypass' ? <ShieldAlert size={12} /> : m.id === modeInput ? <ShieldCheck size={12} /> : null}
                  {m.label}
                </button>
              ))}
            </div>
          </div>

          <div className="codex-feed-wrap">
            <div className="codex-feed" ref={feedRef} onScroll={handleFeedScroll}>
              {msgs.length === 0 && (
                <div className="codex-empty">
                  <div className="codex-empty-badge"><Sparkles size={22} /></div>
                  <strong>
                    {supportsChatAgents.length > 0
                      ? `在 ${selectedVM?.displayName || codexVM} 中运行 ${agentLabel(agentInput)}`
                      : `当前虚拟机未检测到 Codex / Claude`}
                  </strong>
                  <span>工作目录：{workdirInput} · 权限模式：{MODES.find(m => m.id === modeInput)?.label}</span>

                  {supportsChatAgents.length > 0 ? (
                    <div className="quick-prompts">
                      {QUICK_PROMPTS.map(qp => (
                        <button
                          key={qp.title}
                          type="button"
                          className="quick-prompt-card"
                          onClick={() => handleSend(qp.text)}
                        >
                          <strong>{qp.title}</strong>
                          <span>{qp.text}</span>
                        </button>
                      ))}
                    </div>
                  ) : (
                    vmHasAgents && vmAgents.length > 0 && (
                      <div className="heading-actions" style={{ marginTop: 10 }}>
                        {vmAgents.map(a => (
                          <button key={a} className="primary" onClick={() => bridge('resume', { name: codexVM, agent: a })}>
                            <Terminal size={14} /> 在终端启动 {agentLabel(a)}
                          </button>
                        ))}
                      </div>
                    )
                  )}
                </div>
              )}

              {msgs.map(m => (
                <div key={m.id} className={'codex-msg ' + m.role}>
                  {m.role === 'user' ? (
                    <div className="codex-user-wrap">
                      {editingMsgId === m.id ? (
                        <div className="chat-edit-box">
                          <textarea
                            rows={3}
                            autoFocus
                            value={editingText}
                            onChange={e => setEditingText(e.target.value)}
                          />
                          <div className="chat-edit-actions">
                            <button type="button" className="secondary" onClick={() => setEditingMsgId('')}>取消</button>
                            <button
                              type="button"
                              className="primary"
                              disabled={activeRunning || !editingText.trim()}
                              onClick={() => {
                                const txt = editingText.trim();
                                setEditingMsgId('');
                                bridge('codexEditResend', {
                                  vm: codexVM,
                                  sessionId: activeSession?.id,
                                  messageId: m.id,
                                  workdir: workdirInput,
                                  prompt: txt,
                                  mode: modeInput,
                                  agent: agentInput,
                                });
                              }}
                            >
                              保存并重发
                            </button>
                          </div>
                        </div>
                      ) : (
                        <>
                          <div className="codex-bubble-user">
                            {m.text}
                            {m.attachments?.length > 0 && (
                              <div className="user-attachments">
                                {m.attachments.map((p, i) => (
                                  <span key={i} className="user-att-chip"><Paperclip size={11} /> {p.split('/').pop()}</span>
                                ))}
                              </div>
                            )}
                          </div>
                          <div className="msg-hover-actions">
                            <button
                              type="button"
                              onClick={async () => {
                                if (await copyText(m.text)) {
                                  setCopiedId(m.id);
                                  setTimeout(() => setCopiedId(''), 1400);
                                }
                              }}
                            >
                              {copiedId === m.id ? <Check size={12} /> : <Copy size={12} />} {copiedId === m.id ? '已复制' : '复制'}
                            </button>
                            {!activeRunning && (
                              <button
                                type="button"
                                onClick={() => {
                                  setEditingMsgId(m.id);
                                  setEditingText(m.text || '');
                                }}
                              >
                                <Pencil size={12} /> 编辑重发
                              </button>
                            )}
                          </div>
                        </>
                      )}
                    </div>
                  ) : (
                    <div className="codex-turn-ai">
                      <div className="codex-ai-head">
                        <span className="codex-ai-avatar"><Sparkles size={12} /></span>
                        <strong>{agentLabel(activeSession?.agent || agentInput)}</strong>
                        {m.status === 'running' && (
                          <span className="codex-ai-live"><LoaderCircle size={12} className="spin" /> 执行中</span>
                        )}
                        {m.status === 'stopped' && <span className="chat-status-pill stopped">已停止</span>}
                        {m.status === 'error' && <span className="chat-status-pill error">执行失败</span>}
                        {(m.items?.length || 0) > 0 && <span className="chat-steps-count">{m.items.length} 步</span>}
                        <LiveTimer startedAt={m.startedAt} finishedAt={m.finishedAt} running={m.status === 'running'} />
                      </div>

                      {(m.items || []).length > 0 && (
                        <div className="codex-steps">
                          {m.items.map(it => (
                            <StepRow key={it.id} item={it} onInspectFile={inspectFileDiff} />
                          ))}
                        </div>
                      )}

                      {m.text && <MarkdownView text={m.text} />}

                      {m.error && (
                        <div className="notice error" style={{ margin: '4px 0 0', flexDirection: 'column', alignItems: 'flex-start' }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                            <AlertTriangle size={15} />
                            <span>{m.error}</span>
                          </div>
                          {renderErrorRecovery(m.error)}
                        </div>
                      )}

                      <div className="chat-ai-foot">
                        {m.usage && (
                          <span className="codex-usage">
                            Token · 输入 {m.usage.input_tokens || 0} · 缓存 {m.usage.cached_input_tokens || 0} · 输出 {m.usage.output_tokens || 0}
                          </span>
                        )}
                        {m.status !== 'running' && (
                          <div className="chat-ai-actions">
                            {m.text && (
                              <button
                                type="button"
                                onClick={async () => {
                                  if (await copyText(m.text)) {
                                    setCopiedId(m.id);
                                    setTimeout(() => setCopiedId(''), 1400);
                                  }
                                }}
                              >
                                {copiedId === m.id ? <Check size={12} /> : <Copy size={12} />} {copiedId === m.id ? '已复制' : '复制回答'}
                              </button>
                            )}
                            {msgs.indexOf(m) > 0 && msgs[msgs.indexOf(m) - 1]?.role === 'user' && !activeRunning && (
                              <button
                                type="button"
                                onClick={() => {
                                  const prevUser = msgs[msgs.indexOf(m) - 1];
                                  bridge('codexEditResend', {
                                    vm: codexVM,
                                    sessionId: activeSession?.id,
                                    messageId: prevUser.id,
                                    workdir: workdirInput,
                                    prompt: prevUser.text,
                                    mode: modeInput,
                                    agent: agentInput,
                                  });
                                }}
                              >
                                <RotateCcw size={12} /> 重试
                              </button>
                            )}
                          </div>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              ))}
              <div ref={endRef} />
            </div>

            {showScrollBottom && (
              <button type="button" className="scroll-bottom-btn" onClick={scrollToBottom}>
                <ArrowDown size={14} /> 回到底部
              </button>
            )}
          </div>

          <div className={'codex-composer' + (modeInput === 'bypass' ? ' danger-mode' : '')}>
            {modeInput === 'bypass' && (
              <div className="bypass-warning-bar">
                <ShieldAlert size={13} />
                <span>当前处于「完全放行」模式：Agent 将不经确认直接执行命令与修改文件</span>
              </div>
            )}

            {stagedFiles.length > 0 && (
              <div className="staged-files-bar">
                {stagedFiles.map(f => (
                  <span key={f.id} className="staged-file-chip">
                    <Paperclip size={11} />
                    <span title={f.guestPath}>{f.name}</span>
                    <button type="button" onClick={() => bridge('codexRemoveAttachment', { vm: codexVM, id: f.id })}>
                      <X size={11} />
                    </button>
                  </span>
                ))}
              </div>
            )}

            {slashMatches.length > 0 && (
              <div className="slash-popover">
                {slashMatches.map(sc => (
                  <button
                    key={sc.cmd}
                    type="button"
                    className="slash-item"
                    onClick={() => {
                      handleSend(sc.cmd);
                      composerRef.current?.focus();
                    }}
                  >
                    <code>{sc.cmd}</code>
                    <span>{sc.desc}</span>
                  </button>
                ))}
              </div>
            )}

            <textarea
              ref={composerRef}
              rows={2}
              value={prompt}
              onChange={e => setPrompt(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder={`向 ${selectedVM?.displayName || codexVM} 的 ${agentLabel(agentInput)} 发送任务…（Enter 发送，Shift+Enter 换行，输入 / 查看快捷命令）`}
            />
            <div className="codex-composer-foot">
              <div className="composer-left-tools">
                {!isRemoteWeb && (
                  <button
                    type="button"
                    className="small-button"
                    title="附加本地文件或图片到共享目录"
                    onClick={() => bridge('codexAttachFile', { vm: codexVM })}
                  >
                    <Paperclip size={13} /> 附件
                  </button>
                )}
                {!isRemoteWeb && vmBrowser?.status === 'ready' && (
                  <button
                    type="button"
                    className="small-button"
                    title="截取当前 Linux 浏览器页面并附加到对话"
                    onClick={() => bridge('browserScreenshotToChat', { name: codexVM, jump: false })}
                  >
                    <Camera size={13} /> 截屏
                  </button>
                )}
                <span className="codex-session-pill">
                  {threadId ? `继续会话 · ${threadId.slice(0, 8)}` : '新会话'}
                </span>
              </div>
              {activeRunning ? (
                <button
                  type="button"
                  className="danger-button"
                  onClick={() => bridge('codexStop', { sessionId: activeSession?.id, vm: codexVM })}
                >
                  <Square size={13} /> 停止
                </button>
              ) : (
                <button type="button" className="primary" disabled={!prompt.trim() || supportsChatAgents.length === 0} onClick={() => handleSend()}>
                  <Send size={13} /> 发送
                </button>
              )}
            </div>
          </div>
        </div>

        {diffOpen && (
          <aside className="chat-diff-pane">
            <div className="chat-diff-head">
              <div>
                <strong>代码变更审阅</strong>
                <small>{workdirInput}</small>
              </div>
              <div className="heading-actions">
                <button
                  type="button"
                  className="icon-button"
                  title="刷新 git diff"
                  onClick={() => bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput })}
                >
                  <RefreshCw size={14} className={codexState.gitDiff?.loading ? 'spin' : ''} />
                </button>
                <button type="button" className="icon-button" title="关闭" onClick={() => setDiffOpen(false)}>
                  <X size={14} />
                </button>
              </div>
            </div>

            {sessionChanges.length > 0 && (
              <div className="diff-file-chips">
                <button
                  type="button"
                  className={!codexState.gitDiff?.file ? 'active' : ''}
                  onClick={() => bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput })}
                >
                  全部文件
                </button>
                {sessionChanges.map(c => (
                  <button
                    key={c.path}
                    type="button"
                    className={codexState.gitDiff?.file === c.path ? 'active' : ''}
                    onClick={() => bridge('codexGitDiff', { vm: codexVM, workdir: workdirInput, file: c.path })}
                    title={c.path}
                  >
                    <code>{c.kind[0]?.toUpperCase() || 'M'}</code> {c.path.split('/').pop()}
                  </button>
                ))}
              </div>
            )}

            <div className="chat-diff-body">
              {codexState.gitDiff?.loading ? (
                <div className="diff-empty"><LoaderCircle size={18} className="spin" /> 正在读取 git diff…</div>
              ) : codexState.gitDiff?.error ? (
                <div className="diff-empty">{codexState.gitDiff.error}</div>
              ) : (
                <>
                  {codexState.gitDiff?.status && (
                    <pre className="diff-status-box">{codexState.gitDiff.status}</pre>
                  )}
                  <DiffView diffText={codexState.gitDiff?.diff || ''} />
                </>
              )}
            </div>
          </aside>
        )}
      </div>

      {bypassConfirmTarget && (
        <div className="modal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) setBypassConfirmTarget(false); }}>
          <div className="modal" role="dialog" aria-modal="true">
            <h2>启用「完全放行」模式？</h2>
            <p className="muted">
              此模式下，{agentLabel(agentInput)} 将绕过沙盒和人工审批，直接在虚拟机内执行命令并修改已挂载的项目文件。请确保当前目录已做好 Git 备份。
            </p>
            <div className="dialog-actions">
              <button type="button" className="secondary" onClick={() => setBypassConfirmTarget(false)}>取消</button>
              <button type="button" className="danger-button" onClick={confirmBypass}>确认启用</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
