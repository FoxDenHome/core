// Package mounts mounts the owner's SMB shares for a desktop user. The
// daemon mounts as root, with sec=krb5 and cruid=<user>, so the kernel uses
// that user's Kerberos ticket; it only mounts onto empty directories the user
// owns and only unmounts the user's own SMB mounts.
package mounts

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// User is the local account a mount is for, from the control socket's peer
// credentials.
type User struct {
	UID, GID uint32
}

// Request is one mount.
type Request struct {
	Share provision.Share
	Path  string
	// AtHome allows SMB Direct, which never works through the tunnel.
	AtHome bool
}

// Mount is an active SMB mount of a user.
type Mount struct {
	Source    string `json:"source"`
	Path      string `json:"path"`
	Transport string `json:"transport"`
}

// attempt is one set of mount options to try.
type attempt struct {
	host      string
	options   []string
	transport string
}

// attempts lists option sets, best first: SMB Direct with multichannel,
// SMB Direct, TCP with multichannel, plain TCP. The first that mounts wins.
func attempts(req Request, u User, rdma bool) []attempt {
	base := []string{
		"vers=3.1.1",
		"sec=krb5",
		fmt.Sprintf("cruid=%d", u.UID),
		fmt.Sprintf("uid=%d", u.UID),
		fmt.Sprintf("gid=%d", u.GID),
		"forceuid", "forcegid",
		// Mounted by root on the user's behalf.
		"nosuid", "nodev",
	}
	if req.Share.Home {
		base = append(base, "file_mode=0600", "dir_mode=0700")
	} else {
		base = append(base, "file_mode=0644", "dir_mode=0755")
	}
	with := func(extra ...string) []string { return append(append([]string(nil), base...), extra...) }
	multichannel := []string{"multichannel", "max_channels=4"}

	var out []attempt
	if rdma && req.Share.RDMAHost != "" {
		out = append(out,
			attempt{req.Share.RDMAHost, with(append([]string{"rdma"}, multichannel...)...), "SMB Direct, multichannel"},
			attempt{req.Share.RDMAHost, with("rdma"), "SMB Direct"},
		)
	}
	return append(out,
		attempt{req.Share.Host, with(multichannel...), "TCP, multichannel"},
		attempt{req.Share.Host, with(), "TCP"},
	)
}

func source(host, share string) string { return "//" + host + "/" + share }

// validShareName keeps share names from smuggling anything into the source.
func validShareName(s string) bool {
	return s != "" && !strings.ContainsAny(s, "/\\,\x00") && len(s) < 81
}

// Mounter does the system work; Linux only.
type Mounter interface {
	Mount(ctx context.Context, u User, req Request) (Mount, error)
	Unmount(u User, path string) error
	List(u User) ([]Mount, error)
}

var ErrUnsupported = errors.New("mounting shares is not supported on this system")
