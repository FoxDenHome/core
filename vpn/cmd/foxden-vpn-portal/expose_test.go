package main

import (
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/provision"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// exposeTicketFor runs the device proof for dev (answering with answerWith)
// and asks for an expose ticket.
func (h *harness) exposeTicketFor(dev, answerWith wgtypes.Key) (int, exposeTicketResponse) {
	var ch deviceChallengeResponse
	if code := h.postJSON("/api/device/challenge", map[string]string{"public_key": dev.PublicKey().String(), "purpose": "expose"}, &ch); code != http.StatusOK {
		return code, exposeTicketResponse{}
	}
	sealed, _ := base64.RawURLEncoding.DecodeString(ch.Challenge)
	answer, err := provision.AnswerChallenge(sealed, answerWith, h.serverPub())
	if err != nil {
		answer = []byte("nope")
	}
	var out exposeTicketResponse
	code := h.postJSON("/api/expose/ticket", map[string]string{"token": ch.Token, "answer": base64.StdEncoding.EncodeToString(answer)}, &out)
	return code, out
}

func TestExposeTicket(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()
	if code, _ := h.exposeTicketFor(dev, dev); code != http.StatusForbidden {
		t.Fatalf("unregistered device got a ticket: %d", code)
	}
	redirect := h.startEnroll(c, csrf, dev.PublicKey(), "", "fennec")
	if _, out := h.complete(redirect, dev); out.Error != "" {
		t.Fatal(out.Error)
	}
	pub := dev.PublicKey()

	code, ticket := h.exposeTicketFor(dev, dev)
	if code != http.StatusOK || ticket.Ticket == "" {
		t.Fatalf("ticket: %d", code)
	}
	var id exposeCheckResponse
	if code := h.postJSON("/api/expose/check", map[string]string{"ticket": ticket.Ticket}, &id); code != http.StatusOK {
		t.Fatalf("check: %d", code)
	}
	if id.Owner != "dori" || id.Device != "fennec" || id.PublicKey != pub.String() {
		t.Fatalf("check: %+v", id)
	}
	if code := h.postJSON("/api/expose/check", map[string]string{"public_key": pub.String()}, nil); code != http.StatusOK {
		t.Fatalf("active: %d", code)
	}

	// Other tokens are not tickets.
	for _, tok := range []string{redirect.Query().Get("token"), "garbage", ""} {
		if code := h.postJSON("/api/expose/check", map[string]string{"ticket": tok}, nil); code == http.StatusOK {
			t.Fatalf("token %q accepted as a ticket", tok)
		}
	}
	// A PKINIT proof does not get a ticket.
	var ch deviceChallengeResponse
	h.postJSON("/api/device/challenge", map[string]string{"public_key": pub.String()}, &ch)
	if code := h.postJSON("/api/expose/ticket", map[string]string{"token": ch.Token, "answer": "x"}, nil); code != http.StatusForbidden {
		t.Fatalf("pkinit token: %d", code)
	}
	if code := h.postJSON("/api/device/challenge", map[string]string{"public_key": pub.String(), "purpose": "enroll"}, nil); code != http.StatusBadRequest {
		t.Fatalf("enroll purpose: %d", code)
	}

	// A disabled device is no longer active, and its tickets stop working.
	for _, row := range h.primary.Tables["/interface/wireguard/peers"] {
		if row["public-key"] == pub.String() {
			row["disabled"] = "true"
		}
	}
	if code := h.postJSON("/api/expose/check", map[string]string{"public_key": pub.String()}, nil); code != http.StatusForbidden {
		t.Fatalf("disabled device active: %d", code)
	}
	if code := h.postJSON("/api/expose/check", map[string]string{"ticket": ticket.Ticket}, nil); code != http.StatusForbidden {
		t.Fatalf("disabled device's ticket: %d", code)
	}
}

func TestExposeTicketWrongKey(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()
	if _, out := h.complete(h.startEnroll(c, csrf, dev.PublicKey(), "", "fennec"), dev); out.Error != "" {
		t.Fatal(out.Error)
	}
	other, _ := wgtypes.GeneratePrivateKey()
	if code, _ := h.exposeTicketFor(dev, other); code != http.StatusForbidden {
		t.Fatalf("answered with another key: %d", code)
	}
}
