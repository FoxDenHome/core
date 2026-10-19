package tray

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/kanidm"
	"github.com/FoxDenHome/core/vpn/internal/sshkeys"
)

// Authorized SSH Keys shows which keys may log in to this machine
// (~/.ssh/authorized_keys) next to the owner's keys in Kanidm, which the
// FoxDen servers accept, and the user's own keys in ~/.ssh. Only the local
// file is ever changed: Kanidm is read, as anonymous, like kanidm-unixd on
// the servers does.

const sshKeysTitle = "Authorized SSH Keys"

// sshKeyRow is one key in the dialog.
type sshKeyRow struct {
	Line        int    `json:"line,omitempty"` // in authorized_keys, from 1
	Text        string `json:"text"`
	Tag         string `json:"tag,omitempty"` // Kanidm's label
	Type        string `json:"type,omitempty"`
	Comment     string `json:"comment,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Options     string `json:"options,omitempty"`
	// Invalid is set for local lines that are not keys.
	Invalid string `json:"invalid,omitempty"`
	// Also is where else the key is: "kanidm" for a local key that is in
	// Kanidm too, "local" for another that is already authorized here.
	Also string `json:"also,omitempty"`
}

// sshKeysForm is the dialog's input. It is shown again with Error set until
// the change is saved or cancelled.
type sshKeysForm struct {
	Title   string `json:"title"`
	Message string `json:"message"`
	Error   string `json:"error"`
	Path    string `json:"path"`
	// ReadOnly says why the file cannot be changed here, if it cannot.
	ReadOnly    string      `json:"read_only"`
	Local       []sshKeyRow `json:"local"`
	KanidmUser  string      `json:"kanidm_user"`
	KanidmError string      `json:"kanidm_error"`
	Kanidm      []sshKeyRow `json:"kanidm"`
	Own         []sshKeyRow `json:"own"`
	// Remove and Add are changes not saved yet: lines to drop, and keys
	// to append.
	Remove []int    `json:"remove"`
	Add    []string `json:"add"`
	// Text is the file to edit, for dialogs that edit it as text.
	Text string `json:"text"`

	data []byte // the file as read
}

// sshKeysAnswer is what the dialog returns: either the lines to remove and
// keys to add, or, from a text editor, the whole file.
type sshKeysAnswer struct {
	OK     bool     `json:"ok"`
	Remove []int    `json:"remove"`
	Add    []string `json:"add"`
	Text   *string  `json:"text"`
}

func authorizedKeysPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".ssh", "authorized_keys"), nil
}

// keyRow describes the key in text, which may be a line that is not one.
func keyRow(text string) sshKeyRow {
	r := sshKeyRow{Text: text}
	k, err := sshkeys.ParseKey(text)
	if err != nil {
		r.Invalid = err.Error()
		return r
	}
	r.Type, r.Comment, r.Fingerprint, r.Options = k.Type, k.Comment, k.Fingerprint, k.Options
	return r
}

// ownKeys are the public keys in ~/.ssh, offered for adding.
func ownKeys(dir string) []sshKeyRow {
	files, _ := filepath.Glob(filepath.Join(dir, "*.pub"))
	var out []sshKeyRow
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil || len(b) > 16<<10 {
			continue
		}
		r := keyRow(strings.TrimSpace(string(b)))
		if r.Invalid != "" || strings.HasSuffix(r.Type, "-cert-v01@openssh.com") {
			continue
		}
		if r.Comment == "" {
			r.Comment = filepath.Base(f)
		}
		r.Tag = filepath.Base(f)
		out = append(out, r)
	}
	return out
}

// newSSHKeysForm builds the dialog for the file at path, as data, with the
// owner's Kanidm keys.
func newSSHKeysForm(path string, data []byte, user string, kanidmKeys []kanidm.SSHKey, kanidmErr error) sshKeysForm {
	f := sshKeysForm{
		Title: sshKeysTitle, Path: path, data: data, Text: string(data), KanidmUser: user,
		Local: []sshKeyRow{}, Kanidm: []sshKeyRow{}, Own: []sshKeyRow{},
		Message: "Keys listed under This Machine may log in here over SSH. Your Kanidm keys are " +
			"what the FoxDen servers accept; they are shown for reference and are changed in Kanidm.",
	}
	if target := sshkeys.Linked(path); target != "" {
		f.ReadOnly = "It links to " + target + ", which is managed elsewhere, so it is not changed here."
	}
	local := map[string]bool{}
	for _, l := range sshkeys.Parse(data) {
		if l.Key == nil && l.Err == nil {
			continue // blank or a comment
		}
		r := keyRow(l.Text)
		r.Line = l.Number
		if l.Key != nil {
			local[l.Key.Fingerprint] = true
		}
		f.Local = append(f.Local, r)
	}
	inKanidm := map[string]bool{}
	for _, k := range kanidmKeys {
		r := keyRow(k.Key)
		r.Tag = k.Tag
		if r.Invalid != "" {
			continue
		}
		inKanidm[r.Fingerprint] = true
		if local[r.Fingerprint] {
			r.Also = "local"
		}
		f.Kanidm = append(f.Kanidm, r)
	}
	for i := range f.Local {
		if inKanidm[f.Local[i].Fingerprint] {
			f.Local[i].Also = "kanidm"
		}
	}
	for _, r := range ownKeys(filepath.Dir(path)) {
		if local[r.Fingerprint] {
			r.Also = "local"
		}
		f.Own = append(f.Own, r)
	}
	switch {
	case user == "":
		f.KanidmError = "Your Kanidm keys show up here once this device is registered and has a Kerberos ticket."
	case kanidmErr != nil:
		f.KanidmError = kanidmErr.Error()
	}
	return f
}

// reference is the Kanidm and ~/.ssh keys as text, for dialogs that edit the
// file as text.
func (f sshKeysForm) reference() string {
	var b strings.Builder
	if f.KanidmUser != "" {
		b.WriteString("# Kanidm keys of " + f.KanidmUser + " (accepted by the FoxDen servers):\n")
	} else {
		b.WriteString("# Kanidm keys:\n")
	}
	if f.KanidmError != "" {
		b.WriteString("#   " + f.KanidmError + "\n")
	}
	for _, r := range f.Kanidm {
		b.WriteString(r.Text + "\n")
	}
	if len(f.Own) > 0 {
		b.WriteString("\n# Your keys in ~/.ssh:\n")
		for _, r := range f.Own {
			b.WriteString(r.Text + "\n")
		}
	}
	return b.String()
}

// apply turns the answer into the new file.
func (f sshKeysForm) apply(a sshKeysAnswer) ([]byte, error) {
	if a.Text != nil {
		text := strings.TrimRight(*a.Text, " \t\r\n")
		if text != "" {
			text += "\n"
		}
		if err := sshkeys.Check([]byte(text)); err != nil {
			return nil, err
		}
		return []byte(text), nil
	}
	return sshkeys.Edit(f.data, a.Remove, a.Add)
}

// editSSHKeys shows the dialog and saves what is changed in it.
func (t *tray) editSSHKeys() {
	if !t.sshKeysOpen.CompareAndSwap(false, true) {
		return // already showing
	}
	defer t.sshKeysOpen.Store(false)

	path, err := authorizedKeysPath()
	if err != nil {
		notify(sshKeysTitle, err.Error())
		return
	}
	user := ""
	if t.krb != nil {
		user = t.krb.user()
	}
	var keys []kanidm.SSHKey
	var kerr error
	if user != "" && t.kanidmURL != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		keys, kerr = (&kanidm.Client{URL: t.kanidmURL}).SSHKeys(ctx, user)
		cancel()
	}

	var pending sshKeysAnswer
	errMsg := ""
	for {
		data, err := sshkeys.Read(path)
		if err != nil {
			notify(sshKeysTitle, err.Error())
			return
		}
		f := newSSHKeysForm(path, data, user, keys, kerr)
		f.Error, f.Remove, f.Add = errMsg, pending.Remove, pending.Add
		if pending.Text != nil {
			f.Text = *pending.Text
		}
		a, ok, err := showSSHKeysForm(f)
		if err != nil {
			notify(sshKeysTitle, err.Error())
			return
		}
		if !ok || f.ReadOnly != "" {
			return
		}
		pending = a
		out, err := f.apply(a)
		if err != nil {
			errMsg = err.Error()
			continue
		}
		if bytes.Equal(out, data) {
			return
		}
		// Edited elsewhere while the dialog was open: show it again, with
		// the keys to add but not the lines to remove, which may have moved.
		if now, err := sshkeys.Read(path); err == nil && !bytes.Equal(now, data) {
			errMsg = path + " was changed meanwhile. Here it is again; check it and save once more."
			pending.Remove, pending.Text = nil, nil
			continue
		}
		if err := sshkeys.Write(path, out); err != nil {
			errMsg = err.Error()
			continue
		}
		notify(sshKeysTitle, savedMessage(data, out))
		return
	}
}

// savedMessage says what changed, by counting keys.
func savedMessage(before, after []byte) string {
	fps := func(data []byte) []string {
		var out []string
		for _, l := range sshkeys.Parse(data) {
			if l.Key != nil {
				out = append(out, l.Key.Fingerprint)
			}
		}
		return out
	}
	was, now := fps(before), fps(after)
	added, removed := 0, 0
	for _, fp := range now {
		if !slices.Contains(was, fp) {
			added++
		}
	}
	for _, fp := range was {
		if !slices.Contains(now, fp) {
			removed++
		}
	}
	var parts []string
	if added > 0 {
		parts = append(parts, plural(added, "key", "keys")+" added")
	}
	if removed > 0 {
		parts = append(parts, plural(removed, "key", "keys")+" removed")
	}
	if len(parts) == 0 {
		return "authorized_keys saved."
	}
	return "authorized_keys saved: " + strings.Join(parts, ", ") + "."
}
