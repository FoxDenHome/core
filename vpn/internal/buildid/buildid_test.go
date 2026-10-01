package buildid

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFile(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	_ = os.WriteFile(a, []byte("one"), 0o755)
	_ = os.WriteFile(b, []byte("two"), 0o755)
	if File(a) == "" || File(a) == File(b) || File(a) != File(a) {
		t.Fatal("build IDs must be stable and distinguish contents")
	}
	link := filepath.Join(dir, "link")
	_ = os.Symlink(a, link)
	if File(link) != File(a) {
		t.Fatal("symlinks must be followed")
	}
	if File(filepath.Join(dir, "missing")) != "" {
		t.Fatal("missing file must give an empty ID")
	}
	if Self() == "" {
		t.Fatal("no ID for the running test binary")
	}
}
