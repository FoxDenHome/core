package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/registry"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Enrollment lets the VPN app register its own key:
//
//  1. The tray opens GET /enroll with the device's public key and a loopback
//     callback. The user logs in and picks which device this is.
//  2. POST /enroll changes nothing yet. It redirects to the callback with a
//     signed token and a challenge sealed to the key.
//  3. The daemon opens the challenge and calls POST /api/enroll/complete.
//     Only then is the router changed, and the response carries the sealed
//     provisioning so the device works before the CDN has it.
//
// A link with someone else's key therefore cannot register it: the redirect
// lands on the victim's own machine, which can neither use it nor answer a
// challenge sealed to a key it does not hold.

const enrollTTL = 5 * time.Minute

const (
	purposeEnroll = "enroll"
	purposePKINIT = "pkinit"
	// purposeExpose proves a device to get an expose ticket, which is a token
	// with purposeExposeTicket.
	purposeExpose       = "expose"
	purposeExposeTicket = "expose-ticket"
)

// checkAnswer verifies a token for purpose and the device's answer to the
// challenge it carries.
func (p *portal) checkAnswer(token, answerB64, purpose string) (*enrollToken, error) {
	tok, err := p.parseToken(token)
	if err != nil {
		return nil, err
	}
	if tok.Purpose != purpose {
		return nil, errors.New("token is not for this request")
	}
	answer, err := base64.StdEncoding.DecodeString(answerB64)
	sum := sha256.Sum256(answer)
	if err != nil || subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(tok.Challenge)) != 1 {
		return nil, errors.New("wrong challenge answer")
	}
	return tok, nil
}

// enrollToken is what POST /enroll hands to the device, signed by the portal.
type enrollToken struct {
	// Purpose keeps a token for one endpoint from being used at another.
	Purpose   string    `json:"p"`
	User      string    `json:"u"`
	Key       string    `json:"k"`
	Device    string    `json:"d"`
	Challenge string    `json:"c"` // sha256 of the secret, hex
	Expires   time.Time `json:"e"`
}

func (p *portal) signToken(t enrollToken) (string, error) {
	b, err := json.Marshal(t)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(b)
	return payload + "." + p.cookies.mac("enroll|"+payload), nil
}

func (p *portal) parseToken(s string) (*enrollToken, error) {
	payload, mac, ok := strings.Cut(s, ".")
	if !ok || subtle.ConstantTimeCompare([]byte(mac), []byte(p.cookies.mac("enroll|"+payload))) != 1 {
		return nil, errors.New("invalid enrollment token")
	}
	b, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return nil, err
	}
	var t enrollToken
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, err
	}
	if time.Now().After(t.Expires) {
		return nil, errors.New("enrollment expired, please start again from the app")
	}
	return &t, nil
}

// loopbackCallback accepts only http://127.0.0.1, [::1] or localhost with a
// port: the device's own tray.
func loopbackCallback(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Port() == "" || u.User != nil {
		return nil, errors.New("invalid callback")
	}
	host := u.Hostname()
	if ip := net.ParseIP(host); (ip == nil || !ip.IsLoopback()) && host != "localhost" {
		return nil, errors.New("callback must be on this device")
	}
	return u, nil
}

// enrollCSP allows the form to redirect to the loopback callback.
const enrollCSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' http://127.0.0.1:* http://localhost:* http://[::1]:*; frame-ancestors 'none'"

type enrollDevice struct {
	Name     string
	Address  string
	Selected bool
	IsThis   bool // already holds this key
}

func (p *portal) enrollPage(w http.ResponseWriter, r *http.Request) {
	s := p.session(r)
	if s == nil {
		http.Redirect(w, r, "/login?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusSeeOther)
		return
	}
	q := r.URL.Query()
	key, state := q.Get("pubkey"), q.Get("state")
	if _, err := loopbackCallback(q.Get("callback")); err != nil || !registry.ValidPublicKey(key) || state == "" {
		http.Error(w, "This link is not a valid enrollment request. Start again from the FoxDen VPN app.", http.StatusBadRequest)
		return
	}
	data := map[string]any{
		"User":     s.User,
		"CSRF":     p.cookies.csrf(s),
		"Key":      key,
		"Callback": q.Get("callback"),
		"State":    state,
		"NewName":  strings.ToLower(q.Get("name")),
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		data["Error"] = "Cannot reach the router right now: " + err.Error()
	} else {
		replace := q.Get("replace")
		var devices []enrollDevice
		anySelected := false
		for _, peer := range snap.OwnedBy(s.User) {
			d := enrollDevice{Name: peer.Device(), IsThis: peer.PublicKey == key, Selected: peer.Name == replace}
			if len(peer.Addresses) > 0 {
				d.Address = peer.Addresses[0].Addr().String()
			}
			anySelected = anySelected || d.Selected
			devices = append(devices, d)
		}
		if other := snap.ByKey(key); other != nil && other.Owner != s.User {
			data["Error"] = "This key is already registered to someone else."
		}
		data["Devices"] = devices
		data["NewSelected"] = !anySelected
	}
	w.Header().Set("Content-Security-Policy", enrollCSP)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := pages.ExecuteTemplate(w, "enroll.html", data); err != nil {
		log.Printf("render: %v", err)
	}
}

func (p *portal) enrollSubmit(w http.ResponseWriter, r *http.Request, s *session) {
	cb, err := loopbackCallback(r.PostFormValue("callback"))
	key, state := r.PostFormValue("pubkey"), r.PostFormValue("state")
	if err != nil || state == "" {
		http.Error(w, "invalid enrollment request", http.StatusBadRequest)
		return
	}
	device := r.PostFormValue("device")
	if device == "" {
		device = strings.ToLower(strings.TrimSpace(r.PostFormValue("new_name")))
	}
	if !registry.ValidDeviceName(device) {
		http.Error(w, "Device names are 1-31 lowercase letters, digits and dashes. Go back and pick another.", http.StatusBadRequest)
		return
	}
	pub, err := wgtypes.ParseKey(key)
	if err != nil {
		http.Error(w, "invalid public key", http.StatusBadRequest)
		return
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		http.Error(w, "Cannot reach the router: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	serverKey, err := wgtypes.ParseKey(snap.Server["private-key"])
	if err != nil {
		http.Error(w, "cannot read the VPN server key", http.StatusInternalServerError)
		return
	}
	sealed, secret, err := provision.NewChallenge(serverKey, pub)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	sum := sha256.Sum256(secret)
	token, err := p.signToken(enrollToken{
		Purpose: purposeEnroll, User: s.User, Key: key, Device: device,
		Challenge: hex.EncodeToString(sum[:]), Expires: time.Now().Add(enrollTTL),
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	q := cb.Query()
	q.Set("state", state)
	q.Set("token", token)
	q.Set("challenge", base64.RawURLEncoding.EncodeToString(sealed))
	cb.RawQuery = q.Encode()
	w.Header().Set("Content-Security-Policy", enrollCSP)
	http.Redirect(w, r, cb.String(), http.StatusSeeOther)
}

type enrollCompleteRequest struct {
	Token  string `json:"token"`
	Answer string `json:"answer"` // base64 of the challenge secret
}

type enrollCompleteResponse struct {
	Device string `json:"device"`
	Config string `json:"config"` // base64 provisioning blob, sealed to the device
	Error  string `json:"error,omitempty"`
}

func writeEnrollJSON(w http.ResponseWriter, code int, v enrollCompleteResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (p *portal) enrollComplete(w http.ResponseWriter, r *http.Request) {
	var req enrollCompleteRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeEnrollJSON(w, http.StatusBadRequest, enrollCompleteResponse{Error: "bad request"})
		return
	}
	tok, err := p.checkAnswer(req.Token, req.Answer, purposeEnroll)
	if err != nil {
		writeEnrollJSON(w, http.StatusForbidden, enrollCompleteResponse{Error: err.Error()})
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	blob, err := p.applyEnrollment(r.Context(), tok)
	if err != nil {
		log.Printf("enrollment of %s for %s failed: %v", tok.Device, tok.User, err)
		writeEnrollJSON(w, http.StatusConflict, enrollCompleteResponse{Error: err.Error()})
		return
	}
	writeEnrollJSON(w, http.StatusOK, enrollCompleteResponse{
		Device: tok.Device,
		Config: base64.StdEncoding.EncodeToString(blob),
	})
}

// applyEnrollment registers the token's key and returns its sealed config.
func (p *portal) applyEnrollment(ctx context.Context, tok *enrollToken) ([]byte, error) {
	c, err := p.dial(ctx, p.cfg.Routers[0])
	if err != nil {
		return nil, err
	}
	defer c.Close()
	snap, err := registry.Read(ctx, c, p.cfg.VPN)
	if err != nil {
		return nil, err
	}
	removeID, id, attrs, err := snap.Enroll(p.cfg.VPN, tok.User, tok.Device, tok.Key)
	if err != nil {
		return nil, err
	}
	if removeID != "" {
		if err := registry.Remove(ctx, c, removeID); err != nil {
			return nil, err
		}
	}
	if err := registry.Apply(ctx, c, id, attrs); err != nil {
		return nil, err
	}
	log.Printf("%s enrolled device %s", tok.User, tok.Device)
	if err := p.syncFrom(ctx, c); err != nil {
		log.Printf("sync after enrollment: %v", err) // the device gets its config below anyway
	}

	snap, err = registry.Read(ctx, c, p.cfg.VPN)
	if err != nil {
		return nil, err
	}
	peer := snap.ByKey(tok.Key)
	if peer == nil {
		return nil, errors.New("registered peer not found on the router")
	}
	cfg := snap.Config(*peer, p.cfg.VPN)
	if cfg == nil {
		return nil, fmt.Errorf("peer %s has no usable configuration", peer.Name)
	}
	serverKey, err := wgtypes.ParseKey(snap.Server["private-key"])
	if err != nil {
		return nil, err
	}
	pub, err := wgtypes.ParseKey(tok.Key)
	if err != nil {
		return nil, err
	}
	return provision.Seal(cfg, serverKey, pub)
}
