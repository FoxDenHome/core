package mounts

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Linux mounts with mount.cifs; cifs.upcall (from cifs-utils, via
// request-key) fetches the user's service ticket from their ccache.
type Linux struct {
	// MountCIFS runs mount.cifs; replaced in tests.
	MountCIFS func(ctx context.Context, source, path string, options []string) error
	// Unmount detaches path; replaced in tests.
	UnmountFn func(path string) error
	// MountInfo is /proc/self/mountinfo.
	MountInfo string
	// RDMADevices is /sys/class/infiniband.
	RDMADevices string
	// Resolve4 finds a host's IPv4 address; replaced in tests.
	Resolve4 func(ctx context.Context, host string) (string, error)

	// mu serializes mounts, so two requests for one folder cannot both pass
	// checkTarget and stack mounts.
	mu sync.Mutex
}

func New() *Linux {
	return &Linux{
		MountCIFS: runMountCIFS,
		UnmountFn: func(p string) error { return unix.Unmount(p, 0) },
		MountInfo: "/proc/self/mountinfo", RDMADevices: "/sys/class/infiniband",
		Resolve4: resolve4,
	}
}

func resolve4(ctx context.Context, host string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
	if err != nil {
		return "", err
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("%s has no IPv4 address", host)
	}
	return ips[0].String(), nil
}

func runMountCIFS(ctx context.Context, source, path string, options []string) error {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	bin, err := exec.LookPath("mount.cifs")
	if err != nil {
		return errors.New("mount.cifs not found, install cifs-utils")
	}
	cmd := exec.CommandContext(ctx, bin, source, path, "-o", strings.Join(options, ","))
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin"} // never prompt or pick up odd env
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(out.String()); msg != "" {
			return errors.New(msg)
		}
		return err
	}
	return nil
}

// RDMAActive reports whether any RDMA port is up.
func (l *Linux) RDMAActive() bool {
	ports, _ := filepath.Glob(filepath.Join(l.RDMADevices, "*", "ports", "*", "state"))
	for _, p := range ports {
		if b, err := os.ReadFile(p); err == nil && strings.Contains(string(b), "ACTIVE") {
			return true
		}
	}
	return false
}

// checkTarget allows only an existing, empty directory owned by u, reached
// without symlinks, that is not already a mount point.
func (l *Linux) checkTarget(u User, path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("the folder must be an absolute path")
	}
	if real, err := filepath.EvalSymlinks(path); err != nil || real != path {
		return errors.New("the folder must not be or contain a symlink")
	}
	var st unix.Stat_t
	if err := unix.Lstat(path, &st); err != nil {
		return fmt.Errorf("folder: %w", err)
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return errors.New("not a folder")
	}
	if st.Uid != u.UID {
		return errors.New("the folder must belong to you")
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	if len(entries) > 0 {
		return errors.New("the folder must be empty")
	}
	if m, _ := l.lookup(path); m != nil {
		return errors.New("something is already mounted there")
	}
	return nil
}

func (l *Linux) Mount(ctx context.Context, u User, req Request) (Mount, error) {
	if !validShareName(req.Share.Name) || req.Share.Host == "" {
		return Mount{}, errors.New("invalid share")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.checkTarget(u, req.Path); err != nil {
		return Mount{}, err
	}
	var rdmaIP string
	if req.AtHome && req.Share.RDMAHost != "" && l.RDMAActive() {
		ip, err := l.Resolve4(ctx, req.Share.RDMAHost)
		if err != nil {
			log.Printf("SMB Direct to %s: %v", req.Share.RDMAHost, err)
		}
		rdmaIP = ip
	}
	var errs []string
	for _, a := range attempts(req, u, rdmaIP) {
		src := source(a.host, req.Share.Name)
		err := l.MountCIFS(ctx, src, req.Path, a.options)
		if err == nil {
			return Mount{Source: src, Path: req.Path, Transport: a.transport}, nil
		}
		log.Printf("mounting %s with %s: %v", src, a.transport, err)
		errs = append(errs, a.transport+": "+err.Error())
		if ctx.Err() != nil {
			break
		}
	}
	return Mount{}, errors.New(errs[len(errs)-1]) // the most basic attempt's reason
}

type mountEntry struct {
	path, source, fstype, options string
}

func unescapeMountinfo(s string) string {
	r := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return r.Replace(s)
}

func (l *Linux) entries() ([]mountEntry, error) {
	f, err := os.Open(l.MountInfo)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []mountEntry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		// id parent dev root mountpoint opts [optional...] - fstype source superopts
		fields := strings.Fields(sc.Text())
		sep := -1
		for i, f := range fields {
			if f == "-" {
				sep = i
				break
			}
		}
		if sep < 5 || len(fields) < sep+4 {
			continue
		}
		out = append(out, mountEntry{
			path: unescapeMountinfo(fields[4]), fstype: fields[sep+1],
			source: unescapeMountinfo(fields[sep+2]), options: fields[sep+3],
		})
	}
	return out, sc.Err()
}

func (l *Linux) lookup(path string) (*mountEntry, error) {
	es, err := l.entries()
	if err != nil {
		return nil, err
	}
	for i := len(es) - 1; i >= 0; i-- { // the topmost mount wins
		if es[i].path == path {
			return &es[i], nil
		}
	}
	return nil, nil
}

func ownedBy(e mountEntry, u User) bool {
	if e.fstype != "cifs" && e.fstype != "smb3" {
		return false
	}
	for _, o := range strings.Split(e.options, ",") {
		if o == fmt.Sprintf("cruid=%d", u.UID) {
			return true
		}
	}
	return false
}

func (l *Linux) List(u User) ([]Mount, error) {
	es, err := l.entries()
	if err != nil {
		return nil, err
	}
	var out []Mount
	for _, e := range es {
		if ownedBy(e, u) {
			transport := "TCP"
			if strings.Contains(","+e.options+",", ",rdma,") {
				transport = "SMB Direct"
			}
			out = append(out, Mount{Source: e.source, Path: e.path, Transport: transport})
		}
	}
	return out, nil
}

func (l *Linux) Unmount(u User, path string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, err := l.lookup(path)
	if err != nil {
		return err
	}
	if e == nil {
		return nil // already gone
	}
	if !ownedBy(*e, u) {
		return errors.New("that is not one of your SMB mounts")
	}
	if err := l.UnmountFn(path); err != nil {
		if errors.Is(err, syscall.EBUSY) {
			return errors.New("the share is in use; close files and windows using it first")
		}
		return err
	}
	return nil
}
