package main

import "time"

const adbMaximumUSBTimeoutMilliseconds = uint64(^uint32(0))

// adbUSBTimeoutMilliseconds converts a Go duration to libusb's unsigned
// millisecond timeout. libusb defines zero as "wait forever", so every finite
// operation must be rounded up to at least one millisecond.
func adbUSBTimeoutMilliseconds(timeout time.Duration) uint {
	if timeout <= 0 {
		return 1
	}
	milliseconds := uint64(timeout / time.Millisecond)
	if milliseconds < 1 {
		return 1
	}
	if milliseconds > adbMaximumUSBTimeoutMilliseconds {
		return uint(adbMaximumUSBTimeoutMilliseconds)
	}
	return uint(milliseconds)
}
