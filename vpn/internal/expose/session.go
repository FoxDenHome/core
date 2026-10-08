package expose

import (
	"net"
	"time"

	"github.com/quic-go/quic-go"
)

// QUICConfig is the QUIC configuration of both ends. The device accepts a
// stream per public connection; the edge only the one control stream.
func QUICConfig(edge bool) *quic.Config {
	c := &quic.Config{
		KeepAlivePeriod:       20 * time.Second,
		MaxIdleTimeout:        time.Minute,
		MaxIncomingStreams:    1000,
		MaxIncomingUniStreams: -1,
	}
	if edge {
		c.MaxIncomingStreams = 1
	}
	return c
}

// quicStream makes a QUIC stream a net.Conn. CloseWrite is the stream's own
// half close; Close also stops reading.
type quicStream struct {
	*quic.Stream
	c *quic.Conn
}

// StreamConn makes a stream of c a net.Conn.
func StreamConn(c *quic.Conn, s *quic.Stream) net.Conn { return &quicStream{Stream: s, c: c} }

func (s *quicStream) LocalAddr() net.Addr  { return s.c.LocalAddr() }
func (s *quicStream) RemoteAddr() net.Addr { return s.c.RemoteAddr() }
func (s *quicStream) CloseWrite() error    { return s.Stream.Close() }

func (s *quicStream) Close() error {
	s.CancelRead(0)
	return s.Stream.Close()
}
