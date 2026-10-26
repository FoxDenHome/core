package tlscert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSetTXT(t *testing.T) {
	var got map[string]string
	reply := "good 127.0.0.1"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		got = map[string]string{"hostname": r.Form.Get("hostname"), "password": r.Form.Get("password"), "txt": r.Form.Get("txt")}
		_, _ = w.Write([]byte(reply))
	}))
	defer srv.Close()
	defer func(u string) { heUpdateURL = u }(heUpdateURL)
	heUpdateURL = srv.URL

	m := &Manager{opts: Options{Domain: "status.example.com", DNSKey: "secret", HTTP: srv.Client()}}
	if err := m.setTXT(context.Background(), "token"); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"hostname": "_acme-challenge.status.example.com", "password": "secret", "txt": "token"}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}

	reply = "nochg"
	if err := m.setTXT(context.Background(), "token"); err != nil {
		t.Errorf("nochg: %v", err)
	}
	reply = "badauth"
	if err := m.setTXT(context.Background(), "token"); err == nil {
		t.Error("badauth: want error")
	}
}

func TestRenewalTime(t *testing.T) {
	if !renewalTime(nil).IsZero() {
		t.Error("missing certificate should renew now")
	}
	notAfter := time.Date(2030, 1, 31, 0, 0, 0, 0, time.UTC)
	cert := &tls.Certificate{Leaf: &x509.Certificate{NotAfter: notAfter}}
	if got, want := renewalTime(cert), notAfter.Add(-renewBefore); !got.Equal(want) {
		t.Errorf("renewalTime = %s, want %s", got, want)
	}
}

func TestCache(t *testing.T) {
	dir := t.TempDir()
	m, err := New(Options{Domain: "status.example.com", CacheDir: dir, DNSKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.GetCertificate(nil); err == nil {
		t.Fatal("want error before a certificate exists")
	}

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		DNSNames:     []string{"status.example.com"},
		NotAfter:     time.Now().Add(90 * 24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.store([][]byte{der}, key); err != nil {
		t.Fatal(err)
	}

	// A restart picks up the stored certificate.
	m, err = New(Options{Domain: "status.example.com", CacheDir: dir, DNSKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	cert, err := m.GetCertificate(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cert.Leaf.DNSNames[0] != "status.example.com" {
		t.Errorf("DNSNames = %v", cert.Leaf.DNSNames)
	}

	// The account key survives too.
	k1, err := m.accountKey()
	if err != nil {
		t.Fatal(err)
	}
	k2, err := m.accountKey()
	if err != nil {
		t.Fatal(err)
	}
	if !k1.(*ecdsa.PrivateKey).Equal(k2) {
		t.Error("account key changed between loads")
	}
}
