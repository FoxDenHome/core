package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/pkinit"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Kerberos certificates: a registered device gets a short-lived PKINIT
// certificate for its owner, so the owner's desktop session can get Kerberos
// tickets (for SMB) without a password. The device proves it holds its
// WireGuard key with the same sealed challenge as enrollment; ownership comes
// from the router's peer table, so removing a device stops new certificates.

const pkinitChallengeTTL = 2 * time.Minute

func (p *portal) loadPKINIT() error {
	certPEM, err := os.ReadFile(p.cfg.PKINIT.CACert)
	if err != nil {
		return err
	}
	keyPEM, err := os.ReadFile(p.cfg.PKINIT.CAKey)
	if err != nil {
		return err
	}
	ca, err := pkinit.LoadCA(certPEM, keyPEM)
	if err != nil {
		return err
	}
	ttl, err := time.ParseDuration(p.cfg.PKINIT.Validity)
	if err != nil {
		return fmt.Errorf("validity: %w", err)
	}
	p.ca, p.caTTL = ca, ttl
	return nil
}

func writeAPIJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

type apiError struct {
	Error string `json:"error"`
}

type deviceChallengeResponse struct {
	Token     string `json:"token"`
	Challenge string `json:"challenge"` // base64url, sealed to the device key
}

// deviceChallenge starts a device proof for a registered WireGuard key.
func (p *portal) deviceChallenge(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PublicKey string `json:"public_key"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"bad request"})
		return
	}
	pub, err := wgtypes.ParseKey(req.PublicKey)
	if err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"invalid public key"})
		return
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		writeAPIJSON(w, http.StatusServiceUnavailable, apiError{"cannot reach the router"})
		return
	}
	serverKey, err := wgtypes.ParseKey(snap.Server["private-key"])
	if err != nil {
		writeAPIJSON(w, http.StatusInternalServerError, apiError{"cannot read the VPN server key"})
		return
	}
	sealed, secret, err := provision.NewChallenge(serverKey, pub)
	if err != nil {
		writeAPIJSON(w, http.StatusInternalServerError, apiError{err.Error()})
		return
	}
	sum := sha256.Sum256(secret)
	token, err := p.signToken(enrollToken{
		Purpose: purposePKINIT, Key: pub.String(),
		Challenge: hex.EncodeToString(sum[:]), Expires: time.Now().Add(pkinitChallengeTTL),
	})
	if err != nil {
		writeAPIJSON(w, http.StatusInternalServerError, apiError{err.Error()})
		return
	}
	writeAPIJSON(w, http.StatusOK, deviceChallengeResponse{Token: token, Challenge: base64.RawURLEncoding.EncodeToString(sealed)})
}

type kerberosCertRequest struct {
	Token  string `json:"token"`
	Answer string `json:"answer"`
	// PublicKey is the PKINIT key (PKIX DER, base64) of the user session.
	PublicKey string `json:"public_key"`
}

type kerberosCertResponse struct {
	Principal   string    `json:"principal"`
	Certificate string    `json:"certificate"` // PEM
	CA          string    `json:"ca"`          // PEM, the KDC's trust anchor too
	Expires     time.Time `json:"expires"`
}

func pkinitKey(b64 string) (any, error) {
	der, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	switch k := pub.(type) {
	case *ecdsa.PublicKey:
		if k.Curve != elliptic.P256() && k.Curve != elliptic.P384() {
			return nil, errors.New("unsupported curve")
		}
	case *rsa.PublicKey:
		if k.N.BitLen() < 2048 {
			return nil, errors.New("RSA key too small")
		}
	default:
		return nil, errors.New("unsupported key type")
	}
	return pub, nil
}

func (p *portal) kerberosCert(w http.ResponseWriter, r *http.Request) {
	if p.ca == nil {
		writeAPIJSON(w, http.StatusServiceUnavailable, apiError{"Kerberos certificates are not configured"})
		return
	}
	var req kerberosCertRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"bad request"})
		return
	}
	tok, err := p.checkAnswer(req.Token, req.Answer, purposePKINIT)
	if err != nil {
		writeAPIJSON(w, http.StatusForbidden, apiError{err.Error()})
		return
	}
	pub, err := pkinitKey(req.PublicKey)
	if err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"PKINIT key: " + err.Error()})
		return
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		writeAPIJSON(w, http.StatusServiceUnavailable, apiError{"cannot reach the router"})
		return
	}
	peer := snap.ByKey(tok.Key)
	switch {
	case peer == nil:
		writeAPIJSON(w, http.StatusForbidden, apiError{"this device is not registered"})
		return
	case peer.Disabled:
		writeAPIJSON(w, http.StatusForbidden, apiError{"this device is disabled"})
		return
	case peer.Owner == "":
		writeAPIJSON(w, http.StatusForbidden, apiError{"this device has no owner; register it through the portal"})
		return
	}
	cert, err := p.ca.IssueClient(peer.Owner, p.cfg.PKINIT.Realm, pub, p.caTTL)
	if err != nil {
		writeAPIJSON(w, http.StatusInternalServerError, apiError{err.Error()})
		return
	}
	log.Printf("issued a Kerberos certificate for %s to device %s", peer.Owner, peer.Device())
	writeAPIJSON(w, http.StatusOK, kerberosCertResponse{
		Principal:   peer.Owner + "@" + p.cfg.PKINIT.Realm,
		Certificate: string(pkinit.CertPEM(cert)),
		CA:          string(pkinit.CertPEM(p.ca.Cert)),
		Expires:     cert.NotAfter,
	})
}
