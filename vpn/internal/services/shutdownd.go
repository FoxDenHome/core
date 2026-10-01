package services

import (
	_ "embed"
	"strings"
)

// shutdownd lets the UPS monitor shut this machine down cleanly on power loss.
// https://github.com/FoxDenHome/shutdownd
//
// Pinned to the "latest" release, built from c611a5d2e63f. The release tag is
// mutable: if it is replaced, downloads stop matching and the service reports
// an error until the pins here are updated (and later, until the release is
// signed instead).
var shutdownd = &Service{
	Name:        "shutdownd",
	Description: "Clean shutdown on power loss (UPS)",
	Version:     "c611a5d",
	Artifacts: map[string]Artifact{
		"linux/amd64": {
			URL:    "https://github.com/FoxDenHome/shutdownd/releases/download/latest/shutdownd-linux-amd64",
			SHA256: "d510f83c125b3922c874320c578b9b979362c858551a11a7fd96537976dedf40",
		},
		"linux/arm64": {
			URL:    "https://github.com/FoxDenHome/shutdownd/releases/download/latest/shutdownd-linux-arm64",
			SHA256: "9bf7132fa7e7dff7a09e2330d7be781d6f637419e7ac43888e8c912e5a5da041",
		},
		"darwin/arm64": {
			URL:    "https://github.com/FoxDenHome/shutdownd/releases/download/latest/shutdownd-darwin-arm64",
			SHA256: "0b16948ee4caa9008abbc7dceeb02938db30f7d52a7aed89a2a1dedc3e959338",
		},
	},
}

// shutdowndServerCert is the public certificate of the machine allowed to
// trigger shutdowns (shutdownd's server.pem; CN=server, valid until 2034).
// While it is empty, an existing /etc/shutdownd/server.pem is kept as is.
//
//go:embed shutdownd-server.pem
var shutdowndServerCertFile string

func shutdowndServerCert() []byte {
	if strings.Contains(shutdowndServerCertFile, "BEGIN CERTIFICATE") {
		return []byte(shutdowndServerCertFile)
	}
	return nil
}
