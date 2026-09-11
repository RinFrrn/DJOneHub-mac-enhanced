//go:build !darwin || !cgo

package main

import "errors"

func runModuleNotify(_ moduleNotifyOptions) error {
	return errors.New("module notification deployment requires macOS with libusb; run the ARM sender on QDC507")
}
