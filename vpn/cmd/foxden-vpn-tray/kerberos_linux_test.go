package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

func krbDaemon(t *testing.T, provisioned bool, issued *atomic.Int32) *api.Client {
	sock := filepath.Join(t.TempDir(), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(api.Status{Provisioned: provisioned})
	})
	mux.HandleFunc("POST /v1/kerberos/cert", func(w http.ResponseWriter, r *http.Request) {
		issued.Add(1)
		_ = json.NewEncoder(w).Encode(api.KerberosCert{Principal: "dori@FOXDEN.NETWORK", Certificate: "CERT", CA: "CA", Expires: time.Now().Add(24 * time.Hour)})
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return api.NewClient(sock)
}

func TestKerberosRenewal(t *testing.T) {
	var issued atomic.Int32
	tr := &tray{client: krbDaemon(t, true, &issued), ui: newUI()}
	tr.last, _ = tr.client.Status()
	k := newKerberos(tr)
	k.dir = t.TempDir()
	if _, err := os.Stat("/usr/bin/kinit"); err != nil {
		t.Skip("needs kinit on PATH for the LookPath check")
	}
	var kinits []string
	valid := true
	k.kinit = func(_ context.Context, env []string, args ...string) error {
		kinits = append(kinits, strings.Join(args, " "))
		return nil
	}
	k.klistOK = func(context.Context, []string, string) bool { return valid }
	ctx := context.Background()

	k.ensure(ctx)
	if len(kinits) != 1 || issued.Load() != 1 || k.principl != "dori@FOXDEN.NETWORK" || k.err != "" {
		t.Fatalf("first ensure: kinits %v, issued %d, state %q/%q", kinits, issued.Load(), k.principl, k.err)
	}
	if !strings.HasSuffix(kinits[0], " dori@FOXDEN.NETWORK") || !strings.Contains(kinits[0], "X509_user_identity=FILE:"+k.dir+"/pkinit.pem,"+k.dir+"/pkinit.key") {
		t.Fatalf("kinit args: %s", kinits[0])
	}
	for _, f := range []string{"pkinit.key", "pkinit.pem", "pkinit-ca.pem", "krb5.conf"} {
		fi, err := os.Stat(filepath.Join(k.dir, f))
		if err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", f, fi, err)
		}
	}
	conf, _ := os.ReadFile(filepath.Join(k.dir, "krb5.conf"))
	if !strings.Contains(string(conf), "pkinit_anchors = FILE:"+k.dir+"/pkinit-ca.pem") || !strings.Contains(string(conf), ".foxden.network = FOXDEN.NETWORK") {
		t.Fatalf("krb5.conf:\n%s", conf)
	}
	key1, _ := os.ReadFile(filepath.Join(k.dir, "pkinit.key"))

	k.ensure(ctx) // fresh and valid: nothing to do
	if len(kinits) != 1 {
		t.Fatalf("renewed a fresh ticket: %v", kinits)
	}
	valid = false // e.g. kdestroy, or someone else's ticket in the cache
	k.ensure(ctx)
	if len(kinits) != 2 {
		t.Fatal("did not renew a missing ticket")
	}
	k.renewed = time.Now().Add(-krbRenewAfter - time.Minute)
	valid = true
	k.ensure(ctx)
	if len(kinits) != 3 {
		t.Fatal("did not renew an old ticket")
	}
	if key2, _ := os.ReadFile(filepath.Join(k.dir, "pkinit.key")); string(key2) != string(key1) {
		t.Fatal("session key changed between renewals")
	}
}

func TestKerberosNotRegistered(t *testing.T) {
	var issued atomic.Int32
	tr := &tray{client: krbDaemon(t, false, &issued), ui: newUI()}
	tr.last, _ = tr.client.Status()
	k := newKerberos(tr)
	k.dir = t.TempDir()
	k.ensure(context.Background())
	if k.err == "" || issued.Load() != 0 {
		t.Fatalf("unregistered: err %q, issued %d", k.err, issued.Load())
	}
}
