//go:build !linux

package daemon

import (
	"net"

	"github.com/FoxDenHome/core/vpn/internal/mounts"
)

func peerUser(net.Conn) (mounts.User, bool) { return mounts.User{}, false }
