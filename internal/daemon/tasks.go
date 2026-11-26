//go:build darwin || linux

package daemon

import (
 "context"
 "crypto/rand"
 "encoding/hex"
 "encoding/json"
 "errors"
 "log/slog"
 "os"
 "path/filepath"
 "sort"
 "sync"
 "time"
)

const maxTasks = 256
const maxPending = 16

var ErrBusy = errors.New("task queue full or service closing")

type Task struct {
 ID string `json:"id"`
 Kind string `json:"kind"`
 Target string `json:"target,omitempty"`
 Status string `json:"status"`
 CreatedAt time.Time `json:"created_at"`
 UpdatedAt time.Time `json:"updated_at"`
 Error string `json:"error,omitempty"`
 VMs []VM `json:"vms,omitempty"`
}

type taskWork struct { id string; timeout time.Duration; run func(context.Context) ([]VM,error) }

type TaskManager struct {
 mu sync.Mutex
 path string
 tasks map[string]Task
 changed chan struct{}
 queue chan taskWork
 ctx context.Context
 cancel context.CancelFunc
 done chan struct{}
 closing bool
}

func NewTaskManager(parent context.Context, path string) (*TaskManager,error) {
 ctx,cancel:=context.WithCancel(parent)
 m:=&TaskManager{path:path,tasks:make(map[string]Task),changed:make(chan struct{}),queue:make(chan taskWork,maxPending),ctx:ctx,cancel:cancel,done:make(chan struct{})}
 if path!="" {
  data,err:=os.ReadFile(path)
  if err==nil {
   if err=json.Unmarshal(data,&m.tasks);err!=nil{cancel();return nil,err}
   if m.tasks==nil{m.tasks=make(map[string]Task)}
   for id,t:=range m.tasks {
    if t.Status=="queued" || t.Status=="running" {t.Status="interrupted";t.Error="service restarted; task was not replayed";t.UpdatedAt=time.Now().UTC();m.tasks[id]=t}
   }
   if err=m.persistLocked();err!=nil{cancel();return nil,err}
  } else if !os.IsNotExist(err){cancel();return nil,err}
 }
 go m.worker()
 return m,nil
}

// Persist before publishing state transitions. All callers hold mu.
func (m *TaskManager) persistLocked() error {
 if m.path==""{return nil}
 data,err:=json.Marshal(m.tasks);if err!=nil{return err}
 f,err:=os.CreateTemp(filepath.Dir(m.path),".tasks-*");if err!=nil{return err}
 defer os.Remove(f.Name())
 _,werr:=f.Write(data)
 err=errors.Join(werr,f.Sync(),f.Close());if err!=nil{return err}
 return os.Rename(f.Name(),m.path)
}

func (m *TaskManager) notifyLocked(){close(m.changed);m.changed=make(chan struct{})}

func (m *TaskManager) Submit(kind string, run func(context.Context)([]VM,error))(Task,error){
 return m.SubmitTarget(kind,"",2*time.Minute,run)
}

func (m *TaskManager) SubmitTarget(kind,target string,timeout time.Duration,run func(context.Context)([]VM,error))(Task,error){
 m.mu.Lock();defer m.mu.Unlock()
 if m.closing || m.ctx.Err()!=nil || len(m.queue)>=cap(m.queue){return Task{},ErrBusy}
 var raw [16]byte
 if _,err:=rand.Read(raw[:]);err!=nil{return Task{},err}
 if target!="" {
  for _,existing:=range m.tasks {if existing.Target==target && (existing.Status=="queued" || existing.Status=="running"){return Task{},ErrBusy}}
 }
 now:=time.Now().UTC()
 t:=Task{ID:hex.EncodeToString(raw[:]),Kind:kind,Target:target,Status:"queued",CreatedAt:now,UpdatedAt:now}
 var evicted *Task
 if len(m.tasks)>=maxTasks {
  for _,v:=range m.tasks {
   if v.Status=="queued" || v.Status=="running"{continue}
   if evicted==nil || v.UpdatedAt.Before(evicted.UpdatedAt){copy:=v;evicted=&copy}
  }
  if evicted==nil{return Task{},ErrBusy}
  delete(m.tasks,evicted.ID)
 }
 m.tasks[t.ID]=t
 if err:=m.persistLocked();err!=nil{delete(m.tasks,t.ID);if evicted!=nil{m.tasks[evicted.ID]=*evicted};return Task{},err}
 m.queue<-taskWork{id:t.ID,timeout:timeout,run:run}
 m.notifyLocked()
 return t,nil
}

func (m *TaskManager) update(id,status,message string,vms []VM) error {
 m.mu.Lock();defer m.mu.Unlock()
 t:=m.tasks[id];t.Status=status;t.Error=message;t.VMs=vms;t.UpdatedAt=time.Now().UTC()
 m.tasks[id]=t
 err:=m.persistLocked()
 if err!=nil {
  // Do not claim success when the durable record could not be written.
  t.Status="interrupted";t.Error="task state could not be persisted";t.VMs=nil;m.tasks[id]=t
 }
 m.notifyLocked()
 return err
}

func (m *TaskManager) worker(){
 defer close(m.done)
 for {
  select {
  case <-m.ctx.Done():return
  case work:=<-m.queue:
   if m.ctx.Err()!=nil{return}
   if m.update(work.id,"running","",nil)!=nil{continue}
   ctx,cancel:=context.WithTimeout(m.ctx,work.timeout)
   result,err:=runTaskSafely(ctx,work.run)
   ctxErr:=ctx.Err()
   cancel()
   switch {
   case m.ctx.Err()!=nil:_=m.update(work.id,"interrupted","service stopped",nil)
   case errors.Is(ctxErr,context.DeadlineExceeded):_=m.update(work.id,"failed","task deadline exceeded",nil)
   case err!=nil:_=m.update(work.id,"failed","operation failed",nil)
   default:_=m.update(work.id,"succeeded","",result)
   }
  }
 }
}

// Keep a failed handler from terminating the whole daemon.
func runTaskSafely(ctx context.Context,run func(context.Context)([]VM,error))(result []VM,err error){
 defer func(){if recover()!=nil{slog.Error("background task panicked");result=nil;err=errors.New("task panicked")}}()
 return run(ctx)
}

func (m *TaskManager) Get(id string)(Task,bool){
 m.mu.Lock();defer m.mu.Unlock();t,ok:=m.tasks[id];return t,ok
}

func (m *TaskManager) Snapshot()([]Task,<-chan struct{}){
 m.mu.Lock();defer m.mu.Unlock()
 tasks:=make([]Task,0,len(m.tasks))
 for _,t:=range m.tasks{tasks=append(tasks,t)}
 sort.Slice(tasks,func(i,j int)bool{return tasks[i].CreatedAt.Before(tasks[j].CreatedAt)})
 return tasks,m.changed
}

func (m *TaskManager) Close(ctx context.Context) error {
 m.mu.Lock();m.closing=true;m.cancel();m.mu.Unlock()
 select{case <-m.done:case <-ctx.Done():return ctx.Err()}
 m.mu.Lock();defer m.mu.Unlock()
 for id,t:=range m.tasks{if t.Status=="queued" || t.Status=="running"{t.Status="interrupted";t.Error="service stopped";t.UpdatedAt=time.Now().UTC();m.tasks[id]=t}}
 err:=m.persistLocked();m.notifyLocked();return err
}
