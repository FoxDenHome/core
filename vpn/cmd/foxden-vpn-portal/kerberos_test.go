package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/daemon"
	"github.com/FoxDenHome/core/vpn/internal/pkinit"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func (h *harness) withCA() *pkinit.CA {
	ca, err := pkinit.NewCA("FOXDEN.NETWORK", time.Hour)
	if err != nil {
		h.t.Fatal(err)
	}
	h.p.ca, h.p.caTTL = ca, 24*time.Hour
	h.p.cfg.PKINIT.Realm = "FOXDEN.NETWORK"
	return ca
}

func (h *harness) postJSON(path string, body, out any) int {
	h.t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(h.srv.URL+path, "application/json", bytes.NewReader(b))
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		_ = json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func pkinitPub(t *testing.T) string {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

// certFor runs the device proof for dev and asks for a certificate.
func (h *harness) certFor(dev wgtypes.Key, answerWith wgtypes.Key) (int, kerberosCertResponse) {
	var ch deviceChallengeResponse
	if code := h.postJSON("/api/device/challenge", map[string]string{"public_key": dev.PublicKey().String()}, &ch); code != http.StatusOK {
		return code, kerberosCertResponse{}
	}
	sealed, _ := base64.RawURLEncoding.DecodeString(ch.Challenge)
	answer, err := provision.AnswerChallenge(sealed, answerWith, h.serverPub())
	if err != nil {
		answer = []byte("nope")
	}
	var out kerberosCertResponse
	code := h.postJSON("/api/kerberos/cert", kerberosCertRequest{
		Token: ch.Token, Answer: base64.StdEncoding.EncodeToString(answer), PublicKey: pkinitPub(h.t),
	}, &out)
	return code, out
}

func TestKerberosCert(t *testing.T) {
	h := newHarness(t)
	ca := h.withCA()
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()
	if _, out := h.complete(h.startEnroll(c, csrf, dev.PublicKey(), "", "fennec"), dev); out.Error != "" {
		t.Fatal(out.Error)
	}

	code, out := h.certFor(dev, dev)
	if code != http.StatusOK || out.Principal != "dori@FOXDEN.NETWORK" {
		t.Fatalf("issue: %d %+v", code, out)
	}
	cert, err := pkinit.ParseCertPEM([]byte(out.Certificate))
	if err != nil {
		t.Fatal(err)
	}
	if comps, realm, _ := pkinit.Principal(cert); !slices.Equal(comps, []string{"dori"}) || realm != "FOXDEN.NETWORK" {
		t.Fatalf("certificate names %v@%s", comps, realm)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca.Cert)
	if _, err := cert.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		t.Fatalf("does not chain to the CA: %v", err)
	}
	if d := time.Until(cert.NotAfter); d < 23*time.Hour || d > 25*time.Hour {
		t.Fatalf("validity %v", d)
	}
}

func TestKerberosCertRejects(t *testing.T) {
	h := newHarness(t)
	h.withCA()
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()
	redirect := h.startEnroll(c, csrf, dev.PublicKey(), "", "fennec")
	if _, out := h.complete(redirect, dev); out.Error != "" {
		t.Fatal(out.Error)
	}

	// Answering with another key.
	other, _ := wgtypes.GeneratePrivateKey()
	if code, _ := h.certFor(dev, other); code != http.StatusForbidden {
		t.Fatalf("wrong key: %d", code)
	}
	// A key that is not registered.
	if code, _ := h.certFor(other, other); code != http.StatusForbidden {
		t.Fatalf("unregistered: %d", code)
	}
	// An admin-made peer has no owner to issue for.
	admin, _ := wgtypes.GeneratePrivateKey()
	h.primary.Tables["/interface/wireguard/peers"] = append(h.primary.Tables["/interface/wireguard/peers"], routeros.Row{
		".id": "*99", "interface": "wg-vpn", "name": "fennec-old", "public-key": admin.PublicKey().String(),
		"allowed-address": "10.100.10.99/32",
	})
	if code, _ := h.certFor(admin, admin); code != http.StatusForbidden {
		t.Fatalf("unowned: %d", code)
	}
	// An enrollment token is not good for a certificate.
	sealed, _ := base64.RawURLEncoding.DecodeString(redirect.Query().Get("challenge"))
	answer, _ := provision.AnswerChallenge(sealed, dev, h.serverPub())
	code := h.postJSON("/api/kerberos/cert", kerberosCertRequest{
		Token: redirect.Query().Get("token"), Answer: base64.StdEncoding.EncodeToString(answer), PublicKey: pkinitPub(t),
	}, nil)
	if code != http.StatusForbidden {
		t.Fatalf("enroll token accepted for a certificate: %d", code)
	}
	// Without a CA nothing is issued.
	h.p.ca = nil
	if code, _ := h.certFor(dev, dev); code != http.StatusServiceUnavailable {
		t.Fatalf("no CA: %d", code)
	}
}

func TestKerberosCertWithRealDaemon(t *testing.T) {
	h := newHarness(t)
	h.withCA()
	c, csrf := h.client("dori")
	d, err := daemon.New(daemon.Options{
		StateDir: t.TempDir(), ProvisionURL: h.srv.URL + "/nothing-here", PortalURL: h.srv.URL,
		ServerKey: h.serverPub(), Tunnel: tunnel.Options{Name: "fvpntest0"}, IdleTimeout: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := d.KerberosCert(ctx, pkinitPub(t)); err == nil {
		t.Fatal("unregistered device got a certificate")
	}
	start, _ := d.EnrollStart(false)
	pub, _ := wgtypes.ParseKey(start.PublicKey)
	redirect := h.startEnroll(c, csrf, pub, "", "fennec")
	if err := d.EnrollComplete(ctx, redirect.Query().Get("token"), redirect.Query().Get("challenge")); err != nil {
		t.Fatal(err)
	}
	cert, err := d.KerberosCert(ctx, pkinitPub(t))
	if err != nil || cert.Principal != "dori@FOXDEN.NETWORK" || cert.CA == "" {
		t.Fatalf("cert: %+v, %v", cert, err)
	}
}
