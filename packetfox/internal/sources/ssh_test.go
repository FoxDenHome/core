package sources

import (
	"crypto/ed25519"
	"net"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/ssh"
)

func newKey(t *testing.T) ssh.PublicKey {
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	k, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestKnownHostsTOFU(t *testing.T) {
	kh := &KnownHosts{Path: filepath.Join(t.TempDir(), "known_hosts")}
	addr := &net.TCPAddr{IP: net.IPv4(10, 1, 2, 3), Port: 22}
	a, b := newKey(t), newKey(t)
	cb := kh.callback(nil)
	if err := cb("ap.example:22", addr, a); err != nil {
		t.Fatalf("first use: %v", err)
	}
	if err := cb("ap.example:22", addr, a); err != nil {
		t.Fatalf("pinned key: %v", err)
	}
	if err := cb("ap.example:22", addr, b); err == nil {
		t.Fatal("changed key accepted")
	}
	if err := cb("other.example:22", addr, b); err != nil {
		t.Fatalf("other host first use: %v", err)
	}
}
