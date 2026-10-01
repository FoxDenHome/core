package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

type Settings struct {
	Enabled          bool     `json:"enabled"`
	Mode             string   `json:"mode"`
	DisabledNetworks []string `json:"disabled_networks"`
}

func defaultSettings() Settings {
	return Settings{Enabled: true, Mode: api.ModeSplit}
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// loadOrCreateKey returns the device's private key, generating one on first start.
func loadOrCreateKey(dir string) (wgtypes.Key, bool, error) {
	path := filepath.Join(dir, "private.key")
	b, err := os.ReadFile(path)
	if err == nil {
		k, err := wgtypes.ParseKey(strings.TrimSpace(string(b)))
		return k, false, err
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return wgtypes.Key{}, false, err
	}
	k, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		return wgtypes.Key{}, false, err
	}
	if err := writeFileAtomic(path, []byte(k.String()+"\n"), 0o600); err != nil {
		return wgtypes.Key{}, false, err
	}
	return k, true, nil
}

func loadSettings(dir string) Settings {
	s := defaultSettings()
	b, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err == nil {
		_ = json.Unmarshal(b, &s)
	}
	if s.Mode != api.ModeFull {
		s.Mode = api.ModeSplit
	}
	return s
}

func saveSettings(dir string, s Settings) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, "settings.json"), b, 0o600)
}

const provisionCache = "provision.json"

func loadProvision(dir string) *provision.Config {
	b, err := os.ReadFile(filepath.Join(dir, provisionCache))
	if err != nil {
		return nil
	}
	var c provision.Config
	if json.Unmarshal(b, &c) != nil || c.Validate() != nil {
		return nil
	}
	return &c
}

func saveProvision(dir string, c *provision.Config) error {
	path := filepath.Join(dir, provisionCache)
	if c == nil {
		err := os.Remove(path)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileAtomic(path, b, 0o600); err != nil {
		return fmt.Errorf("caching provisioning data: %w", err)
	}
	return nil
}
