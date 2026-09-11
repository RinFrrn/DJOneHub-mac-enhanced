package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/iniwex5/vohive/internal/modulepush"
)

func TestDaemonMonitorToBark(t *testing.T) {
	// Exercise the real supervisor, parser, durable queue and HTTPS sender.
	dir := t.TempDir()
	monitor := filepath.Join(dir, "monitor")
	fixture := `#!/bin/sh
if [ "$1" = --calls ]; then
  echo '{"kind":"calls","calls":[1]}'
  echo '{"kind":"calls","calls":[1]}'
else
  echo '{"kind":"sms","storage":0,"pdus":["000001"]}'
  echo '{"kind":"sms","storage":0,"pdus":["000001","000002"]}'
  echo '{"kind":"sms","storage":0,"pdus":["000001","000002"]}'
fi
exec sleep 20
`
	if err := os.WriteFile(monitor, []byte(fixture), 0700); err != nil {
		t.Fatal(err)
	}
	arrivals := make(chan string, 4)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var p struct {
			Title string `json:"title"`
		}
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			t.Error(err)
		}
		arrivals <- p.Title
		_, _ = io.WriteString(w, `{"code":200}`)
	}))
	defer server.Close()
	sender := modulepush.NewSender(modulepush.Config{BarkURL: server.URL + "/private-key"})
	sender.Client.Transport = server.Client().Transport
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	statePath := filepath.Join(dir, "state.json")
	go func() { done <- serve(ctx, sender, monitor, statePath) }()
	titles := map[string]bool{}
	for len(titles) < 2 {
		select {
		case title := <-arrivals:
			if titles[title] {
				t.Fatal("duplicate notification", title)
			}
			titles[title] = true
		case err := <-done:
			t.Fatal("daemon exited early", err)
		case <-time.After(5 * time.Second):
			t.Fatal("missing notification", titles)
		}
	}
	if !titles["DJOneHub 来电"] || !titles["DJOneHub 新短信"] {
		t.Fatal(titles)
	}
	// Let the service receipts reach durable state before shutdown.
	deadline := time.Now().Add(3 * time.Second)
	for {
		s := modulepush.NewState()
		if err := modulepush.ReadPrivateJSON(statePath, s); err == nil && len(s.Queue) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("receipts not persisted")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	select {
	case title := <-arrivals:
		t.Fatal("duplicate delivery", title)
	default:
	}
	state, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(state), "000001") || strings.Contains(string(state), "private-key") {
		t.Fatal("private content leaked to state")
	}
}

func TestInvalidMonitorStream(t *testing.T) {
	events := make(chan modulepush.Snapshot, 1)
	if err := readEvents(context.Background(), strings.NewReader("not json\n"), events); err == nil {
		t.Fatal("accepted invalid stream")
	}
}
