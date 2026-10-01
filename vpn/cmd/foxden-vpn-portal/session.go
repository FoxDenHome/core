package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Sessions are signed cookies, so the portal keeps no state of its own.

type signer struct {
	key    []byte
	secure bool
}

func (s *signer) mac(payload string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *signer) set(w http.ResponseWriter, name string, v any, ttl time.Duration) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	payload := base64.RawURLEncoding.EncodeToString(b)
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    payload + "." + s.mac(name+"|"+payload),
		Path:     "/",
		MaxAge:   int(ttl.Seconds()),
		HttpOnly: true,
		Secure:   s.secure,
		SameSite: http.SameSiteLaxMode,
	})
	return nil
}

func (s *signer) get(r *http.Request, name string, v any) error {
	c, err := r.Cookie(name)
	if err != nil {
		return err
	}
	payload, mac, ok := strings.Cut(c.Value, ".")
	if !ok || !hmac.Equal([]byte(mac), []byte(s.mac(name+"|"+payload))) {
		return errors.New("bad cookie signature")
	}
	b, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func (s *signer) clear(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{Name: name, Path: "/", MaxAge: -1, HttpOnly: true, Secure: s.secure})
}

type session struct {
	User    string    `json:"u"`
	Expires time.Time `json:"e"`
}

type loginState struct {
	State    string    `json:"s"`
	Verifier string    `json:"v"`
	Next     string    `json:"n"`
	Expires  time.Time `json:"e"`
}

// csrf derives the form token from the session, so it needs no storage either.
func (s *signer) csrf(sess *session) string {
	return s.mac("csrf|" + sess.User + "|" + strconv.FormatInt(sess.Expires.Unix(), 10))
}
