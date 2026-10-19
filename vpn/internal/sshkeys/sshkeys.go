// Package sshkeys reads and edits OpenSSH authorized_keys files. Edits keep
// every line they do not touch as it was, comments and options included.
package sshkeys

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Key is one public key, as written in an authorized_keys line.
type Key struct {
	// Options precede the key, as in `from="10.0.0.0/8" ssh-ed25519 …`.
	Options string
	Type    string
	Blob    string // base64
	Comment string
	// Fingerprint is OpenSSH's SHA256 fingerprint, "SHA256:…".
	Fingerprint string
}

// Line is a line of an authorized_keys file. Key is nil for blank lines and
// comments, and Err is set for lines that are neither nor a valid key.
type Line struct {
	Number int // from 1
	Text   string
	Key    *Key
	Err    error
}

// keyType reports whether s names a key type sshd accepts, plain or as a
// certificate.
func keyType(s string) bool {
	s = strings.TrimSuffix(s, "-cert-v01@openssh.com")
	switch s {
	case "ssh-ed25519", "ssh-rsa", "ssh-dss",
		"ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
		"sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com":
		return true
	}
	return false
}

// ParseKey parses one key, with or without options: an authorized_keys line
// or the contents of a .pub file.
func ParseKey(s string) (*Key, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("empty key")
	}
	var k Key
	if f := strings.Fields(s); !keyType(f[0]) {
		opts, rest, err := cutOptions(s)
		if err != nil {
			return nil, err
		}
		k.Options, s = opts, rest
	}
	f := strings.Fields(s)
	if len(f) < 2 {
		return nil, errors.New("not an SSH public key")
	}
	if !keyType(f[0]) {
		return nil, fmt.Errorf("unknown key type %q", f[0])
	}
	blob, err := base64.StdEncoding.DecodeString(f[1])
	if err != nil {
		return nil, errors.New("the key is not valid base64")
	}
	// The blob starts with its own type, as an SSH string.
	if len(blob) < 4 {
		return nil, errors.New("the key is truncated")
	}
	n := binary.BigEndian.Uint32(blob)
	if uint64(n) > uint64(len(blob)-4) || string(blob[4:4+n]) != f[0] {
		return nil, fmt.Errorf("the key data is not a %s key", f[0])
	}
	k.Type, k.Blob = f[0], f[1]
	k.Comment = strings.Join(f[2:], " ")
	sum := sha256.Sum256(blob)
	k.Fingerprint = "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
	return &k, nil
}

// cutOptions splits the options off an authorized_keys line: up to the
// first space outside double quotes.
func cutOptions(s string) (opts, rest string, err error) {
	quoted := false
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\' && quoted && i+1 < len(s):
			i++
		case c == '"':
			quoted = !quoted
		case (c == ' ' || c == '\t') && !quoted:
			return s[:i], strings.TrimLeft(s[i:], " \t"), nil
		}
	}
	return "", "", errors.New("not an SSH public key")
}

// String is the key as an authorized_keys line.
func (k *Key) String() string {
	s := k.Type + " " + k.Blob
	if k.Options != "" {
		s = k.Options + " " + s
	}
	if k.Comment != "" {
		s += " " + k.Comment
	}
	return s
}

// Parse splits an authorized_keys file into its lines.
func Parse(data []byte) []Line {
	text := strings.TrimSuffix(string(data), "\n")
	if text == "" {
		return nil
	}
	var out []Line
	for i, t := range strings.Split(text, "\n") {
		t = strings.TrimSuffix(t, "\r")
		l := Line{Number: i + 1, Text: t}
		if s := strings.TrimSpace(t); s != "" && !strings.HasPrefix(s, "#") {
			l.Key, l.Err = ParseKey(s)
		}
		out = append(out, l)
	}
	return out
}

// Edit removes the lines numbered in remove from data and appends add,
// skipping keys that are already there. Every other line stays as it was.
func Edit(data []byte, remove []int, add []string) ([]byte, error) {
	drop := map[int]bool{}
	for _, n := range remove {
		drop[n] = true
	}
	var out []string
	have := map[string]bool{}
	for _, l := range Parse(data) {
		if drop[l.Number] {
			continue
		}
		if l.Key != nil {
			have[l.Key.Fingerprint] = true
		}
		out = append(out, l.Text)
	}
	for _, a := range add {
		k, err := ParseKey(a)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", short(a), err)
		}
		if have[k.Fingerprint] {
			continue
		}
		have[k.Fingerprint] = true
		out = append(out, k.String())
	}
	if len(out) == 0 {
		return nil, nil
	}
	return []byte(strings.Join(out, "\n") + "\n"), nil
}

// Check reports the first line of data that is neither a key, a comment nor
// blank.
func Check(data []byte) error {
	for _, l := range Parse(data) {
		if l.Err != nil {
			return fmt.Errorf("line %d (%s): %w", l.Number, short(l.Text), l.Err)
		}
	}
	return nil
}

func short(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 40 {
		return s[:37] + "…"
	}
	return s
}

// ErrLinked means the file is a symbolic link, most likely to a file that is
// managed elsewhere (by home-manager, say), so it is not written.
var ErrLinked = errors.New("is a symbolic link")

// Read reads the file at path; a missing file reads as empty.
func Read(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return b, err
}

// Linked reports where path links to, or "" if it is not a symbolic link.
func Linked(path string) string {
	fi, err := os.Lstat(path)
	if err != nil || fi.Mode()&fs.ModeSymlink == 0 {
		return ""
	}
	if target, err := os.Readlink(path); err == nil {
		return target
	}
	return "?"
}

// Write replaces the file at path with data, atomically. The file keeps its
// mode, and a new one, and its directory, are private, as sshd's StrictModes
// wants.
func Write(path string, data []byte) error {
	if target := Linked(path); target != "" {
		return fmt.Errorf("%s %w to %s", path, ErrLinked, target)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	mode := fs.FileMode(0o600)
	if fi, err := os.Stat(path); err == nil {
		mode = fi.Mode().Perm() &^ 0o022
	}
	f, err := os.CreateTemp(dir, ".authorized_keys-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name()) // after a failure
	_, err = f.Write(data)
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
