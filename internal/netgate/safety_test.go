package netgate

import (
 "testing"
 "time"
)

func goodReport(epoch uint64, now time.Time) SafetyReport {
 r:=SafetyReport{
  Policy:SafetyPolicyVersion,RunID:"vm-run-1",Configuration:"config-hash-1",
  CheckEpoch:epoch,CreatedAt:now.Add(-time.Second),
 }
 for _,id:=range requiredSafetyChecks {
  r.Checks=append(r.Checks,SafetyCheck{ID:id,State:Passed,Evidence:"measured by trusted host",CheckedAt:now})
 }
 return r
}

func TestSafetyReportGrantsOnlyMatchingEpoch(t *testing.T) {
 g:=New();epoch:=g.BeginCheck();report:=goodReport(epoch,time.Now())
 if err:=g.GrantReport(report,"vm-run-1","config-hash-1",90*time.Second);err!=nil{t.Fatal(err)}
 if state,_:=g.Status();state!=Open{t.Fatal(state)}
 g.Revoke()
 if err:=g.GrantReport(report,"vm-run-1","config-hash-1",90*time.Second);err==nil{t.Fatal("replayed report was accepted")}
}

func TestSafetyReportRejectsMissingDuplicateFailedAndStale(t *testing.T) {
 now:=time.Now()
 base:=goodReport(1,now)
 cases:=map[string]func(*SafetyReport){
  "missing":func(r *SafetyReport){r.Checks=r.Checks[:len(r.Checks)-1]},
  "duplicate":func(r *SafetyReport){r.Checks=append(r.Checks,r.Checks[0])},
  "failed":func(r *SafetyReport){r.Checks[0].State=Failed},
  "unknown":func(r *SafetyReport){r.Checks[0].ID="not-a-real-check"},
  "empty-evidence":func(r *SafetyReport){r.Checks[0].Evidence=""},
  "stale":func(r *SafetyReport){r.CreatedAt=now.Add(-SafetyReportLifetime-time.Second)},
  "wrong-config":func(r *SafetyReport){r.Configuration="other"},
 }
 for name,mutate:=range cases{
  t.Run(name,func(t *testing.T){
   r:=base
   r.Checks=append([]SafetyCheck(nil),base.Checks...)
   mutate(&r)
   if err:=r.Validate("vm-run-1","config-hash-1",1,now);err==nil{t.Fatal("invalid report accepted")}
  })
 }
}
