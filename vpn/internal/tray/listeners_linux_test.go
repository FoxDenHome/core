package tray

import (
	"net/netip"
	"strings"
	"testing"
)

func TestParseProcNetTCP(t *testing.T) {
	tcp := `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0000000000000000 100 0 0 10 0
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 222 1 0000000000000000 100 0 0 10 0
   2: 0501A8C0:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 333 1 0000000000000000 100 0 0 10 0
   3: 0100007F:0BB8 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 444 1 0000000000000000 100 0 0 10 0
`
	tcp6 := `  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1538 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555 1 0000000000000000 100 0 0 10 0
   1: 0000000000000000FFFF00000100007F:0050 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 666 1 0000000000000000 100 0 0 10 0
`
	var got []string
	for _, in := range []string{tcp, tcp6} {
		socks, err := parseProcNetTCP(strings.NewReader(in))
		if err != nil {
			t.Fatal(err)
		}
		for _, s := range socks {
			got = append(got, netip.AddrPortFrom(s.Addr, uint16(s.Port)).String()+"#"+s.inode)
		}
	}
	want := "127.0.0.1:3000#111 0.0.0.0:22#222 192.168.1.5:8080#333 [::1]:5432#555 127.0.0.1:80#666"
	if strings.Join(got, " ") != want {
		t.Fatalf("got  %s\nwant %s", strings.Join(got, " "), want)
	}
}
