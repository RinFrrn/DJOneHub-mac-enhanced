//go:build !darwin || !cgo

package main

import (
	"net/http"
)

func (a *app) sentinelStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "sentinel 部署仅在 macOS 版本可用")
}

func (a *app) sentinelInstallOnceAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "sentinel 部署仅在 macOS 版本可用")
}

func (a *app) sentinelUninstallAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "sentinel 部署仅在 macOS 版本可用")
}
