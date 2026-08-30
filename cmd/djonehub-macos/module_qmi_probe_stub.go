//go:build !darwin || !cgo

package main

import "net/http"

func (a *app) qmiVoiceProbeAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 探针部署仅在 macOS 版本可用")
}

func (a *app) qmiVoiceControlStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 控制候选部署仅在 macOS 版本可用")
}

func (a *app) qmiVoiceControlDialAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 控制候选部署仅在 macOS 版本可用")
}

func (a *app) qmiVoiceControlAnswerAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 控制候选部署仅在 macOS 版本可用")
}

func (a *app) qmiVoiceControlEndAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice 控制候选部署仅在 macOS 版本可用")
}

func (a *app) qmiVoiceDaemonStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QMI Voice daemon 验证仅在 macOS 版本可用")
}

func (a *app) voiceTestStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "iOS STATUS 测试仅在 macOS 版本可用")
}

func (a *app) voiceTestArmOnceAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "iOS STATUS 测试仅在 macOS 版本可用")
}

func (a *app) voiceTestUninstallAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "iOS STATUS 测试仅在 macOS 版本可用")
}
