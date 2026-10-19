// Package kanidm reads a person's SSH public keys from Kanidm, the way
// kanidm-unixd on the servers does: as the anonymous account, which Kanidm
// lets read the POSIX attributes of accounts. It never changes anything.
package kanidm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// sessionHeader carries the auth session from one step to the next.
const sessionHeader = "X-KANIDM-AUTH-SESSION-ID"

// SSHKey is one of a person's keys, with the label Kanidm keeps it under.
type SSHKey struct {
	Tag string
	Key string
}

type Client struct {
	URL  string // https://auth.foxden.network
	HTTP *http.Client
}

func (c *Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

// SSHKeys returns the SSH public keys of user, with their labels. A user
// that is not a POSIX account, or has no keys, has none.
func (c *Client) SSHKeys(ctx context.Context, user string) ([]SSHKey, error) {
	token, err := c.anonymous(ctx)
	if err != nil {
		return nil, fmt.Errorf("Kanidm login: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.endpoint("/v1/person/"+url.PathEscape(user)+"/_attr/ssh_publickey"), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	var vals []string // null without keys
	if err := c.do(req, &vals, nil); err != nil {
		return nil, fmt.Errorf("Kanidm: %w", err)
	}
	keys := make([]SSHKey, 0, len(vals))
	for _, v := range vals {
		// "<tag>: <key>"
		tag, key, ok := strings.Cut(v, ": ")
		if !ok {
			tag, key = "", v
		}
		keys = append(keys, SSHKey{Tag: tag, Key: strings.TrimSpace(key)})
	}
	return keys, nil
}

type authState struct {
	State struct {
		Choose   []string        `json:"choose"`
		Continue json.RawMessage `json:"continue"`
		Denied   *string         `json:"denied"`
		Success  *string         `json:"success"`
	} `json:"state"`
}

// anonymous logs in as anonymous and returns the bearer token.
func (c *Client) anonymous(ctx context.Context) (string, error) {
	steps := []any{
		map[string]any{"init2": map[string]any{"username": "anonymous", "issue": "token", "privileged": false}},
		map[string]any{"begin": "anonymous"},
		map[string]any{"cred": "anonymous"},
	}
	session := ""
	for _, step := range steps {
		body, _ := json.Marshal(map[string]any{"step": step})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint("/v1/auth"), bytes.NewReader(body))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/json")
		if session != "" {
			req.Header.Set(sessionHeader, session)
		}
		var st authState
		var hdr http.Header
		if err := c.do(req, &st, &hdr); err != nil {
			return "", err
		}
		if s := hdr.Get(sessionHeader); s != "" {
			session = s
		}
		switch {
		case st.State.Denied != nil:
			return "", errors.New("denied: " + *st.State.Denied)
		case st.State.Success != nil:
			return *st.State.Success, nil
		}
	}
	return "", errors.New("anonymous login did not finish")
}

func (c *Client) endpoint(path string) string {
	return strings.TrimSuffix(c.URL, "/") + path
}

func (c *Client) do(req *http.Request, out any, hdr *http.Header) error {
	req.Header.Set("Accept", "application/json")
	resp, err := c.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		msg := strings.TrimSpace(string(data))
		if msg == "" || len(msg) > 200 {
			msg = resp.Status
		}
		return errors.New(msg)
	}
	if hdr != nil {
		*hdr = resp.Header
	}
	return json.Unmarshal(data, out)
}
