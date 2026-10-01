package modulepairing

import (
	"path/filepath"
	"testing"
	"time"
)

func TestBillingCycleBoundary(t *testing.T) {
	zone := time.FixedZone("test", 8*3600)
	for _, c := range []struct{ now, want string }{{"2026-09-09", "2026-08-10"}, {"2026-09-10", "2026-09-10"}, {"2026-01-01", "2025-12-10"}} {
		now, _ := time.ParseInLocation("2006-01-02", c.now, zone)
		if got := cycleStart(now, 10).Format("2006-01-02"); got != c.want {
			t.Fatalf("%s: %s", c.now, got)
		}
	}
}

func TestHistorySnapshotIsIndependent(t *testing.T) {
	m := TrafficMeter{snapshot: TrafficSnapshot{Days: map[string]uint64{"2026-09-27": 42}}}
	if m.Snapshot().Days != nil {
		t.Fatal("regular samples include history")
	}
	history := m.snapshotWithHistory(true)
	history.Days["2026-09-27"] = 99
	if m.snapshotWithHistory(true).Days["2026-09-27"] != 42 {
		t.Fatal("snapshot shares mutable history")
	}
}

func TestSIMAccountsStaySeparate(t *testing.T) {
	m := TrafficMeter{identity: "unknown", snapshot: TrafficSnapshot{TotalRX: 99, Days: map[string]uint64{}}, accounts: map[string]TrafficSnapshot{}}
	m.selectSIM("8986001234567890123")
	first := m.identity
	m.snapshot.TotalRX = 500
	m.snapshot.PlanGB = 20
	m.selectSIM("8986001234567890456")
	if m.snapshot.TotalRX != 0 || m.snapshot.PlanGB != 0 {
		t.Fatal("new SIM inherited old account")
	}
	m.selectSIM("8986001234567890123")
	if m.identity != first || m.snapshot.TotalRX != 500 || m.snapshot.PlanGB != 20 {
		t.Fatal("returning SIM lost account")
	}
	m.selectSIM("")
	if m.snapshot.TotalRX != 99 {
		t.Fatal("legacy unknown usage lost")
	}
}

func TestSIMTransitionKeepsPendingUsageUnknown(t *testing.T) {
	m := TrafficMeter{identity: "unknown", snapshot: TrafficSnapshot{Days: map[string]uint64{}}, accounts: map[string]TrafficSnapshot{}}
	m.selectSIM("8986001234567890123")
	m.pendingRX, m.pendingTX = 100, 20
	m.pendingDays = map[string]uint64{"2026-09-27": 120}
	m.selectSIM("8986001234567890456")
	unknown := m.accounts["unknown"]
	if unknown.TotalRX != 100 || unknown.TotalTX != 20 || m.snapshot.TotalRX != 0 {
		t.Fatal("transition bytes assigned to a SIM")
	}
	day := 1
	_, err := m.Configure(TrafficRequest{Unix: 1790500000, BillingDay: &day, ExpectedSIM: "wrong-card"})
	if err == nil {
		t.Fatal("wrong-card settings accepted")
	}
}

func TestTrafficPlanRecalculatesWithoutResettingTotals(t *testing.T) {
	m := TrafficMeter{Path: filepath.Join(t.TempDir(), "traffic.json"), snapshot: TrafficSnapshot{TotalRX: 900, Days: map[string]uint64{"2026-09-01": 100, "2026-09-12": 200}}}
	now, _ := time.Parse("2006-01-02", "2026-09-20")
	day := 10
	gb := 20.0
	result, err := m.Configure(TrafficRequest{Unix: now.Unix(), BillingDay: &day, PlanGB: &gb})
	if err != nil || result.CycleBytes != 200 || result.TotalRX != 900 || result.PlanGB != 20 {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	day = 1
	result, err = m.Configure(TrafficRequest{Unix: now.Unix(), BillingDay: &day})
	if err != nil || result.CycleBytes != 300 {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}

func TestCellularCountersExcludeParentAndUSB(t *testing.T) {
	sample := "rmnet0: 900 1 0 0 0 0 0 0 400 1 0 0 0 0 0 0\nrmnet_data0: 800 1 0 0 0 0 0 0 400 1 0 0 0 0 0 0\nbridge0: 200 1 0 0 0 0 0 0 900 1 0 0 0 0 0 0"
	c := parseCellularCounters(sample)
	if len(c) != 1 || c["rmnet_data0"] != [2]uint64{800, 400} {
		t.Fatalf("wrong counters: %v", c)
	}
}
