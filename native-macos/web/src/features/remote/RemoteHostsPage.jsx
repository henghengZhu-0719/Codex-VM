import React, { useState } from 'react';
import {
  Check,
  CheckCircle2,
  Copy,
  ExternalLink,
  Laptop,
  LoaderCircle,
  Play,
  Plus,
  RefreshCw,
  Server,
  Square,
  Terminal,
  Trash2,
  Wifi,
  WifiOff,
  X,
} from 'lucide-react';
import { bridge, copyText } from '../../bridge.js';
import { IconButton, SectionTitle } from '../../components/SharedUI.jsx';

export default function RemoteHostsPage({
  hosts = [],
  vmLists = {},
  statusText = '',
  connectionState = 'disconnected',
  activeHostID = '',
  daemon = { connected: false, status: 'disconnected', tasks: [] },
  onOpenSettings,
}) {
  const [showAdd, setShowAdd] = useState(false);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [quickSpec, setQuickSpec] = useState('');
  const [form, setForm] = useState({
    name: 'Mac Pro',
    hostname: '',
    username: '',
    sshPort: '22',
    workbenchPort: '18080',
  });
  const [copiedKey, setCopiedKey] = useState('');

  const handleCopy = async (key, text) => {
    const ok = await copyText(text);
    if (ok) {
      setCopiedKey(key);
      setTimeout(() => setCopiedKey(cur => (cur === key ? '' : cur)), 1800);
    }
  };

  const applyQuickSpec = raw => {
    setQuickSpec(raw);
    const trimmed = raw.trim();
    if (!trimmed) return;
    let user = '';
    let rest = trimmed;
    if (rest.includes('@')) {
      const idx = rest.indexOf('@');
      user = rest.slice(0, idx).trim();
      rest = rest.slice(idx + 1).trim();
    }
    let host = rest;
    let port = '';
    if (rest.includes(':')) {
      const idx = rest.lastIndexOf(':');
      host = rest.slice(0, idx).trim();
      port = rest.slice(idx + 1).trim();
    }
    setForm(old => ({
      ...old,
      username: user || old.username,
      hostname: host || old.hostname,
      sshPort: /^\d+$/.test(port) ? port : old.sshPort,
    }));
  };

  const submitAdd = e => {
    e?.preventDefault?.();
    if (!form.name.trim() || !form.hostname.trim() || !form.username.trim()) return;
    bridge('remoteHostAdd', {
      name: form.name.trim(),
      hostname: form.hostname.trim(),
      username: form.username.trim(),
      sshPort: Number(form.sshPort) || 22,
      workbenchPort: Number(form.workbenchPort) || 18080,
    });
    setShowAdd(false);
    setQuickSpec('');
    setForm({ name: '', hostname: '', username: '', sshPort: '22', workbenchPort: '18080' });
  };

  const totalRemoteVMs = hosts.reduce((sum, h) => sum + (vmLists[h.id]?.vms?.length || 0), 0);
  const runningRemoteVMs = hosts.reduce(
    (sum, h) => sum + (vmLists[h.id]?.vms || []).filter(v => v.status === 'Running').length,
    0,
  );

  return (
    <div className="remote-page">
      <SectionTitle title="远程主机">
        {hosts.length > 0 && (
          <button className="secondary" onClick={() => bridge('remoteVMList')}>
            <RefreshCw size={14} /> 刷新全部
          </button>
        )}
        <button className="primary" onClick={() => setShowAdd(true)}>
          <Plus size={15} /> 添加远程主机
        </button>
      </SectionTitle>

      {/* Summary Banner */}
      <div className="remote-summary-bar">
        <div className="remote-summary-item">
          <Server size={15} />
          <span><strong>{hosts.length}</strong> 台主机</span>
        </div>
        <div className="remote-summary-sep" />
        <div className="remote-summary-item">
          <span className={'status-dot ' + (runningRemoteVMs > 0 ? 'active' : '')} />
          <span><strong>{runningRemoteVMs}</strong> / {totalRemoteVMs} 远端 VM 运行中</span>
        </div>
        <div className="remote-summary-sep" />
        <div className="remote-summary-item">
          {daemon?.connected ? <Wifi size={14} className="ok-icon" /> : <WifiOff size={14} />}
          <span>本机 Daemon：{daemon?.connected ? 'SSE 已连接' : '兼容模式'}</span>
        </div>
        {statusText && statusText !== '未连接' && (
          <div className={'remote-summary-status ' + (connectionState === 'error' ? 'is-error' : '')}>
            {statusText}
          </div>
        )}
      </div>

      {/* Empty Onboarding State */}
      {hosts.length === 0 ? (
        <div className="remote-empty-card">
          <div className="remote-empty-icon">
            <Laptop size={28} />
          </div>
          <h3>从本机直连远端 Mac Pro 虚拟机</h3>
          <p className="muted">
            通过 EasyTier + SSH 密钥认证直接管理远端所有虚拟机（含已停止 VM），支持一键启停、打开原生终端与跨设备恢复 tmux AI 会话，无需在 VPS 上运行虚拟机。
          </p>
          <div className="remote-steps-grid">
            <div className="remote-step-pill">
              <span className="remote-step-num">1</span>
              <div>
                <strong>远端开启远程登录</strong>
                <div className="muted">Mac Pro 系统设置 → 通用 → 共享</div>
              </div>
            </div>
            <div className="remote-step-pill">
              <span className="remote-step-num">2</span>
              <div>
                <strong>配置 SSH 公钥与指纹</strong>
                <div className="muted">首次终端执行 ssh user@ip 确认指纹</div>
              </div>
            </div>
            <div className="remote-step-pill">
              <span className="remote-step-num">3</span>
              <div>
                <strong>添加主机一键连接</strong>
                <div className="muted">自动拉取远端全部 VM 与状态</div>
              </div>
            </div>
          </div>
          <div className="remote-empty-actions">
            <button className="primary" onClick={() => setShowAdd(true)}>
              <Plus size={15} /> 添加第一台远程主机
            </button>
            {onOpenSettings && (
              <button className="secondary" onClick={onOpenSettings}>
                配置本机共享 / 后台服务
              </button>
            )}
          </div>
        </div>
      ) : (
        <div className="remote-host-grid">
          {hosts.map(h => {
            const list = vmLists[h.id];
            const loading = !list || list.loading;
            const vms = list?.vms || [];
            const runningCount = vms.filter(v => v.status === 'Running').length;
            const hasError = !!list?.error;
            const verifyCmd = `ssh -p ${h.sshPort} ${h.username}@${h.hostname} true`;
            const isWebActive = activeHostID === h.id;

            return (
              <section className="remote-host-card" key={h.id}>
                <header className="remote-host-card-head">
                  <div className="remote-host-title-wrap">
                    <span
                      className={
                        'status-dot ' +
                        (loading ? 'pending' : hasError ? 'error' : 'active')
                      }
                    />
                    <div>
                      <div className="remote-host-name-row">
                        <h3>{h.name}</h3>
                        <span className="remote-host-addr">
                          {h.username}@{h.hostname}:{h.sshPort}
                        </span>
                      </div>
                      <div className="muted remote-host-meta">
                        {loading
                          ? '正在通过 SSH 获取远端 VM…'
                          : hasError
                            ? '连接异常（不影响远端已运行的任务）'
                            : `${runningCount} 运行中 · 共 ${vms.length} 台虚拟机`}
                      </div>
                    </div>
                  </div>
                  <div className="remote-host-head-actions">
                    <IconButton
                      title={`刷新 ${h.name}`}
                      disabled={loading}
                      onClick={() => bridge('remoteVMList', { id: h.id })}
                    >
                      <RefreshCw size={14} className={loading ? 'spin' : ''} />
                    </IconButton>
                    {isWebActive && connectionState === 'connected' ? (
                      <>
                        <button className="secondary" onClick={() => bridge('remoteHostOpen')}>
                          <ExternalLink size={13} /> 打开工作台
                        </button>
                        <button className="secondary" onClick={() => bridge('remoteHostDisconnect')}>
                          断开
                        </button>
                      </>
                    ) : (
                      <button
                        className="secondary"
                        disabled={connectionState === 'connecting'}
                        onClick={() => bridge('remoteHostConnect', { id: h.id })}
                        title="通过 SSH 隧道打开远端网页工作台"
                      >
                        <ExternalLink size={13} />
                        {isWebActive && connectionState === 'connecting' ? '连接中…' : '网页工作台'}
                      </button>
                    )}
                    <IconButton
                      title={`移除主机 ${h.name}`}
                      onClick={() => {
                        if (window.confirm(`确定移除远程主机「${h.name}」？`)) {
                          bridge('remoteHostRemove', { id: h.id });
                        }
                      }}
                    >
                      <Trash2 size={14} />
                    </IconButton>
                  </div>
                </header>

                {hasError && (
                  <div className="remote-error-box" role="status">
                    <div className="remote-error-text">{list.error}</div>
                    <div className="remote-error-actions">
                      <button
                        className="secondary"
                        onClick={() => handleCopy(`verify-${h.id}`, verifyCmd)}
                      >
                        {copiedKey === `verify-${h.id}` ? <Check size={13} /> : <Copy size={13} />}
                        {copiedKey === `verify-${h.id}` ? '已复制验证命令' : '复制 SSH 验证命令'}
                      </button>
                      <button className="secondary" onClick={() => bridge('remoteVMList', { id: h.id })}>
                        重试
                      </button>
                    </div>
                  </div>
                )}

                {!hasError && loading && vms.length === 0 && (
                  <div className="remote-vm-empty">
                    <LoaderCircle size={16} className="spin" /> 正在连接 {h.hostname}…
                  </div>
                )}

                {!hasError && !loading && vms.length === 0 && (
                  <div className="remote-vm-empty muted">该远程主机上暂无项目虚拟机</div>
                )}

                {vms.length > 0 && (
                  <div className="remote-vm-list">
                    {vms.map(vm => {
                      const isRunning = vm.status === 'Running';
                      const cliCmd = `agent-vm --host ${h.name} shell ${vm.name}`;
                      const copyId = `cli-${h.id}-${vm.name}`;
                      return (
                        <div className={'remote-vm-row ' + (isRunning ? 'is-running' : 'is-stopped')} key={vm.name}>
                          <div className="remote-vm-info">
                            <span className={'status-dot ' + (isRunning ? 'active' : '')} />
                            <div className="remote-vm-names">
                              <div className="remote-vm-title">
                                <strong>{vm.displayName}</strong>
                                <span className={'remote-vm-badge ' + (isRunning ? 'running' : 'stopped')}>
                                  {isRunning ? '运行中' : vm.status || '已停止'}
                                </span>
                              </div>
                              {vm.displayName !== vm.name && (
                                <div className="remote-vm-sub muted">{vm.name}</div>
                              )}
                            </div>
                          </div>

                          <div className="remote-vm-actions">
                            {isRunning ? (
                              <>
                                <button
                                  className="primary"
                                  onClick={() => bridge('remoteVMTerminal', { id: h.id, vmName: vm.name })}
                                >
                                  <Terminal size={13} /> 连接终端
                                </button>
                                <button
                                  className="secondary"
                                  title={cliCmd}
                                  onClick={() => handleCopy(copyId, cliCmd)}
                                >
                                  {copiedKey === copyId ? <Check size={13} /> : <Copy size={13} />}
                                  {copiedKey === copyId ? '已复制' : 'CLI'}
                                </button>
                                <button
                                  className="secondary"
                                  onClick={() => {
                                    if (window.confirm(`确定停止「${h.name}」上的虚拟机「${vm.displayName}」？`)) {
                                      bridge('remoteHostVMStop', { id: h.id, vmName: vm.name });
                                    }
                                  }}
                                >
                                  <Square size={12} /> 停止
                                </button>
                              </>
                            ) : (
                              <button
                                className="primary"
                                onClick={() => bridge('remoteHostVMStart', { id: h.id, vmName: vm.name })}
                              >
                                <Play size={13} /> 启动
                              </button>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </section>
            );
          })}
        </div>
      )}

      {/* Add Remote Host Modal */}
      {showAdd && (
        <div className="modal-backdrop" onClick={() => setShowAdd(false)}>
          <div className="modal remote-add-modal" onClick={e => e.stopPropagation()}>
            <div className="modal-head">
              <h3>添加远程主机</h3>
              <IconButton title="关闭" onClick={() => setShowAdd(false)}>
                <X size={16} />
              </IconButton>
            </div>
            <form onSubmit={submitAdd} className="remote-add-form">
              <div className="remote-quick-parse">
                <label>
                  <span>快捷粘贴（可选）</span>
                  <input
                    placeholder="例如：zhuyq@10.144.0.2 或 zhuyq@10.144.0.2:2222"
                    value={quickSpec}
                    onChange={e => applyQuickSpec(e.target.value)}
                  />
                </label>
              </div>
              <div className="form-grid">
                <label>
                  主机别名
                  <input
                    required
                    placeholder="Mac Pro"
                    value={form.name}
                    onChange={e => setForm({ ...form, name: e.target.value })}
                  />
                </label>
                <label>
                  EasyTier IP / 主机名
                  <input
                    required
                    placeholder="10.144.0.2"
                    value={form.hostname}
                    onChange={e => setForm({ ...form, hostname: e.target.value })}
                  />
                </label>
                <label>
                  SSH 用户名
                  <input
                    required
                    placeholder="macpro"
                    value={form.username}
                    onChange={e => setForm({ ...form, username: e.target.value })}
                  />
                </label>
                <label>
                  SSH 端口
                  <input
                    type="number"
                    min="1"
                    max="65535"
                    value={form.sshPort}
                    onChange={e => setForm({ ...form, sshPort: e.target.value })}
                  />
                </label>
              </div>

              <button
                type="button"
                className="remote-advanced-toggle"
                onClick={() => setShowAdvanced(v => !v)}
              >
                {showAdvanced ? '收起高级选项' : '高级选项（网页工作台端口）'}
              </button>

              {showAdvanced && (
                <div className="form-grid" style={{ marginTop: 8 }}>
                  <label>
                    网页工作台端口（可选，CLI 直连模式不需要）
                    <input
                      type="number"
                      min="1024"
                      max="65535"
                      value={form.workbenchPort}
                      onChange={e => setForm({ ...form, workbenchPort: e.target.value })}
                    />
                  </label>
                </div>
              )}

              <div className="remote-security-note">
                <CheckCircle2 size={14} />
                <span>严格校验 known_hosts 指纹、使用本机 SSH 公钥、禁用 Agent/X11 转发，不保存密码或私钥。</span>
              </div>

              <div className="modal-actions">
                <button type="button" className="secondary" onClick={() => setShowAdd(false)}>
                  取消
                </button>
                <button
                  type="submit"
                  className="primary"
                  disabled={!form.name.trim() || !form.hostname.trim() || !form.username.trim()}
                >
                  保存并拉取 VM
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
