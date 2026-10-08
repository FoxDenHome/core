package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
)

// PROXY protocol v2, as foxIngress sends it in front of every connection.

var proxySig = []byte{0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A}

// proxiedConn reports the client address from the PROXY header.
type proxiedConn struct {
	net.Conn
	remote net.Addr
}

func (c *proxiedConn) RemoteAddr() net.Addr { return c.remote }

func (c *proxiedConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return c.Conn.Close()
}

// readProxyHeader consumes a PROXY v2 header from c. A LOCAL command (health
// checks) keeps the connection's own address.
func readProxyHeader(c net.Conn) (net.Conn, error) {
	var hdr [16]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil {
		return nil, err
	}
	if !bytes.Equal(hdr[:12], proxySig) || hdr[12]>>4 != 2 {
		return nil, errors.New("not a PROXY v2 header")
	}
	body := make([]byte, binary.BigEndian.Uint16(hdr[14:16]))
	if _, err := io.ReadFull(c, body); err != nil {
		return nil, err
	}
	switch hdr[12] & 0x0f {
	case 0: // LOCAL
		return c, nil
	case 1: // PROXY
	default:
		return nil, errors.New("unknown PROXY command")
	}
	var src netip.AddrPort
	switch hdr[13] {
	case 0x11: // TCP over IPv4
		if len(body) < 12 {
			return nil, errors.New("short PROXY header")
		}
		src = netip.AddrPortFrom(netip.AddrFrom4([4]byte(body[0:4])), binary.BigEndian.Uint16(body[8:10]))
	case 0x21: // TCP over IPv6
		if len(body) < 36 {
			return nil, errors.New("short PROXY header")
		}
		src = netip.AddrPortFrom(netip.AddrFrom16([16]byte(body[0:16])).Unmap(), binary.BigEndian.Uint16(body[32:34]))
	default:
		return c, nil // UNSPEC or a family we do not care about
	}
	return &proxiedConn{Conn: c, remote: net.TCPAddrFromAddrPort(src)}, nil
}
