package netgate

import (
 "errors"
 "fmt"
 "time"
)

// SafetyPolicyVersion binds authorization to a fixed checklist defined by the
// host. Callers cannot choose which evidence is required.
const SafetyPolicyVersion = "agentvm-safety/1"
const SafetyReportLifetime = 15 * time.Minute

type CheckState string
const (
 Passed CheckState = "passed"
 Failed CheckState = "failed"
 Unknown CheckState = "unknown"
)

type SafetyCheck struct {
 ID string `json:"id"`
 State CheckState `json:"state"`
 Evidence string `json:"evidence"`
 CheckedAt time.Time `json:"checked_at"`
}

type SafetyReport struct {
 Policy string `json:"policy"`
 RunID string `json:"run_id"`
 Configuration string `json:"configuration"`
 CheckEpoch uint64 `json:"check_epoch"`
 CreatedAt time.Time `json:"created_at"`
 Checks []SafetyCheck `json:"checks"`
}

var requiredSafetyChecks = [...]string{
 "proxy_transport", "dns_transport", "egress_policy", "fail_closed",
 "udp_policy", "ipv6_policy", "host_boundary", "exit_consistency",
}

// Validate requires complete, fresh, host-generated evidence for this VM,
// config and check epoch. It never performs the measurements itself.
func (r SafetyReport) Validate(runID, configuration string, epoch uint64, now time.Time) error {
 if r.Policy != SafetyPolicyVersion || runID == "" || configuration == "" ||
  r.RunID != runID || r.Configuration != configuration || r.CheckEpoch != epoch {
  return errors.New("netgate: safety report identity or configuration mismatch")
 }
 if r.CreatedAt.IsZero() || r.CreatedAt.After(now.Add(time.Minute)) ||
  !now.Before(r.CreatedAt.Add(SafetyReportLifetime)) {
  return errors.New("netgate: safety report expired or future-dated")
 }
 seen:=make(map[string]SafetyCheck,len(r.Checks))
 required:=make(map[string]bool,len(requiredSafetyChecks))
 for _,id:=range requiredSafetyChecks {required[id]=true}
 for _,check:=range r.Checks {
  if !required[check.ID] {return fmt.Errorf("netgate: unknown safety check %q",check.ID)}
  if _,exists:=seen[check.ID];exists{return fmt.Errorf("netgate: duplicate safety check %q",check.ID)}
  if check.State!=Passed || check.Evidence=="" || check.CheckedAt.Before(r.CreatedAt) ||
   check.CheckedAt.After(now.Add(time.Minute)) {
   return fmt.Errorf("netgate: failed or invalid safety evidence %q",check.ID)
  }
  seen[check.ID]=check
 }
 for _,id:=range requiredSafetyChecks {
  if _,found:=seen[id];!found{return fmt.Errorf("netgate: missing safety evidence %q",id)}
 }
 return nil
}

// GrantReport is intended for a trusted host-only safety verifier.
// A report from the guest or untrusted frontend must never be passed here.
func (g *Gate) GrantReport(report SafetyReport, runID, configuration string, lease time.Duration) error {
 g.mu.Lock()
 defer g.mu.Unlock()
 g.expireLocked()
 if g.state!=Checking || g.epoch!=report.CheckEpoch{return ErrStale}
 if err:=report.Validate(runID,configuration,g.epoch,time.Now());err!=nil{return err}
 if lease<=0{return ErrClosed}
 if lease>90*time.Second {lease=90*time.Second}
 g.openLocked(lease)
 return nil
}
