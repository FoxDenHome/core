// Package fastly manages items of a Fastly edge dictionary, which the CDN
// serves provisioning blobs from.
package fastly

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const apiBase = "https://api.fastly.com"

type Dictionary struct {
	BaseURL   string // defaults to the Fastly API
	Token     string
	ServiceID string
	Name      string

	id   string
	http http.Client
}

func (d *Dictionary) do(ctx context.Context, method, path string, form url.Values, out any) error {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	base := d.BaseURL
	if base == "" {
		base = apiBase
	}
	req, err := http.NewRequestWithContext(ctx, method, base+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Fastly-Key", d.Token)
	req.Header.Set("Accept", "application/json")
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if d.http.Timeout == 0 {
		d.http.Timeout = 30 * time.Second
	}
	resp, err := d.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("fastly %s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(msg)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// resolve finds the dictionary id by name on the active service version.
// Dictionary items are versionless, so the id stays valid across versions.
func (d *Dictionary) resolve(ctx context.Context) (string, error) {
	if d.id != "" {
		return d.id, nil
	}
	var svc struct {
		ActiveVersion int `json:"active_version"`
	}
	if err := d.do(ctx, http.MethodGet, "/service/"+d.ServiceID+"/details", nil, &svc); err != nil {
		return "", err
	}
	var dict struct {
		ID string `json:"id"`
	}
	path := fmt.Sprintf("/service/%s/version/%d/dictionary/%s", d.ServiceID, svc.ActiveVersion, url.PathEscape(d.Name))
	if err := d.do(ctx, http.MethodGet, path, nil, &dict); err != nil {
		return "", err
	}
	d.id = dict.ID
	return d.id, nil
}

func (d *Dictionary) itemPath(ctx context.Context, rest string) (string, error) {
	id, err := d.resolve(ctx)
	if err != nil {
		return "", err
	}
	return "/service/" + d.ServiceID + "/dictionary/" + id + rest, nil
}

func (d *Dictionary) Items(ctx context.Context) (map[string]string, error) {
	out := map[string]string{}
	for page := 1; ; page++ {
		path, err := d.itemPath(ctx, fmt.Sprintf("/items?per_page=500&page=%d", page))
		if err != nil {
			return nil, err
		}
		var items []struct {
			Key   string `json:"item_key"`
			Value string `json:"item_value"`
		}
		if err := d.do(ctx, http.MethodGet, path, nil, &items); err != nil {
			return nil, err
		}
		for _, it := range items {
			out[it.Key] = it.Value
		}
		if len(items) < 500 {
			return out, nil
		}
	}
}

func (d *Dictionary) Put(ctx context.Context, key, value string) error {
	path, err := d.itemPath(ctx, "/item/"+url.PathEscape(key))
	if err != nil {
		return err
	}
	return d.do(ctx, http.MethodPut, path, url.Values{"item_value": {value}}, nil)
}

func (d *Dictionary) Delete(ctx context.Context, key string) error {
	path, err := d.itemPath(ctx, "/item/"+url.PathEscape(key))
	if err != nil {
		return err
	}
	return d.do(ctx, http.MethodDelete, path, nil, nil)
}
