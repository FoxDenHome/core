package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
)

// Apple's Heimdal, by full path: its ticket lands in the login session's
// cache, where the SMB client looks. A Homebrew or Nix MIT kinit earlier in
// PATH would write a cache only it reads.
const (
	krbKinit = "/usr/bin/kinit"
	krbKlist = "/usr/bin/klist"
)

func kinitArgs(cert, key, ca, principal string) []string {
	return []string{"-C", "FILE:" + cert + "," + key, "-D", "FILE:" + ca, principal}
}

// newSessionKey makes an RSA key in PKCS #1, the form Apple's hx509 has
// always read.
func newSessionKey() (crypto.Signer, []byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}
	b := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	return key, b, nil
}

func sessionKeyUsable(k crypto.Signer) bool {
	_, ok := k.(*rsa.PrivateKey)
	return ok
}
