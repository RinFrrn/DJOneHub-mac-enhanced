//go:build !darwin || !cgo

package main

import "net/http"

func (a *app) moduleADBInventoryAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "模块 ADB 盘点仅在 macOS 版本可用")
}
