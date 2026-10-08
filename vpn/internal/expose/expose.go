// Package expose is the protocol between `foxden-vpnd expose` and
// foxden-vpn-edge, which publishes local ports of VPN devices like ngrok:
//
//  1. The CLI gets a short-lived ticket from the daemon, which proves the
//     device to the portal with its WireGuard key (the key never leaves the
//     daemon), plus where the edge's control service is.
//  2. The CLI connects to the control service over QUIC with ALPN ALPN and
//     opens the control stream. It sends a Hello with the ticket and what it
//     wants exposed. The edge checks the ticket with the portal and answers
//     with a Welcome.
//  3. For every public connection the edge then opens a stream, writes a
//     StreamHeader and splices the bytes; the CLI connects each stream to
//     the local port.
//
// The control service is not reachable from the internet, only through the
// VPN or from the LAN; the edge never dials devices, and routers need no
// change per tunnel.
package expose

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"regexp"
	"sync"
	"time"
)

// ALPN identifies the control protocol.
const ALPN = "foxden-expose/1"

const (
	// KindHTTP gets a random host name under the edge's domain. The edge
	// terminates TLS and forwards plain bytes (HTTP or anything else).
	KindHTTP = "http"
	// KindTCP gets a random public TCP port and forwards it as is.
	KindTCP = "tcp"
)

// Hello is the CLI's first message.
type Hello struct {
	Ticket string `json:"ticket"`
	Kind   string `json:"kind"`
	// Name asks for a host name label (KindHTTP), Port for a port (KindTCP).
	// Both are optional; reconnecting clients ask for what they had.
	Name string `json:"name,omitempty"`
	Port int    `json:"port,omitempty"`
}

// Welcome is the edge's answer to Hello. On error the connection closes.
type Welcome struct {
	Error string `json:"error,omitempty"`
	// URL is what to hand out, e.g. https://abc.tunnel.f0x.es or
	// tcp://tunnel.f0x.es:30042.
	URL  string `json:"url,omitempty"`
	Name string `json:"name,omitempty"`
	Port int    `json:"port,omitempty"`
}

// StreamHeader precedes the data on every stream the edge opens.
type StreamHeader struct {
	// Remote is the public client's address.
	Remote string `json:"remote"`
}

const maxMessage = 16 << 10

// HandshakeTimeout bounds the Hello/Welcome exchange.
const HandshakeTimeout = 30 * time.Second

func WriteMsg(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

// ReadMsg reads one newline-terminated JSON message.
func ReadMsg(r *bufio.Reader, v any) error {
	line, err := r.ReadSlice('\n')
	if errors.Is(err, bufio.ErrBufferFull) {
		return errors.New("message too long")
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(line, v)
}

// NewReader returns a reader sized for messages; wrap the connection with
// Conn afterwards so nothing it buffered is lost.
func NewReader(c net.Conn) *bufio.Reader { return bufio.NewReaderSize(c, maxMessage) }

// Conn is a net.Conn whose reads come through a bufio.Reader.
type Conn struct {
	net.Conn
	R *bufio.Reader
}

func (c *Conn) Read(b []byte) (int, error) { return c.R.Read(b) }
func (c *Conn) CloseWrite() error          { return CloseWrite(c.Conn) }

var nameRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`)

// ValidName reports whether s can be a host name label under the edge.
func ValidName(s string) bool { return nameRE.MatchString(s) }

// CloseWrite half-closes c where it can, and closes it otherwise.
func CloseWrite(c net.Conn) error {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return c.Close()
}

// Pipe copies both ways until both directions are done, then closes both.
func Pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		_ = CloseWrite(dst)
	}
	wg.Add(2)
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}
