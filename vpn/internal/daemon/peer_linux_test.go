package daemon

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
)

func TestPeerUser(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "s")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		c, err := net.Dial("unix", sock)
		if err == nil {
			defer c.Close()
			_, _ = c.Read(make([]byte, 1))
		}
	}()
	c, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	u, ok := peerUser(c)
	if !ok || u.UID != uint32(os.Getuid()) || u.GID != uint32(os.Getgid()) {
		t.Fatalf("peer = %+v, %v", u, ok)
	}
}

// TestMountsThroughSocket goes through New and Serve, so a missing mounter
// or peer lookup shows up here.
func TestMountsThroughSocket(t *testing.T) {
	d, err := New(Options{StateDir: t.TempDir(), Tunnel: tunnel.Options{Name: "fvpntest1"}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sock := filepath.Join(t.TempDir(), "s")
	go func() { _ = d.Serve(ctx, sock, "") }()
	c := api.NewClient(sock)
	var list []api.Mount
	for i := 0; ; i++ {
		if list, err = c.Mounts(); err == nil || i == 50 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range list {
		t.Logf("mounted: %+v", m) // only this user's SMB mounts, usually none
	}
	if _, err := c.Mount("share", t.TempDir()); err == nil || !strings.Contains(err.Error(), "not registered") {
		t.Fatalf("mount before registration: %v", err)
	}
	if err := c.Unmount(t.TempDir()); err != nil {
		t.Fatalf("unmount of a plain folder: %v", err)
	}
}
