//go:build linux || darwin

package tunnel

import (
	"errors"
	"log"
	"net"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/ipc"
	"golang.zx2c4.com/wireguard/tun"
)

// userspaceDevice runs wireguard-go in-process and exposes the standard UAPI
// socket, so wgctrl drives it exactly like a kernel device.
type userspaceDevice struct {
	dev  *device.Device
	uapi net.Listener
	name string
}

func startUserspace(name string, mtu int) (*userspaceDevice, error) {
	tdev, err := tun.CreateTUN(name, mtu)
	if err != nil {
		return nil, err
	}
	realName, err := tdev.Name()
	if err != nil {
		tdev.Close()
		return nil, err
	}
	f, err := ipc.UAPIOpen(realName)
	if err != nil {
		tdev.Close()
		return nil, err
	}
	logger := device.NewLogger(device.LogLevelError, "wireguard-go("+realName+"): ")
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), logger)
	l, err := ipc.UAPIListen(realName, f)
	if err != nil {
		dev.Close()
		return nil, err
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				if !errors.Is(err, net.ErrClosed) {
					log.Printf("wireguard-go: uapi accept: %v", err)
				}
				return
			}
			go dev.IpcHandle(c)
		}
	}()
	if err := dev.Up(); err != nil {
		l.Close()
		dev.Close()
		return nil, err
	}
	return &userspaceDevice{dev: dev, uapi: l, name: realName}, nil
}

func (u *userspaceDevice) Close() {
	u.uapi.Close()
	u.dev.Close()
}
