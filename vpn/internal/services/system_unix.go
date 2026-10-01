//go:build linux || darwin

package services

import "os"

func mkdirOwned(sys *System, p string, uid, gid int) error {
	if err := os.MkdirAll(sys.path(p), 0o755); err != nil {
		return err
	}
	return sys.Chown(sys.path(p), uid, gid)
}

func chmodOwned(sys *System, p string, mode os.FileMode, uid, gid int) error {
	if err := os.Chmod(sys.path(p), mode); err != nil {
		return err
	}
	return sys.Chown(sys.path(p), uid, gid)
}
