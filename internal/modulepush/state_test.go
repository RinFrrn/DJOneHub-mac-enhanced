package modulepush

import (
	"bytes"
	"encoding/json"
	"slices"
	"testing"
	"time"
)

func TestCallLifecycleAndExpiry(t *testing.T) {
	now := time.Now()
	s := NewState()
	apply := func(ids ...int) {
		t.Helper()
		if _, err := s.Apply(Snapshot{Kind: "calls", Calls: ids}, EventOptions{Transports: []string{"bark", "webpush"}}, now); err != nil {
			t.Fatal(err)
		}
	}
	apply(1)
	if len(s.Queue) != 2 {
		t.Fatal(s.Queue)
	}
	first := s.Queue[0].ID
	apply(1)
	if len(s.Queue) != 2 {
		t.Fatal("duplicate ringing notification")
	}
	s.Finish(first, "bark", true, now)
	if !s.Queue[0].Next.After(now) {
		t.Fatal("missing retry backoff")
	}
	apply()
	if len(s.Queue) != 0 {
		t.Fatal("ended call still queued")
	}
	if s.Finish(first, "bark", true, now) {
		t.Fatal("late completion resurrected ended call")
	}
	apply(1)
	if s.Queue[0].ID == first {
		t.Fatal("reused modem call ID needs a new event ID")
	}
	s.Expire(now.Add(26 * time.Second))
	if len(s.Queue) != 0 {
		t.Fatal("stale call retained")
	}
	apply(1)
	if len(s.Queue) != 0 {
		t.Fatal("expiry must not re-arm the same call")
	}
}

func TestSMSBaselineRestartAndStorageDedup(t *testing.T) {
	now := time.Now()
	s := NewState()
	apply := func(storage int, pdus ...string) {
		t.Helper()
		if _, err := s.Apply(Snapshot{Kind: "sms", Storage: storage, PDUs: pdus}, EventOptions{Transports: []string{"bark"}}, now); err != nil {
			t.Fatal(err)
		}
	}
	apply(0, "000001")
	apply(1)
	if len(s.Queue) != 0 {
		t.Fatal("initial historical SMS must be silent")
	}
	apply(0, "000001", "000002")
	if len(s.Queue) != 1 {
		t.Fatal("new SMS not queued")
	}
	data, _ := json.Marshal(s)
	if slices.Contains(data, byte('\x00')) {
		t.Fatal("invalid state encoding")
	}
	restored := NewState()
	if err := json.Unmarshal(data, restored); err != nil {
		t.Fatal(err)
	}
	s = restored
	apply(0, "000001", "000002")
	apply(1, "000002")
	if len(s.Queue) != 1 {
		t.Fatal("restart/storage duplicate")
	}
	s.Finish(s.Queue[0].ID, "bark", false, now)
	apply(0, "000001", "000002", "000103") // SMS-SUBMIT must be ignored.
	if len(s.Queue) != 0 {
		t.Fatal("outgoing SMS generated a notification")
	}
	apply(0, "000001", "000004") // Replacement at the same storage slot.
	if len(s.Queue) != 1 {
		t.Fatal("new PDU at reused slot was missed")
	}
}

func TestMalformedSnapshotIsAtomic(t *testing.T) {
	s := NewState()
	_, _ = s.Apply(Snapshot{Kind: "sms", PDUs: []string{"000001"}}, EventOptions{}, time.Now())
	before, _ := json.Marshal(s)
	for _, event := range []Snapshot{
		{Kind: "sms", Storage: 2}, {Kind: "sms", PDUs: []string{"000002", "zz"}},
		{Kind: "sms", PDUs: []string{"ff00"}}, {Kind: "calls", Calls: []int{0}},
		{Kind: "calls", Calls: []int{1, 1}}, {Kind: "other"},
	} {
		if _, err := s.Apply(event, EventOptions{Transports: []string{"bark"}}, time.Now()); err == nil {
			t.Fatal("accepted malformed snapshot", event)
		}
		after, _ := json.Marshal(s)
		if string(before) != string(after) {
			t.Fatal("partial snapshot mutated state")
		}
	}
}

func TestRetryBudgetAndQueueBound(t *testing.T) {
	s := NewState()
	now := time.Now()
	s.enqueue("sms", "message", []string{"bark"}, "", now)
	for i := 0; i < 10; i++ {
		s.Finish("message", "bark", true, now)
	}
	if len(s.Queue) != 0 {
		t.Fatal("unbounded retries")
	}
	for i := 0; i < 400; i++ {
		s.enqueue("sms", time.Unix(int64(i), 0).String(), []string{"bark"}, "", now)
	}
	if len(s.Queue) != 256 {
		t.Fatal("unbounded queue")
	}
	s.enqueue("call", "call-1", []string{"bark"}, "", now)
	if len(s.Queue) != 256 || s.Queue[255].Kind != "call" {
		t.Fatal("live call dropped under SMS backlog")
	}
}

func TestNotificationPrivacyIsOptInAndRevocable(t *testing.T) {
	now := time.Now()
	s := NewState()
	call := Snapshot{Kind: "calls", Calls: []int{7}, CallNumbers: map[string]string{"7": "+8613800138000"}}
	if _, err := s.Apply(call, EventOptions{Transports: []string{"bark"}}, now); err != nil {
		t.Fatal(err)
	}
	if len(s.Queue) != 1 || s.Queue[0].Detail != "" {
		t.Fatal("caller number must be hidden by default", s.Queue)
	}
	_, _ = s.Apply(Snapshot{Kind: "calls"}, EventOptions{}, now)
	if _, err := s.Apply(call, EventOptions{Transports: []string{"bark"}, ShowCallNumber: true}, now); err != nil {
		t.Fatal(err)
	}
	if len(s.Queue) != 1 || s.Queue[0].Detail != "+8613800138000" {
		t.Fatal("caller number opt-in was not applied", s.Queue)
	}
	if !s.RedactQueuedDetails(false, false) || s.Queue[0].Detail != "" {
		t.Fatal("disabling caller number did not redact queued content")
	}
	if !s.Reconcile(EventOptions{Transports: []string{"webpush"}}) || len(s.Queue) != 0 {
		t.Fatal("disabled transport remained queued", s.Queue)
	}
}

func TestSMSBodyOptInDecodesWithoutPersistingSender(t *testing.T) {
	const fullPDU = "0004038101F100006250724190410A3754747A0E4ABBCD6F793B4C4FBFDDA0F41CE47ED341617B38CD0E8BD96590F92D07E5DF7539283C1EBFEB6E3A889E87971B"
	now := time.Now()
	s := NewState()
	_, _ = s.Apply(Snapshot{Kind: "sms", Storage: 0}, EventOptions{}, now)
	if _, err := s.Apply(Snapshot{Kind: "sms", Storage: 0, PDUs: []string{fullPDU}}, EventOptions{Transports: []string{"webpush"}, ShowSMSBody: true}, now); err != nil {
		t.Fatal(err)
	}
	if len(s.Queue) != 1 || s.Queue[0].Detail != "This information is not available for your account type" {
		t.Fatal("SMS body was not decoded", s.Queue)
	}
	encoded, _ := json.Marshal(s)
	if bytes.Contains(encoded, []byte("101")) {
		t.Fatal("SMS sender was persisted although only body display was enabled")
	}
}
