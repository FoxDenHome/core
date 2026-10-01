package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// fakeSystem is a scratch root with recorded commands instead of real ones.
type fakeSystem struct {
	*System
	cmds   []string
	users  map[string]bool
	active bool
}

func newFakeSystem(t *testing.T) *fakeSystem {
	f := &fakeSystem{users: map[string]bool{}}
	f.System = &System{
		Root: t.TempDir(),
		Run: func(_ context.Context, name string, args ...string) (string, error) {
			cmd := name + " " + strings.Join(args, " ")
			f.cmds = append(f.cmds, cmd)
			switch {
			case name == "useradd":
				f.users[args[len(args)-1]] = true
			case cmd == "systemctl restart shutdownd.service", cmd == "systemctl start shutdownd.service":
				f.active = true
			case strings.HasPrefix(cmd, "systemctl disable --now"):
				f.active = false
			case cmd == "systemctl is-active shutdownd.service":
				if !f.active {
					return "inactive\n", fmt.Errorf("exit status 3")
				}
				return "active\n", nil
			}
			return "", nil
		},
		LookupUser: func(name string) (int, int, error) {
			if !f.users[name] {
				return 0, 0, fmt.Errorf("unknown user %s", name)
			}
			return os.Getuid(), os.Getgid(), nil // chown to ourselves works unprivileged
		},
		Chown: os.Chown,
	}
	return f
}

func (f *fakeSystem) reset() { f.cmds = nil }

func (f *fakeSystem) ran(cmd string) bool {
	for _, c := range f.cmds {
		if c == cmd {
			return true
		}
	}
	return false
}

func testService(t *testing.T, body []byte) (*Service, *atomic.Int32) {
	var downloads atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downloads.Add(1)
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	sum := sha256.Sum256(body)
	return &Service{
		Name: "shutdownd", Description: "test", Version: "test",
		Artifacts: map[string]Artifact{runtime.GOOS + "/" + runtime.GOARCH: {URL: srv.URL, SHA256: hex.EncodeToString(sum[:])}},
		installer: shutdowndLinux{},
	}, &downloads
}

func testManager(t *testing.T, svc *Service, sys *fakeSystem) *Manager {
	m := NewManager(t.TempDir())
	m.catalog = []*Service{svc}
	m.sys = sys.System
	return m
}

func status(m *Manager) api.Service { return m.Status()[0] }

func TestUnmanagedIsLeftAlone(t *testing.T) {
	sys := newFakeSystem(t)
	svc, downloads := testService(t, []byte("binary"))
	m := testManager(t, svc, sys)

	m.reconcile(context.Background())
	if st := status(m); st.State != api.ServiceNotInstalled || st.Wanted != nil {
		t.Fatalf("fresh system: %+v", st)
	}

	// A hand-made install is detected but never touched.
	_ = os.MkdirAll(filepath.Join(sys.Root, "usr/bin"), 0o755)
	_ = os.WriteFile(filepath.Join(sys.Root, shutdowndBin), []byte("handmade"), 0o755)
	m.reconcile(context.Background())
	if st := status(m); st.State != api.ServiceUnmanaged {
		t.Fatalf("manual install: %+v", st)
	}
	if len(sys.cmds) != 0 || downloads.Load() != 0 {
		t.Fatalf("unmanaged service was touched: %v, %d downloads", sys.cmds, downloads.Load())
	}
	if b, _ := os.ReadFile(filepath.Join(sys.Root, shutdowndBin)); string(b) != "handmade" {
		t.Fatal("manual binary was replaced")
	}
}

func TestInstallUpdateRemove(t *testing.T) {
	sys := newFakeSystem(t)
	svc, downloads := testService(t, []byte("binary v1"))
	m := testManager(t, svc, sys)

	// Take over a hand-made install whose private key is world readable.
	cfg := filepath.Join(sys.Root, shutdowndConfig)
	_ = os.MkdirAll(cfg, 0o755)
	_ = os.WriteFile(filepath.Join(cfg, "server.pem"), []byte("-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n"), 0o644)
	_ = os.WriteFile(filepath.Join(cfg, "cert.pem"), []byte("key"), 0o644)

	m.SetWanted(map[string]bool{"shutdownd": true})
	m.reconcile(context.Background())
	st := status(m)
	if st.State != api.ServiceRunning || st.Wanted == nil || !*st.Wanted {
		t.Fatalf("install: %+v", st)
	}
	if b, _ := os.ReadFile(filepath.Join(sys.Root, shutdowndBin)); string(b) != "binary v1" {
		t.Fatal("binary not installed")
	}
	if fi, _ := os.Stat(filepath.Join(sys.Root, shutdowndBin)); fi.Mode().Perm() != 0o755 {
		t.Fatalf("binary mode %v", fi.Mode())
	}
	if fi, _ := os.Stat(filepath.Join(cfg, "cert.pem")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("private key left at %v", fi.Mode())
	}
	for _, p := range []string{shutdowndUnit, shutdowndRunUnit, shutdowndPolkit} {
		if !sys.exists(p) {
			t.Fatalf("%s not written", p)
		}
	}
	for _, c := range []string{"useradd -r -d /var/empty -s " + nologin() + " shutdownd", "systemctl daemon-reload",
		"systemctl enable shutdownd.service", "systemctl restart shutdownd.service"} {
		if !sys.ran(c) {
			t.Fatalf("did not run %q: %v", c, sys.cmds)
		}
	}

	// Nothing changed: no download, no reload, no restart.
	sys.reset()
	m.reconcile(context.Background())
	if downloads.Load() != 1 || sys.ran("systemctl daemon-reload") || sys.ran("systemctl restart shutdownd.service") {
		t.Fatalf("idle reconcile did work: %v, %d downloads", sys.cmds, downloads.Load())
	}

	// Removal keeps the identity in /etc/shutdownd.
	sys.reset()
	m.SetWanted(map[string]bool{"shutdownd": false})
	m.reconcile(context.Background())
	if st := status(m); st.State != api.ServiceNotInstalled {
		t.Fatalf("remove: %+v", st)
	}
	if sys.exists(shutdowndBin) || sys.exists(shutdowndUnit) || !sys.exists(shutdowndConfig+"/cert.pem") {
		t.Fatal("removal left the service or dropped its identity")
	}
	if !sys.ran("systemctl disable --now shutdownd.service") {
		t.Fatalf("not stopped: %v", sys.cmds)
	}
}

func TestPinMismatch(t *testing.T) {
	sys := newFakeSystem(t)
	svc, _ := testService(t, []byte("binary v1"))
	a := svc.Artifacts[runtime.GOOS+"/"+runtime.GOARCH]
	a.SHA256 = strings.Repeat("0", 64) // the release was replaced
	svc.Artifacts[runtime.GOOS+"/"+runtime.GOARCH] = a
	m := testManager(t, svc, sys)

	m.SetWanted(map[string]bool{"shutdownd": true})
	m.reconcile(context.Background())
	if st := status(m); st.State != api.ServiceError || !strings.Contains(st.Detail, "pinned hash") {
		t.Fatalf("mismatch: %+v", st)
	}
	if sys.exists(shutdowndBin) || len(sys.cmds) != 0 {
		t.Fatalf("unverified binary was installed: %v", sys.cmds)
	}
}

func TestRefusesWithoutServerCert(t *testing.T) {
	if shutdowndServerCert() != nil {
		t.Skip("this build pins server.pem")
	}
	sys := newFakeSystem(t)
	svc, _ := testService(t, []byte("binary v1"))
	m := testManager(t, svc, sys)
	m.SetWanted(map[string]bool{"shutdownd": true})
	m.reconcile(context.Background())
	if st := status(m); st.State != api.ServiceError || !strings.Contains(st.Detail, "server.pem") {
		t.Fatalf("no server.pem: %+v", st)
	}
	if len(sys.cmds) != 0 || sys.exists(shutdowndBin) {
		t.Fatalf("touched the system without knowing who may shut it down: %v", sys.cmds)
	}
}
