package modules

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

// baseline tracks lifetime counters where an old non-zero value is normal and
// only an increase means something is happening.
type baseline struct {
	mu    sync.Mutex
	first map[string]float64
}

// growth returns how much a counter rose since it was first seen. The baseline
// is in memory, so a restart accepts whatever the counter is at then.
func (b *baseline) growth(key string, v float64) float64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.first == nil {
		b.first = map[string]float64{}
	}
	base, ok := b.first[key]
	if !ok || v < base {
		b.first[key] = v
		return 0
	}
	return v - base
}

// expand turns "0/{1..24},sfp1" into ["0/1", ..., "0/24", "sfp1"].
func expand(spec string) []string {
	var out []string
	for _, item := range splitTop(spec) {
		out = append(out, expandBraces(strings.TrimSpace(item))...)
	}
	return out
}

func splitTop(s string) []string {
	var parts []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '{':
			depth++
		case '}':
			depth--
		case ',':
			if depth == 0 {
				parts = append(parts, s[start:i])
				start = i + 1
			}
		}
	}
	return append(parts, s[start:])
}

func expandBraces(s string) []string {
	open := strings.IndexByte(s, '{')
	if open < 0 {
		if s == "" {
			return nil
		}
		return []string{s}
	}
	end := strings.IndexByte(s[open:], '}')
	if end < 0 {
		return []string{s}
	}
	end += open
	prefix, body, suffix := s[:open], s[open+1:end], s[end+1:]
	var items []string
	if lo, hi, ok := strings.Cut(body, ".."); ok {
		a, errA := strconv.Atoi(lo)
		b, errB := strconv.Atoi(hi)
		if errA != nil || errB != nil {
			return []string{s}
		}
		step := 1
		if b < a {
			step = -1
		}
		for i := a; ; i += step {
			items = append(items, strconv.Itoa(i))
			if i == b {
				break
			}
		}
	} else {
		items = strings.Split(body, ",")
	}
	var out []string
	for _, it := range items {
		for _, rest := range expandBraces(suffix) {
			out = append(out, prefix+it+rest)
		}
		if suffix == "" {
			out = append(out, prefix+it)
		}
	}
	return out
}

func formatDuration(d time.Duration) string {
	if d <= 0 {
		return "0s"
	}
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	mins := int(d.Minutes()) % 60
	switch {
	case days > 0:
		return fmt.Sprintf("%dd %dh", days, hours)
	case hours > 0:
		return fmt.Sprintf("%dh %dm", hours, mins)
	case mins > 0:
		return fmt.Sprintf("%dm", mins)
	default:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
}

func formatBytes(b float64) string {
	units := []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	i := 0
	for b >= 1024 && i < len(units)-1 {
		b /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", b, units[i])
	}
	return fmt.Sprintf("%.1f %s", b, units[i])
}

// formatSize uses decimal units like drive labels do.
func formatSize(b float64) string {
	units := []string{"B", "KB", "MB", "GB", "TB", "PB"}
	i := 0
	for b >= 1000 && i < len(units)-1 {
		b /= 1000
		i++
	}
	return fmt.Sprintf("%.3g %s", b, units[i])
}

func formatBits(bps float64) string {
	units := []string{"bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"}
	i := 0
	for bps >= 1000 && i < len(units)-1 {
		bps /= 1000
		i++
	}
	return fmt.Sprintf("%.1f %s", bps, units[i])
}

// formatSpeed renders an ifHighSpeed value (Mbit/s) the way port labels do.
func formatSpeed(mbps int64) string {
	switch {
	case mbps <= 0:
		return ""
	case mbps >= 1000 && mbps%1000 == 0:
		return fmt.Sprintf("%dG", mbps/1000)
	case mbps >= 1000:
		return fmt.Sprintf("%.1fG", float64(mbps)/1000)
	default:
		return fmt.Sprintf("%dM", mbps)
	}
}

func formatFloat(v float64, unit string) string {
	if math.IsNaN(v) {
		return "—"
	}
	if v == math.Trunc(v) && math.Abs(v) < 1e6 {
		return fmt.Sprintf("%.0f%s", v, unit)
	}
	return fmt.Sprintf("%.1f%s", v, unit)
}
