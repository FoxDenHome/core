package daemon

import (
	"net"
	"os"
	"path/filepath"
	"testing"
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
