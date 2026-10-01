package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"html/template"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// Enrollment: the tray listens on a one-shot loopback port, sends the
// browser to the portal, and passes the portal's redirect to the daemon,
// which proves it holds the key and installs the configuration it gets back.

const enrollTimeout = 15 * time.Minute

var enrolling atomic.Bool

// browse opens the portal; a variable so tests can play the browser.
var browse = openURL

var resultPage = template.Must(template.New("result").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>FoxDen VPN</title>
<style>
:root { color-scheme: light dark; --bg: #f6f7f9; --card: #fff; --fg: #1d2127; --muted: #616a75; --line: #dde1e6; --good: #1e8e3e; --bad: #d93025; }
@media (prefers-color-scheme: dark) { :root { --bg: #15181c; --card: #1e2227; --fg: #e6e9ed; --muted: #9aa3ad; --line: #2e343b; --good: #5bc77a; --bad: #f2766b; } }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, sans-serif; }
main { max-width: 520px; margin: 15vh auto 0; padding: 0 16px; }
section { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 22px; }
h1 { font-size: 20px; margin: 0 0 6px; color: {{if .OK}}var(--good){{else}}var(--bad){{end}}; }
p { margin: 0; color: var(--muted); }
</style></head>
<body><main><section><h1>{{.Title}}</h1><p>{{.Text}}</p></section></main></body></html>`))

type enrollResult struct {
	OK          bool
	Title, Text string
}

func randomHex() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (t *tray) portal() string {
	if st := t.status(); st != nil && st.PortalURL != "" {
		return st.PortalURL
	}
	return t.portalURL
}

// enroll registers this device through the portal. replace preselects the
// device to replace ("" lets the user choose); regenerate enrolls a new key.
func (t *tray) enroll(regenerate bool, replace string) {
	if !enrolling.CompareAndSwap(false, true) {
		notify(appName, "A registration is already waiting in your browser.")
		return
	}
	defer enrolling.Store(false)

	res, err := t.runEnrollment(regenerate, replace)
	switch {
	case err != nil:
		notify(appName, "Registration failed: "+err.Error())
	case res.OK:
		notify(appName, res.Text)
	default:
		notify(appName, res.Title+": "+res.Text)
	}
	t.pollNow()
}

func (t *tray) runEnrollment(regenerate bool, replace string) (enrollResult, error) {
	start, err := t.client.EnrollStart(regenerate)
	if err != nil {
		return enrollResult{}, err
	}
	if replace == "" {
		replace = start.Replace
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return enrollResult{}, err
	}
	state := randomHex()
	done := make(chan enrollResult, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /callback", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("state") != state {
			http.Error(w, "This registration was not started from this app, or it already finished.", http.StatusBadRequest)
			return
		}
		res := enrollResult{OK: true, Title: "Device registered", Text: "You can close this tab. The VPN configures itself now."}
		st, err := t.client.EnrollComplete(q.Get("token"), q.Get("challenge"))
		if err != nil {
			res = enrollResult{Title: "Registration failed", Text: err.Error()}
		} else {
			res.Text = "Registered as " + st.PeerName + ". You can close this tab."
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
		_ = resultPage.Execute(w, res)
		select {
		case done <- res:
		default:
		}
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(l) }()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx) // lets the result page finish rendering
	}()

	v := url.Values{
		"pubkey":   {start.PublicKey},
		"name":     {deviceName()},
		"callback": {"http://" + l.Addr().String() + "/callback"},
		"state":    {state},
	}
	if replace != "" {
		v.Set("replace", replace)
	}
	if err := browse(strings.TrimSuffix(t.portal(), "/") + "/enroll?" + v.Encode()); err != nil {
		return enrollResult{}, err
	}
	select {
	case res := <-done:
		return res, nil
	case <-time.After(enrollTimeout):
		return enrollResult{}, errors.New("timed out waiting for the browser")
	}
}

func (t *tray) regenerateKey(st *api.Status) {
	msg := "Make a new key for this device and register it as \"" + st.PeerName + "\"?\n\n" +
		"The current key keeps working until the new one is registered."
	if ask(appName, msg, "Regenerate") {
		t.enroll(true, "")
	}
}
