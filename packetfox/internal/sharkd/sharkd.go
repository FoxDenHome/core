// Package sharkd drives Wireshark's sharkd over JSON-RPC on stdin/stdout,
// for dissection, display filters and the detail tree.
package sharkd

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
)

type Client struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader
	nextID int
	dead   error
}

// Start runs sharkd. home holds its (empty) Wireshark profile.
func Start(binary, home string) (*Client, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	cmd := exec.Command(binary, "-")
	cmd.Env = []string{"HOME=" + home, "XDG_CONFIG_HOME=" + home}
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &Client{cmd: cmd, stdin: stdin, stdout: bufio.NewReaderSize(stdout, 1<<20)}, nil
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type response struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// Error is an error sharkd reported for a request, such as an invalid
// display filter. The process is still usable.
type Error struct{ Message string }

func (e *Error) Error() string { return e.Message }

func (c *Client) Call(method string, params any, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dead != nil {
		return c.dead
	}
	c.nextID++
	req, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": c.nextID, "method": method, "params": params})
	if err != nil {
		return err
	}
	if _, err := c.stdin.Write(append(req, '\n')); err != nil {
		c.dead = fmt.Errorf("sharkd: %w", err)
		return c.dead
	}
	for {
		line, err := c.stdout.ReadBytes('\n')
		if err != nil {
			c.dead = fmt.Errorf("sharkd exited: %w", err)
			return c.dead
		}
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var resp response
		if err := json.Unmarshal(line, &resp); err != nil {
			continue
		}
		if resp.ID != c.nextID {
			continue
		}
		if resp.Error != nil {
			return &Error{Message: resp.Error.Message}
		}
		if result == nil {
			return nil
		}
		return json.Unmarshal(resp.Result, result)
	}
}

// Load opens a capture file. maxPackets > 0 stops after that many, so a
// file that is still being written can be read up to the last whole block.
func (c *Client) Load(file string, maxPackets int) error {
	params := map[string]any{"file": file}
	if maxPackets > 0 {
		params["max_packets"] = maxPackets
	}
	var r struct {
		Status string `json:"status"`
	}
	if err := c.Call("load", params, &r); err != nil {
		return err
	}
	if r.Status != "OK" {
		return errors.New("sharkd load: " + r.Status)
	}
	return nil
}

type FrameRow struct {
	Columns []string `json:"c"`
	Num     int      `json:"num"`
	BG      string   `json:"bg,omitempty"`
	FG      string   `json:"fg,omitempty"`
}

// Frames lists frames matching a display filter. The columns are
// Wireshark's defaults: No., Time, Source, Destination, Protocol, Length,
// Info.
func (c *Client) Frames(filter string, skip, limit int) ([]FrameRow, error) {
	params := map[string]any{"limit": limit}
	if skip > 0 { // sharkd rejects 0
		params["skip"] = skip
	}
	if filter != "" {
		params["filter"] = filter
	}
	var rows []FrameRow
	err := c.Call("frames", params, &rows)
	return rows, err
}

// Frame returns the detail tree and bytes of one frame, as sharkd sends
// them.
func (c *Client) Frame(num int) (json.RawMessage, error) {
	var raw json.RawMessage
	err := c.Call("frame", map[string]any{"frame": num, "proto": true, "bytes": true}, &raw)
	return raw, err
}

func (c *Client) Check(filter string) error {
	return c.Call("check", map[string]any{"filter": filter}, nil)
}

// Follow reassembles a stream, for "Follow TCP/UDP stream".
func (c *Client) Follow(proto, filter string) (json.RawMessage, error) {
	var raw json.RawMessage
	err := c.Call("follow", map[string]any{"follow": proto, "filter": filter}, &raw)
	return raw, err
}

func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dead == nil {
		c.dead = errors.New("sharkd closed")
	}
	c.stdin.Close()
	_ = c.cmd.Process.Kill()
	_ = c.cmd.Wait()
}
