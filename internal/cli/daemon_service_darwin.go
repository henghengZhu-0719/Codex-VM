//go:build darwin

package cli

import (
 "bytes"
 "context"
 "crypto/sha256"
 "encoding/xml"
 "errors"
 "fmt"
 "io"
 "os"
 "os/exec"
 "path/filepath"
 "strconv"
 "time"

 "github.com/sylvinus/agent-vm/internal/daemon"
)

func daemonService(command, state string, streams IO) error {
 home, err := os.UserHomeDir()
 if err != nil { return err }
 // Separate launchd identities for separate state directories.
 digest := sha256.Sum256([]byte(state))
 label := fmt.Sprintf("org.agentvm.daemon.%x", digest[:8])
 domain := "gui/" + strconv.Itoa(os.Getuid())
 target := domain + "/" + label
 agents := filepath.Join(home, "Library", "LaunchAgents")
 plist := filepath.Join(agents, label+".plist")
 logs := filepath.Join(state, "daemon-logs")
 run := func(args ...string) error {
  ctx,cancel := context.WithTimeout(context.Background(),20*time.Second)
  defer cancel()
  cmd := exec.CommandContext(ctx,"/bin/launchctl",args...)
  cmd.Stdout,cmd.Stderr=streams.Stdout,streams.Stderr
  return cmd.Run()
 }
 loaded := func() bool {
  ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel()
  return exec.CommandContext(ctx,"/bin/launchctl","print",target).Run()==nil
 }
 healthy := func() bool {
  c:=daemon.NewClient(daemon.SocketPath(state));defer c.Close()
  ctx,cancel:=context.WithTimeout(context.Background(),time.Second);defer cancel()
  var result struct {Status string `json:"status"`}
  return c.Get(ctx,"/health",&result)==nil && result.Status=="ok"
 }
 wait := func(want bool) error {
  for i:=0;i<40;i++ {
   if healthy()==want{return nil}
   time.Sleep(250*time.Millisecond)
  }
  return errors.New("daemon health did not reach expected state; inspect daemon logs")
 }
 switch command {
 case "install":
  if loaded() || healthy() {return errors.New("stop the existing daemon before installing")}
  if _,err:=os.Lstat(plist);err==nil{return errors.New("LaunchAgent already installed; uninstall first")}else if !os.IsNotExist(err){return err}
  exe,err:=os.Executable();if err!=nil{return err}
  exe,err=filepath.EvalSymlinks(exe);if err!=nil{return err}
  // The installed executable must remain available; do not copy or replace
  // an existing installation behind the user's back.
  if err=os.MkdirAll(agents,0700);err!=nil{return err}
  if err=os.MkdirAll(logs,0700);err!=nil{return err}
  info,err:=os.Lstat(logs);if err!=nil{return err}
  if !info.IsDir() || info.Mode().Perm()!=0700{return errors.New("daemon log directory must be private")}
  for _,name:=range []string{"stdout.log","stderr.log"}{
   p:=filepath.Join(logs,name)
   f,err:=os.OpenFile(p,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
   if err==nil{if err=f.Close();err!=nil{return err}}else if !os.IsExist(err){return err}else{
    info,err:=os.Lstat(p);if err!=nil{return err}
    if !info.Mode().IsRegular() || info.Mode().Perm()!=0600{return errors.New("unsafe existing daemon log file")}
   }
  }
  data,err:=launchAgentPlist(label,exe,state,logs,os.Getenv("AGENT_VM_LIMA_HOME"))
  if err!=nil{return err}
  f,err:=os.OpenFile(plist,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600);if err!=nil{return err}
  _,werr:=f.Write(data)
  if err=errors.Join(werr,f.Close());err!=nil{_ = os.Remove(plist);return err}
  if err=run("enable",target);err!=nil{return err}
  if err=run("bootstrap",domain,plist);err!=nil{return err}
  return wait(true)
 case "start":
  if loaded(){return wait(true)}
  if healthy(){return errors.New("foreground daemon is running; stop it first")}
  info,err:=os.Lstat(plist);if err!=nil{return err}
  if !info.Mode().IsRegular(){return errors.New("invalid LaunchAgent file")}
  if err=run("enable",target);err!=nil{return err}
  if err=run("bootstrap",domain,plist);err!=nil{return err}
  return wait(true)
 case "stop","uninstall":
  // Disable before bootout so intentional stops remain stopped across login.
  if _,err:=os.Lstat(plist);err!=nil{return err}
  if err=run("disable",target);err!=nil{return err}
  if loaded(){if err=run("bootout",target);err!=nil{return err}}
  if err=wait(false);err!=nil{return err}
  if command=="uninstall"{return os.Remove(plist)}
  return nil
 case "restart":
  if _,err:=os.Lstat(plist);err!=nil{return err}
  if !loaded(){return daemonService("start",state,streams)}
  if err=run("kickstart","-k",target);err!=nil{return err}
  return wait(true)
 case "logs":
  // Bound the displayed history; no indefinite follow or credential dump.
  for _,name:=range []string{"stdout.log","stderr.log"}{
   f,err:=os.Open(filepath.Join(logs,name));if err!=nil{return err}
   info,err:=f.Stat();if err!=nil{f.Close();return err}
   offset:=max(int64(0),info.Size()-65536)
   if _,err=f.Seek(offset,io.SeekStart);err!=nil{f.Close();return err}
   fmt.Fprintln(streams.Stdout,"---",name,"---")
   _,err=io.CopyN(streams.Stdout,f,info.Size()-offset);f.Close()
   if err!=nil && !errors.Is(err,io.EOF){return err}
  }
  return nil
 }
 return fmt.Errorf("unknown daemon service command: %s",command)
}

func launchAgentPlist(label, exe, state, logs, limaHome string) ([]byte,error) {
 var buf bytes.Buffer
 escape:=func(v string) error {return xml.EscapeText(&buf,[]byte(v))}
 str:=func(v string) error {buf.WriteString("<string>");if err:=escape(v);err!=nil{return err};buf.WriteString("</string>");return nil}
 kv:=func(k,v string) error {buf.WriteString("<key>"+k+"</key>");return str(v)}
 buf.WriteString(xml.Header+"<plist version=\"1.0\"><dict>")
 if err:=kv("Label",label);err!=nil{return nil,err}
 buf.WriteString("<key>ProgramArguments</key><array>")
 for _,v:=range []string{exe,"daemon","serve"}{if err:=str(v);err!=nil{return nil,err}}
 buf.WriteString("</array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer><key>EnvironmentVariables</key><dict>")
 if err:=kv("AGENT_VM_STATE_DIR",state);err!=nil{return nil,err}
 if limaHome!=""{if !filepath.IsAbs(limaHome){return nil,errors.New("AGENT_VM_LIMA_HOME must be absolute for launchd")};if err:=kv("AGENT_VM_LIMA_HOME",limaHome);err!=nil{return nil,err}}
 buf.WriteString("</dict>")
 if err:=kv("StandardOutPath",filepath.Join(logs,"stdout.log"));err!=nil{return nil,err}
 if err:=kv("StandardErrorPath",filepath.Join(logs,"stderr.log"));err!=nil{return nil,err}
 if err:=kv("WorkingDirectory",state);err!=nil{return nil,err}
 buf.WriteString("</dict></plist>\n")
 return buf.Bytes(),nil
}
