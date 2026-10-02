package daemon

import (
	"net"

	"github.com/FoxDenHome/core/vpn/internal/mounts"
	"golang.org/x/sys/unix"
)

// peerUser is the local user on the other end of a control socket
// connection, as the kernel reports it.
func peerUser(c net.Conn) (mounts.User, bool) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return mounts.User{}, false
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return mounts.User{}, false
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil || credErr != nil {
		return mounts.User{}, false
	}
	return mounts.User{UID: cred.Uid, GID: cred.Gid}, true
}
