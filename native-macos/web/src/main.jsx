import React, {useEffect,useMemo,useState,useRef} from 'react';
import {createRoot} from 'react-dom/client';
import {Monitor,Network,ChartNoAxesCombined,Settings2,Plus,Play,Square,Terminal,RefreshCw,MoreHorizontal,ShieldCheck,ShieldAlert,Activity,HardDrive,Cloud,FolderOpen,Clock3,ArrowRight,Power,Search,AlertTriangle,CheckCircle2,LoaderCircle} from 'lucide-react';
import './style.css';

const bridge = (action, payload = {}) => {
  const host = window.webkit?.messageHandlers?.agentVM;
  if (!host) { console.info('Preview mode: ', action); return; }
  host.postMessage({action, payload});
};
const blank = {vms:[], busy:false, proxy:null, quotas:{}, usage:{}, editors:{}, mounts:{}, error:'', proxyError:'', proxyMessage:'', buildStarted:false, buildComplete:false, buildStage:0};
const tabs = [{id:'vms',label:'虚拟机',icon:Monitor},{id:'proxy',label:'网络代理',icon:Network},{id:'quota',label:'AI 额度',icon:ChartNoAxesCombined},{id:'settings',label:'设置',icon:Settings2}];
function IconButton({title,children,onClick,disabled=false,danger=false}) {return <button className={'icon-button '+(danger?'danger':'')} title={title} aria-label={title} onClick={onClick} disabled={disabled}>{children}</button>;}
function MoreMenu({children}) {
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
  return <details ref={menu} className="card-more"><summary title="更多操作" aria-label="更多操作"><MoreHorizontal size={17}/></summary><div className="more-menu" onClick={closeAction}>{children}</div></details>;
}
function KV({name,value}) {return <div className="key-value"><span>{name}</span><strong>{value??'—'}</strong></div>;}
function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let idx = 0, val = bytes;
  while (val >= 1024 && idx < units.length - 1) { val /= 1024; idx++; }
  return val.toFixed(idx >= 3 ? 2 : idx >= 1 ? 1 : 0) + ' ' + units[idx];
}
function formatSubUsage(usage) {
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
function QuotaBar({label,window:win}) {const left=win ? Math.max(0,Math.min(100,100-(win.used_percent??100))):null;return <div className="quota-bar"><div className="flex-between"><span>{label}</span><strong>{left===null?'未知':left+'%'}</strong></div><div className="bar"><div style={{width:(left??0)+'%'}} className={left!==null&&left<=15?'low':''}/></div><small>{win?.reset_after_seconds ? '约 '+Math.ceil(win.reset_after_seconds/3600)+' 小时后重置':''}</small></div>;}
function VMCard({vm,state,select}) {const running=vm.status==='Running';const editor=state.editors?.[vm.name];const quota=state.quotas[vm.name];const usage=state.usage[vm.name];const name=vm.displayName||vm.name;return <article className="vm-card">
<div className="vm-head"><div className="vm-glyph"><Monitor size={20}/></div><div className="vm-name"><strong title={name}>{name}</strong><span>{vm.standalone?'共享工作区':vm.projectPath||'项目环境'}</span></div><div className={'status '+(running?'running':'')}><span className="status-dot"/>{running?'运行中':vm.status==='Stopped'?'已停止':vm.status}</div></div>
<div className="metrics"><div><span>CPU</span><strong>{running&&usage?usage.cpu.toFixed(1)+'%':'—'}</strong></div><div><span>内存</span><strong>{running&&usage?Math.round(usage.used)+' / '+Math.round(usage.total)+' MB':'—'}</strong></div></div>
<div className="quota-inline"><span>Codex 额度</span><div>{quota?.status==='ok' ? <><span>5h {quota.five_hour ? Math.max(0,Math.min(100,100-quota.five_hour.used_percent))+'%' : '—'}</span><span>7d {quota.weekly ? Math.max(0,Math.min(100,100-quota.weekly.used_percent))+'%' : '—'}</span></>:<span className="muted">{running?'暂无数据':'启动后查询'}</span>}</div></div>
{running&&<div className="web-code-row"><span>Web Code</span>{editor?.status==='ready'?<><button className="web-code-link" onClick={()=>bridge('codeOpen',{name:vm.name})}>{editor.url}</button></>:editor?.status==='error'?<button className="web-code-retry" title={editor.error} onClick={()=>bridge('codeRetry',{name:vm.name})}>重试</button>:<span className="muted">启动中…</span>}</div>}
<div className="card-actions"><button className="secondary" onClick={()=>bridge('terminal',{name:vm.name})} disabled={!running}><Terminal size={15}/> 终端</button><button className="secondary" onClick={()=>bridge('resume',{name:vm.name,agent:'codex'})} disabled={!running}><Clock3 size={15}/> 恢复会话</button><div className="flex-fill"/><MoreMenu><button disabled={!running||editor?.status!=='ready'} onClick={()=>bridge('codeOpen',{name:vm.name})}>打开 Web Code</button><button disabled={!running} onClick={()=>bridge('resume',{name:vm.name,agent:'claude'})}>恢复 Claude 会话</button><button onClick={()=>select({type:'rename',vm})}>修改名称</button><button onClick={()=>select({type:'mounts',vm})}>管理共享文件夹</button><button onClick={()=>bridge('quota',{name:vm.name})} disabled={!running}>刷新额度</button><button className="danger-text" onClick={()=>select({type:'delete',vm})} disabled={running}>删除虚拟机</button></MoreMenu><IconButton title={running?'停止虚拟机':'启动虚拟机'} disabled={state.busy||(!running&&vm.status!=='Stopped')} onClick={()=>select({type:running?'stop':'start',vm})}>{running?<Square size={16}/>:<Play size={16}/>}</IconButton></div>
</article>}
function SectionTitle({title,sub,children}) {return <div className="heading"><div><h1>{title}</h1><p>{sub}</p></div><div className="heading-actions">{children}</div></div>}
function App(){
  const [state,setState]=useState(window.__agentVMInitial||blank);
  const [page,setPage]=useState('vms');
  const [modal,setModal]=useState(null);
  const [filter,setFilter]=useState('');
  const [create,setCreate]=useState({name:'',cpus:2,memory:4,disk:20,codeServer:true});
  const [proxyForm,setProxyForm]=useState(null);
  const [proxyDirty,setProxyDirty]=useState(false);
  const [manual,setManual]=useState({name:'',type:'socks5',server:'',port:1080,username:'',password:''});
  const [importUrl,setImportUrl]=useState('');
  const [renameText,setRenameText]=useState('');
  const [nodeFilter,setNodeFilter]=useState('');
  const [showAllNodes,setShowAllNodes]=useState(false);
  const [nodesExpanded,setNodesExpanded]=useState(false);
  useEffect(()=>{window.agentVMReceive = obj=>setState(old=>({...old,...obj}));bridge('ready');return ()=>{delete window.agentVMReceive}},[]);
  useEffect(()=>{if(state.proxy && !proxyDirty)setProxyForm({proxy_mode:state.proxy.proxy_mode,managed_enabled:state.proxy.managed_enabled,use_proxy:state.proxy.use_proxy,custom_proxy_url:state.proxy.custom_proxy_url,dns_url:state.proxy.dns_url,port:state.proxy.port})},[state.proxy,proxyDirty]);
  const vms=useMemo(()=>state.vms.filter(v=>v.name!=='base'&&v.name!=='base-building'),[state.vms]);
  const visible=vms.filter(v=>(v.displayName||v.name).toLowerCase().includes(filter.toLowerCase()));
  const running=vms.filter(v=>v.status==='Running');
  const proxy=state.proxy;
  const nodes=useMemo(()=>(proxy?.sources||[]).flatMap(s=>(s.nodes||[]).map(n=>({...n,source:s.name}))),[proxy?.sources]);
  const activeNodeId=proxy?.route?.[0]||proxy?.selected||'';
  const activeNode=useMemo(()=>nodes.find(n=>n.id===activeNodeId)||null,[nodes,activeNodeId]);
  const filteredNodes=useMemo(()=>{
    const q=nodeFilter.trim().toLowerCase();
    const list=q?nodes.filter(n=>(n.name||'').toLowerCase().includes(q)||(n.type||'').toLowerCase().includes(q)||(n.source||'').toLowerCase().includes(q)):nodes;
    if(!activeNodeId) return list;
    return [...list].sort((a,b)=>(a.id===activeNodeId?-1:b.id===activeNodeId?1:0));
  },[nodes,nodeFilter,activeNodeId]);
  const displayedNodes=showAllNodes?filteredNodes:filteredNodes.slice(0,40);
  const refreshAction=page==='proxy'?'proxyRefresh':page==='quota'?'refreshQuotas':'refresh';
  const act=(type,vm)=>{if(type==='stop'||type==='delete')setModal({type,vm});else bridge(type,{name:vm.name})};
  const confirm=()=>{if(modal?.type==='stop'||modal?.type==='delete')bridge(modal.type,{name:modal.vm.name});if(modal?.type==='deleteSource')bridge('proxySourceDelete',{id:modal.source.id});if(modal?.type==='closeGate')bridge('proxyGateClose');setModal(null)};
  const submitCreate=()=>{bridge('create',{...create});setModal({type:'creating'})};
  return <div className="layout">
  <aside className="sidebar"><div className="brand"><div className="brand-icon"><Monitor size={19}/></div><div className="brand-text"><strong>Agent VM</strong><span>DESKTOP</span></div></div>
  <div className="nav-label">工作空间</div><nav>{tabs.map(t=><button key={t.id} className={'nav-item '+(page===t.id?'selected':'')} onClick={()=>setPage(t.id)}><t.icon size={17}/>{t.label}{t.id==='vms'&&<span className="nav-count">{vms.length}</span>}</button>)}</nav>
  <div className="sidebar-bottom"><div className="sidebar-separator"/><div className="small-label">运行概览</div><div className="side-status"><span className="status-dot active"/><span>{running.length} 台虚拟机运行中</span></div><div className="side-status"><span className={'status-dot '+(proxy?.use_proxy?'active':'')}/><span>代理 {proxy?.use_proxy?'已配置':'未启用'}</span></div><button className="sidebar-refresh" onClick={()=>bridge('refresh')}><RefreshCw size={14}/> 刷新状态</button></div></aside>
  <main className="main"><div className="topbar"><div className="breadcrumbs">工作空间 <span>/</span> {tabs.find(x=>x.id===page)?.label}</div><div className="top-right"><span className="live-marker"><span className="status-dot active"/> 本地运行</span><IconButton title="刷新当前页面" disabled={state.busy||state.proxyBusy} onClick={()=>bridge(refreshAction)}><RefreshCw size={15} className={state.busy||state.proxyBusy?'spin':''}/></IconButton></div></div>
  <div className="content">
  {page==='vms'&&<><SectionTitle title="虚拟机" sub="隔离运行 AI Agent，统一管理资源、会话与项目环境。"><button className="primary" onClick={()=>setModal({type:'create'})}><Plus size={17}/> 新建虚拟机</button></SectionTitle>
  <div className="stat-grid"><div className="stat"><span>虚拟机总数</span><strong>{vms.length}</strong><small>已创建实例</small></div><div className="stat"><span>正在运行</span><strong>{running.length}</strong><small>活跃工作环境</small></div><div className="stat"><span>已停止</span><strong>{vms.length-running.length}</strong><small>不运行来宾进程</small></div></div>
  <div className="section-row"><h2>所有虚拟机 <span>{visible.length}</span></h2><label className="search"><Search size={15}/><input value={filter} onChange={e=>setFilter(e.target.value)} placeholder="搜索虚拟机"/></label></div>
  {visible.length?<div className="vm-grid">{visible.map(v=><VMCard key={v.name} vm={v} state={state} select={({type,vm})=>{if(type==='rename'){setRenameText(v.displayName===v.name?'':v.displayName);setModal({type,vm})}else if(type==='mounts'){setModal({type,vm})}else act(type,vm)}}/>)}</div>:<div className="empty"><Monitor size={30}/><strong>暂无匹配的虚拟机</strong><span>点击「新建虚拟机」开始创建。</span></div>}
  {state.buildStarted&&<div className="notice"><LoaderCircle size={16}/> {state.buildComplete?'创建完成':'正在准备虚拟机 · 阶段 '+state.buildStage}</div>}</>}
  {page==='quota'&&<><SectionTitle title="AI 额度" sub="查看每台运行中虚拟机的 Codex 额度和重置状态。"><button className="secondary" onClick={()=>bridge('refreshQuotas')}><RefreshCw size={16}/> 刷新额度</button></SectionTitle>
  <div className="info-strip"><Activity size={17}/> 数据从各虚拟机内部查询；登录状态、网络和服务限制可能影响结果。</div>
  <div className="quota-grid">{vms.map(vm=>{const q=state.quotas[vm.name];return <section className="panel" key={vm.name}><div className="flex-between"><strong>{vm.displayName||vm.name}</strong><span className="muted">{q?.plan_type?.toUpperCase()||'Codex'}</span></div>{q?.status==='ok'?<><QuotaBar label="5 小时窗口" window={q.five_hour}/><QuotaBar label="每周窗口" window={q.weekly}/><p className="muted text-xs">查询于 {q.fetchedAt||'最近一次刷新'}</p></>:<p className="muted">{q?.error|| (vm.status==='Running'?'正在等待额度数据':'虚拟机已停止')}</p>}<button className="small-button" disabled={vm.status!=='Running'} onClick={()=>bridge('quota',{name:vm.name})}><RefreshCw size={13}/> 刷新该实例</button></section>})}</div></>}
  {page==='proxy'&&<><SectionTitle title="网络代理" sub="按配置、节点、检查、连接的顺序管理代理出口。"/>
  {state.proxyError&&<div className="notice error"><AlertTriangle size={17}/>{state.proxyError}</div>}
  {state.proxyMessage&&<div className="info-strip"><Activity size={16}/>{state.proxyMessage}</div>}
  <section className="panel"><div className="section-row"><h2>01 · 网关配置</h2><span className={'status '+(proxy?.running?'running':'')}>{proxy?.running?'核心运行中':'核心未运行'}</span></div>{proxyForm&&<div className="form-grid"><label>代理模式<select value={proxyForm.proxy_mode||'custom'} onChange={e=>{setProxyDirty(true);setProxyForm({...proxyForm,proxy_mode:e.target.value})}}><option value="custom">自定义 HTTP / SOCKS5</option><option value="mihomo">Mihomo 节点</option></select></label><label>DoH 地址<input value={proxyForm.dns_url||''} onChange={e=>{setProxyDirty(true);setProxyForm({...proxyForm,dns_url:e.target.value})}}/></label>{proxyForm.proxy_mode==='custom'&&<label className="form-wide">代理地址<input value={proxyForm.custom_proxy_url||''} onChange={e=>{setProxyDirty(true);setProxyForm({...proxyForm,custom_proxy_url:e.target.value})}}/></label>}<label className="check-row"><input type="checkbox" checked={!!proxyForm.use_proxy} onChange={e=>{setProxyDirty(true);setProxyForm({...proxyForm,use_proxy:e.target.checked})}}/> 启用代理</label><label className="check-row"><input type="checkbox" checked={!!proxyForm.managed_enabled} onChange={e=>{setProxyDirty(true);setProxyForm({...proxyForm,managed_enabled:e.target.checked})}}/> 托管网络模式（安全验证未完成）</label></div>}<div className="inline-actions"><button className="primary" onClick={()=>{bridge('proxyConfig',proxyForm||{});setProxyDirty(false)}} disabled={!proxyForm||state.proxyBusy||!proxyDirty}>保存配置</button>{proxyDirty&&<button className="secondary" onClick={()=>{setProxyDirty(false);setProxyForm(null)}}>撤销修改</button>}</div></section>
  <section className="panel"><div className="section-row"><h2>02 · 节点与路由</h2><div className="inline-actions" style={{marginTop:0}}><span className="muted">{filteredNodes.length===nodes.length?`${nodes.length} 个节点`:`${filteredNodes.length} / ${nodes.length} 个节点`}</span>{nodes.length>0&&<button className="small-button" onClick={()=>setNodesExpanded(x=>!x)}>{nodesExpanded?'收起节点':`展开节点 (${nodes.length})`}</button>}</div></div><div className="inline-form"><input placeholder="HTTPS 订阅地址" value={importUrl} onChange={e=>setImportUrl(e.target.value)}/><button className="secondary" onClick={()=>{bridge('proxyImport',{url:importUrl});setImportUrl('')}} disabled={!importUrl.startsWith('https://')}>导入订阅</button><button className="secondary" onClick={()=>setModal({type:'manual'})}>添加节点</button></div>{(proxy?.sources?.length||0)>0&&<div className="source-list">{(proxy?.sources||[]).map(src=><div className="source-row" key={src.id}><div><strong>{src.name}</strong><small>{src.nodes?.length||0} 个节点 · {src.error||formatSubUsage(src.usage)||'订阅已导入'}</small></div><button className="small-button" disabled={state.proxyBusy} onClick={()=>bridge('proxySourceRefresh',{id:src.id})}><RefreshCw size={13}/> 更新</button><button className="small-button" disabled={state.proxyBusy} onClick={()=>setModal({type:'deleteSource',source:src})}>移除</button></div>)}</div>}{!nodesExpanded&&activeNode&&<div className="node active" style={{border:'1px solid var(--line)',borderRadius:'10px',padding:'10px 12px',margin:'8px 0'}}><span><Network size={15}/><span className="node-name" title={activeNode.name}>{activeNode.name}</span><small>{activeNode.source} · {activeNode.type}</small><span className="node-badge">当前出口</span></span><button className="small-button" onClick={()=>setNodesExpanded(true)}>切换节点</button></div>}{nodes.length>0&&nodesExpanded&&<><div className="node-toolbar"><label className="search node-search"><Search size={14}/><input value={nodeFilter} onChange={e=>{setNodeFilter(e.target.value);setShowAllNodes(false)}} placeholder="搜索节点名称、协议或来源"/></label>{proxy?.proxy_mode==='mihomo'&&<button className="small-button" disabled={state.proxyBusy} onClick={()=>bridge('proxyDelay',{})}>全部测速</button>}</div><div className="node-list">{displayedNodes.map(n=>{const isActive=n.id===activeNodeId;return <div key={n.id} className={'node '+(isActive?'active':'')}><span><Network size={15}/><span className="node-name" title={n.name}>{n.name}</span><small>{n.source} · {n.type}</small>{isActive&&<span className="node-badge">当前出口</span>}</span><div className="node-actions">{proxy?.proxy_mode==='mihomo'&&<button onClick={()=>bridge('proxyDelay',{id:n.id})} className="small-button" disabled={state.proxyBusy}>测速</button>}<button onClick={()=>bridge('proxyRoute',{id:n.id})} className="small-button" disabled={state.proxyBusy||isActive}>{isActive?'已启用':<>设为出口 <ArrowRight size={13}/></>}</button></div></div>})}{displayedNodes.length===0&&<p className="muted">没有匹配的节点。</p>}</div>{!showAllNodes&&filteredNodes.length>40&&<div className="node-more"><button className="small-button" onClick={()=>setShowAllNodes(true)}>显示全部 {filteredNodes.length} 个节点（当前显示前 40 个）</button></div>}</>}{nodes.length===0&&<p className="muted">暂未导入代理节点。</p>}<div className="inline-actions"><button className="secondary" onClick={()=>bridge('proxyStop')}>停止代理核心</button></div></section>
  <div className="proxy-bottom-grid"><section className="panel"><div className="section-row"><h2>03 · 安全自检</h2><button className="secondary" onClick={()=>bridge('proxyProbe')} disabled={state.proxyBusy}><ShieldCheck size={16}/> 运行检查</button></div><KV name="探测出口 IP" value={proxy?.last_probe?.exit_ip||'未获得'}/><KV name="网络门禁" value={(proxy?.gates||[]).map(g=>g.state).join(' / ')||'无运行中的托管实例'}/><div className="check-list">{(proxy?.last_probe?.report?.checks||[]).map(c=><div className="check-line" key={c.id}>{c.state==='passed'?<CheckCircle2 size={15} color="var(--ok)"/>:<ShieldAlert size={15} color="var(--warn)"/>}<span>{c.id}</span><span className="muted">{c.state}</span></div>)}</div><p className="muted text-xs">主机检测不能证明虚拟机完全隔离；未知项不会被视为通过。</p><button className="small-button" onClick={()=>setModal({type:'closeGate'})}>关闭网络门禁</button></section>
  <section className="panel"><div className="section-row"><h2>04 · 代理连接</h2><button className="secondary" onClick={()=>bridge('proxyConnections')}><RefreshCw size={15}/> 更新连接</button></div><KV name="累计上行" value={((state.proxyUploadTotal||0)/1048576).toFixed(2)+' MB'}/><KV name="累计下行" value={((state.proxyDownloadTotal||0)/1048576).toFixed(2)+' MB'}/>{(state.proxyConnections||[]).slice(0,30).map(c=><div key={c.id} className="connection-row"><span>{c.host}:{c.port}</span><small>{c.network} · ↑{Math.round(c.upload/1024)}KB ↓{Math.round(c.download/1024)}KB</small></div>)}{(!state.proxyConnections||state.proxyConnections.length===0)&&<p className="muted">暂无活跃代理连接。</p>}</section></div></>}
  {page==='settings'&&<><SectionTitle title="设置" sub="原生应用与当前工作环境。"/><section className="panel"><h2>桌面集成</h2><KV name="窗口框架" value="SwiftUI + WKWebView"/><KV name="内部界面" value="React"/><KV name="核心引擎" value="Go · Lima"/><KV name="共享工作区" value="~/AgentVM-Shared"/><div className="inline-actions"><button className="secondary" onClick={()=>bridge('doctor')}>运行环境诊断</button><button className="secondary" onClick={()=>bridge('openShared')}><FolderOpen size={15}/> 打开共享文件夹</button></div></section><section className="panel"><h2>安全原则</h2><p className="muted">所有虚拟机、代理和文件操作都由 Swift 原生桥接校验并交给已有 Go 核心。React 不直接接触宿主机文件和认证凭据。</p></section></>}
  {state.error&&<div className="notice error"><AlertTriangle size={17}/>{state.error}</div>}
  </div></main>
  {modal&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget&&modal.type!=='creating')setModal(null)}}><div className="modal" role="dialog" aria-modal="true">
  {modal.type==='create'&&<><h2>新建虚拟机</h2><p className="muted">默认使用 Agent VM 共享目录，无需额外挂载项目。</p><div className="form-grid"><label className="form-wide">虚拟机名称<input autoFocus value={create.name} onChange={e=>setCreate({...create,name:e.target.value})} placeholder="例如：开发环境"/></label><label>CPU 核数<input type="number" min="1" max="16" value={create.cpus} onChange={e=>setCreate({...create,cpus:Number(e.target.value)})}/></label><label>内存（GB）<input type="number" min="2" max="64" value={create.memory} onChange={e=>setCreate({...create,memory:Number(e.target.value)})}/></label><label>磁盘（GB）<input type="number" min="10" max="1024" value={create.disk} onChange={e=>setCreate({...create,disk:Number(e.target.value)})}/></label><label className="check-row"><input type="checkbox" checked={create.codeServer} onChange={e=>setCreate({...create,codeServer:e.target.checked})}/> 安装 code-server</label></div><div className="dialog-actions"><button className="secondary" onClick={()=>setModal(null)}>取消</button><button className="primary" onClick={submitCreate} disabled={state.busy||!Number.isInteger(create.cpus)||create.cpus<1||create.cpus>16||!Number.isInteger(create.memory)||create.memory<2||create.memory>64||!Number.isInteger(create.disk)||create.disk<10||create.disk>1024}>创建</button></div></>}
  {modal.type==='creating'&&<><h2>正在准备虚拟机</h2><p className="muted">{state.buildComplete?'虚拟机创建完成。':state.error||'创建过程可能包含初始化 Linux 和安装工具。'}</p><div className="dialog-actions"><button className="primary" onClick={()=>setModal(null)}>返回列表</button></div></>}
  {(modal.type==='stop'||modal.type==='delete')&&<><h2>{modal.type==='stop'?'停止虚拟机？':'删除虚拟机？'}</h2><p className="muted">{modal.type==='stop'?'停止会终止其中运行的 Agent 和终端会话，请先保存工作。':'删除将移除 VM 系统盘内的数据；共享目录不会被删除。'}</p><div className="dialog-actions"><button className="secondary" onClick={()=>setModal(null)}>取消</button><button className="danger-button" onClick={confirm}>{modal.type==='stop'?'确认停止':'确认删除'}</button></div></>}
  {(modal.type==='deleteSource'||modal.type==='closeGate')&&<><h2>{modal.type==='closeGate'?'关闭网络门禁？':'删除节点来源？'}</h2><p className="muted">{modal.type==='closeGate'?'将撤销当前托管连接授权。':'将删除节点来源「'+modal.source.name+'」及其节点配置。'}</p><div className="dialog-actions"><button className="secondary" onClick={()=>setModal(null)}>取消</button><button className="danger-button" onClick={confirm}>确认</button></div></>}
  {modal.type==='rename'&&<><h2>修改虚拟机名称</h2><p className="muted">仅更改界面显示名称，不影响实例 ID 与共享目录。</p><label className="dialog-field">显示名称<input autoFocus maxLength="80" value={renameText} placeholder={modal.vm.displayName||modal.vm.name} onChange={e=>setRenameText(e.target.value)}/></label><div className="dialog-actions"><button className="secondary" onClick={()=>setModal(null)}>取消</button><button className="primary" onClick={()=>{bridge('rename',{name:modal.vm.name,label:renameText});setModal(null)}}>保存</button></div></>}
  {modal.type==='mounts'&&<><h2>共享文件夹</h2><p className="muted">虚拟机：{modal.vm.displayName||modal.vm.name}。挂载变更需要重新启动虚拟机才能生效。</p><div className="mount-list"><div className="mount-entry"><span>~/AgentVM-Shared</span><small>所有虚拟机共享 · 读写</small></div>{(state.mounts[modal.vm.name]||[]).map(m=><div className="mount-entry" key={m.path+':'+m.mode}><span title={m.path}>{m.path}</span><small>{m.mode==='rw'?'读写':'只读'}</small><button className="small-button" onClick={()=>setModal({type:'removeMount',vm:modal.vm,mount:m})}>移除</button></div>)}</div><div className="dialog-actions"><button className="secondary" onClick={()=>bridge('mount',{name:modal.vm.name,writable:false})}>添加只读</button><button className="secondary" onClick={()=>bridge('mount',{name:modal.vm.name,writable:true})}>添加读写</button><button className="primary" onClick={()=>setModal(null)}>完成</button></div></>}
  {modal.type==='removeMount'&&<><h2>移除文件夹挂载？</h2><p className="muted">{modal.mount.path} · {modal.mount.mode==='rw'?'读写':'只读'}。不会删除宿主机文件。</p><div className="dialog-actions"><button className="secondary" onClick={()=>setModal({type:'mounts',vm:modal.vm})}>返回</button><button className="danger-button" onClick={()=>{bridge('removeMount',{name:modal.vm.name,path:modal.mount.path,mode:modal.mount.mode});setModal({type:'mounts',vm:modal.vm})}}>移除挂载</button></div></>}
  {modal.type==='manual'&&<><h2>添加代理节点</h2><div className="form-grid"><label>名称<input value={manual.name} onChange={e=>setManual({...manual,name:e.target.value})}/></label><label>协议<select value={manual.type} onChange={e=>setManual({...manual,type:e.target.value})}><option>socks5</option><option>http</option></select></label><label>服务器 IP<input value={manual.server} onChange={e=>setManual({...manual,server:e.target.value})}/></label><label>端口<input type="number" value={manual.port} onChange={e=>setManual({...manual,port:Number(e.target.value)})}/></label><label>用户名<input value={manual.username} onChange={e=>setManual({...manual,username:e.target.value})}/></label><label>密码<input type="password" value={manual.password} onChange={e=>setManual({...manual,password:e.target.value})}/></label></div><div className="dialog-actions"><button className="secondary" onClick={()=>setModal(null)}>取消</button><button className="primary" onClick={()=>{bridge('proxyManual',manual);setManual({...manual,password:''});setModal(null)}} disabled={!manual.name||!manual.server||manual.port<1}>添加</button></div></>}
  </div></div>}
  </div>;
}
createRoot(document.getElementById('root')).render(<App/>);
