package services

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
)

// System is how installers touch the machine, so tests can point them at a
// scratch root and fake commands.
type System struct {
	// Root is prefixed to every absolute path ("" for the real system).
	Root string
	// Run executes a command and returns its combined output.
	Run func(ctx context.Context, name string, args ...string) (string, error)
	// LookupUser returns uid and gid of a system user.
	LookupUser func(name string) (uid, gid int, err error)
	Chown      func(path string, uid, gid int) error
}

func DefaultSystem() *System {
	return &System{
		Run: func(ctx context.Context, name string, args ...string) (string, error) {
			out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
			if err != nil {
				return string(out), fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
			}
			return string(out), nil
		},
		LookupUser: func(name string) (int, int, error) {
			u, err := user.Lookup(name)
			if err != nil {
				return 0, 0, err
			}
			uid, _ := strconv.Atoi(u.Uid)
			gid, _ := strconv.Atoi(u.Gid)
			return uid, gid, nil
		},
		Chown: os.Chown,
	}
}

func (s *System) path(p string) string { return filepath.Join(s.Root, p) }

func (s *System) exists(p string) bool {
	_, err := os.Stat(s.path(p))
	return err == nil
}

// writeFile makes p contain data with the given mode, reporting whether it
// had to change anything.
func (s *System) writeFile(p string, data []byte, mode os.FileMode) (bool, error) {
	full := s.path(p)
	if cur, err := os.ReadFile(full); err == nil && bytes.Equal(cur, data) {
		if fi, err := os.Stat(full); err == nil && fi.Mode().Perm() == mode {
			return false, nil
		}
		return true, os.Chmod(full, mode)
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return false, err
	}
	tmp := full + ".foxden-new"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return false, err
	}
	if err := os.Chmod(tmp, mode); err != nil { // WriteFile's mode is subject to umask
		return false, err
	}
	return true, os.Rename(tmp, full)
}

// installBinary copies src to p (mode 0755) unless it is already identical.
func (s *System) installBinary(src, p string) (bool, error) {
	want, err := fileSHA256(src)
	if err != nil {
		return false, err
	}
	if have, err := fileSHA256(s.path(p)); err == nil && have == want {
		return false, nil
	}
	in, err := os.Open(src)
	if err != nil {
		return false, err
	}
	defer in.Close()
	full := s.path(p)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return false, err
	}
	tmp := full + ".foxden-new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return false, err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return false, err
	}
	if err := out.Close(); err != nil {
		return false, err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return false, err
	}
	// Rename over the old binary: a running process keeps its old inode.
	return true, os.Rename(tmp, full)
}

func (s *System) remove(p string) error {
	err := os.Remove(s.path(p))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (s *System) systemctl(ctx context.Context, args ...string) (string, error) {
	return s.Run(ctx, "systemctl", args...)
}
