package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// fakeDaemon serves the control API on a unix socket.
func fakeDaemon(t *testing.T, complete func(api.EnrollCompleteRequest) (int, any)) *api.Client {
	sock := filepath.Join(t.TempDir(), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(api.Status{PortalURL: "https://portal.example/"})
	})
	mux.HandleFunc("POST /v1/enroll/start", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(api.EnrollStart{PublicKey: "PUB", Replace: "dori-fennec"})
	})
	mux.HandleFunc("POST /v1/enroll/complete", func(w http.ResponseWriter, r *http.Request) {
		var req api.EnrollCompleteRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		code, body := complete(req)
		w.WriteHeader(code)
		if s, ok := body.(string); ok {
			_, _ = w.Write([]byte(s))
			return
		}
		_ = json.NewEncoder(w).Encode(body)
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return api.NewClient(sock)
}

// playBrowser follows the portal link like a browser would after the user
// picked a device, and records what the callback returned.
// Wait on the returned WaitGroup before reading pages.
func playBrowser(t *testing.T, pages *[]string, opened *url.Values) (func(string) error, *sync.WaitGroup) {
	var wg sync.WaitGroup
	wg.Add(1)
	return func(link string) error {
		u, err := url.Parse(link)
		if err != nil {
			return err
		}
		q := u.Query()
		*opened = q
		get := func(state string) {
			cb, _ := url.Parse(q.Get("callback"))
			cv := url.Values{"state": {state}, "token": {"TOKEN"}, "challenge": {"CHALLENGE"}}
			cb.RawQuery = cv.Encode()
			resp, err := http.Get(cb.String())
			if err != nil {
				t.Error(err)
				return
			}
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			*pages = append(*pages, resp.Status+" "+string(b))
		}
		go func() {
			defer wg.Done()
			get("forged") // some other page poking the loopback port
			get(q.Get("state"))
		}()
		return nil
	}, &wg
}

func TestRunEnrollment(t *testing.T) {
	var got api.EnrollCompleteRequest
	tr := &tray{client: fakeDaemon(t, func(req api.EnrollCompleteRequest) (int, any) {
		got = req
		return http.StatusOK, api.Status{Provisioned: true, PeerName: "dori-fennec"}
	}), portalURL: "https://fallback.example/", ui: newUI()}
	st, _ := tr.client.Status()
	tr.last = st

	var pages []string
	var opened url.Values
	var browsed *sync.WaitGroup
	browse, browsed = playBrowser(t, &pages, &opened)
	defer func() { browse = openURL }()

	res, err := tr.runEnrollment(true, "")
	browsed.Wait()
	if err != nil || !res.OK || !strings.Contains(res.Text, "dori-fennec") {
		t.Fatalf("result %+v, %v", res, err)
	}
	if got.Token != "TOKEN" || got.Challenge != "CHALLENGE" {
		t.Fatalf("daemon got %+v", got)
	}
	cb, _ := url.Parse(opened.Get("callback"))
	if opened.Get("pubkey") != "PUB" || opened.Get("replace") != "dori-fennec" || cb.Hostname() != "127.0.0.1" {
		t.Fatalf("portal link: %v", opened)
	}
	if len(pages) != 2 || !strings.HasPrefix(pages[0], "400") || !strings.Contains(pages[1], "Device registered") {
		t.Fatalf("callback pages: %q", pages)
	}
}

func TestRunEnrollmentFailure(t *testing.T) {
	tr := &tray{client: fakeDaemon(t, func(api.EnrollCompleteRequest) (int, any) {
		return http.StatusBadRequest, "portal: wrong challenge answer"
	}), ui: newUI()}
	var pages []string
	var opened url.Values
	var browsed *sync.WaitGroup
	browse, browsed = playBrowser(t, &pages, &opened)
	defer func() { browse = openURL }()

	res, err := tr.runEnrollment(false, "")
	browsed.Wait()
	if err != nil || res.OK || !strings.Contains(res.Text, "wrong challenge answer") {
		t.Fatalf("result %+v, %v", res, err)
	}
	if opened.Get("replace") != "dori-fennec" {
		t.Fatalf("link: %v", opened) // the fake daemon always suggests it
	}
	if len(pages) != 2 || !strings.Contains(pages[1], "Registration failed") {
		t.Fatalf("pages: %q", pages)
	}
}
