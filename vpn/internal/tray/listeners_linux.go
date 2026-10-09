package tray

import (
	"bufio"
	"encoding/hex"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// listenSockets reads the TCP sockets listening in our network namespace
// from /proc, with the name of the process owning each where it is one of
// ours (other users' /proc/<pid>/fd cannot be read).
func listenSockets() ([]listenSocket, error) {
	var out []listenSocket
	inodes := map[string][]int{} // inode -> indexes into out
	for _, f := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		fh, err := os.Open(f)
		if err != nil {
			if os.IsNotExist(err) {
				continue // no IPv6
			}
			return nil, err
		}
		socks, err := parseProcNetTCP(fh)
		_ = fh.Close()
		if err != nil {
			return nil, err
		}
		for _, s := range socks {
			inodes[s.inode] = append(inodes[s.inode], len(out))
			out = append(out, s.listenSocket)
		}
	}
	for inode, name := range socketOwners(inodes) {
		for _, i := range inodes[inode] {
			out[i].Process = name
		}
	}
	return out, nil
}

type procSocket struct {
	listenSocket
	inode string
}

const tcpListen = "0A"

// parseProcNetTCP parses /proc/net/tcp or tcp6, keeping listening sockets.
func parseProcNetTCP(r io.Reader) ([]procSocket, error) {
	var out []procSocket
	sc := bufio.NewScanner(r)
	sc.Scan() // header
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 10 || f[3] != tcpListen {
			continue
		}
		hostHex, portHex, ok := strings.Cut(f[1], ":")
		if !ok {
			continue
		}
		port, err := strconv.ParseUint(portHex, 16, 16)
		if err != nil {
			continue
		}
		addr, ok := procAddr(hostHex)
		if !ok {
			continue
		}
		out = append(out, procSocket{listenSocket{Addr: addr, Port: int(port)}, f[9]})
	}
	return out, sc.Err()
}

// procAddr decodes an address from /proc/net/tcp*: 32-bit words in host
// (little-endian) byte order.
func procAddr(h string) (netip.Addr, bool) {
	b, err := hex.DecodeString(h)
	if err != nil || (len(b) != 4 && len(b) != 16) {
		return netip.Addr{}, false
	}
	for i := 0; i < len(b); i += 4 {
		b[i], b[i+1], b[i+2], b[i+3] = b[i+3], b[i+2], b[i+1], b[i]
	}
	a, _ := netip.AddrFromSlice(b)
	return a.Unmap(), true
}

// ownerCache remembers socket owners between scans; most scans find the
// same sockets, and walking every fd of every process is the slow part.
var ownerCache = map[string]string{}

// socketOwners maps the inodes to the command names of the processes that
// hold them, as far as we can see.
func socketOwners(inodes map[string][]int) map[string]string {
	out := map[string]string{}
	missing := false
	for inode := range inodes {
		if name, ok := ownerCache[inode]; ok {
			out[inode] = name
		} else {
			missing = true
		}
	}
	if !missing {
		return out
	}
	want := map[string]bool{}
	for inode := range inodes {
		want["socket:["+inode+"]"] = true
	}
	found := map[string]string{}
	procs, _ := filepath.Glob("/proc/[0-9]*")
	for _, p := range procs {
		fds, err := os.ReadDir(p + "/fd")
		if err != nil {
			continue
		}
		var comm string
		for _, fd := range fds {
			l, err := os.Readlink(p + "/fd/" + fd.Name())
			if err != nil || !want[l] {
				continue
			}
			if comm == "" {
				b, _ := os.ReadFile(p + "/comm")
				comm = strings.TrimSpace(string(b))
			}
			found[strings.TrimSuffix(strings.TrimPrefix(l, "socket:["), "]")] = comm
		}
	}
	// Unknown owners are cached too (as ""), so other users' sockets do
	// not make every scan walk /proc again.
	clear(ownerCache)
	for inode := range inodes {
		ownerCache[inode] = found[inode]
		out[inode] = found[inode]
	}
	return out
}

// ephemeralPorts returns where the kernel's range for automatically
// assigned ports starts.
func ephemeralPorts() int {
	b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_port_range")
	if err == nil {
		if f := strings.Fields(string(b)); len(f) > 0 {
			if n, err := strconv.Atoi(f[0]); err == nil {
				return n
			}
		}
	}
	return 32768
}
