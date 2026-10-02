package pkinit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/asn1"
	"slices"
	"testing"
	"time"
)

func TestIssueAndParse(t *testing.T) {
	ca, err := NewCA("FOXDEN.NETWORK", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	cli, err := ca.IssueClient("doridian", "FOXDEN.NETWORK", &key.PublicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if c, r, err := Principal(cli); err != nil || !slices.Equal(c, []string{"doridian"}) || r != "FOXDEN.NETWORK" {
		t.Fatalf("client principal %v@%s, %v", c, r, err)
	}
	if !slices.ContainsFunc(cli.UnknownExtKeyUsage, func(o asn1.ObjectIdentifier) bool { return o.Equal(oidKPClientAuth) }) {
		t.Fatal("client EKU missing")
	}
	if _, err := cli.Verify(x509.VerifyOptions{Roots: pool(ca.Cert), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		t.Fatalf("client cert does not chain to the CA: %v", err)
	}

	kdc, err := ca.IssueKDC("FOXDEN.NETWORK", &key.PublicKey, time.Hour, "kerberos.foxden.network")
	if err != nil {
		t.Fatal(err)
	}
	if c, r, _ := Principal(kdc); !slices.Equal(c, []string{"krbtgt", "FOXDEN.NETWORK"}) || r != "FOXDEN.NETWORK" {
		t.Fatalf("kdc principal %v@%s", c, r)
	}
	if !slices.Contains(kdc.DNSNames, "kerberos.foxden.network") {
		t.Fatalf("kdc dns names %v", kdc.DNSNames)
	}
}

func TestPEMRoundTrip(t *testing.T) {
	ca, _ := NewCA("FOXDEN.NETWORK", time.Hour)
	keyPEM, err := KeyPEM(ca.Key)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadCA(CertPEM(ca.Cert), keyPEM)
	if err != nil || !loaded.Cert.Equal(ca.Cert) {
		t.Fatalf("LoadCA: %v", err)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	leaf, _ := ca.IssueClient("x", "R", &key.PublicKey, time.Hour)
	if _, err := LoadCA(CertPEM(leaf), keyPEM); err == nil {
		t.Fatal("accepted a leaf certificate as CA")
	}
}

func pool(c *x509.Certificate) *x509.CertPool {
	p := x509.NewCertPool()
	p.AddCert(c)
	return p
}
