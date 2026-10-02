package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/user"
	"strconv"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// Serve exposes the control API on a unix socket. Access is controlled by the
// socket's group: anyone in it can see status and flip settings.
func (d *Daemon) Serve(ctx context.Context, socket, group string) error {
	_ = os.Remove(socket)
	l, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	gid := -1
	if group != "" {
		g, err := user.LookupGroup(group)
		if err != nil {
			l.Close()
			return fmt.Errorf("socket group: %w", err)
		}
		gid, _ = strconv.Atoi(g.Gid)
	}
	if err := os.Chown(socket, 0, gid); err != nil {
		log.Printf("chown %s: %v", socket, err)
	}
	if err := os.Chmod(socket, 0o660); err != nil {
		l.Close()
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, d.Status())
	})
	mux.HandleFunc("POST /v1/settings", func(w http.ResponseWriter, r *http.Request) {
		var u api.SettingsUpdate
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&u); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		st, err := d.Update(u)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, st)
	})
	mux.HandleFunc("POST /v1/refresh", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, d.Refresh(r.Context()))
	})
	mux.HandleFunc("POST /v1/kerberos/cert", func(w http.ResponseWriter, r *http.Request) {
		var req api.KerberosCertRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		cert, err := d.KerberosCert(r.Context(), req.PublicKey)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		writeJSON(w, cert)
	})
	mux.HandleFunc("POST /v1/enroll/start", func(w http.ResponseWriter, r *http.Request) {
		var req api.EnrollStartRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		st, err := d.EnrollStart(req.Regenerate)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, st)
	})
	mux.HandleFunc("POST /v1/enroll/complete", func(w http.ResponseWriter, r *http.Request) {
		var req api.EnrollCompleteRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := d.EnrollComplete(r.Context(), req.Token, req.Challenge); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, d.Status())
	})

	d.mountHandlers(mux)
	srv := &http.Server{Handler: mux, ConnContext: withPeer}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	err = srv.Serve(l)
	_ = os.Remove(socket)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
