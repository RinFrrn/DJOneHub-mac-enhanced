package main

import (
	"testing"
	"time"
)

func TestADBUSBTimeoutNeverBecomesInfinite(t *testing.T) {
	for name, timeout := range map[string]time.Duration{
		"zero":        0,
		"negative":    -time.Millisecond,
		"submillisec": 500 * time.Microsecond,
	} {
		if got := adbUSBTimeoutMilliseconds(timeout); got != 1 {
			t.Errorf("%s timeout converted to %d ms; want 1 ms", name, got)
		}
	}
}

func TestADBUSBTimeoutConversion(t *testing.T) {
	if got := adbUSBTimeoutMilliseconds(25 * time.Millisecond); got != 25 {
		t.Fatalf("25 ms converted to %d ms", got)
	}
	if got := adbUSBTimeoutMilliseconds(2000000 * time.Hour); uint64(got) != adbMaximumUSBTimeoutMilliseconds {
		t.Fatalf("oversized timeout converted to %d ms", got)
	}
}
