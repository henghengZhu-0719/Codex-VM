// Package netgate implements revocable network authorization for VM connections.
package netgate

import (
 "context"
 "errors"
 "net"
 "sync"
 "time"
)

var ErrClosed = errors.New("netgate: network closed")
var ErrStale = errors.New("netgate: authorization changed")

type State string
const (
 Closed State = "closed"
 Checking State = "checking"
 Open State = "open"
)

type Gate struct {
 mu sync.Mutex
 state State
 epoch uint64
 expires time.Time
 timer *time.Timer
 connections map[*trackedConn]struct{}
 pending map[uint64]map[uint64]context.CancelFunc
 nextDial uint64
}

func New() *Gate { return &Gate{state: Closed, connections: make(map[*trackedConn]struct{}), pending: make(map[uint64]map[uint64]context.CancelFunc)} }

func (g *Gate) Status() (State, uint64) {
 g.mu.Lock(); defer g.mu.Unlock()
 g.expireLocked()
 return g.state, g.epoch
}

func (g *Gate) BeginCheck() uint64 {
 g.mu.Lock(); defer g.mu.Unlock()
 g.revokeLocked()
 g.state = Checking
 return g.epoch
}

// Authorize must only be invoked after trusted host-side validation.
func (g *Gate) Authorize(checkEpoch uint64, lease time.Duration) error {
 g.mu.Lock(); defer g.mu.Unlock()
 g.expireLocked()
 if g.epoch != checkEpoch || g.state != Checking { return ErrStale }
 if lease <= 0 { return ErrClosed }
 g.openLocked(lease)
 return nil
}

// Caller must hold g.mu. Only a trusted host verifier may grant access.
func (g *Gate) openLocked(lease time.Duration) {
 g.state = Open
 g.expires = time.Now().Add(lease)
 epoch:=g.epoch
 g.timer=time.AfterFunc(lease,func(){
  g.mu.Lock();defer g.mu.Unlock()
  if g.epoch==epoch && g.state==Open && !time.Now().Before(g.expires){g.revokeLocked()}
 })
}

func (g *Gate) Revoke() { g.mu.Lock(); defer g.mu.Unlock(); g.revokeLocked() }

// Dial rechecks authorization after a potentially slow upstream handshake.
// Every accepted connection is tracked and revoked on epoch changes.
func (g *Gate) Dial(ctx context.Context, dial func(context.Context)(net.Conn,error)) (net.Conn,error) {
 g.mu.Lock()
 g.expireLocked()
 if g.state != Open { g.mu.Unlock(); return nil, ErrClosed }
 epoch := g.epoch
 g.nextDial++
 dialID:=g.nextDial
 dialCtx,cancel:=context.WithCancel(ctx)
 if g.pending[epoch]==nil {g.pending[epoch]=make(map[uint64]context.CancelFunc)}
 g.pending[epoch][dialID]=cancel
 g.mu.Unlock()

 // The upstream dialer must honor dialCtx; revocation cancels it even
 // before the TCP connection has been registered as active.
 conn,err:=dial(dialCtx)
 g.mu.Lock()
 delete(g.pending[epoch],dialID)
 if len(g.pending[epoch])==0 {delete(g.pending,epoch)}
 g.expireLocked()
 valid:=g.state==Open && g.epoch==epoch && dialCtx.Err()==nil
 if err!=nil || !valid {
  g.mu.Unlock()
  cancel()
  if conn!=nil {_=conn.Close()}
  if ctx.Err()!=nil {return nil,ctx.Err()}
  if !valid{return nil,ErrStale}
  return nil,err
 }
 if conn==nil {g.mu.Unlock();cancel();return nil,errors.New("netgate: dial returned nil connection")}
 t:=&trackedConn{Conn:conn,gate:g,epoch:epoch}
 g.connections[t]=struct{}{}
 g.mu.Unlock()
 cancel()
 return t,nil
}

func (g *Gate) expireLocked() {
 if g.state == Open && !time.Now().Before(g.expires) { g.revokeLocked() }
}
func (g *Gate) revokeLocked() {
 if g.timer!=nil {g.timer.Stop();g.timer=nil}
 for _,epochPending:=range g.pending {for _,cancel:=range epochPending {cancel()}}
 g.epoch++
 g.state = Closed
 g.expires = time.Time{}
 for c := range g.connections {
  _ = c.Conn.Close()
  delete(g.connections,c)
 }
}

type trackedConn struct {
 net.Conn
 gate *Gate
 epoch uint64
 once sync.Once
}
func (c *trackedConn) Close() error {
 var err error
 c.once.Do(func(){
  c.gate.mu.Lock()
  delete(c.gate.connections,c)
  c.gate.mu.Unlock()
  err=c.Conn.Close()
 })
 return err
}
func (c *trackedConn) valid() bool {
 g:=c.gate; g.mu.Lock(); defer g.mu.Unlock()
 g.expireLocked()
 return g.state==Open && g.epoch==c.epoch
}
func (c *trackedConn) Read(p []byte)(int,error){ if !c.valid(){return 0,ErrStale};return c.Conn.Read(p) }
func (c *trackedConn) Write(p []byte)(int,error){ if !c.valid(){return 0,ErrStale};return c.Conn.Write(p) }
