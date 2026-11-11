package tlscert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeCloudns keeps TXT records the way the ClouDNS API reports them.
type fakeCloudns struct {
	records map[string]map[string]string
	nextID  int
	calls   []string
}

func (f *fakeCloudns) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	endpoint := strings.TrimPrefix(r.URL.Path, "/dns/")
	f.calls = append(f.calls, endpoint)
	reply := func(v any) { _ = json.NewEncoder(w).Encode(v) }
	if r.Form.Get("sub-auth-id") != "id" || r.Form.Get("auth-password") != "pw" || r.Form.Get("domain-name") != "status.acme.example.com" {
		reply(map[string]string{"status": "Failed", "statusDescription": "Invalid authentication"})
		return
	}
	switch endpoint {
	case "add-record.json":
		if r.Form.Get("record-type") != "TXT" || r.Form.Get("host") != "_acme-challenge.status.example.com" || r.Form.Get("ttl") != "60" {
			reply(map[string]string{"status": "Failed", "statusDescription": "bad record " + r.Form.Encode()})
			return
		}
		f.nextID++
		id := strconv.Itoa(f.nextID)
		f.records[id] = map[string]string{"id": id, "type": "TXT", "host": r.Form.Get("host"), "record": r.Form.Get("record")}
		reply(map[string]any{"status": "Success", "data": map[string]int{"id": f.nextID}})
	case "records.json":
		if len(f.records) == 0 {
			_, _ = w.Write([]byte("[]"))
			return
		}
		reply(f.records)
	case "delete-record.json":
		delete(f.records, r.Form.Get("record-id"))
		reply(map[string]string{"status": "Success"})
	default:
		http.NotFound(w, r)
	}
}

func TestTXT(t *testing.T) {
	fake := &fakeCloudns{records: map[string]map[string]string{}}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	defer func(u string) { cloudnsAPI = u }(cloudnsAPI)
	cloudnsAPI = srv.URL + "/dns"

	m := &Manager{opts: Options{Domain: "status.example.com", DNSAuthID: "id", DNSPassword: "pw", DNSZone: "status.acme.example.com", HTTP: srv.Client()}}
	ctx := context.Background()
	// The other router's challenge
	if err := m.addTXT(ctx, "other"); err != nil {
		t.Fatal(err)
	}
	if err := m.addTXT(ctx, "token"); err != nil {
		t.Fatal(err)
	}
	if len(fake.records) != 2 {
		t.Fatalf("records = %v", fake.records)
	}
	if err := m.deleteTXT(ctx, "token"); err != nil {
		t.Fatal(err)
	}
	if len(fake.records) != 1 || fake.records["1"]["record"] != "other" {
		t.Errorf("only token should be gone: %v", fake.records)
	}
	if err := m.deleteTXT(ctx, "other"); err != nil {
		t.Fatal(err)
	}
	// Nothing left: records.json answers []
	if err := m.deleteTXT(ctx, "other"); err != nil {
		t.Fatal(err)
	}

	m.opts.DNSPassword = "wrong"
	if err := m.addTXT(ctx, "token"); err == nil || !strings.Contains(err.Error(), "Invalid authentication") {
		t.Errorf("bad password: err = %v", err)
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
	m, err := New(Options{Domain: "status.example.com", CacheDir: dir, DNSAuthID: "id", DNSPassword: "pw", DNSZone: "status.acme.example.com"})
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
	m, err = New(Options{Domain: "status.example.com", CacheDir: dir, DNSAuthID: "id", DNSPassword: "pw", DNSZone: "status.acme.example.com"})
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
