// Package web serves the UI and its JSON API. It sits behind nginx and
// oauth2-proxy, which only let Kanidm superadmins through and pass the user
// in X-Preferred-Username.
package web

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"strconv"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/journey"
	"github.com/FoxDenHome/core/packetfox/internal/session"
	"github.com/FoxDenHome/core/packetfox/internal/sharkd"
)

//go:embed static
var static embed.FS

type Server struct {
	cfg *config.Config
	mgr *session.Manager
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func user(r *http.Request) string {
	if u := r.Header.Get("X-Preferred-Username"); u != "" {
		return u
	}
	return r.Header.Get("X-User")
}

func intParam(r *http.Request, name string, def, max int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil || v < 0 {
		return def
	}
	return min(v, max)
}

func Handler(cfg *config.Config, mgr *session.Manager) http.Handler {
	s := &Server{cfg: cfg, mgr: mgr}
	mux := http.NewServeMux()
	sub, _ := fs.Sub(static, "static")
	mux.Handle("GET /", http.FileServerFS(sub))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok\n")) })

	mux.HandleFunc("GET /api/whoami", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"user": user(r)})
	})
	mux.HandleFunc("GET /api/inventory", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"endpoints": cfg.Endpoints, "devices": mgr.Inv.Devices(), "limits": cfg.Limits})
	})
	mux.HandleFunc("POST /api/devices/{name}/discover", func(w http.ResponseWriter, r *http.Request) {
		d, err := mgr.Inv.Discover(r.Context(), r.PathValue("name"))
		if err != nil {
			writeErr(w, http.StatusNotFound, err)
			return
		}
		writeJSON(w, d)
	})

	mux.HandleFunc("GET /api/capture", func(w http.ResponseWriter, r *http.Request) {
		c := mgr.Current()
		if c == nil {
			writeJSON(w, map[string]any{"running": false})
			return
		}
		writeJSON(w, map[string]any{"running": c.Running(), "session": c.Meta()})
	})
	mux.HandleFunc("POST /api/capture", func(w http.ResponseWriter, r *http.Request) {
		var req session.StartRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		sess, err := mgr.Start(req, user(r))
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, sess.Meta())
	})
	mux.HandleFunc("POST /api/capture/stop", func(w http.ResponseWriter, r *http.Request) {
		mgr.Stop()
		writeJSON(w, map[string]bool{"ok": true})
	})

	mux.HandleFunc("GET /api/sessions", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, mgr.List())
	})
	mux.HandleFunc("GET /api/sessions/{id}", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		writeJSON(w, sess.Meta())
	}))
	mux.HandleFunc("DELETE /api/sessions/{id}", func(w http.ResponseWriter, r *http.Request) {
		if err := mgr.Delete(r.PathValue("id")); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("GET /api/sessions/{id}/frames", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		rows, err := sess.Frames(r.URL.Query().Get("filter"), intParam(r, "skip", 0, 1<<30), intParam(r, "limit", 500, 5000))
		if err != nil {
			sharkErr(w, err)
			return
		}
		writeJSON(w, map[string]any{"rows": rows, "flushed": sess.Flushed()})
	}))
	mux.HandleFunc("GET /api/sessions/{id}/frames/{num}", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		num, err := strconv.Atoi(r.PathValue("num"))
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		d, err := sess.Frame(num)
		if err != nil {
			sharkErr(w, err)
			return
		}
		writeJSON(w, d)
	}))
	mux.HandleFunc("GET /api/sessions/{id}/check", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		if err := sess.Check(r.URL.Query().Get("filter")); err != nil {
			sharkErr(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("GET /api/sessions/{id}/follow", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		proto := r.URL.Query().Get("proto")
		if proto != "TCP" && proto != "UDP" {
			writeErr(w, http.StatusBadRequest, errors.New("proto must be TCP or UDP"))
			return
		}
		raw, err := sess.Follow(proto, r.URL.Query().Get("filter"))
		if err != nil {
			sharkErr(w, err)
			return
		}
		writeJSON(w, raw)
	}))
	mux.HandleFunc("GET /api/sessions/{id}/summary", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		writeJSON(w, sess.Summary())
	}))
	mux.HandleFunc("GET /api/sessions/{id}/journeys", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		q := r.URL.Query()
		writeJSON(w, sess.Journeys(journey.Status(q.Get("status")), q.Get("at"), intParam(r, "limit", 200, 2000)))
	}))
	mux.HandleFunc("GET /api/sessions/{id}/pcapng", s.withSession(func(w http.ResponseWriter, r *http.Request, sess *session.Session) {
		w.Header().Set("Content-Type", "application/x-pcapng")
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="pfox-%s.pcapng"`, r.PathValue("id")))
		http.ServeFile(w, r, sess.CaptureFile())
	}))
	return securityHeaders(mux)
}

func (s *Server) withSession(h func(http.ResponseWriter, *http.Request, *session.Session)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, err := s.mgr.Get(r.PathValue("id"))
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				writeErr(w, http.StatusNotFound, errors.New("no such session"))
			} else {
				writeErr(w, http.StatusInternalServerError, err)
			}
			return
		}
		h(w, r, sess)
	}
}

func sharkErr(w http.ResponseWriter, err error) {
	var se *sharkd.Error
	if errors.As(err, &se) {
		writeErr(w, http.StatusUnprocessableEntity, err)
		return
	}
	writeErr(w, http.StatusInternalServerError, err)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		// The API changes routers; refuse cross-site form posts
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" || r.Header.Get("X-PacketFox") != "1" {
				writeErr(w, http.StatusForbidden, errors.New("missing X-PacketFox header"))
				return
			}
		}
		h.ServeHTTP(w, r)
	})
}
