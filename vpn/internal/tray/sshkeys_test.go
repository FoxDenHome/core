package tray

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/kanidm"
)

const (
	testKeyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDYYt3MdHLz2FnZ3A23KXRfall7dBn5AYHrShCEyGBO a@laptop"
	testKeyB = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGk1P2R0aD1hCQjJPRC3sXcyUuArt3sAHHeW0+QVoFSOK4jcoopnREYGD1SD70uh1XMFPCx7+YUp4pp7sMtHvw0= b@desk"
)

// sshKeysFixture is a home with an authorized_keys holding key A, a comment
// and a broken line, and key B in ~/.ssh/id_ecdsa.pub.
func sshKeysFixture(t *testing.T) (path string, data []byte) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), ".ssh")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path = filepath.Join(dir, "authorized_keys")
	data = []byte("# keep me\n" + testKeyA + "\nbroken line\n")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "id_ecdsa.pub"), []byte(testKeyB+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path, data
}

func TestSSHKeysForm(t *testing.T) {
	path, data := sshKeysFixture(t)
	kk := []kanidm.SSHKey{{Tag: "laptop", Key: testKeyA}, {Tag: "desk", Key: testKeyB}, {Tag: "junk", Key: "nope"}}
	f := newSSHKeysForm(path, data, "fox", kk, nil)

	if len(f.Local) != 2 || f.Local[0].Line != 2 || f.Local[0].Also != "kanidm" || f.Local[1].Invalid == "" {
		t.Errorf("local: %+v", f.Local)
	}
	if len(f.Kanidm) != 2 || f.Kanidm[0].Also != "local" || f.Kanidm[1].Also != "" || f.Kanidm[1].Tag != "desk" {
		t.Errorf("kanidm: %+v", f.Kanidm)
	}
	if len(f.Own) != 1 || f.Own[0].Tag != "id_ecdsa.pub" || f.Own[0].Comment != "b@desk" {
		t.Errorf("own: %+v", f.Own)
	}
	if f.ReadOnly != "" || f.KanidmError != "" {
		t.Errorf("read only %q, Kanidm error %q", f.ReadOnly, f.KanidmError)
	}
	if ref := f.reference(); !strings.Contains(ref, "of fox") || !strings.Contains(ref, testKeyB) {
		t.Errorf("reference: %q", ref)
	}

	// Remove A and the broken line, add B: the comment stays.
	out, err := f.apply(sshKeysAnswer{Remove: []int{2, 3}, Add: []string{testKeyB}})
	if err != nil || string(out) != "# keep me\n"+testKeyB+"\n" {
		t.Errorf("apply: %q, %v", out, err)
	}
	if _, err := f.apply(sshKeysAnswer{Add: []string{"ssh-ed25519 nope"}}); err == nil {
		t.Error("bad key added")
	}
	text := "  " + testKeyB + "\n\n"
	if out, err := f.apply(sshKeysAnswer{Text: &text}); err != nil || string(out) != "  "+testKeyB+"\n" {
		t.Errorf("apply text: %q, %v", out, err)
	}
	text = string(data)
	if _, err := f.apply(sshKeysAnswer{Text: &text}); err == nil || !strings.Contains(err.Error(), "line 3") {
		t.Errorf("broken text: %v", err)
	}

	if f := newSSHKeysForm(path, data, "", nil, nil); f.KanidmError == "" {
		t.Error("no hint without a Kanidm user")
	}
	if f := newSSHKeysForm(path, data, "fox", nil, errors.New("Kanidm: down")); f.KanidmError != "Kanidm: down" {
		t.Errorf("Kanidm error %q", f.KanidmError)
	}

	link := filepath.Join(filepath.Dir(path), "linked")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if f := newSSHKeysForm(link, data, "fox", nil, nil); !strings.Contains(f.ReadOnly, path) {
		t.Errorf("read only: %q", f.ReadOnly)
	}
}

func TestSavedMessage(t *testing.T) {
	for _, c := range []struct{ before, after, want string }{
		{testKeyA + "\n", testKeyB + "\n", "authorized_keys saved: 1 key added, 1 key removed."},
		{"", testKeyA + "\n" + testKeyB + "\n", "authorized_keys saved: 2 keys added."},
		{testKeyA + "\n", "# hi\n" + testKeyA + "\n", "authorized_keys saved."},
	} {
		if got := savedMessage([]byte(c.before), []byte(c.after)); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}
