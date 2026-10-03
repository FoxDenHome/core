package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"

	"github.com/FoxDenHome/core/vpn/internal/pkinit"
)

// MIT krb5, from PATH; the trust anchor comes from our krb5.conf.
const (
	krbKinit = "kinit"
	krbKlist = "klist"
)

func kinitArgs(cert, key, _ /* ca */, principal string) []string {
	return []string{"-X", "X509_user_identity=FILE:" + cert + "," + key, principal}
}

func newSessionKey() (crypto.Signer, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	b, err := pkinit.KeyPEM(key)
	return key, b, err
}

func sessionKeyUsable(k crypto.Signer) bool {
	_, ok := k.(*ecdsa.PrivateKey)
	return ok
}
