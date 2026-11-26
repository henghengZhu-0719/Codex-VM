// Package session manages explicitly named, detached guest tmux sessions.
package session

import (
 "bytes"
 "context"
 "errors"
 "fmt"
 "io"
 "regexp"
 "strconv"
 "strings"
 "time"

 "github.com/sylvinus/agent-vm/internal/vm"
)

var validName=regexp.MustCompile("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$")
func ValidName(s string)bool{return validName.MatchString(s)}

type Session struct {
 Name string `json:"name"`
 Attached int `json:"attached"`
 CreatedAt time.Time `json:"created_at"`
}

func ValidAgent(s string)bool{
 switch s{case "shell","codex","claude","opencode","vibe","pi","codex-resume","claude-resume":return true};return false
}

func command(ctx context.Context,b vm.Backend,name,dir string,args ...string)(string,error){
 ctx,cancel:=context.WithTimeout(ctx,12*time.Second);defer cancel()
 var out bytes.Buffer
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Workdir:dir,Args:args,Stdout:&out,Stderr:io.Discard})
 if err!=nil{return "",err}
 if code!=0{return "",fmt.Errorf("guest session command exited %d",code)}
 return out.String(),nil
}

func List(ctx context.Context,b vm.Backend,name string)([]Session,error){
 // An absent tmux server is normal; a missing tmux installation is not.
 raw,err:=command(ctx,b,name,"","sh","-c",`command -v tmux >/dev/null || exit 127
 if [ ! -S "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/agent-vm" ]; then exit 0; fi
 exec tmux -L agent-vm list-sessions -F '#{session_name}|#{session_attached}|#{session_created}'`)
 if err!=nil{return nil,err}
 result:=[]Session{}
 for _,line:=range strings.Split(strings.TrimSpace(raw),"\n"){
  if line==""{continue}
  fields:=strings.Split(line,"|")
  if len(fields)!=3 || !ValidName(fields[0]){return nil,errors.New("invalid session record")}
  n,e:=strconv.Atoi(fields[1]);ts,e2:=strconv.ParseInt(fields[2],10,64)
  if e!=nil || e2!=nil{return nil,errors.New("invalid session metadata")}
  result=append(result,Session{Name:fields[0],Attached:n,CreatedAt:time.Unix(ts,0).UTC()})
 }
 return result,nil
}

func Create(ctx context.Context,b vm.Backend,vmName,dir,name,agent string)error{
 if !ValidName(name)||!ValidAgent(agent){return errors.New("invalid session name or agent")}
 // Fixed commands only. Keep the user's shell open when the agent exits,
 // so its last output remains available for inspection and native resume.
 program:="exec zsh -l"
 if agent!="shell"{program=agent+"; exec zsh -l"}
 tool:=agent
 switch agent{case "codex-resume":tool="codex";program="codex resume; exec zsh -l";case "claude-resume":tool="claude";program="claude --resume; exec zsh -l"}
 _,err:=command(ctx,b,vmName,dir,"sh","-c",`command -v tmux >/dev/null || exit 127
 if [ "$2" != shell ]; then command -v "$2" >/dev/null || exit 127; fi
 exec tmux -L agent-vm new-session -d -s "$1" -c "$PWD" "zsh -l -c '$3'"`,"agent-vm",name,tool,program)
 return err
}

func Stop(ctx context.Context,b vm.Backend,vmName,name string)error{
 if !ValidName(name){return errors.New("invalid session name")}
 _,err:=command(ctx,b,vmName,"","tmux","-L","agent-vm","kill-session","-t","="+name)
 return err
}

func Attach(ctx context.Context,b vm.Backend,vmName,name string,stdin io.Reader,stdout,stderr io.Writer)(int,error){
 if !ValidName(name){return 1,errors.New("invalid session name")}
 return b.Shell(ctx,vmName,vm.ShellOpts{Args:[]string{"tmux","-L","agent-vm","attach-session","-t","="+name},Stdin:stdin,Stdout:stdout,Stderr:stderr,Interactive:true})
}
