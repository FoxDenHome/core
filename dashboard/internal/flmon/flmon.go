// Package flmon talks to the FLMON telnet monitor of BDT FlexStor II tape
// libraries (IBM TS3100/TS3200, Dell TL2000/TL4000, ...). The monitor needs
// no login for its read-only commands and serves one session at a time.
package flmon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	prompt  = "FLMON>"
	success = "Command executed successfully"

	promptTimeout = 3 * time.Second
)

const (
	iac  = 255
	dont = 254
	do   = 253
	wont = 252
	will = 251
	sb   = 250
	se   = 240
)

// ErrBusy means the monitor accepted the connection but never prompted,
// which is what it does while another session is open.
var ErrBusy = errors.New("telnet monitor busy (another session open?)")

type Session struct {
	conn net.Conn
	buf  bytes.Buffer
}

// Dial connects and waits for the first prompt.
func Dial(ctx context.Context, addr string) (*Session, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	s := &Session{conn: conn}
	// A busy monitor never prompts; don't spend the whole poll finding out.
	wait := time.Now().Add(promptTimeout)
	if dl, ok := ctx.Deadline(); ok && dl.Before(wait) {
		wait = dl
	}
	_ = conn.SetDeadline(wait)
	if _, err := s.readUntil(func(b []byte) bool { return bytes.Contains(b, []byte(prompt)) }); err != nil {
		_ = conn.Close()
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil, ErrBusy
		}
		return nil, err
	}
	s.buf.Reset()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	} else {
		_ = conn.SetDeadline(time.Time{})
	}
	return s, nil
}

func (s *Session) Close() {
	_ = s.conn.Close()
}

// Run sends a command and returns its output, without the echo, the success
// line and the status bytes that follow it.
func (s *Session) Run(cmd string) (string, error) {
	if _, err := s.conn.Write([]byte(cmd + "\r\n")); err != nil {
		return "", err
	}
	out, err := s.readUntil(func(b []byte) bool {
		i := bytes.Index(b, []byte(success))
		return i >= 0 && bytes.Contains(b[i:], []byte(prompt))
	})
	if err != nil {
		return "", fmt.Errorf("%s: %w", cmd, err)
	}
	s.buf.Reset()
	text := string(out)
	text = text[:strings.Index(text, success)]
	// Some commands print a stray prompt before the success line.
	text = strings.ReplaceAll(text, prompt, "")
	// The monitor echoes the command.
	if first, rest, ok := strings.Cut(text, "\n"); ok && strings.TrimSpace(first) == cmd {
		text = rest
	}
	return text, nil
}

// readUntil reads into the buffer, answering telnet negotiation, until done
// says the buffer is complete.
func (s *Session) readUntil(done func([]byte) bool) ([]byte, error) {
	chunk := make([]byte, 4096)
	for !done(s.buf.Bytes()) {
		n, err := s.conn.Read(chunk)
		if n > 0 {
			s.feed(chunk[:n])
		}
		if err != nil {
			return nil, err
		}
	}
	return s.buf.Bytes(), nil
}

// feed strips telnet commands from data, refusing every option offered.
func (s *Session) feed(data []byte) {
	for i := 0; i < len(data); i++ {
		b := data[i]
		if b != iac || i+1 >= len(data) {
			if b != 0 && b != '\r' {
				s.buf.WriteByte(b)
			}
			continue
		}
		switch c := data[i+1]; c {
		case do, dont, will, wont:
			if i+2 < len(data) {
				opt := data[i+2]
				switch c {
				case do:
					_, _ = s.conn.Write([]byte{iac, wont, opt})
				case will:
					_, _ = s.conn.Write([]byte{iac, dont, opt})
				}
			}
			i += 2
		case sb:
			end := bytes.Index(data[i:], []byte{iac, se})
			if end < 0 {
				i = len(data)
			} else {
				i += end + 1
			}
		default:
			i++
		}
	}
}

// Fields is a block of "Key : value" pairs.
type Fields map[string]string

// Status is the output of "stat".
type Status struct {
	Library Fields
	Drives  []Fields
}

// ParseStatus reads "stat". Blocks are laid out in two columns of a 20
// character key, ": " and an 18 character value; overlong values push the
// right column out, so a line that doesn't fit the grid is read as one pair.
// Keys under a "Port X Identifier" line get that port's prefix, since every
// port repeats Status, Link and Speed.
func ParseStatus(text string) Status {
	var st Status
	cur := Fields{}
	st.Library = cur
	prefix := ""
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, " ")
		if strings.HasPrefix(line, "Drive No. ") && strings.Contains(line, "Information:") {
			cur = Fields{}
			st.Drives = append(st.Drives, cur)
			prefix = ""
			continue
		}
		if line == "" {
			// Port blocks end at a blank line.
			prefix = ""
			continue
		}
		for _, kv := range splitColumns(line) {
			k, v := kv[0], kv[1]
			if strings.HasPrefix(k, "Port ") && strings.HasSuffix(k, " Identifier") {
				prefix = strings.TrimSuffix(k, "Identifier")
			} else if prefix != "" {
				k = prefix + k
			}
			if _, dup := cur[k]; !dup {
				cur[k] = v
			}
		}
	}
	return st
}

func splitColumns(line string) [][2]string {
	if len(line) < 22 || line[20:22] != ": " {
		return nil
	}
	left := strings.TrimSpace(line[:20])
	if len(line) > 62 && line[60:62] == ": " && line[40] != ' ' {
		return [][2]string{
			{left, strings.TrimSpace(line[22:40])},
			{strings.TrimSpace(line[40:60]), strings.TrimSpace(line[62:])},
		}
	}
	return [][2]string{{left, strings.TrimSpace(line[22:])}}
}

// Element is one row of the inventory table.
type Element struct {
	Kind       string // "Mailslot", "Slot", "Drive" or "Transp."
	Number     int
	Address    int    // library element address
	Medium     string // "Data 6", "Clean 1", "" when empty
	Barcode    string
	Loads      int  // loads of the cartridge in it, -1 when not shown
	Access     bool // element is accessible
	Exceptions string
}

func (e Element) Full() bool {
	return e.Medium != "" || e.Barcode != ""
}

func (e Element) Cleaning() bool {
	return strings.HasPrefix(e.Medium, "Clean")
}

type Inventory struct {
	Elements []Element
	// Settings holds the "Key: value" lines after the table (loader mode,
	// autoclean, ...).
	Settings Fields
}

var settingRe = regexp.MustCompile(`^([A-Za-z][\w ]*?\w)\s*:\s+(.*)$`)

// ParseInventory reads "inv". Each table has a header naming its columns;
// values sit under their header, so columns are cut at the header positions.
func ParseInventory(text string) Inventory {
	inv := Inventory{Settings: Fields{}}
	var cols map[string]int
	kind := ""
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, " ")
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) > 3 && f[1] == "Lib-Elem." {
			kind = f[0]
			cols = map[string]int{}
			for _, h := range []string{"Lib-Elem.", "Medium", "PVT", "Loads", "Exceptions"} {
				cols[h] = strings.Index(line, h)
			}
			// "A HC" or "AIHC": the accessible flag is the first letter.
			cols["A"] = cols["Loads"] + len("Loads") + 3
			continue
		}
		if cols != nil {
			if n, err := strconv.Atoi(f[0]); err == nil && len(line) > cols["Medium"] {
				e := Element{Kind: kind, Number: n, Loads: -1}
				addr := strings.TrimSpace(cut(line, cols["Lib-Elem."], cols["Medium"]))
				if _, a, ok := strings.Cut(addr, "-"); ok {
					e.Address, _ = strconv.Atoi(strings.TrimSpace(a))
				}
				e.Medium = strings.Join(strings.Fields(cut(line, cols["Medium"], cols["PVT"])), " ")
				e.Barcode = strings.TrimSpace(cut(line, cols["PVT"], cols["Loads"]-3))
				if l, err := strconv.Atoi(strings.TrimSpace(cut(line, cols["Loads"]-3, cols["A"]-1))); err == nil {
					e.Loads = l
				}
				e.Access = strings.TrimSpace(cut(line, cols["A"], cols["A"]+1)) == "1"
				e.Exceptions = strings.TrimSpace(cut(line, cols["Exceptions"], len(line)))
				inv.Elements = append(inv.Elements, e)
				continue
			}
		}
		if m := settingRe.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			cols = nil
			inv.Settings[m[1]] = strings.TrimSpace(m[2])
		}
	}
	return inv
}

func cut(s string, from, to int) string {
	from = max(0, min(from, len(s)))
	to = max(from, min(to, len(s)))
	return s[from:to]
}

// Table reads a whitespace-separated table whose rows start with a number,
// as "fst", "rets" and "adir" print them. Rows are keyed by section (the
// header's first word, e.g. "Slot", "Drive", "Motor") and then row number.
func Table(text string) map[string]map[int][]string {
	out := map[string]map[int][]string{}
	section := ""
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || strings.HasPrefix(f[0], "---") {
			continue
		}
		n, err := strconv.Atoi(f[0])
		if err != nil {
			section = f[0]
			continue
		}
		if out[section] == nil {
			out[section] = map[int][]string{}
		}
		out[section][n] = f[1:]
	}
	return out
}

// Activity is the output of "dra <drive>".
type Activity struct {
	Activity string
	// Flags lists the flags that are set.
	Flags []string
}

func ParseActivity(text string) Activity {
	var a Activity
	var names []string
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		switch {
		case len(f) == 0:
		case f[0] == "Activity:":
			a.Activity = strings.Join(f[1:], " ")
		case f[0] == "Flags:" || f[0] == "ExtFlags:":
			for i, v := range f[1:] {
				if v != "0" && i < len(names) {
					a.Flags = append(a.Flags, names[i])
				}
			}
			names = nil
		default:
			names = f
		}
	}
	return a
}

// LogEntry is one entry of the error log ("edp").
type LogEntry struct {
	Time    time.Time
	Source  string // "LIB/ERR", ...
	Message string
}

var logHeadRe = regexp.MustCompile(`^(\d\d\.\d\d\.\d\d \d\d:\d\d:\d\d)\.\d+\s+(\S+?)<`)

// ParseLog reads "edp", newest first as the library prints it. An entry is a
// header with its sense bytes in <...>, possibly spanning lines, then the text.
// Times are the library's local time, read as UTC.
func ParseLog(text string) []LogEntry {
	var out []LogEntry
	var cur *LogEntry
	for _, line := range strings.Split(text, "\n") {
		if m := logHeadRe.FindStringSubmatch(line); m != nil {
			t, _ := time.Parse("06.01.02 15:04:05", m[1])
			out = append(out, LogEntry{Time: t, Source: m[2]})
			cur = &out[len(out)-1]
		}
		if cur == nil {
			continue
		}
		if _, msg, ok := strings.Cut(line, ">"); ok {
			cur.Message = strings.TrimSpace(msg)
			cur = nil
		}
	}
	return out
}
