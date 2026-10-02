package daemon

import (
	"context"
	"encoding/json"
	"net"
	"net/http"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/mounts"
)

type peerKey struct{}

// withPeer remembers who is on the other end of each control connection.
func withPeer(ctx context.Context, c net.Conn) context.Context {
	if u, ok := peerUser(c); ok {
		return context.WithValue(ctx, peerKey{}, u)
	}
	return ctx
}

func peerFrom(r *http.Request) (mounts.User, bool) {
	u, ok := r.Context().Value(peerKey{}).(mounts.User)
	return u, ok
}

func (d *Daemon) mountHandlers(mux *http.ServeMux) {
	userOr403 := func(w http.ResponseWriter, r *http.Request) (mounts.User, bool) {
		u, ok := peerFrom(r)
		if !ok {
			http.Error(w, "cannot tell which user is asking", http.StatusForbidden)
		}
		return u, ok
	}
	mux.HandleFunc("GET /v1/mounts", func(w http.ResponseWriter, r *http.Request) {
		u, ok := userOr403(w, r)
		if !ok {
			return
		}
		list, err := d.mounter.List(u)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		out := []api.Mount{}
		for _, m := range list {
			out = append(out, api.Mount{Source: m.Source, Path: m.Path, Transport: m.Transport})
		}
		writeJSON(w, out)
	})
	mux.HandleFunc("POST /v1/mounts", func(w http.ResponseWriter, r *http.Request) {
		u, ok := userOr403(w, r)
		if !ok {
			return
		}
		var req api.MountRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		d.mu.Lock()
		prov, atHome := d.prov, d.location == api.LocationLAN
		d.mu.Unlock()
		if prov == nil {
			http.Error(w, "this device is not registered", http.StatusConflict)
			return
		}
		for _, s := range prov.Shares {
			if s.Name != req.Share {
				continue
			}
			m, err := d.mounter.Mount(r.Context(), u, mounts.Request{Share: s, Path: req.Path, AtHome: atHome})
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			writeJSON(w, api.Mount{Source: m.Source, Path: m.Path, Transport: m.Transport})
			return
		}
		http.Error(w, "unknown share", http.StatusNotFound)
	})
	mux.HandleFunc("POST /v1/mounts/unmount", func(w http.ResponseWriter, r *http.Request) {
		u, ok := userOr403(w, r)
		if !ok {
			return
		}
		var req api.MountRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := d.mounter.Unmount(u, req.Path); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, struct{}{})
	})
}
