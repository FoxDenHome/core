// Package registrytest provides a fake RouterOS for tests.
package registrytest

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/FoxDenHome/core/vpn/internal/routeros"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Router is an in-memory RouterOS with just enough of /print semantics.
type Router struct {
	Tables map[string][]routeros.Row
	NextID int
	Ops    []string
}

func New() *Router {
	server, _ := wgtypes.GeneratePrivateKey()
	f := &Router{Tables: map[string][]routeros.Row{}}
	f.Tables["/interface/wireguard"] = []routeros.Row{{
		".id": "*1", "name": "wg-vpn", "listen-port": "13231", "mtu": "1280",
		"private-key": server.String(), "public-key": server.PublicKey().String(),
	}}
	f.Tables["/ip/address"] = []routeros.Row{
		{"address": "10.100.0.1/16", "interface": "wg-vpn"},
		{"address": "10.2.1.1/16", "interface": "vlan-lan"},
		{"address": "10.2.6.1/24", "interface": "vlan-lan"},
		{"address": "10.2.0.53/32", "interface": "vrrp-lan-dns"},
		{"address": "10.1.1.1/16", "interface": "vlan-mgmt", "disabled": "true"},
	}
	f.Tables["/ipv6/address"] = []routeros.Row{
		{"address": "fd2c:f4cb:63be::a64:1/112", "interface": "wg-vpn"},
		{"address": "fe80::1/64", "interface": "vlan-lan"},
		{"address": "::2:0:0:0:1/64", "interface": "vlan-lan"},
		{"address": "2a0e:7d44:f069:a02::1/64", "interface": "vlan-lan"},
	}
	f.NextID = 100
	return f
}

func (f *Router) Print(_ context.Context, path string, q routeros.Row) ([]routeros.Row, error) {
	var out []routeros.Row
	for _, r := range f.Tables[path] {
		match := true
		for k, v := range q {
			if r[k] != v {
				match = false
			}
		}
		if match {
			out = append(out, r)
		}
	}
	return out, nil
}

// conflict mimics RouterOS refusing duplicate peer names and keys.
func (f *Router) conflict(path, id string, a routeros.Row) error {
	if path != "/interface/wireguard/peers" {
		return nil
	}
	for _, r := range f.Tables[path] {
		if r[".id"] == id {
			continue
		}
		if n, ok := a["name"]; ok && r["name"] == n {
			return errors.New("failure: entry with this name already exists")
		}
		if k, ok := a["public-key"]; ok && r["public-key"] == k && r["interface"] == a["interface"] {
			return errors.New("failure: peer with this public key already exists")
		}
	}
	return nil
}

func (f *Router) Add(_ context.Context, path string, a routeros.Row) error {
	if err := f.conflict(path, "", a); err != nil {
		return err
	}
	r := routeros.Row{".id": fmt.Sprintf("*%X", f.NextID)}
	f.NextID++
	for k, v := range a {
		r[k] = v
	}
	f.Tables[path] = append(f.Tables[path], r)
	f.Ops = append(f.Ops, "add")
	return nil
}

func (f *Router) find(path, id string) int {
	return slices.IndexFunc(f.Tables[path], func(r routeros.Row) bool { return r[".id"] == id })
}

func (f *Router) Set(_ context.Context, path, id string, a routeros.Row) error {
	i := f.find(path, id)
	if i < 0 {
		return fmt.Errorf("no such item %s", id)
	}
	if err := f.conflict(path, id, a); err != nil {
		return err
	}
	for k, v := range a {
		f.Tables[path][i][k] = v
	}
	f.Ops = append(f.Ops, "set")
	return nil
}

func (f *Router) Remove(_ context.Context, path, id string) error {
	i := f.find(path, id)
	if i < 0 {
		return fmt.Errorf("no such item %s", id)
	}
	f.Tables[path] = slices.Delete(f.Tables[path], i, i+1)
	f.Ops = append(f.Ops, "remove")
	return nil
}

func (f *Router) Close() error { return nil }
