package modulepairing

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

type TrafficSnapshot struct {
	UnknownBytes uint64            `json:"unknown_bytes"`
	SIMID        string            `json:"sim_id"`
	SIMLabel     string            `json:"sim_label"`
	Available    bool              `json:"available"`
	Interface    string            `json:"interface"`
	DownloadRate float64           `json:"download_rate"`
	UploadRate   float64           `json:"upload_rate"`
	BootRX       uint64            `json:"boot_rx"`
	BootTX       uint64            `json:"boot_tx"`
	TotalRX      uint64            `json:"total_rx"`
	TotalTX      uint64            `json:"total_tx"`
	PlanGB       float64           `json:"plan_gb"`
	BillingDay   int               `json:"billing_day"`
	CycleStart   string            `json:"cycle_start"`
	CycleBytes   uint64            `json:"cycle_bytes"`
	TimeReady    bool              `json:"time_ready"`
	Days         map[string]uint64 `json:"days,omitempty"`
	Unassigned   uint64            `json:"unassigned"`
}

type TrafficRequest struct {
	ExpectedSIM   string   `json:"expected_sim,omitempty"`
	History       bool     `json:"history,omitempty"`
	Unix          int64    `json:"unix"`
	OffsetMinutes int      `json:"offset_minutes"`
	PlanGB        *float64 `json:"plan_gb,omitempty"`
	BillingDay    *int     `json:"billing_day,omitempty"`
}

// TrafficMeter counts only logical cellular interfaces, never their parent or
// USB bridge. Rates use Go's monotonic clock; totals survive daemon restarts.
type TrafficMeter struct {
	mu                sync.Mutex
	Path              string
	snapshot          TrafficSnapshot
	previous          map[string][2]uint64
	sampled           time.Time
	saved             time.Time
	clock             time.Time
	clockAt           time.Time
	Monitor           string
	accounts          map[string]TrafficSnapshot
	identity          string
	transition        bool
	pendingRX         uint64
	pendingTX         uint64
	pendingDays       map[string]uint64
	pendingUnassigned uint64
}

type trafficDisk struct {
	TrafficSnapshot
	Accounts map[string]TrafficSnapshot `json:"accounts,omitempty"`
}

func simKey(value string) (string, string) {
	value = strings.TrimSpace(value)
	if len(value) < 19 || len(value) > 20 || !strings.HasPrefix(value, "89") {
		return "unknown", "未识别 SIM"
	}
	for _, c := range value {
		if c < '0' || c > '9' {
			return "unknown", "未识别 SIM"
		}
	}
	sum := sha256.Sum256([]byte(value))
	return fmt.Sprintf("%x", sum[:16]), "SIM · " + value[len(value)-4:]
}

func (m *TrafficMeter) selectSIM(value string) {
	key, label := simKey(value)
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.accounts == nil {
		m.accounts = make(map[string]TrafficSnapshot)
	}
	if m.identity == key {
		m.settlePending(&m.snapshot)
		if !m.clockAt.IsZero() {
			m.updateCycle(m.clock.Add(time.Since(m.clockAt)))
		}
		return
	}
	unknown := m.accounts["unknown"]
	if m.identity == "unknown" {
		unknown = m.snapshot
	}
	m.settlePending(&unknown)
	m.accounts["unknown"] = unknown
	if m.identity == "unknown" {
		m.snapshot = unknown
	}
	old := m.snapshot
	m.accounts[m.identity] = old
	next, exists := m.accounts[key]
	if !exists {
		next = TrafficSnapshot{BillingDay: 1, Days: make(map[string]uint64)}
	}
	next.SIMLabel = label
	if next.Days == nil {
		next.Days = make(map[string]uint64)
	}
	next.SIMID = key
	next.Available, next.Interface, next.TimeReady = old.Available, old.Interface, old.TimeReady
	next.BootRX, next.BootTX = old.BootRX, old.BootTX
	m.snapshot, m.identity = next, key
	// The observation interval spanning an identity change has no reliable owner.
	m.transition = true
	if !m.clockAt.IsZero() {
		m.updateCycle(m.clock.Add(time.Since(m.clockAt)))
	}
}

func (m *TrafficMeter) settlePending(target *TrafficSnapshot) {
	target.TotalRX += m.pendingRX
	target.TotalTX += m.pendingTX
	if target.Days == nil {
		target.Days = make(map[string]uint64)
	}
	if target.SIMID == "unknown" || target.SIMID == "" {
		target.Unassigned += m.pendingRX + m.pendingTX
	} else {
		target.Unassigned += m.pendingUnassigned
		for day, value := range m.pendingDays {
			target.Days[day] += value
		}
	}
	m.pendingRX, m.pendingTX, m.pendingUnassigned = 0, 0, 0
	m.pendingDays = make(map[string]uint64)
}

func (m *TrafficMeter) watchSIM(ctx context.Context) {
	for {
		query, cancel := context.WithTimeout(ctx, 8*time.Second)
		data, err := exec.CommandContext(query, m.Monitor, "--sim").Output()
		cancel()
		if err != nil {
			m.selectSIM("")
			// A crashing vendor query must not be restarted every five seconds.
			// Keep accounting conservative until the runtime is restarted.
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) && exitErr.ExitCode() < 0 {
				return
			}
		} else {
			m.selectSIM(string(data))
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func cycleStart(now time.Time, day int) time.Time {
	if day < 1 || day > 28 {
		day = 1
	}
	start := time.Date(now.Year(), now.Month(), day, 0, 0, 0, 0, now.Location())
	if now.Before(start) {
		start = start.AddDate(0, -1, 0)
	}
	return start
}

func (m *TrafficMeter) Configure(request TrafficRequest) (TrafficSnapshot, error) {
	if request.Unix < 1577836800 || request.Unix > 4102444800 || request.OffsetMinutes < -840 || request.OffsetMinutes > 840 {
		return TrafficSnapshot{}, ErrInvalid
	}
	if request.PlanGB != nil && (*request.PlanGB < 0 || *request.PlanGB > 100000) {
		return TrafficSnapshot{}, ErrInvalid
	}
	if request.BillingDay != nil && (*request.BillingDay < 1 || *request.BillingDay > 28) {
		return TrafficSnapshot{}, ErrInvalid
	}
	m.mu.Lock()
	if (request.PlanGB != nil || request.BillingDay != nil) && request.ExpectedSIM != "" && request.ExpectedSIM != m.identity {
		m.mu.Unlock()
		return TrafficSnapshot{}, ErrInvalid
	}
	m.clockAt = time.Now()
	m.clock = time.Unix(request.Unix, 0).In(time.FixedZone("billing", request.OffsetMinutes*60))
	m.snapshot.TimeReady = true
	if request.PlanGB != nil {
		m.snapshot.PlanGB = *request.PlanGB
	}
	if request.BillingDay != nil {
		m.snapshot.BillingDay = *request.BillingDay
	}
	if m.snapshot.Days == nil {
		m.snapshot.Days = make(map[string]uint64)
	}
	m.updateCycle(m.clock)
	m.mu.Unlock()
	if request.PlanGB != nil || request.BillingDay != nil {
		m.save()
	}
	return m.snapshotWithHistory(request.History), nil
}

func (m *TrafficMeter) updateCycle(now time.Time) {
	start := cycleStart(now, m.snapshot.BillingDay).Format("2006-01-02")
	m.snapshot.CycleStart = start
	m.snapshot.CycleBytes = 0
	for day, value := range m.snapshot.Days {
		if day >= start && day <= now.Format("2006-01-02") {
			m.snapshot.CycleBytes += value
		}
	}
}

func (m *TrafficMeter) Snapshot() TrafficSnapshot {
	return m.snapshotWithHistory(false)
}

func (m *TrafficMeter) snapshotWithHistory(history bool) TrafficSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	snapshot := m.snapshot
	unknown := m.accounts["unknown"]
	snapshot.UnknownBytes = unknown.TotalRX + unknown.TotalTX
	if m.identity == "unknown" {
		snapshot.UnknownBytes = snapshot.TotalRX + snapshot.TotalTX
	}
	snapshot.Days = nil
	if history {
		snapshot.Days = make(map[string]uint64, len(m.snapshot.Days))
		for day, value := range m.snapshot.Days {
			snapshot.Days[day] = value
		}
	}
	return snapshot
}

func (m *TrafficMeter) Run(ctx context.Context) {
	m.mu.Lock()
	if data, err := os.ReadFile(m.Path); err == nil {
		var disk trafficDisk
		if json.Unmarshal(data, &disk) == nil {
			m.snapshot = disk.TrafficSnapshot
			m.accounts = disk.Accounts
		}
	}
	if m.accounts == nil {
		m.accounts = map[string]TrafficSnapshot{"unknown": m.snapshot}
	}
	m.identity = "unknown"
	m.snapshot = m.accounts["unknown"]
	m.snapshot.SIMLabel = "未识别 SIM"
	m.snapshot.SIMID = "unknown"
	m.snapshot.Available = false
	m.snapshot.TimeReady = false
	if m.snapshot.BillingDay == 0 {
		m.snapshot.BillingDay = 1
	}
	if m.snapshot.Days == nil {
		m.snapshot.Days = make(map[string]uint64)
	}
	m.previous = make(map[string][2]uint64)
	m.mu.Unlock()
	identityDone := make(chan struct{})
	identityCtx, cancelIdentity := context.WithCancel(ctx)
	if m.Monitor != "" {
		go func() { defer close(identityDone); m.watchSIM(identityCtx) }()
	} else {
		close(identityDone)
	}
	defer func() { cancelIdentity(); <-identityDone; m.save() }()
	m.sample(time.Now())
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			m.sample(now)
		}
	}
}

func parseCellularCounters(data string) map[string][2]uint64 {
	counters := make(map[string][2]uint64)
	for _, line := range strings.Split(data, "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		name := strings.TrimSpace(parts[0])
		if !strings.HasPrefix(name, "rmnet_data") {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) < 16 {
			continue
		}
		rx, e1 := strconv.ParseUint(fields[0], 10, 64)
		tx, e2 := strconv.ParseUint(fields[8], 10, 64)
		if e1 == nil && e2 == nil {
			counters[name] = [2]uint64{rx, tx}
		}
	}
	return counters
}

func (m *TrafficMeter) sample(now time.Time) {
	data, err := os.ReadFile("/proc/net/dev")
	m.mu.Lock()
	current := parseCellularCounters(string(data))
	m.snapshot.Available = err == nil && len(current) > 0
	var rx, tx, bootRX, bootTX uint64
	for name, c := range current {
		bootRX += c[0]
		bootTX += c[1]
		if p, ok := m.previous[name]; ok {
			if c[0] >= p[0] {
				rx += c[0] - p[0]
			}
			if c[1] >= p[1] {
				tx += c[1] - p[1]
			}
		}
	}
	m.snapshot.Interface = "rmnet_data"
	m.snapshot.BootRX, m.snapshot.BootTX = bootRX, bootTX
	if m.transition && m.identity != "unknown" {
		unknown := m.accounts["unknown"]
		unknown.TotalRX += rx
		unknown.TotalTX += tx
		unknown.Unassigned += rx + tx
		m.accounts["unknown"] = unknown
		rx, tx = 0, 0
		m.transition = false
	}
	m.transition = false
	m.snapshot.TotalRX += rx
	m.snapshot.TotalTX += tx
	if m.Monitor != "" {
		m.snapshot.TotalRX -= rx
		m.snapshot.TotalTX -= tx
		m.pendingRX += rx
		m.pendingTX += tx
		if m.pendingDays == nil {
			m.pendingDays = make(map[string]uint64)
		}
		if m.clockAt.IsZero() {
			m.pendingUnassigned += rx + tx
		} else {
			m.pendingDays[m.clock.Add(time.Since(m.clockAt)).Format("2006-01-02")] += rx + tx
		}
	}
	if m.clockAt.IsZero() {
		if m.Monitor == "" {
			m.snapshot.Unassigned += rx + tx
		}
	} else {
		date := m.clock.Add(time.Since(m.clockAt))
		if m.Monitor == "" {
			m.snapshot.Days[date.Format("2006-01-02")] += rx + tx
		}
		m.updateCycle(date)
		cutoff := date.AddDate(-1, 0, 0).Format("2006-01-02")
		for day := range m.snapshot.Days {
			if day < cutoff {
				delete(m.snapshot.Days, day)
			}
		}
	}
	m.snapshot.DownloadRate, m.snapshot.UploadRate = 0, 0
	if elapsed := now.Sub(m.sampled).Seconds(); !m.sampled.IsZero() && elapsed > 0 {
		m.snapshot.DownloadRate = float64(rx) / elapsed
		m.snapshot.UploadRate = float64(tx) / elapsed
	}
	m.previous, m.sampled = current, now
	shouldSave := m.saved.IsZero() || now.Sub(m.saved) >= time.Minute
	m.mu.Unlock()
	if shouldSave {
		m.save()
	}
}

func (m *TrafficMeter) save() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.accounts == nil {
		m.accounts = make(map[string]TrafficSnapshot)
	}
	m.accounts[m.identity] = m.snapshot
	accounts := make(map[string]TrafficSnapshot, len(m.accounts))
	for key, value := range m.accounts {
		accounts[key] = value
	}
	unknown := accounts["unknown"]
	unknown.TotalRX += m.pendingRX
	unknown.TotalTX += m.pendingTX
	unknown.Unassigned += m.pendingRX + m.pendingTX
	accounts["unknown"] = unknown
	data, err := json.Marshal(trafficDisk{TrafficSnapshot: m.snapshot, Accounts: accounts})
	if err == nil && writePrivateAtomic(m.Path, data) == nil {
		m.saved = time.Now()
	}
}
