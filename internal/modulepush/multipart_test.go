package modulepush

import (
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func multipartPDU(sequence byte, wide bool) string {
	header := []byte{5, 0, 3, 42, 2, sequence}
	if wide {
		header = []byte{6, 8, 4, 0, 42, 2, sequence}
	}
	body := []byte{0x4f, 0x60}
	if sequence == 2 {
		body = []byte{0x59, 0x7d}
	}
	pdu := []byte{0, 0x44, 4, 0x91, 0x21, 0x43, 0, 8, 0x62, 0x90, 0x31, 0x90, 0, 0, 0x23, byte(len(header) + len(body))}
	return hex.EncodeToString(append(append(pdu, header...), body...))
}

func TestMultipartNotification(t *testing.T) {
	for _, wide := range []bool{false, true} {
		now := time.Now()
		options := EventOptions{Transports: []string{"bark"}, ShowSMSBody: true}
		s := NewState()
		apply := func(storage int, pdus ...string) {
			t.Helper()
			if _, err := s.Apply(Snapshot{Kind: "sms", Storage: storage, PDUs: pdus}, options, now); err != nil {
				t.Fatal(err)
			}
		}
		apply(0)
		apply(1)
		apply(0, multipartPDU(2, wide))
		if len(s.Queue) != 0 {
			t.Fatal("partial SMS was sent")
		}
		data, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		s = NewState()
		if err = json.Unmarshal(data, s); err != nil {
			t.Fatal(err)
		}
		apply(1, multipartPDU(1, wide))
		if len(s.Queue) != 1 || s.Queue[0].Detail != "你好" {
			t.Fatalf("expected one merged notification: %#v", s.Queue)
		}
		s.Finish(s.Queue[0].ID, "bark", false, now)
		apply(0, multipartPDU(1, wide), multipartPDU(2, wide))
		apply(1, multipartPDU(1, wide), multipartPDU(2, wide))
		if len(s.Queue) != 0 {
			t.Fatal("duplicate notification after delivery")
		}
	}
}

func TestMultipartHistoricalAndPrivacy(t *testing.T) {
	now := time.Now()
	s := NewState()
	options := EventOptions{Transports: []string{"bark"}, ShowSMSBody: true}
	_, _ = s.Apply(Snapshot{Kind: "sms", PDUs: []string{multipartPDU(1, false), multipartPDU(2, false)}}, options, now)
	if len(s.Queue) != 0 {
		t.Fatal("historical multipart replayed")
	}
	s = NewState()
	_, _ = s.Apply(Snapshot{Kind: "sms"}, options, now)
	_, _ = s.Apply(Snapshot{Kind: "sms", PDUs: []string{multipartPDU(1, false)}}, options, now)
	if !s.RedactQueuedDetails(false, false) {
		t.Fatal("pending body not redacted")
	}
	options.ShowSMSBody = false
	_, _ = s.Apply(Snapshot{Kind: "sms", PDUs: []string{multipartPDU(1, false), multipartPDU(2, false)}}, options, now)
	if len(s.Queue) != 1 || s.Queue[0].Detail != "" {
		t.Fatal("privacy disabled body leaked")
	}
	data, _ := json.Marshal(s)
	for _, value := range []string{"你好", "你", "好", "+1234"} {
		if strings.Contains(string(data), value) {
			t.Fatal("private content persisted")
		}
	}
}
