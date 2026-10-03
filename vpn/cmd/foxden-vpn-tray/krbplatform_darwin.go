package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os/exec"
	"strings"
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

// prepareKinit lets Heimdal check the KDC's certificate itself, against the
// CA kinit is given (-D). Otherwise only the Security framework checks it,
// which knows only the keychain's CAs and fails with MissingIntermediate.
// The setting is per user and only adds hx509's own validation, with the
// anchors each caller passes; it makes nothing trust our CA.
func prepareKinit() error {
	const domain, key = "org.h5l.hx509", "AllowHX509Validation"
	if out, err := exec.Command("defaults", "read", domain, key).Output(); err == nil && strings.TrimSpace(string(out)) == "1" {
		return nil
	}
	if out, err := exec.Command("defaults", "write", domain, key, "-bool", "true").CombinedOutput(); err != nil {
		return fmt.Errorf("enabling Heimdal's certificate validation: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
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
