package sources

import (
	"bytes"
	"testing"

	"github.com/gopacket/gopacket/layers"
)

func TestDecodeTZSP(t *testing.T) {
	frame := []byte{0xde, 0xad, 0xbe, 0xef}
	// version 1, type 0, encap Ethernet, padding, a 2-byte tag, END
	pkt := append([]byte{1, 0, 0, 1, 0, 10, 2, 0xaa, 0xbb, 1}, frame...)
	lt, payload, err := decodeTZSP(pkt)
	if err != nil {
		t.Fatal(err)
	}
	if lt != layers.LinkTypeEthernet || !bytes.Equal(payload, frame) {
		t.Errorf("got %v %x", lt, payload)
	}

	for _, bad := range [][]byte{{1, 0}, {2, 0, 0, 1, 1}, {1, 0, 0, 1, 10}, {1, 0, 0, 1, 10, 5, 1}} {
		if _, _, err := decodeTZSP(bad); err == nil {
			t.Errorf("%x: no error", bad)
		}
	}
}
