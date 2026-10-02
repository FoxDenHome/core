package mounts

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/provision"
)

var me = User{UID: uint32(os.Getuid()), GID: uint32(os.Getgid())}

var share = provision.Share{Name: "share", Host: "nas.foxden.network", RDMAHost: "nas-smb.foxden.network"}

func fakeLinux(t *testing.T, rdmaPort string) (*Linux, *[]string) {
	dir := t.TempDir()
	if rdmaPort != "" {
		p := filepath.Join(dir, "ib", "rocep13s0f0", "ports", "1")
		_ = os.MkdirAll(p, 0o755)
		_ = os.WriteFile(filepath.Join(p, "state"), []byte(rdmaPort+"\n"), 0o644)
	}
	_ = os.WriteFile(filepath.Join(dir, "mountinfo"), nil, 0o644)
	var calls []string
	return &Linux{
		MountCIFS: func(_ context.Context, src, path string, opts []string) error {
			calls = append(calls, src+" "+strings.Join(opts, ","))
			return nil
		},
		UnmountFn:   func(string) error { return nil },
		MountInfo:   filepath.Join(dir, "mountinfo"),
		RDMADevices: filepath.Join(dir, "ib"),
	}, &calls
}

func target(t *testing.T) string {
	p := filepath.Join(t.TempDir(), "NAS")
	if err := os.Mkdir(p, 0o755); err != nil {
		t.Fatal(err)
	}
	real, _ := filepath.EvalSymlinks(p)
	return real
}

func TestAttemptOrder(t *testing.T) {
	got := func(rdma bool, s provision.Share) (out []string) {
		for _, a := range attempts(Request{Share: s}, me, rdma) {
			out = append(out, a.host+" "+a.transport)
		}
		return
	}
	if g := got(true, share); !slices.Equal(g, []string{
		"nas-smb.foxden.network SMB Direct, multichannel", "nas-smb.foxden.network SMB Direct",
		"nas.foxden.network TCP, multichannel", "nas.foxden.network TCP",
	}) {
		t.Fatalf("with RDMA: %v", g)
	}
	if g := got(false, share); len(g) != 2 || strings.Contains(g[0], "Direct") {
		t.Fatalf("without RDMA: %v", g)
	}
	noRDMAHost := share
	noRDMAHost.RDMAHost = ""
	if g := got(true, noRDMAHost); len(g) != 2 {
		t.Fatalf("server without SMB Direct: %v", g)
	}
	opts := strings.Join(attempts(Request{Share: provision.Share{Name: "dori", Host: "h", Home: true}}, me, false)[0].options, ",")
	for _, want := range []string{"sec=krb5", fmt.Sprintf("cruid=%d", me.UID), "nosuid", "nodev", "file_mode=0600", "dir_mode=0700", "vers=3.1.1"} {
		if !strings.Contains(","+opts+",", ","+want+",") {
			t.Errorf("home share options %q lack %s", opts, want)
		}
	}
}

func TestMountPicksRDMAOnlyAtHomeWithActivePort(t *testing.T) {
	for _, c := range []struct {
		port   string
		atHome bool
		want   string
	}{
		{"4: ACTIVE", true, "//nas-smb.foxden.network/share"},
		{"4: ACTIVE", false, "//nas.foxden.network/share"},
		{"1: DOWN", true, "//nas.foxden.network/share"},
		{"", true, "//nas.foxden.network/share"},
	} {
		l, calls := fakeLinux(t, c.port)
		m, err := l.Mount(context.Background(), me, Request{Share: share, Path: target(t), AtHome: c.atHome})
		if err != nil || m.Source != c.want || !strings.HasPrefix((*calls)[0], c.want+" ") {
			t.Errorf("port %q home %v: %+v %v %v", c.port, c.atHome, m, err, *calls)
		}
	}
}

func TestMountFallsBack(t *testing.T) {
	l, calls := fakeLinux(t, "4: ACTIVE")
	l.MountCIFS = func(_ context.Context, src, _ string, opts []string) error {
		*calls = append(*calls, src+" "+strings.Join(opts, ","))
		if strings.Contains(strings.Join(opts, ","), "rdma") {
			return errors.New("mount error(112): Host is down")
		}
		return nil
	}
	m, err := l.Mount(context.Background(), me, Request{Share: share, Path: target(t), AtHome: true})
	if err != nil || m.Transport != "TCP, multichannel" || len(*calls) != 3 {
		t.Fatalf("%+v %v %v", m, err, *calls)
	}
	l.MountCIFS = func(context.Context, string, string, []string) error {
		return errors.New("mount error(13): Permission denied")
	}
	if _, err := l.Mount(context.Background(), me, Request{Share: share, Path: target(t), AtHome: true}); err == nil || !strings.Contains(err.Error(), "TCP: mount error(13)") {
		t.Fatalf("all failing: %v", err)
	}
}

func TestTargetChecks(t *testing.T) {
	l, calls := fakeLinux(t, "")
	full := target(t)
	_ = os.WriteFile(filepath.Join(full, "x"), nil, 0o644)
	link := filepath.Join(filepath.Dir(target(t)), "link")
	_ = os.Symlink(target(t), link)
	file := filepath.Join(target(t), "f")
	_ = os.WriteFile(file, nil, 0o644)
	for name, c := range map[string]struct {
		u    User
		path string
	}{
		"not empty": {me, full}, "symlink": {me, link}, "relative": {me, "NAS"}, "unclean": {me, full + "/../NAS"},
		"a file": {me, file}, "missing": {me, filepath.Join(full, "nope")}, "someone else's": {User{UID: me.UID + 1}, target(t)},
	} {
		if _, err := l.Mount(context.Background(), c.u, Request{Share: share, Path: c.path}); err == nil {
			t.Errorf("%s: mounted", name)
		}
	}
	if _, err := l.Mount(context.Background(), me, Request{Share: provision.Share{Name: "a,b", Host: "h"}, Path: target(t)}); err == nil {
		t.Error("share name with a comma accepted")
	}
	if len(*calls) != 0 {
		t.Fatalf("mount.cifs was run: %v", *calls)
	}
}

func TestListAndUnmountOnlyOwn(t *testing.T) {
	l, _ := fakeLinux(t, "")
	info := fmt.Sprintf(`22 1 0:21 / /proc rw - proc proc rw
90 30 0:55 / /home/me/NAS rw,nosuid,nodev - cifs //nas-smb.foxden.network/share rw,vers=3.1.1,sec=krb5,cruid=%[1]d,uid=%[1]d,rdma
91 30 0:56 / /home/other/NAS rw - cifs //nas.foxden.network/share rw,vers=3.1.1,sec=krb5,cruid=%[2]d,uid=%[2]d
92 30 0:57 / /home/me/My\040Home rw - cifs //nas.foxden.network/dori rw,vers=3.1.1,sec=krb5,cruid=%[1]d
`, me.UID, me.UID+1)
	_ = os.WriteFile(l.MountInfo, []byte(info), 0o644)
	list, err := l.List(me)
	if err != nil || len(list) != 2 || list[0].Transport != "SMB Direct" || list[1].Path != "/home/me/My Home" {
		t.Fatalf("list: %+v %v", list, err)
	}
	var unmounted []string
	l.UnmountFn = func(p string) error { unmounted = append(unmounted, p); return nil }
	if err := l.Unmount(me, "/home/other/NAS"); err == nil {
		t.Fatal("unmounted someone else's share")
	}
	if err := l.Unmount(me, "/proc"); err == nil {
		t.Fatal("unmounted a non-SMB mount")
	}
	if err := l.Unmount(me, "/home/me/NAS"); err != nil || !slices.Equal(unmounted, []string{"/home/me/NAS"}) {
		t.Fatalf("own unmount: %v %v", err, unmounted)
	}
}
