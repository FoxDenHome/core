// Package pkinit issues the X.509 certificates Kerberos PKINIT needs (RFC
// 4556): a client certificate names its principal in an id-pkinit-san
// otherName and carries the PKINIT client EKU; the KDC's names
// krbtgt/REALM@REALM with the KDC EKU.
package pkinit

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"time"
)

var (
	oidSubjectAltName  = asn1.ObjectIdentifier{2, 5, 29, 17}
	oidPKINITSAN       = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 2, 2}
	oidKPClientAuth    = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 2, 3, 4}
	oidKPKdc           = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 2, 3, 5}
	ntPrincipal        = 1
	ntSrvInst          = 2
	tagGeneralString   = 27
	generalNameDNS     = 2
	generalNameOtherNm = 0
)

// generalString is an ASN.1 GeneralString, which encoding/asn1 cannot
// produce from a Go string.
func generalString(s string) asn1.RawValue {
	return asn1.RawValue{Class: asn1.ClassUniversal, Tag: tagGeneralString, Bytes: []byte(s)}
}

type principalName struct {
	NameType   int             `asn1:"explicit,tag:0"`
	NameString []asn1.RawValue `asn1:"explicit,tag:1"`
}

// Realm holds the [0] EXPLICIT wrapper itself: encoding/asn1 ignores the
// explicit tag on RawValue fields.
type krb5PrincipalName struct {
	Realm         asn1.RawValue
	PrincipalName principalName `asn1:"explicit,tag:1"`
}

func explicit0(v asn1.RawValue) (asn1.RawValue, error) {
	b, err := asn1.Marshal(v)
	if err != nil {
		return asn1.RawValue{}, err
	}
	return asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: 0, IsCompound: true, Bytes: b}, nil
}

// principalSAN encodes a subjectAltName extension naming the principal
// (components@realm), plus any DNS names.
func principalSAN(nameType int, components []string, realm string, dnsNames ...string) (pkix.Extension, error) {
	realmField, err := explicit0(generalString(realm))
	if err != nil {
		return pkix.Extension{}, err
	}
	pn := krb5PrincipalName{Realm: realmField, PrincipalName: principalName{NameType: nameType}}
	for _, c := range components {
		pn.PrincipalName.NameString = append(pn.PrincipalName.NameString, generalString(c))
	}
	value, err := asn1.Marshal(pn)
	if err != nil {
		return pkix.Extension{}, err
	}
	// OtherName ::= SEQUENCE { type-id OID, value [0] EXPLICIT ANY }
	oid, err := asn1.Marshal(oidPKINITSAN)
	if err != nil {
		return pkix.Extension{}, err
	}
	explicit, err := asn1.Marshal(asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: 0, IsCompound: true, Bytes: value})
	if err != nil {
		return pkix.Extension{}, err
	}
	names := []asn1.RawValue{{Class: asn1.ClassContextSpecific, Tag: generalNameOtherNm, IsCompound: true, Bytes: append(oid, explicit...)}}
	for _, d := range dnsNames {
		names = append(names, asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: generalNameDNS, Bytes: []byte(d)})
	}
	san, err := asn1.Marshal(names)
	if err != nil {
		return pkix.Extension{}, err
	}
	return pkix.Extension{Id: oidSubjectAltName, Value: san}, nil
}

// Principal returns the principal an id-pkinit-san in cert names, as
// components and realm.
func Principal(cert *x509.Certificate) ([]string, string, error) {
	for _, ext := range cert.Extensions {
		if !ext.Id.Equal(oidSubjectAltName) {
			continue
		}
		var names []asn1.RawValue
		if _, err := asn1.Unmarshal(ext.Value, &names); err != nil {
			return nil, "", err
		}
		for _, n := range names {
			if n.Class != asn1.ClassContextSpecific || n.Tag != generalNameOtherNm {
				continue
			}
			var oid asn1.ObjectIdentifier
			rest, err := asn1.Unmarshal(n.Bytes, &oid)
			if err != nil || !oid.Equal(oidPKINITSAN) {
				continue
			}
			var explicit asn1.RawValue
			if _, err := asn1.Unmarshal(rest, &explicit); err != nil {
				return nil, "", err
			}
			var pn krb5PrincipalName
			if _, err := asn1.Unmarshal(explicit.Bytes, &pn); err != nil {
				return nil, "", err
			}
			var realm asn1.RawValue
			if _, err := asn1.Unmarshal(pn.Realm.Bytes, &realm); err != nil {
				return nil, "", err
			}
			var components []string
			for _, c := range pn.PrincipalName.NameString {
				components = append(components, string(c.Bytes))
			}
			return components, string(realm.Bytes), nil
		}
	}
	return nil, "", errors.New("certificate names no Kerberos principal")
}

func serial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

// CA is a PKINIT certificate authority.
type CA struct {
	Cert *x509.Certificate
	Key  crypto.Signer
}

// NewCA creates a self-signed CA for realm.
func NewCA(realm string, validity time.Duration) (*CA, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{Organization: []string{"FoxDen"}, CommonName: realm + " PKINIT CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(validity),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &CA{Cert: cert, Key: key}, nil
}

func (ca *CA) issue(tmpl *x509.Certificate, pub crypto.PublicKey) (*x509.Certificate, error) {
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	tmpl.SerialNumber = sn
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.Cert, pub, ca.Key)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

// IssueKDC issues the KDC's certificate for realm.
func (ca *CA) IssueKDC(realm string, pub crypto.PublicKey, validity time.Duration, dnsNames ...string) (*x509.Certificate, error) {
	san, err := principalSAN(ntSrvInst, []string{"krbtgt", realm}, realm, dnsNames...)
	if err != nil {
		return nil, err
	}
	return ca.issue(&x509.Certificate{
		Subject:            pkix.Name{Organization: []string{"FoxDen"}, CommonName: "krbtgt/" + realm},
		NotBefore:          time.Now().Add(-time.Hour),
		NotAfter:           time.Now().Add(validity),
		KeyUsage:           x509.KeyUsageDigitalSignature | x509.KeyUsageKeyAgreement,
		ExtKeyUsage:        []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		UnknownExtKeyUsage: []asn1.ObjectIdentifier{oidKPKdc},
		ExtraExtensions:    []pkix.Extension{san},
	}, pub)
}

// IssueClient issues a short-lived certificate for user@realm.
func (ca *CA) IssueClient(user, realm string, pub crypto.PublicKey, validity time.Duration) (*x509.Certificate, error) {
	if user == "" || realm == "" {
		return nil, errors.New("empty principal")
	}
	san, err := principalSAN(ntPrincipal, []string{user}, realm)
	if err != nil {
		return nil, err
	}
	return ca.issue(&x509.Certificate{
		Subject:            pkix.Name{Organization: []string{"FoxDen"}, CommonName: user + "@" + realm},
		NotBefore:          time.Now().Add(-5 * time.Minute), // clock skew
		NotAfter:           time.Now().Add(validity),
		KeyUsage:           x509.KeyUsageDigitalSignature,
		ExtKeyUsage:        []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		UnknownExtKeyUsage: []asn1.ObjectIdentifier{oidKPClientAuth},
		ExtraExtensions:    []pkix.Extension{san},
	}, pub)
}

// CertPEM encodes a certificate.
func CertPEM(c *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw})
}

// KeyPEM encodes a private key as PKCS #8.
func KeyPEM(k crypto.Signer) ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// ParseCertPEM decodes the first certificate in b.
func ParseCertPEM(b []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("no certificate found")
	}
	return x509.ParseCertificate(block.Bytes)
}

// ParseKeyPEM decodes a PKCS #8, PKCS #1 (RSA) or EC private key.
func ParseKeyPEM(b []byte) (crypto.Signer, error) {
	block, _ := pem.Decode(b)
	if block == nil {
		return nil, errors.New("no private key found")
	}
	if k, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if s, ok := k.(crypto.Signer); ok {
			return s, nil
		}
		return nil, fmt.Errorf("unsupported key type %T", k)
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	return x509.ParseECPrivateKey(block.Bytes)
}

// LoadCA reads a CA certificate and key.
func LoadCA(certPEM, keyPEM []byte) (*CA, error) {
	cert, err := ParseCertPEM(certPEM)
	if err != nil {
		return nil, err
	}
	key, err := ParseKeyPEM(keyPEM)
	if err != nil {
		return nil, err
	}
	if !cert.IsCA {
		return nil, errors.New("not a CA certificate")
	}
	return &CA{Cert: cert, Key: key}, nil
}
