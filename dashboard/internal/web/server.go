// Package web serves the embedded UI and the state API.
package web

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"

	"github.com/FoxDenHome/core/dashboard/internal/poller"
)

//go:embed static
var static embed.FS

func Handler(p *poller.Poller) http.Handler {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(static, "static")
	mux.Handle("GET /", http.FileServerFS(sub))
	mux.HandleFunc("GET /api/rack", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(p.Snapshot())
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	return mux
}
