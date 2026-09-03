//go:build darwin && cgo

package main

import (
	"errors"
	"fmt"
	"net"
	"testing"
)

func TestVoiceDaemonDialUnavailableOnlyAcceptsDialErrors(t *testing.T) {
	dialError := &net.OpError{Op: "dial", Net: "tcp4", Err: errors.New("i/o timeout")}
	if !isVoiceDaemonDialUnavailable(dialError) {
		t.Fatal("TCP dial timeout was not classified as ECM unavailability")
	}
	if !isVoiceDaemonDialUnavailable(fmt.Errorf("wrapped: %w", dialError)) {
		t.Fatal("wrapped TCP dial timeout was not classified as ECM unavailability")
	}
	if isVoiceDaemonDialUnavailable(&net.OpError{Op: "read", Net: "tcp4", Err: errors.New("i/o timeout")}) {
		t.Fatal("post-connect protocol read failure was classified as ECM unavailability")
	}
	if isVoiceDaemonDialUnavailable(errors.New("no route to host")) {
		t.Fatal("untyped string error was classified as ECM unavailability")
	}
}
