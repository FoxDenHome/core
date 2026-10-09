// Package buildid identifies a build by hashing its executable, which works
// the same for go build, make and Nix (Nix builds carry no VCS stamp).
package buildid

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// File returns the build ID of the executable at path, or "" if unreadable.
// Symlinks are followed, so a profile link reports what it points to now.
func File(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// Self returns the build ID of the running executable. It is read once, so
// it keeps describing this process after the file on disk is replaced; call
// it at start.
var Self = sync.OnceValue(func() string {
	if p := SelfPath(); p != "" {
		return File(p)
	}
	return ""
})

// SelfPath returns where the running executable is, with symlinks
// resolved: on Nix the store path, inside its app bundle on macOS. It is
// read once, like Self.
var SelfPath = sync.OnceValue(func() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if p, err := filepath.EvalSymlinks(exe); err == nil {
		return p
	}
	return exe
})
