package daemon

import (
	"net"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

func bindToInterface(iface string) func(network, address string, c syscall.RawConn) error {
	return func(network, _ string, c syscall.RawConn) error {
		ifc, err := net.InterfaceByName(iface)
		if err != nil {
			return err
		}
		var serr error
		err = c.Control(func(fd uintptr) {
			if strings.HasSuffix(network, "6") {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, ifc.Index)
			} else {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, ifc.Index)
			}
		})
		if err != nil {
			return err
		}
		return serr
	}
}
