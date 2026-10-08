package expose

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/quic-go/quic-go"
)

// Ticket is what the daemon hands out per connection: the portal's ticket
// and where the edge's control service is (reached through the tunnel).
type Ticket struct {
	Ticket     string
	Edges      []string // host:port
	ServerName string
}

// Client keeps one tunnel open and connects its streams to Target.
type Client struct {
	Target string
	// Hello is what to ask for; Ticket is filled in per connection.
	Hello Hello
	// Ticket gets a fresh ticket for each connection.
	Ticket func(context.Context) (Ticket, error)
	// Edges and ServerName override the ticket's.
	Edges      []string
	ServerName string
	// TLS is the base TLS configuration (nil: system roots).
	TLS *tls.Config
	// OnURL is called with the tunnel's address whenever it changes.
	OnURL func(url string)
	Logf  func(format string, args ...any)

	url string
}

func (c *Client) logf(format string, args ...any) {
	if c.Logf != nil {
		c.Logf(format, args...)
	} else {
		log.Printf(format, args...)
	}
}

// Run keeps the tunnel up, reconnecting (to the same name or port) until ctx
// ends. Only a first attempt that fails is fatal.
func (c *Client) Run(ctx context.Context) error {
	backoff := time.Second
	for {
		up, err := c.session(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if c.url == "" {
			return err
		}
		if up {
			backoff = time.Second
		}
		c.logf("disconnected (%v), reconnecting in %s", err, backoff)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}

// dialTimeout bounds connecting to one edge address.
const dialTimeout = 15 * time.Second

// connect dials the edge addresses in turn and opens the control stream.
func (c *Client) connect(ctx context.Context, t Ticket) (*quic.Conn, net.Conn, error) {
	edges, serverName := t.Edges, t.ServerName
	if len(c.Edges) > 0 {
		edges = c.Edges
	}
	if c.ServerName != "" {
		serverName = c.ServerName
	}
	if len(edges) == 0 {
		return nil, nil, errors.New("no edge to connect to")
	}
	tlsConf := &tls.Config{}
	if c.TLS != nil {
		tlsConf = c.TLS.Clone()
	}
	tlsConf.ServerName, tlsConf.NextProtos = serverName, []string{ALPN}

	var errs []error
	for _, addr := range edges {
		dctx, cancel := context.WithTimeout(ctx, dialTimeout)
		conn, err := quic.DialAddr(dctx, addr, tlsConf, QUICConfig(false))
		var st *quic.Stream
		if err == nil {
			if st, err = conn.OpenStreamSync(dctx); err != nil {
				_ = conn.CloseWithError(0, "")
			}
		}
		cancel()
		if err == nil {
			return conn, StreamConn(conn, st), nil
		}
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		errs = append(errs, fmt.Errorf("%s: %w", addr, err))
	}
	return nil, nil, errors.Join(errs...)
}

// session runs one connection to the edge. up reports whether it got as far
// as a working tunnel.
func (c *Client) session(ctx context.Context) (up bool, err error) {
	t, err := c.Ticket(ctx)
	if err != nil {
		return false, fmt.Errorf("getting a ticket: %w", err)
	}
	conn, ctl, err := c.connect(ctx, t)
	if err != nil {
		return false, err
	}
	defer conn.CloseWithError(0, "")

	_ = ctl.SetDeadline(time.Now().Add(HandshakeTimeout))
	hello := c.Hello
	hello.Ticket = t.Ticket
	if err := WriteMsg(ctl, hello); err != nil {
		return false, err
	}
	r := NewReader(ctl)
	var w Welcome
	if err := ReadMsg(r, &w); err != nil {
		return false, fmt.Errorf("handshake: %w", err)
	}
	if w.Error != "" {
		return false, fmt.Errorf("edge: %s", w.Error)
	}
	// The control stream stays open, unused, for the session's lifetime.
	_ = ctl.SetDeadline(time.Time{})

	if w.URL != c.url {
		c.url = w.URL
		if c.OnURL != nil {
			c.OnURL(w.URL)
		}
	} else {
		c.logf("reconnected")
	}
	// Ask for the same address after a reconnect.
	c.Hello.Name, c.Hello.Port = w.Name, w.Port

	for {
		st, err := conn.AcceptStream(ctx)
		if err != nil {
			return true, err
		}
		go c.handle(StreamConn(conn, st))
	}
}

func (c *Client) handle(st net.Conn) {
	_ = st.SetReadDeadline(time.Now().Add(HandshakeTimeout))
	r := NewReader(st)
	var h StreamHeader
	if err := ReadMsg(r, &h); err != nil {
		_ = st.Close()
		return
	}
	_ = st.SetReadDeadline(time.Time{})
	local, err := net.DialTimeout("tcp", c.Target, 10*time.Second)
	if err != nil {
		c.logf("%s: %v", h.Remote, err)
		_ = st.Close()
		return
	}
	c.logf("connection from %s", h.Remote)
	Pipe(&Conn{Conn: st, R: r}, local)
}
