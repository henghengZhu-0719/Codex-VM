package session

import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "bytes"
 "strings"
 "time"
 "github.com/sylvinus/agent-vm/internal/vm"
)

type ToolStatus struct {
 Installed bool `json:"installed"`
 LoginHint string `json:"login_hint"`
}
type Tools struct {
 Tmux bool `json:"tmux"`
 Agents map[string]ToolStatus `json:"agents"`
}

func InspectTools(ctx context.Context,b vm.Backend,name string)(Tools,error){
 ctx,cancel:=context.WithTimeout(ctx,10*time.Second);defer cancel()
 const script=`import json, os, shutil
home=os.path.expanduser('~')
path=home+'/.local/bin:'+home+'/.claude/local/bin:'+os.environ.get('PATH','')
hints={'codex':'.codex/auth.json','claude':'.claude/.credentials.json','agy':'.gemini/antigravity-cli/antigravity-oauth-token'}
agents={}
for name in ('codex','claude','agy','opencode','vibe','pi'):
    hint='unknown'
    if name in hints:
        hint='credential_file_present' if os.path.isfile(os.path.join(home,hints[name])) else 'credential_file_missing'
    agents[name]=dict(installed=bool(shutil.which(name,path=path)),login_hint=hint)
print(json.dumps(dict(tmux=bool(shutil.which('tmux',path=path)),agents=agents)))
`
 var out bytes.Buffer
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Args:[]string{"python3","-"},Stdin:strings.NewReader(script),Stdout:&out,Stderr:io.Discard})
 if err!=nil{return Tools{},err};if code!=0{return Tools{},errors.New("tool inspection failed")}
 var result Tools
 if err=json.Unmarshal(out.Bytes(),&result);err!=nil{return Tools{},err}
 return result,nil
}

// Explicit installation only, through the guest's existing package manager
// and network policy. Never change proxy settings or request a password.
func InstallTmux(ctx context.Context,b vm.Backend,name string)error{
 ctx,cancel:=context.WithTimeout(ctx,4*time.Minute);defer cancel()
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Args:[]string{"sh","-c","command -v tmux >/dev/null || (sudo -n apt-get update && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tmux)","agent-vm"},Stdout:io.Discard,Stderr:io.Discard})
 if err!=nil{return err};if code!=0{return errors.New("tmux installation failed")}
 status,err:=InspectTools(ctx,b,name);if err!=nil{return err};if !status.Tmux{return errors.New("tmux missing after install")};return nil
}
