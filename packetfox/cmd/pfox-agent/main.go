// pfox-agent is the forced command of the pfox user on NixOS hosts. It
// lists every network namespace on the host with its interfaces, and runs
// tcpdump in one of them, writing pcap to stdout.
//
// Namespaces are found three ways:
//
//   - the root netns ("-")
//   - named ones in /run/netns (foxDen hosts are host-<name>; services,
//     OCI containers and SR-IOV VFs live in those)
//   - every other netns some process is in ("ns-<inode>"), such as units
//     with PrivateNetwork=true or containers a runtime made on its own.
//     These are entered through /proc/<pid>/ns/net, like nsenter does.
//
// It runs through a NixOS security wrapper with CAP_NET_RAW, CAP_NET_ADMIN,
// CAP_SYS_ADMIN (setns) and CAP_SYS_PTRACE (opening other processes'
// namespaces). tcpdump gets only the first two.
//
// Commands (from SSH_ORIGINAL_COMMAND):
//
//	list
//	capture <netns|-> <iface> <snaplen> <base64url BPF|->
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"

	"github.com/FoxDenHome/core/packetfox/internal/filter"
)

// Set by the nix package
var tcpdumpPath = "tcpdump"

const netnsDir = "/run/netns"

var (
	nameRe  = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)
	anonRe  = regexp.MustCompile(`^ns-([0-9]{1,20})$`)
	ifaceRe = regexp.MustCompile(`^[A-Za-z0-9_.@-]{1,15}$`)
)

type iface struct {
	Netns string `json:"netns"`
	// What the netns is: its name, or the unit or container whose
	// process holds it
	Label string `json:"label"`
	Iface string `json:"iface"`
	// physical, sriov-vf, sriov-pf, macvlan, macvtap, veth, bridge, …
	Kind string `json:"kind"`
	Up   bool   `json:"up"`
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "pfox-agent: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	args := os.Args[1:]
	if cmd, ok := os.LookupEnv("SSH_ORIGINAL_COMMAND"); ok {
		args = strings.Fields(cmd)
	}
	if len(args) == 0 {
		fail("no command")
	}
	switch args[0] {
	case "list":
		if len(args) != 1 {
			fail("usage: list")
		}
		list()
	case "capture":
		if len(args) != 5 {
			fail("usage: capture <netns|-> <iface> <snaplen> <base64url BPF|->")
		}
		capture(args[1], args[2], args[3], args[4])
	default:
		fail("unknown command %q", args[0])
	}
}

func inode(path string) (uint64, error) {
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		return 0, err
	}
	return st.Ino, nil
}

type namespace struct {
	id, label, path string
}

// unitOf names what a process belongs to, from its cgroup.
func unitOf(pid string) string {
	raw, err := os.ReadFile("/proc/" + pid + "/cgroup")
	if err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
			path, ok := strings.CutPrefix(line, "0::")
			if !ok {
				continue
			}
			parts := strings.Split(path, "/")
			for i := len(parts) - 1; i >= 0; i-- {
				p := parts[i]
				switch {
				case strings.HasPrefix(p, "libpod-") && strings.HasSuffix(p, ".scope"):
					id := strings.TrimSuffix(strings.TrimPrefix(p, "libpod-"), ".scope")
					return "container " + id[:min(12, len(id))]
				case strings.HasSuffix(p, ".service"), strings.HasSuffix(p, ".scope") && !strings.HasPrefix(p, "session-"):
					return p
				}
			}
		}
	}
	comm, _ := os.ReadFile("/proc/" + pid + "/comm")
	return strings.TrimSpace(string(comm)) + " (pid " + pid + ")"
}

// pidsByInode maps netns inodes to the processes in them, lowest PID first.
func pidsByInode() map[uint64][]int {
	out := map[uint64][]int{}
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		ino, err := inode("/proc/" + e.Name() + "/ns/net")
		if err != nil {
			continue
		}
		out[ino] = append(out[ino], pid)
	}
	for _, pids := range out {
		sort.Ints(pids)
	}
	return out
}

func namespaces() []namespace {
	nss := []namespace{{id: "", label: "root netns", path: "/proc/self/ns/net"}}
	known := map[uint64]bool{}
	if ino, err := inode("/proc/self/ns/net"); err == nil {
		known[ino] = true
	}

	entries, _ := os.ReadDir(netnsDir)
	var named []namespace
	for _, e := range entries {
		if !nameRe.MatchString(e.Name()) {
			continue
		}
		path := filepath.Join(netnsDir, e.Name())
		ino, err := inode(path)
		if err != nil || known[ino] {
			continue
		}
		known[ino] = true
		named = append(named, namespace{id: e.Name(), label: e.Name(), path: path})
	}
	sort.Slice(named, func(a, b int) bool { return named[a].id < named[b].id })
	nss = append(nss, named...)

	var anon []namespace
	for ino, pids := range pidsByInode() {
		if known[ino] {
			continue
		}
		pid := strconv.Itoa(pids[0])
		anon = append(anon, namespace{
			id:    "ns-" + strconv.FormatUint(ino, 10),
			label: unitOf(pid),
			path:  "/proc/" + pid + "/ns/net",
		})
	}
	sort.Slice(anon, func(a, b int) bool { return anon[a].label < anon[b].label })
	return append(nss, anon...)
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// kindOf describes a link. /sys/bus/pci is the same in every netns, so
// SR-IOV functions are recognized even inside a service's netns.
func kindOf(l netlink.Link) string {
	kind := l.Type()
	if kind != "device" {
		return kind
	}
	a := l.Attrs()
	if a.ParentDevBus == "pci" && a.ParentDev != "" {
		dev := "/sys/bus/pci/devices/" + a.ParentDev
		if exists(dev + "/physfn") {
			return "sriov-vf"
		}
		if n, err := os.ReadFile(dev + "/sriov_numvfs"); err == nil && strings.TrimSpace(string(n)) != "0" {
			return "sriov-pf"
		}
	}
	if a.ParentDev != "" {
		return "physical"
	}
	return "device"
}

func interfaces(ns namespace) ([]iface, error) {
	var nl *netlink.Handle
	var err error
	if ns.id == "" {
		nl, err = netlink.NewHandle()
	} else {
		var h netns.NsHandle
		if h, err = netns.GetFromPath(ns.path); err != nil {
			return nil, err
		}
		defer h.Close()
		nl, err = netlink.NewHandleAt(h)
	}
	if err != nil {
		return nil, err
	}
	defer nl.Close()
	links, err := nl.LinkList()
	if err != nil {
		return nil, err
	}
	var out []iface
	for _, l := range links {
		a := l.Attrs()
		if a.Flags&net.FlagLoopback != 0 {
			continue
		}
		out = append(out, iface{
			Netns: ns.id, Label: ns.label, Iface: a.Name, Kind: kindOf(l),
			Up: a.Flags&net.FlagUp != 0,
		})
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Iface < out[b].Iface })
	return out, nil
}

func list() {
	out := []iface{}
	for _, ns := range namespaces() {
		ifs, err := interfaces(ns)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pfox-agent: %s: %v\n", ns.label, err)
			continue
		}
		out = append(out, ifs...)
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}

// openNetns opens a netns by the ID list gave it.
func openNetns(id string) (int, error) {
	if m := anonRe.FindStringSubmatch(id); m != nil {
		want, _ := strconv.ParseUint(m[1], 10, 64)
		for _, pid := range pidsByInode()[want] {
			fd, err := unix.Open(fmt.Sprintf("/proc/%d/ns/net", pid), unix.O_RDONLY|unix.O_CLOEXEC, 0)
			if err != nil {
				continue
			}
			// The process may have exited and its PID been reused
			var st unix.Stat_t
			if unix.Fstat(fd, &st) == nil && st.Ino == want {
				return fd, nil
			}
			unix.Close(fd)
		}
		return -1, fmt.Errorf("netns %s is gone", id)
	}
	if !nameRe.MatchString(id) {
		return -1, fmt.Errorf("invalid netns %q", id)
	}
	fd, err := unix.Open(netnsDir+"/"+id, unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("netns %s: %w", id, err)
	}
	return fd, nil
}

func capture(nsID, ifName, snaplenStr, bpfB64 string) {
	snaplen, err := strconv.Atoi(snaplenStr)
	if err != nil || snaplen < 1 || snaplen > 262144 {
		fail("invalid snaplen")
	}
	if ifName != "any" && !ifaceRe.MatchString(ifName) {
		fail("invalid interface")
	}
	bpf := ""
	if bpfB64 != "-" {
		raw, err := base64.RawURLEncoding.DecodeString(bpfB64)
		if err != nil {
			fail("invalid BPF encoding")
		}
		bpf = string(raw)
	}
	if !filter.ValidBPF(bpf) {
		fail("BPF expression contains forbidden characters")
	}

	// tcpdump inherits the netns of the thread that execs it
	runtime.LockOSThread()
	if nsID != "-" {
		fd, err := openNetns(nsID)
		if err != nil {
			fail("%v", err)
		}
		if err := unix.Setns(fd, unix.CLONE_NEWNET); err != nil {
			fail("entering netns %s: %v", nsID, err)
		}
		unix.Close(fd)
	}
	if ifName != "any" {
		if _, err := net.InterfaceByName(ifName); err != nil {
			fail("interface %s: %v", ifName, err)
		}
	}
	// tcpdump needs only the packet capture capabilities
	for _, c := range []uintptr{unix.CAP_SYS_ADMIN, unix.CAP_SYS_PTRACE} {
		if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_LOWER, c, 0, 0); err != nil && !errors.Is(err, unix.EINVAL) {
			fail("dropping capability %d: %v", c, err)
		}
	}

	argv := []string{
		tcpdumpPath, "-i", ifName, "-n", "-p", "-U", "--immediate-mode",
		"--time-stamp-precision=nano", "-s", strconv.Itoa(snaplen), "-w", "-",
	}
	if bpf != "" {
		argv = append(argv, "--", bpf)
	}
	err = syscall.Exec(tcpdumpPath, argv, []string{"PATH=/run/current-system/sw/bin"})
	fail("exec tcpdump: %v", err)
}
