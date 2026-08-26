package main

import (
	"testing"
	"time"
)

func TestParseCLCCIncomingCall(t *testing.T) {
	got := parseCLCC("AT+CLCC\r\n+CLCC: 1,1,4,0,0,\"13800138000\",129\r\nOK")
	if len(got) != 1 {
		t.Fatalf("parseCLCC() len=%d, want 1", len(got))
	}
	if got[0].Index != 1 || got[0].Direction != "incoming" ||
		got[0].State != "incoming" || got[0].Number != "13800138000" {
		t.Fatalf("parseCLCC()=%+v", got[0])
	}
}

func TestParseCLCCNoCall(t *testing.T) {
	if got := parseCLCC("AT+CLCC\r\nOK"); len(got) != 0 {
		t.Fatalf("parseCLCC()=%+v, want empty", got)
	}
}

func TestParseCLCCIgnoresDataSession(t *testing.T) {
	response := "AT+CLCC\r\n+CLCC: 2,1,0,1,0,\"\",128\r\nOK"
	if got := parseCLCC(response); len(got) != 0 {
		t.Fatalf("parseCLCC()=%+v, want data session ignored", got)
	}
}

func TestValidateCallATResponseRejectsModemError(t *testing.T) {
	if err := validateCallATResponse("ATD10086;\r\nERROR"); err == nil {
		t.Fatal("validateCallATResponse accepted ERROR reply")
	}
	if err := validateCallATResponse("ATD10086;\r\nOK"); err != nil {
		t.Fatalf("validateCallATResponse rejected OK reply: %v", err)
	}
}

func TestShouldPrewarmModuleVoice(t *testing.T) {
	for _, state := range []string{"dialing", "alerting", "incoming", "waiting"} {
		if !shouldPrewarmModuleVoice(state) {
			t.Fatalf("shouldPrewarmModuleVoice(%q)=false, want true", state)
		}
	}
	for _, state := range []string{"active", "held", "unknown"} {
		if shouldPrewarmModuleVoice(state) {
			t.Fatalf("shouldPrewarmModuleVoice(%q)=true, want false", state)
		}
	}
}

func TestNextCallPollIntervalIsFastOnlyDuringSetup(t *testing.T) {
	a := &app{}
	for _, state := range []string{"dialing", "alerting", "incoming", "waiting"} {
		a.activeCall = &callRecord{State: state}
		if got := a.nextCallPollInterval(defaultCallPollInterval); got != callSetupPollInterval {
			t.Fatalf("nextCallPollInterval()=%s for %q, want %s", got, state, callSetupPollInterval)
		}
	}
	for _, state := range []string{"active", "held", "unknown"} {
		a.activeCall = &callRecord{State: state}
		if got := a.nextCallPollInterval(defaultCallPollInterval); got != defaultCallPollInterval {
			t.Fatalf("nextCallPollInterval()=%s for %q, want %s", got, state, defaultCallPollInterval)
		}
	}
	a.activeCall = nil
	if got := a.nextCallPollInterval(defaultCallPollInterval); got != defaultCallPollInterval {
		t.Fatalf("nextCallPollInterval()=%s while idle, want %s", got, defaultCallPollInterval)
	}
}

func TestWakeCallPollerCoalescesPendingWake(t *testing.T) {
	a := &app{callPollWake: make(chan struct{}, 1)}
	a.wakeCallPoller()
	a.wakeCallPoller()
	if got := len(a.callPollWake); got != 1 {
		t.Fatalf("pending wake count=%d, want 1", got)
	}
}

func TestNewCallCancelsPendingVoiceRouteStop(t *testing.T) {
	a := &app{}
	a.scheduleModuleVoiceRouteStop(time.Hour)
	a.callMu.RLock()
	if a.moduleVoiceStopTimer == nil {
		a.callMu.RUnlock()
		t.Fatal("voice route stop timer was not scheduled")
	}
	a.callMu.RUnlock()

	now := time.Date(2026, 8, 26, 20, 0, 0, 0, time.Local)
	a.applyCallPoll([]parsedCall{{
		Index: 1, Direction: "outgoing", State: "dialing", Number: "10086",
	}}, now)

	a.callMu.RLock()
	defer a.callMu.RUnlock()
	if a.moduleVoiceStopTimer != nil {
		t.Fatal("new call did not cancel the previous route stop timer")
	}
}

func TestCallLifecycleMarksMissed(t *testing.T) {
	a := &app{callPollInterval: defaultCallPollInterval, callNotifier: func(callRecord) {}}
	started := time.Date(2026, 7, 26, 10, 0, 0, 0, time.Local)
	a.applyCallPoll([]parsedCall{{
		Index: 1, Direction: "incoming", State: "incoming", Number: "10086",
	}}, started)
	a.applyCallPoll(nil, started.Add(8*time.Second))

	if a.activeCall != nil {
		t.Fatal("active call was not cleared")
	}
	if len(a.callHistory) != 1 || !a.callHistory[0].Missed {
		t.Fatalf("history=%+v, want one missed call", a.callHistory)
	}
}

func TestAnsweredCallIsNotMissed(t *testing.T) {
	a := &app{callPollInterval: defaultCallPollInterval, callNotifier: func(callRecord) {}}
	started := time.Date(2026, 7, 26, 10, 0, 0, 0, time.Local)
	a.applyCallPoll([]parsedCall{{
		Index: 1, Direction: "incoming", State: "incoming", Number: "10086",
	}}, started)
	a.applyCallPoll([]parsedCall{{
		Index: 1, Direction: "incoming", State: "active", Number: "10086",
	}}, started.Add(3*time.Second))
	a.applyCallPoll(nil, started.Add(8*time.Second))

	if len(a.callHistory) != 1 || a.callHistory[0].Missed {
		t.Fatalf("history=%+v, want answered call", a.callHistory)
	}
}

func TestNormalizeDialNumber(t *testing.T) {
	cases := map[string]string{
		"13800138000":        "13800138000",
		"+86 138-0013(8000)": "+8613800138000",
		"10086":              "10086",
		"*100#":              "*100#",
		"":                   "",
		"   ":                "",
		"12a45":              "",
		"tel:+8613800138000": "",
		"1-800-FLOWERS":      "",
	}
	for input, want := range cases {
		if got := normalizeDialNumber(input); got != want {
			t.Fatalf("normalizeDialNumber(%q)=%q, want %q", input, got, want)
		}
	}
}
