package sources

import (
	"errors"

	"github.com/gopacket/gopacket/layers"
)

// TZSP encapsulations (https://en.wikipedia.org/wiki/TZSP)
const (
	tzspEncapEthernet = 1
	tzspEncap80211    = 18
	tzspEncapRawIP    = 7
)

// decodeTZSP strips the TZSP header from a datagram as RouterOS sends it
// (version 1, type "received tag list", encapsulation, then tagged fields
// until END).
func decodeTZSP(b []byte) (layers.LinkType, []byte, error) {
	if len(b) < 4 {
		return 0, nil, errors.New("short TZSP header")
	}
	if b[0] != 1 {
		return 0, nil, errors.New("unknown TZSP version")
	}
	encap := int(b[2])<<8 | int(b[3])
	i := 4
	for {
		if i >= len(b) {
			return 0, nil, errors.New("TZSP tags run past the end")
		}
		tag := b[i]
		i++
		if tag == 1 { // END
			break
		}
		if tag == 0 { // PADDING
			continue
		}
		if i >= len(b) {
			return 0, nil, errors.New("TZSP tag without length")
		}
		i += 1 + int(b[i])
	}
	payload := b[i:]
	switch encap {
	case tzspEncapEthernet:
		return layers.LinkTypeEthernet, payload, nil
	case tzspEncap80211:
		return layers.LinkTypeIEEE802_11, payload, nil
	case tzspEncapRawIP:
		return layers.LinkTypeRaw, payload, nil
	}
	// Unknown encapsulation: guess raw IP from the version nibble
	if len(payload) > 0 && (payload[0]>>4 == 4 || payload[0]>>4 == 6) {
		return layers.LinkTypeRaw, payload, nil
	}
	return 0, nil, errors.New("unsupported TZSP encapsulation")
}
