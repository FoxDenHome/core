package kanidm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

// fakeKanidm follows Kanidm's anonymous auth: init2, begin, cred, each step
// in the session the first one opened.
func fakeKanidm(t *testing.T, keys map[string][]string) *httptest.Server {
	t.Helper()
	step := map[string]int{}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/auth", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Step map[string]json.RawMessage }
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		sid := r.Header.Get(sessionHeader)
		reply := func(state string) {
			w.Header().Set(sessionHeader, "sess-1")
			_, _ = w.Write([]byte(`{"sessionid":"sess-1","state":` + state + `}`))
		}
		switch {
		case req.Step["init2"] != nil && sid == "":
			if !strings.Contains(string(req.Step["init2"]), `"anonymous"`) {
				reply(`{"denied":"only anonymous here"}`)
				return
			}
			step["sess-1"] = 1
			reply(`{"choose":["anonymous"]}`)
		case req.Step["begin"] != nil && sid == "sess-1" && step[sid] == 1:
			step[sid] = 2
			reply(`{"continue":["anonymous"]}`)
		case req.Step["cred"] != nil && sid == "sess-1" && step[sid] == 2:
			reply(`{"success":"anon-token"}`)
		default:
			http.Error(w, "out of order", http.StatusBadRequest)
		}
	})
	mux.HandleFunc("GET /v1/person/{id}/_attr/ssh_publickey", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer anon-token" {
			http.Error(w, "notauthenticated", http.StatusUnauthorized)
			return
		}
		k, ok := keys[r.PathValue("id")]
		if !ok {
			http.Error(w, `"nomatchingentries"`, http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(k)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestSSHKeys(t *testing.T) {
	srv := fakeKanidm(t, map[string][]string{
		"fox":    {"laptop: ssh-ed25519 AAAA laptop", "yubikey: sk-ssh-ed25519@openssh.com BBBB"},
		"nobody": nil,
	})
	c := &Client{URL: srv.URL + "/"}
	got, err := c.SSHKeys(context.Background(), "fox")
	if err != nil {
		t.Fatal(err)
	}
	want := []SSHKey{{"laptop", "ssh-ed25519 AAAA laptop"}, {"yubikey", "sk-ssh-ed25519@openssh.com BBBB"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v", got)
	}
	if got, err := c.SSHKeys(context.Background(), "nobody"); err != nil || len(got) != 0 {
		t.Errorf("no keys: %+v, %v", got, err)
	}
	if _, err := c.SSHKeys(context.Background(), "ghost"); err == nil || !strings.Contains(err.Error(), "nomatchingentries") {
		t.Errorf("unknown user: %v", err)
	}
}
