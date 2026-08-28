//go:build !darwin || !cgo

package main

import "net/http"

func (a *app) moduleADBInventoryAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "模块 ADB 盘点仅在 macOS 版本可用")
}

func (a *app) moduleADBQMIBundleAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "模块 QMI ABI 导出仅在 macOS 版本可用")
}
