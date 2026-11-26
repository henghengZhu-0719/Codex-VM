// Package resource observes guest resource usage without changing VM state.
package resource

import (
 "bytes"
 "context"
 "encoding/json"
 "errors"
 "io"
 "strings"
 "time"
 "github.com/sylvinus/agent-vm/internal/vm"
)

type Metrics struct {
 CPUPercent float64 `json:"cpu_percent"`
 MemoryTotalBytes int64 `json:"memory_total_bytes"`
 MemoryAvailableBytes int64 `json:"memory_available_bytes"`
 MemoryUsedBytes int64 `json:"memory_used_bytes"`
 SwapUsedBytes int64 `json:"swap_used_bytes"`
 SwapTotalBytes int64 `json:"swap_total_bytes"`
 ActiveSessions int `json:"active_sessions"`
 ProtectedProcesses int `json:"protected_processes"`
 IdleCandidate bool `json:"idle_candidate"`
 SampledAt time.Time `json:"sampled_at"`
}

// Conservative point-in-time observation, never authorization to stop a VM.
const script = `import json, os, time
def cpu():
    fields = list(map(int, open('/proc/stat').readline().split()[1:9]))
    return sum(fields), fields[3]+fields[4]
a,b=cpu()
time.sleep(0.3)
c,d=cpu()
if c<=a: raise RuntimeError('invalid CPU sample')
mem={}
for line in open('/proc/meminfo'):
    k,v=line.split(':',1)
    mem[k]=int(v.split()[0])*1024
total=mem['MemTotal']
avail=mem['MemAvailable']
if total<=0 or not 0<=avail<=total: raise RuntimeError('invalid memory sample')
active=0
protected=0
names={'codex','claude','agy','opencode','vibe','pi','chromium','chrome','chatgpt','tmux','screen','code-server','electron','node','python','python3'}
for entry in os.scandir('/proc'):
    if not entry.name.isdigit() or int(entry.name)==os.getpid(): continue
    try:
        if entry.stat().st_uid!=os.getuid(): continue
        stat=open(entry.path+'/stat').read().rsplit(')',1)[1].split()
        if int(stat[4])!=0: active+=1
        comm=open(entry.path+'/comm').read().strip().lower()
        if any(comm==n or comm.startswith(n+'-') for n in names): protected+=1
    except FileNotFoundError: continue
    except ProcessLookupError: continue
pct=max(0,min(100,100*(1-(d-b)/(c-a))))
print(json.dumps(dict(cpu_percent=pct,memory_total_bytes=total,memory_available_bytes=avail,memory_used_bytes=total-avail,swap_total_bytes=mem['SwapTotal'],swap_used_bytes=mem['SwapTotal']-mem['SwapFree'],active_sessions=active,protected_processes=protected,idle_candidate=pct<3 and active==0 and protected==0)))
`

func Inspect(ctx context.Context,b vm.Backend,name string)(Metrics,error){
 ctx,cancel:=context.WithTimeout(ctx,8*time.Second);defer cancel()
 var out bytes.Buffer
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Args:[]string{"python3","-"},Stdin:strings.NewReader(script),Stdout:&out,Stderr:io.Discard})
 if err!=nil{return Metrics{},err}
 if code!=0{return Metrics{},errors.New("guest resource sample failed")}
 var m Metrics
 if err=json.Unmarshal(out.Bytes(),&m);err!=nil{return Metrics{},err}
 if m.MemoryTotalBytes<=0 || m.MemoryAvailableBytes<0 || m.MemoryAvailableBytes>m.MemoryTotalBytes{return Metrics{},errors.New("invalid guest metrics")}
 m.SampledAt=time.Now().UTC()
 return m,nil
}
