package sshkeys

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	ed25519Key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDYYt3MdHLz2FnZ3A23KXRfall7dBn5AYHrShCEyGBO test@a"
	ed25519FP  = "SHA256:0Gh2Ph0zLTJf2A9FXRtd6sF76H/KGloVS9jrLU3ZywA"
	ecdsaKey   = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGk1P2R0aD1hCQjJPRC3sXcyUuArt3sAHHeW0+QVoFSOK4jcoopnREYGD1SD70uh1XMFPCx7+YUp4pp7sMtHvw0= b"
	ecdsaFP    = "SHA256:h+l5yEDVl65rgMWlVXNsJiBJYfldqBPC0jVv+i+6xoc"
)

func TestParseKey(t *testing.T) {
	k, err := ParseKey("  " + ed25519Key + "  \n")
	if err != nil {
		t.Fatal(err)
	}
	if k.Type != "ssh-ed25519" || k.Comment != "test@a" || k.Fingerprint != ed25519FP || k.Options != "" {
		t.Errorf("got %+v", k)
	}
	if k.String() != ed25519Key {
		t.Errorf("String() = %q", k.String())
	}

	opts := `from="10.0.0.0/8,192.168.1.1",command="echo \"a b\"",no-pty`
	k, err = ParseKey(opts + " " + ecdsaKey)
	if err != nil {
		t.Fatal(err)
	}
	if k.Options != opts || k.Fingerprint != ecdsaFP || k.Comment != "b" {
		t.Errorf("got %+v", k)
	}
	if k.String() != opts+" "+ecdsaKey {
		t.Errorf("String() = %q", k.String())
	}

	k, err = ParseKey(strings.TrimSuffix(ed25519Key, " test@a"))
	if err != nil || k.Comment != "" {
		t.Errorf("no comment: %+v, %v", k, err)
	}

	for _, bad := range []string{
		"",
		"hello world",
		"ssh-ed25519",
		"ssh-ed25519 !!!notbase64",
		"ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAICDYYt3MdHLz2FnZ3A23KXRfall7dBn5AYHrShCEyGBO", // an ed25519 blob
		"ssh-ed25519 AAAA",
		`from="unterminated ssh-ed25519 AAAA`,
	} {
		if _, err := ParseKey(bad); err == nil {
			t.Errorf("ParseKey(%q) accepted", bad)
		}
	}
}

func TestParse(t *testing.T) {
	data := "# mine\n" + ed25519Key + "\r\n\nnot a key\n" + ecdsaKey
	lines := Parse([]byte(data))
	if len(lines) != 5 {
		t.Fatalf("%d lines", len(lines))
	}
	if lines[0].Key != nil || lines[0].Err != nil || lines[2].Key != nil || lines[2].Err != nil {
		t.Error("comment or blank line taken for a key")
	}
	if lines[1].Key == nil || lines[1].Key.Fingerprint != ed25519FP || lines[1].Text != ed25519Key {
		t.Errorf("line 2: %+v", lines[1])
	}
	if lines[3].Err == nil {
		t.Error("garbage accepted")
	}
	if lines[4].Number != 5 || lines[4].Key == nil {
		t.Errorf("line 5: %+v", lines[4])
	}
	if err := Check([]byte(data)); err == nil || !strings.Contains(err.Error(), "line 4") {
		t.Errorf("Check: %v", err)
	}
	if err := Check([]byte("# x\n" + ed25519Key + "\n")); err != nil {
		t.Errorf("Check: %v", err)
	}
	if Parse(nil) != nil || Parse([]byte("\n")) != nil {
		t.Error("empty file has lines")
	}
}

func TestEdit(t *testing.T) {
	data := []byte("# mine\n" + ed25519Key + "\n" + ecdsaKey + "\n")
	out, err := Edit(data, []int{2}, []string{ed25519Key + " again", ecdsaKey, "  " + ed25519Key})
	if err != nil {
		t.Fatal(err)
	}
	// The removed key comes back once, at the end; the present one is not
	// added twice.
	want := "# mine\n" + ecdsaKey + "\n" + ed25519Key + " again\n"
	if string(out) != want {
		t.Errorf("got %q, want %q", out, want)
	}
	if _, err := Edit(data, nil, []string{"nope"}); err == nil {
		t.Error("bad key added")
	}
	out, err = Edit([]byte(ed25519Key+"\n"), []int{1}, nil)
	if err != nil || out != nil {
		t.Errorf("removing the last key: %q, %v", out, err)
	}
}

func TestWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".ssh", "authorized_keys")
	if b, err := Read(path); err != nil || b != nil {
		t.Fatalf("missing file: %q, %v", b, err)
	}
	if err := Write(path, []byte(ed25519Key+"\n")); err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]os.FileMode{path: 0o600, filepath.Dir(path): 0o700} {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != want {
			t.Errorf("%s: %v, %v", p, fi.Mode(), err)
		}
	}
	// A group-writable file would fail StrictModes; writing fixes it.
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	if err := Write(path, []byte(ecdsaKey+"\n")); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", fi.Mode())
	}
	if b, _ := Read(path); string(b) != ecdsaKey+"\n" {
		t.Errorf("read back %q", b)
	}

	link := filepath.Join(dir, "linked")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if Linked(link) != path || Linked(path) != "" {
		t.Error("Linked")
	}
	if err := Write(link, nil); !errors.Is(err, ErrLinked) {
		t.Errorf("wrote through a link: %v", err)
	}
	if entries, _ := os.ReadDir(filepath.Dir(path)); len(entries) != 1 {
		t.Errorf("left behind: %v", entries)
	}
}
