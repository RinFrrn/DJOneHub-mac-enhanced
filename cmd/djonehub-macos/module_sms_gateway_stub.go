//go:build !darwin || !cgo

package main

import "net/http"

func (a *app) qmiSMSGatewayStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QDC507 短信网关验证仅在 macOS 版本可用")
}

func (a *app) qmiSMSSessionStatusAPI(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "QDC507 短信会话验证仅在 macOS 版本可用")
}
