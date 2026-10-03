package main

import "github.com/FoxDenHome/core/vpn/internal/api"

// daemonMounter has the daemon mount as root with the user's ticket
// (sec=krb5,cruid=<uid>).
type daemonMounter struct{ t *tray }

func newShareMounter(t *tray) shareMounter { return daemonMounter{t} }

func (m daemonMounter) Mounts() ([]api.Mount, error) { return m.t.client.Mounts() }
func (m daemonMounter) Mount(sh api.Share, path string) (*api.Mount, error) {
	return m.t.client.Mount(sh.Name, path)
}
func (m daemonMounter) Unmount(path string) error { return m.t.client.Unmount(path) }
