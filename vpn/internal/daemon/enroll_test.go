package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// fakePortal accepts an enrollment when the answer matches the secret it
// sealed, and returns cfg sealed to the enrolled key.
type fakePortal struct {
	server  wgtypes.Key
	secrets map[string][]byte // token -> secret
	keys    map[string]wgtypes.Key
	cfg     *provision.Config
}

func (f *fakePortal) challenge(t *testing.T, token string, peer wgtypes.Key) string {
	sealed, secret, err := provision.NewChallenge(f.server, peer)
	if err != nil {
		t.Fatal(err)
	}
	f.secrets[token], f.keys[token] = secret, peer
	return base64.RawURLEncoding.EncodeToString(sealed)
}

func (f *fakePortal) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct{ Token, Answer string }
	_ = json.NewDecoder(r.Body).Decode(&req)
	answer, _ := base64.StdEncoding.DecodeString(req.Answer)
	want := f.secrets[req.Token]
	if sha256.Sum256(answer) != sha256.Sum256(want) || want == nil {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "wrong challenge answer"})
		return
	}
	blob, _ := provision.Seal(f.cfg, f.server, f.keys[req.Token])
	_ = json.NewEncoder(w).Encode(map[string]string{"device": "fennec", "config": base64.StdEncoding.EncodeToString(blob)})
}

func newEnrollDaemon(t *testing.T, cdn http.Handler) (*Daemon, *fakePortal, string) {
	server, _ := wgtypes.GeneratePrivateKey()
	fp := &fakePortal{server: server, secrets: map[string][]byte{}, keys: map[string]wgtypes.Key{}}
	fp.cfg = testProv(t)
	fp.cfg.Name = "dori-fennec"
	fp.cfg.Server.PublicKey = server.PublicKey().String()
	portal := httptest.NewServer(fp)
	t.Cleanup(portal.Close)
	if cdn == nil {
		cdn = http.NotFoundHandler()
	}
	cdnSrv := httptest.NewServer(cdn)
	t.Cleanup(cdnSrv.Close)
	dir := t.TempDir()
	d, err := New(Options{
		StateDir: dir, ProvisionURL: cdnSrv.URL, PortalURL: portal.URL, ServerKey: server.PublicKey(),
		Tunnel: tunnel.Options{Name: "fvpntest0"}, IdleTimeout: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	d.settings.Enabled = false
	return d, fp, dir
}

func TestEnrollRegenerate(t *testing.T) {
	d, fp, dir := newEnrollDaemon(t, nil)
	ctx := context.Background()
	oldKey := d.PublicKey()

	start, err := d.EnrollStart(true)
	if err != nil || start.PublicKey == oldKey.String() {
		t.Fatalf("start: %+v, %v", start, err)
	}
	// Abandoned enrollment: the device keeps its key; asking again reuses
	// the pending one.
	if d.PublicKey() != oldKey {
		t.Fatal("key switched before the portal accepted the new one")
	}
	again, _ := d.EnrollStart(true)
	if again.PublicKey != start.PublicKey {
		t.Fatal("pending key not reused")
	}

	pending, _ := wgtypes.ParseKey(start.PublicKey)
	if err := d.EnrollComplete(ctx, "tok", fp.challenge(t, "tok", pending)); err != nil {
		t.Fatal(err)
	}
	st := d.Status()
	if d.PublicKey() != pending || !st.Provisioned || st.PeerName != "dori-fennec" || st.PublicKey != start.PublicKey {
		t.Fatalf("after enrollment: key %s, status %+v", d.PublicKey(), st)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "private.key"))
	saved, _ := wgtypes.ParseKey(strings.TrimSpace(string(b)))
	if saved.PublicKey() != pending {
		t.Fatal("new key not saved")
	}
	if _, err := os.Stat(filepath.Join(dir, pendingKeyFile)); !os.IsNotExist(err) {
		t.Fatal("pending key left behind")
	}
}

func TestEnrollRejectsForeignChallenge(t *testing.T) {
	d, fp, _ := newEnrollDaemon(t, nil)
	other, _ := wgtypes.GeneratePrivateKey()
	err := d.EnrollComplete(context.Background(), "tok", fp.challenge(t, "tok", other.PublicKey()))
	if err == nil || !strings.Contains(err.Error(), "not for this device") {
		t.Fatalf("got %v", err)
	}
	if d.Status().Provisioned {
		t.Fatal("provisioned from someone else's enrollment")
	}
}

func TestEnrolledConfigSurvivesCDNLag(t *testing.T) {
	d, fp, _ := newEnrollDaemon(t, nil) // the CDN answers 404 for everything
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = d.Run(ctx) }()

	self := d.PublicKey()
	if err := d.EnrollComplete(ctx, "tok", fp.challenge(t, "tok", self)); err != nil {
		t.Fatal(err)
	}
	st := d.Refresh(ctx)
	if !st.Provisioned || st.ProvisionError != "" {
		t.Fatalf("CDN 404 right after enrolling wiped the config: %+v", st)
	}
}
