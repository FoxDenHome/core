// Package provision implements the client side of the FoxDen VPN provisioning
// protocol.
//
// For every peer on the routers' wg-vpn interface, mikrotik/configure/vpn.py
// publishes a blob at <base>/<hex(sha256(peer public key))>. The blob is a
// NaCl box (Curve25519/XSalsa20/Poly1305) from the wg-vpn server key to the
// peer key, laid out as nonce(24) || ciphertext. WireGuard keys are plain
// Curve25519 keys, so no extra key material is needed: only the peer can open
// it, and only the holder of the server key can have produced it.
package provision

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/crypto/nacl/box"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

const Version = 1

var ErrNotProvisioned = errors.New("public key is not registered on the VPN server yet")

type Server struct {
	PublicKey    string `json:"public_key"`
	PresharedKey string `json:"preshared_key,omitempty"`
	Host         string `json:"host"`
	Port         uint16 `json:"port"`
}

type DNS struct {
	Servers []netip.Addr `json:"servers"`
	Domains []string     `json:"domains"`
}

type Network struct {
	Name     string         `json:"name"`
	Prefixes []netip.Prefix `json:"prefixes"`
	// DNS lists the on-LAN resolvers of this network, used to detect whether
	// we are at home.
	DNS []netip.Addr `json:"dns,omitempty"`
}

// Share is an SMB share the device's owner may mount.
type Share struct {
	Name    string `json:"name"`
	Comment string `json:"comment,omitempty"`
	// Host serves SMB over TCP; RDMAHost (optional) also over SMB Direct.
	Host     string `json:"host"`
	RDMAHost string `json:"rdma_host,omitempty"`
	// Home marks a share private to the owner.
	Home bool `json:"home,omitempty"`
}

// Launcher is what the tray's Servers menu offers: SSH sessions, web UIs and
// KVM consoles, the latter two logging in with JIT RADIUS credentials.
type Launcher struct {
	Hosts []LaunchHost `json:"hosts,omitempty"`
	// JITRadius is oauth-jit-radius, which hands out RADIUS credentials for
	// a Kerberos ticket at <JITRadius>/api/credentials.
	JITRadius string `json:"jit_radius,omitempty"`
}

// LaunchHost is one host and what can be opened on it.
type LaunchHost struct {
	Name string `json:"name"`
	// SSH is the host name to ssh to.
	SSH string `json:"ssh,omitempty"`
	Web *WebUI `json:"web,omitempty"`
	KVM *KVM   `json:"kvm,omitempty"`
}

type WebUI struct {
	URL string `json:"url"`
	// Radius marks a web UI that takes JIT RADIUS credentials.
	Radius bool `json:"radius,omitempty"`
}

// KVM is the NetCmdr IP KVM switch port a host's console is on.
type KVM struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

type Config struct {
	Version   int            `json:"version"`
	Name      string         `json:"name"`
	Addresses []netip.Prefix `json:"addresses"`
	MTU       int            `json:"mtu"`
	Server    Server         `json:"server"`
	DNS       DNS            `json:"dns"`
	// VPNPrefixes are routed through the tunnel when away from home (the VPN
	// subnet itself).
	VPNPrefixes []netip.Prefix `json:"vpn_prefixes"`
	// InternalPrefixes are what the home DNS answers vpn.foxden.network with.
	InternalPrefixes []netip.Prefix `json:"internal_prefixes"`
	Networks         []Network      `json:"networks"`
	Shares           []Share        `json:"shares,omitempty"`
	Launcher         *Launcher      `json:"launcher,omitempty"`
	Expose           *Expose        `json:"expose,omitempty"`
}

// Expose is where foxden-vpn-edge's control service is: internal addresses,
// reached through the tunnel like the rest of their network, or directly at
// home.
type Expose struct {
	Addresses []netip.Addr `json:"addresses"`
	Port      uint16       `json:"port"`
	// ServerName is the name on the edge's certificate.
	ServerName string `json:"server_name"`
}

func (c *Config) IsInternal(a netip.Addr) bool {
	a = a.Unmap()
	for _, p := range c.InternalPrefixes {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func (c *Config) Validate() error {
	if c.Version != Version {
		return fmt.Errorf("unsupported provisioning version %d", c.Version)
	}
	if len(c.Addresses) == 0 {
		return errors.New("no addresses assigned")
	}
	if c.Server.Host == "" || c.Server.Port == 0 {
		return errors.New("no server endpoint")
	}
	if _, err := wgtypes.ParseKey(c.Server.PublicKey); err != nil {
		return fmt.Errorf("server public key: %w", err)
	}
	if c.MTU == 0 {
		c.MTU = 1280
	}
	return nil
}

func BlobName(pub wgtypes.Key) string {
	sum := sha256.Sum256(pub[:])
	return hex.EncodeToString(sum[:])
}

func Open(blob []byte, priv wgtypes.Key, serverPub wgtypes.Key) (*Config, error) {
	plain, err := openRaw(blob, priv, serverPub)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(plain, &cfg); err != nil {
		return nil, fmt.Errorf("decoding provisioning blob: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// openRaw opens nonce(24) || box from peer to priv.
func openRaw(blob []byte, priv wgtypes.Key, peerPub wgtypes.Key) ([]byte, error) {
	if len(blob) < 24+box.Overhead {
		return nil, errors.New("sealed data too short")
	}
	var nonce [24]byte
	copy(nonce[:], blob[:24])
	pk := [32]byte(peerPub)
	sk := [32]byte(priv)
	plain, ok := box.Open(nil, blob[24:], &nonce, &pk, &sk)
	if !ok {
		return nil, errors.New("sealed data failed authentication (wrong server key?)")
	}
	return plain, nil
}

func Fetch(ctx context.Context, baseURL string, priv wgtypes.Key, serverPub wgtypes.Key) (*Config, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	url := strings.TrimSuffix(baseURL, "/") + "/" + BlobName(priv.PublicKey())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNotProvisioned
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("provisioning server returned %s", resp.Status)
	}
	blob, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return Open(blob, priv, serverPub)
}

// Seal is the server side of Open: it boxes cfg from the server key to peer.
func Seal(cfg *Config, server wgtypes.Key, peer wgtypes.Key) ([]byte, error) {
	plain, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	return sealRaw(plain, server, peer)
}

func sealRaw(plain []byte, server wgtypes.Key, peer wgtypes.Key) ([]byte, error) {
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	pk, sk := [32]byte(peer), [32]byte(server)
	return box.Seal(nonce[:], plain, &nonce, &pk, &sk), nil
}

// OpenAsServer decrypts a blob previously sealed for peer, so the publisher
// can tell whether it is still current (sealing is randomized).
func OpenAsServer(blob []byte, server wgtypes.Key, peer wgtypes.Key) (*Config, error) {
	return Open(blob, server, peer)
}
