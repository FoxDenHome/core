package tray

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"golang.org/x/sys/unix"
)

// smbfsMounter mounts as the logged-in user, which macOS allows on folders
// the user owns. The SMB client then authenticates with the user's own
// Kerberos ticket, which a root daemon cannot reach. macOS has no SMB
// Direct and uses multichannel on its own.
type smbfsMounter struct{ t *tray }

func newShareMounter(t *tray) shareMounter { return smbfsMounter{t} }

func cString(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

// Mounts lists this user's SMB mounts.
func (smbfsMounter) Mounts() ([]api.Mount, error) {
	n, err := unix.Getfsstat(nil, unix.MNT_NOWAIT)
	if err != nil {
		return nil, err
	}
	buf := make([]unix.Statfs_t, n+8)
	n, err = unix.Getfsstat(buf, unix.MNT_NOWAIT)
	if err != nil {
		return nil, err
	}
	uid := uint32(os.Getuid())
	out := []api.Mount{}
	for _, f := range buf[:n] {
		if cString(f.Fstypename[:]) != "smbfs" || f.Owner != uid {
			continue
		}
		out = append(out, api.Mount{Source: cString(f.Mntfromname[:]), Path: cString(f.Mntonname[:]), Transport: "TCP"})
	}
	return out, nil
}

func (m smbfsMounter) mountedAt(path string) (*api.Mount, error) {
	list, err := m.Mounts()
	if err != nil {
		return nil, err
	}
	for _, x := range list {
		if x.Path == path {
			return &x, nil
		}
	}
	return nil, nil
}

func (m smbfsMounter) Mount(sh api.Share, path string) (*api.Mount, error) {
	if sh.Host == "" {
		return nil, errors.New("the VPN service did not say which server has this share; update it")
	}
	if sh.Name == "" || strings.ContainsAny(sh.Name, "/\\@:;?#%\x00") || len(sh.Name) > 80 {
		return nil, errors.New("invalid share")
	}
	// Without a ticket, mount_smbfs -N would just fail; mounting resumes
	// once the ticket is there.
	user := ""
	if m.t.krb != nil {
		user = m.t.krb.user()
	}
	if user == "" {
		return nil, errors.New("waiting for a Kerberos ticket")
	}
	if cur, err := m.mountedAt(path); err != nil {
		return nil, err
	} else if cur != nil {
		return nil, errors.New("something is already mounted there")
	}
	src := "//" + user + "@" + sh.Host + "/" + sh.Name
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	// -N: never ask for a password; Kerberos or nothing.
	cmd := exec.CommandContext(ctx, "/sbin/mount_smbfs", "-N", src, path)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(out.String())
		msg = strings.TrimPrefix(msg, "mount_smbfs: ")
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	return &api.Mount{Source: src, Path: path, Transport: "TCP"}, nil
}

func (m smbfsMounter) Unmount(path string) error {
	cur, err := m.mountedAt(path)
	if err != nil {
		return err
	}
	if cur == nil {
		return nil // already gone
	}
	if err := unix.Unmount(path, 0); err != nil {
		if errors.Is(err, syscall.EBUSY) {
			return errors.New("the share is in use; close files and windows using it first")
		}
		return err
	}
	return nil
}
