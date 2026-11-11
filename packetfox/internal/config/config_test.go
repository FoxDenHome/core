package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	raw := `{
		"collector": {"ipv4": "10.2.11.45", "ipv6": "fd2c:f4cb:63be:2::b2d", "base_port": 37008},
		"routers": [{"name": "router", "address": "router.foxden.network:8728", "username": "pfox", "addresses": ["10.2.1.1/16", "10.2.0.1"]}],
		"endpoints": [{"name": "fennec", "system": "landevices", "netns": "", "interfaces": [{"name": "default", "addresses": ["10.2.10.1/16", "fd2c:f4cb:63be:2::a01/64"], "mac": null, "fqdns": ["fennec.foxden.network"]}]}],
		"limits": {"max_duration": "30m", "max_packets": 1000, "max_sessions": 5}
	}`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ROUTEROS_PASSWORD", "secret")
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Limits.MaxDuration.Duration != 30*time.Minute || cfg.Limits.MaxPackets != 1000 {
		t.Errorf("limits %+v", cfg.Limits)
	}
	if cfg.Listen != "127.0.0.1:1447" || cfg.RouterOSPassword != "secret" {
		t.Errorf("defaults/env: %q %q", cfg.Listen, cfg.RouterOSPassword)
	}
	if a := cfg.Endpoints[0].Addrs(); len(a) != 2 || a[0].String() != "10.2.10.1" {
		t.Errorf("addrs %v", a)
	}
}
