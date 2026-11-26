//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "os"
 "os/signal"
 "path/filepath"
 "sync"
 "syscall"

 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/quota"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vm"
 "github.com/sylvinus/agent-vm/internal/vmname"
)

// A single app owns the existing read-only backend. Serialize calls until
// its thread-safety and shared Lima configuration have been audited.
type daemonInventory struct { app *app; mu sync.Mutex; quotaMu sync.Mutex; quotas map[string]quota.Snapshot }

func vmDTO(v *vm.Instance) daemon.VM {
 return daemon.VM{Name:v.Name, Status:string(v.Status), CPUs:v.CPUs, Memory:v.Memory, Disk:v.Disk}
}

func (d *daemonInventory) List(ctx context.Context)([]daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 vms,err:=d.app.lookVMs(ctx);if err!=nil{return nil,err}
 out:=make([]daemon.VM,0,len(vms))
 for _,v:=range vms{out=append(out,vmDTO(v))}
 return out,nil
}

func (d *daemonInventory) instance(ctx context.Context,name string)(*vm.Instance,error){
 b,err:=d.app.readOnlyBackend();if err!=nil{return nil,err}
 v,err:=b.Get(ctx,name)
 if errors.Is(err,vm.ErrNotFound){return nil,daemon.ErrNotFound}
 return v,err
}

func (d *daemonInventory) Get(ctx context.Context,name string)(daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 v,err:=d.instance(ctx,name);if err!=nil{return daemon.VM{},err};return vmDTO(v),nil
}

func (d *daemonInventory) Mounts(ctx context.Context,name string)(any,error){
 d.mu.Lock();defer d.mu.Unlock()
 v,err:=d.instance(ctx,name);if err!=nil{return nil,err};return v.Mounts,nil
}

// Change uses the same per-VM lock and startup checks as the legacy CLI.
// Do not change the working directory of this long-lived process.
func (d *daemonInventory) Change(ctx context.Context,name,action string)(daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 if name==vmname.Template || name=="base-building" || vmname.IsScratch(name){return daemon.VM{},errors.New("not a managed project VM")}
 unlock,err:=d.app.lockVM(ctx,name);if err!=nil{return daemon.VM{},err};defer unlock()
 if err=ctx.Err();err!=nil{return daemon.VM{},err}
 inst,err:=d.instance(ctx,name);if err!=nil{return daemon.VM{},err}
 switch action {
 case "start":
  if inst.Status==vm.Running{return vmDTO(inst),nil}
  if inst.Status!=vm.Stopped || inst.ConfigErr!=nil || len(inst.Mounts)==0{return daemon.VM{},errors.New("VM needs manual repair or project selection")}
  // An existing VM's original project must be independently verified.
  project,err:=vmname.AbsDir(inst.Mounts[0].Location)
  if err!=nil || vmname.Name(project)!=name{return daemon.VM{},errors.New("cannot verify original project")}
  if os.Getenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS")=="1" || os.Getenv("AGENT_VM_UNSAFE_WRITABLE_GIT")=="1"{return daemon.VM{},errors.New("unsafe environment overrides are not accepted by daemon start")}
  opts:=newVMOpts()
  opts.ReadOnly=allReadOnly(inst)
  s:=&start{app:d.app,ctx:ctx,opts:opts,dir:project,name:name}
  if err=s.ensureRunningLocked();err!=nil{return daemon.VM{},err}
 case "delete":
  if inst.Status!=vm.Stopped{return daemon.VM{},errors.New("stop VM before deletion")}
  if !d.app.deleteVM(ctx,name){return daemon.VM{},errors.New("VM deletion not verified")}
  d.quotaMu.Lock();delete(d.quotas,name);d.quotaMu.Unlock()
  return daemon.VM{Name:name,Status:"Deleted"},nil
 case "stop":
  if inst.Status==vm.Stopped{return vmDTO(inst),nil}
  if !d.app.stopVM(ctx,name){return daemon.VM{},errors.New("VM stop not verified")}
 default:return daemon.VM{},errors.New("unsupported VM action")
 }
 inst,err=d.instance(ctx,name);if err!=nil{return daemon.VM{},err}
 if (action=="start" && inst.Status!=vm.Running)||(action=="stop" && inst.Status!=vm.Stopped){return daemon.VM{},errors.New("VM did not reach requested state")}
 return vmDTO(inst),nil
}

func (d *daemonInventory) ResolveCreate(input daemon.CreateRequest)(daemon.CreateRequest,string,error){
 if !filepath.IsAbs(input.Project) || input.CPUs<0 || input.CPUs>256 || input.MemoryGiB<0 || input.MemoryGiB>1024 || input.DiskGiB<0 || input.DiskGiB>16384{return input,"",errors.New("invalid project or resource settings")}
 project,err:=vmname.AbsDir(input.Project);if err!=nil{return input,"",err}
 info,err:=os.Stat(project);if err!=nil || !info.IsDir(){return input,"",errors.New("project directory unavailable")}
 input.Project=project
 name:=vmname.Name(project)
 if name==vmname.Template || name=="base-building" || vmname.IsScratch(name){return input,"",errors.New("reserved VM name")}
 return input,name,nil
}

func (d *daemonInventory) Create(ctx context.Context,input daemon.CreateRequest,name string)(daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 input,resolved,err:=d.ResolveCreate(input);if err!=nil || resolved!=name{return daemon.VM{},errors.New("project changed before execution")}
 unlock,err:=d.app.lockVM(ctx,name);if err!=nil{return daemon.VM{},err};defer unlock()
 if err=ctx.Err();err!=nil{return daemon.VM{},err}
 if _,err=d.instance(ctx,name);!errors.Is(err,daemon.ErrNotFound){return daemon.VM{},errors.New("VM already exists or cannot be inspected")}
 if os.Getenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS")=="1" || os.Getenv("AGENT_VM_UNSAFE_WRITABLE_GIT")=="1"{return daemon.VM{},errors.New("unsafe environment overrides are not accepted")}
 opts:=newVMOpts();opts.CPUs=input.CPUs;opts.Memory=input.MemoryGiB;opts.Disk=input.DiskGiB;opts.ReadOnly=input.ReadOnly
 s:=&start{app:d.app,ctx:ctx,opts:opts,dir:input.Project,name:name}
 if err=s.ensureRunningLocked();err!=nil{return daemon.VM{},err}
 inst,err:=d.instance(ctx,name);if err!=nil{return daemon.VM{},err}
 if inst.Status!=vm.Running{return daemon.VM{},errors.New("VM not running after creation")}
 return vmDTO(inst),nil
}

func daemonCommand(args []string, streams IO) int {
 if len(args)>0 && args[0]=="quota"{return daemonQuotaCommand(args,streams)}
 if len(args)>0 && args[0]=="session"{return daemonSessionCommand(args,streams)}
 if len(args)>0 && args[0]=="usage"{return daemonUsageCommand(args,streams)}
 if len(args)>0 && args[0]=="browser"{return daemonBrowserCommand(args,streams)}
 if len(args)>0 && (args[0]=="volume" || args[0]=="proxy"){return daemonManagerCommand(args,streams)}
 if len(args)>=1 && (args[0]=="vm-create" || args[0]=="vm-delete"){
  st,err:=state.Default();if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
  var result any
  switch args[0]{
  case "vm-create":
   if len(args)<2{fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon vm-create PROJECT [--cpus N --memory N --disk N --readonly]");return 2}
   project,err:=filepath.Abs(args[1]);if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
   opts:=newVMOpts()
   _,rest,err:=opts.takeAll(args[2:])
   if err!=nil || len(rest)!=0 || opts.Reset || opts.Scratch || opts.RM || opts.UnsafeNoPrompts || opts.UnsafeWritableGit || opts.SSHPort!=-1{fmt.Fprintln(streams.Stderr,"Unsupported create options");return 2}
   err=c.CreateVM(context.Background(),daemon.CreateRequest{Project:project,CPUs:opts.CPUs,MemoryGiB:opts.Memory,DiskGiB:opts.Disk,ReadOnly:opts.ReadOnly},&result)
   if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  case "vm-delete":
   if len(args)!=3 || args[2]!="--confirm"{fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon vm-delete NAME --confirm (stopped VMs only)");return 2}
   if err=c.DeleteVM(context.Background(),args[1],&result);err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  }
  if err=json.NewEncoder(streams.Stdout).Encode(result);err!=nil{return 1};return 0
 }

 if len(args)==2 && (args[0]=="vm-start" || args[0]=="vm-stop"){
  st,err:=state.Default();if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
  var result any
  if err=c.ChangeVM(context.Background(),args[1],args[0][3:],&result);err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  if err=json.NewEncoder(streams.Stdout).Encode(result);err!=nil{return 1};return 0
 }

 if len(args)!=1 {fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon <serve|status|list|tasks|refresh|vm-start NAME|vm-stop NAME|vm-create PROJECT|vm-delete NAME --confirm|install|uninstall|start|stop|restart|logs>");return 2}
 st,err:=state.Default()
 if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 switch args[0]{
 case "install","uninstall","start","stop","restart","logs":
  if err := daemonService(args[0], string(st), streams); err != nil { fmt.Fprintln(streams.Stderr,err); return 1 }; return 0
 case "serve":
  a,err:=newApp(IO{Stdin:nil,Stdout:io.Discard,Stderr:streams.Stderr})
  if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  // Never trigger an implicit legacy VM migration from an API request.
  a.migrate=nil
  // API operations must never wait for a controlling-terminal prompt.
  a.ui.StderrIsTerminal=false
  ctx,cancel:=signal.NotifyContext(context.Background(),os.Interrupt,syscall.SIGTERM);defer cancel()
  if err=daemon.Serve(ctx,string(st),&daemonInventory{app:a});err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  return 0
 case "status","list","tasks","refresh":
  c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
  path:="/health";if args[0]=="list"{path="/api/v1/vms"}
  if args[0]=="tasks"{path="/api/v1/tasks"}
  var result any
  var requestErr error
  if args[0]=="refresh"{requestErr=c.SubmitInventory(context.Background(),&result)}else{requestErr=c.Get(context.Background(),path,&result)}
  if requestErr!=nil{fmt.Fprintln(streams.Stderr,requestErr);return 1}
  enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
  if err:=enc.Encode(result);err!=nil{return 1};return 0
 default:
  fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon <serve|status|list|tasks|refresh|vm-start NAME|vm-stop NAME|vm-create PROJECT|vm-delete NAME --confirm|install|uninstall|start|stop|restart|logs>");return 2
 }
}
