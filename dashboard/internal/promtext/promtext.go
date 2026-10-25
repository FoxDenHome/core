// Package promtext parses the Prometheus text exposition format, just enough to
// read node_exporter and smartctl_exporter without pulling in client_golang.
package promtext

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
)

type Sample struct {
	Name   string
	Labels map[string]string
	Value  float64
}

type Metrics map[string][]Sample

func Parse(r io.Reader) (Metrics, error) {
	out := Metrics{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' {
			continue
		}
		s, err := parseLine(line)
		if err != nil {
			return nil, err
		}
		out[s.Name] = append(out[s.Name], s)
	}
	return out, sc.Err()
}

func parseLine(line string) (Sample, error) {
	s := Sample{Labels: map[string]string{}}
	i := strings.IndexAny(line, "{ ")
	if i < 0 {
		return s, fmt.Errorf("malformed line %q", line)
	}
	s.Name = line[:i]
	rest := line[i:]
	if rest[0] == '{' {
		var err error
		rest, err = parseLabels(rest[1:], s.Labels)
		if err != nil {
			return s, fmt.Errorf("%w in %q", err, line)
		}
	}
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return s, fmt.Errorf("missing value in %q", line)
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return s, fmt.Errorf("bad value in %q", line)
	}
	s.Value = v
	return s, nil
}

func parseLabels(in string, labels map[string]string) (string, error) {
	for {
		in = strings.TrimLeft(in, " ,")
		if in == "" {
			return "", fmt.Errorf("unterminated labels")
		}
		if in[0] == '}' {
			return in[1:], nil
		}
		eq := strings.IndexByte(in, '=')
		if eq < 0 || len(in) < eq+2 || in[eq+1] != '"' {
			return "", fmt.Errorf("malformed label")
		}
		key := strings.TrimSpace(in[:eq])
		in = in[eq+2:]
		var b strings.Builder
		closed := false
		for i := 0; i < len(in); i++ {
			c := in[i]
			if c == '\\' && i+1 < len(in) {
				i++
				switch in[i] {
				case 'n':
					b.WriteByte('\n')
				default:
					b.WriteByte(in[i])
				}
				continue
			}
			if c == '"' {
				in = in[i+1:]
				closed = true
				break
			}
			b.WriteByte(c)
		}
		if !closed {
			return "", fmt.Errorf("unterminated label value")
		}
		labels[key] = b.String()
	}
}

// Fetch scrapes a /metrics URL.
func Fetch(ctx context.Context, client *http.Client, url string) (Metrics, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return Parse(resp.Body)
}

// Find returns the samples of name whose labels include all of match.
func (m Metrics) Find(name string, match map[string]string) []Sample {
	var out []Sample
outer:
	for _, s := range m[name] {
		for k, v := range match {
			if s.Labels[k] != v {
				continue outer
			}
		}
		out = append(out, s)
	}
	return out
}

// Value returns the first matching sample's value.
func (m Metrics) Value(name string, match map[string]string) (float64, bool) {
	found := m.Find(name, match)
	if len(found) == 0 {
		return 0, false
	}
	return found[0].Value, true
}

// Max returns the largest value of name, or NaN if there is none.
func (m Metrics) Max(name string, match map[string]string) float64 {
	best := math.NaN()
	for _, s := range m.Find(name, match) {
		if math.IsNaN(best) || s.Value > best {
			best = s.Value
		}
	}
	return best
}
