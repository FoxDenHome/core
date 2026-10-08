package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/registry"
)

// Expose tickets let a device open tunnels on foxden-vpn-edge. The daemon
// proves the device with the usual sealed challenge (purpose "expose") and
// gets a short-lived ticket naming the device and its owner. The edge, which
// holds no secrets, hands the ticket back here to learn who it belongs to,
// and later checks by key that the device is still registered.

const exposeTicketTTL = 2 * time.Minute

type exposeTicketResponse struct {
	Ticket  string    `json:"ticket"`
	Expires time.Time `json:"expires"`
}

func (p *portal) exposeTicket(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token  string `json:"token"`
		Answer string `json:"answer"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"bad request"})
		return
	}
	tok, err := p.checkAnswer(req.Token, req.Answer, purposeExpose)
	if err != nil {
		writeAPIJSON(w, http.StatusForbidden, apiError{err.Error()})
		return
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		writeAPIJSON(w, http.StatusServiceUnavailable, apiError{"cannot reach the router"})
		return
	}
	peer, err := activePeer(snap, tok.Key)
	if err != nil {
		writeAPIJSON(w, http.StatusForbidden, apiError{err.Error()})
		return
	}
	expires := time.Now().Add(exposeTicketTTL)
	ticket, err := p.signToken(enrollToken{
		Purpose: purposeExposeTicket, User: peer.Owner, Key: peer.PublicKey, Device: peer.Device(), Expires: expires,
	})
	if err != nil {
		writeAPIJSON(w, http.StatusInternalServerError, apiError{err.Error()})
		return
	}
	writeAPIJSON(w, http.StatusOK, exposeTicketResponse{Ticket: ticket, Expires: expires})
}

type exposeCheckResponse struct {
	Owner     string `json:"owner,omitempty"`
	Device    string `json:"device,omitempty"`
	PublicKey string `json:"public_key,omitempty"`
}

// exposeCheck answers the edge: with a ticket, whose device it is; with a
// public key alone, only whether that device is still active (403 if not).
func (p *portal) exposeCheck(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Ticket    string `json:"ticket"`
		PublicKey string `json:"public_key"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"bad request"})
		return
	}
	var tok *enrollToken
	key := req.PublicKey
	if req.Ticket != "" {
		t, err := p.parseToken(req.Ticket)
		if err == nil && t.Purpose != purposeExposeTicket {
			err = errTicket
		}
		if err != nil {
			writeAPIJSON(w, http.StatusForbidden, apiError{"invalid or expired ticket"})
			return
		}
		tok, key = t, t.Key
	} else if !registry.ValidPublicKey(key) {
		writeAPIJSON(w, http.StatusBadRequest, apiError{"invalid public key"})
		return
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		writeAPIJSON(w, http.StatusServiceUnavailable, apiError{"cannot reach the router"})
		return
	}
	peer, err := activePeer(snap, key)
	if err == nil && tok != nil && peer.Owner != tok.User {
		err = errTicket // the device changed hands since
	}
	if err != nil {
		writeAPIJSON(w, http.StatusForbidden, apiError{err.Error()})
		return
	}
	if tok == nil {
		writeAPIJSON(w, http.StatusOK, exposeCheckResponse{})
		return
	}
	log.Printf("expose ticket used by %s for device %s", peer.Owner, peer.Device())
	writeAPIJSON(w, http.StatusOK, exposeCheckResponse{Owner: peer.Owner, Device: peer.Device(), PublicKey: peer.PublicKey})
}

var errTicket = errors.New("invalid or expired ticket")
