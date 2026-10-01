package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"html"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/daemon"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

const testCallback = "http://127.0.0.1:41234/callback"

func (h *harness) serverPub() wgtypes.Key {
	k, _ := wgtypes.ParseKey(h.primary.Tables["/interface/wireguard"][0]["public-key"])
	return k
}

// startEnroll submits the device picker and returns the loopback redirect.
func (h *harness) startEnroll(c *http.Client, csrf string, key wgtypes.Key, device, newName string) *url.URL {
	h.t.Helper()
	resp := h.post(c, "/enroll", url.Values{
		"csrf": {csrf}, "pubkey": {key.String()}, "callback": {testCallback}, "state": {"st8"},
		"device": {device}, "new_name": {newName},
	})
	if resp.StatusCode != http.StatusSeeOther {
		h.t.Fatalf("POST /enroll: %d", resp.StatusCode)
	}
	u, err := url.Parse(resp.Header.Get("Location"))
	if err != nil || !strings.HasPrefix(u.String(), testCallback+"?") || u.Query().Get("state") != "st8" {
		h.t.Fatalf("redirect = %q", resp.Header.Get("Location"))
	}
	return u
}

// complete is what the daemon does with the redirect.
func (h *harness) complete(redirect *url.URL, priv wgtypes.Key) (*http.Response, enrollCompleteResponse) {
	h.t.Helper()
	sealed, _ := base64.RawURLEncoding.DecodeString(redirect.Query().Get("challenge"))
	answer, err := provision.AnswerChallenge(sealed, priv, h.serverPub())
	if err != nil {
		answer = []byte("cannot open it")
	}
	body, _ := json.Marshal(enrollCompleteRequest{Token: redirect.Query().Get("token"), Answer: base64.StdEncoding.EncodeToString(answer)})
	resp, err := http.Post(h.srv.URL+"/api/enroll/complete", "application/json", bytes.NewReader(body))
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out enrollCompleteResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func TestEnrollFlow(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()

	// The picker shows; nothing is registered until the device answers.
	resp, err := c.Get(h.srv.URL + "/enroll?" + url.Values{"pubkey": {dev.PublicKey().String()}, "name": {"fennec"},
		"callback": {testCallback}, "state": {"st8"}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	page, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(html.UnescapeString(string(page)), `value="fennec"`) {
		t.Fatal("new device name not prefilled")
	}
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "http://127.0.0.1:*") {
		t.Fatalf("CSP blocks the loopback redirect: %q", csp)
	}
	redirect := h.startEnroll(c, csrf, dev.PublicKey(), "", "fennec")
	if len(peerNames(h.primary)) != 0 {
		t.Fatal("router changed before the device proved it holds the key")
	}

	resp, out := h.complete(redirect, dev)
	if resp.StatusCode != http.StatusOK || out.Device != "fennec" {
		t.Fatalf("complete: %d %+v", resp.StatusCode, out)
	}
	blob, _ := base64.StdEncoding.DecodeString(out.Config)
	cfg, err := provision.Open(blob, dev, h.serverPub())
	if err != nil || cfg.Name != "dori-fennec" {
		t.Fatalf("returned config: %+v, %v", cfg, err)
	}
	if h.blobFor(dev) == nil || len(peerNames(h.backup)) != 1 {
		t.Fatal("enrollment was not published and mirrored")
	}

	// Regenerating the key replaces the device in place.
	dev2, _ := wgtypes.GeneratePrivateKey()
	_, out = h.complete(h.startEnroll(c, csrf, dev2.PublicKey(), "fennec", ""), dev2)
	blob, _ = base64.StdEncoding.DecodeString(out.Config)
	cfg2, err := provision.Open(blob, dev2, h.serverPub())
	if err != nil || cfg2.Addresses[0] != cfg.Addresses[0] || h.blobFor(dev) != nil {
		t.Fatalf("regenerate: %+v, %v", cfg2, err)
	}
}

func TestEnrollRejects(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	victim, _ := wgtypes.GeneratePrivateKey()
	attacker, _ := wgtypes.GeneratePrivateKey()

	// A phishing link with the attacker's key: the challenge reaches the
	// victim's machine, which cannot answer it.
	redirect := h.startEnroll(c, csrf, attacker.PublicKey(), "", "laptop")
	if resp, _ := h.complete(redirect, victim); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("answered with the wrong key: %d", resp.StatusCode)
	}

	// A tampered token (say, another device name) is rejected even with a
	// correct answer.
	redirect = h.startEnroll(c, csrf, victim.PublicKey(), "", "laptop")
	q := redirect.Query()
	tok := q.Get("token")
	q.Set("token", "x"+tok)
	redirect.RawQuery = q.Encode()
	if resp, _ := h.complete(redirect, victim); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("tampered token: %d", resp.StatusCode)
	}
	if len(peerNames(h.primary)) != 0 {
		t.Fatal("a rejected enrollment changed the router")
	}

	// Only loopback callbacks.
	for _, cb := range []string{"https://evil.example/cb", "http://evil.example:80/cb", "http://127.0.0.1/no-port", "http://user@127.0.0.1:1/"} {
		resp := h.post(c, "/enroll", url.Values{"csrf": {csrf}, "pubkey": {victim.PublicKey().String()},
			"callback": {cb}, "state": {"s"}, "new_name": {"laptop"}})
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("callback %q accepted: %d", cb, resp.StatusCode)
		}
	}
}

func TestLoopbackCallback(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:1234/x", "http://[::1]:1234/x", "http://localhost:9/"} {
		if _, err := loopbackCallback(ok); err != nil {
			t.Errorf("%s rejected: %v", ok, err)
		}
	}
}

// The real daemon against the real portal: the wire formats must agree.
func TestEnrollWithRealDaemon(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	d, err := daemon.New(daemon.Options{
		StateDir: t.TempDir(), ProvisionURL: h.srv.URL + "/nothing-here", PortalURL: h.srv.URL,
		ServerKey: h.serverPub(), Tunnel: tunnel.Options{Name: "fvpntest0"}, IdleTimeout: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	start, err := d.EnrollStart(false)
	if err != nil {
		t.Fatal(err)
	}
	pub, _ := wgtypes.ParseKey(start.PublicKey)
	redirect := h.startEnroll(c, csrf, pub, "", "fennec")
	if err := d.EnrollComplete(ctx, redirect.Query().Get("token"), redirect.Query().Get("challenge")); err != nil {
		t.Fatal(err)
	}
	if st := d.Status(); !st.Provisioned || st.PeerName != "dori-fennec" {
		t.Fatalf("daemon after enrollment: %+v", st)
	}

	// Regenerate: the daemon switches to the new key, the router follows.
	start, _ = d.EnrollStart(true)
	if start.Replace != "dori-fennec" {
		t.Fatalf("regenerate should replace the device itself: %+v", start)
	}
	pub2, _ := wgtypes.ParseKey(start.PublicKey)
	redirect = h.startEnroll(c, csrf, pub2, "fennec", "")
	if err := d.EnrollComplete(ctx, redirect.Query().Get("token"), redirect.Query().Get("challenge")); err != nil {
		t.Fatal(err)
	}
	if d.PublicKey() != pub2 {
		t.Fatal("daemon did not switch to the new key")
	}
	rows := h.primary.Tables["/interface/wireguard/peers"]
	if len(rows) != 1 || rows[0]["public-key"] != pub2.String() {
		t.Fatalf("router: %v", rows)
	}
}
