//go:build !darwin || !cgo

package main

import "net/http"

func (a *app) qmiVoiceProbeAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 探针部署仅在 macOS 版本可用")
}
