package provision

import (
	"bytes"
	"crypto/rand"
	"errors"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Enrollment challenges prove that a device holds the private key it asks
// to register: the portal seals a random secret to the key, and only its
// holder can return it. The prefix keeps the daemon from ever answering
// anything else sealed to it, such as its own provisioning.
const challengePrefix = "foxden-enroll-challenge v1\n"

// NewChallenge returns the sealed challenge for peer and the secret it hides.
func NewChallenge(server wgtypes.Key, peer wgtypes.Key) (sealed, secret []byte, err error) {
	secret = make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, nil, err
	}
	sealed, err = sealRaw(append([]byte(challengePrefix), secret...), server, peer)
	return sealed, secret, err
}

// AnswerChallenge opens a challenge with the device key.
func AnswerChallenge(sealed []byte, priv wgtypes.Key, serverPub wgtypes.Key) ([]byte, error) {
	plain, err := openRaw(sealed, priv, serverPub)
	if err != nil {
		return nil, err
	}
	secret, ok := bytes.CutPrefix(plain, []byte(challengePrefix))
	if !ok || len(secret) != 32 {
		return nil, errors.New("not an enrollment challenge")
	}
	return secret, nil
}
