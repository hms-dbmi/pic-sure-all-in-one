package actions

import "strings"

// maxBufferLines caps retained sanitized output (matches the log pane's
// scrollback budget).
const maxBufferLines = 2000

// maxPendingLen force-breaks a pathological never-terminated line.
const maxPendingLen = 64 * 1024

// OutputBuffer assembles a raw PTY byte stream into text that is safe to
// hand to a viewport. Raw PTY output is full of terminal control traffic —
// CRLF newlines, carriage-return progress rewrites (git/docker/maven),
// erase-line and cursor-movement CSI sequences, OSC titles — which, rendered
// verbatim, moves the REAL terminal cursor and shreds the TUI frame.
//
// The buffer emulates just enough of a terminal: \r\n is a newline, a bare
// \r rewrites the current line (progress bars collapse to their latest
// state, still visible live before the newline arrives), SGR color
// sequences pass through, every other escape sequence and control byte is
// dropped. Escape sequences and CRLF pairs split across Feed chunks are
// handled.
type OutputBuffer struct {
	lines     []string
	pending   []byte
	esc       []byte // in-progress escape sequence, including the ESC
	inOSC     bool
	crPending bool
}

// NewOutputBuffer returns an empty buffer.
func NewOutputBuffer() *OutputBuffer { return &OutputBuffer{} }

// Feed consumes one PTY chunk.
func (o *OutputBuffer) Feed(data []byte) {
	for _, b := range data {
		if len(o.esc) > 0 {
			o.feedEscape(b)
			continue
		}

		if o.crPending {
			o.crPending = false
			if b == '\n' {
				o.commit()
				continue
			}
			o.pending = o.pending[:0] // bare \r: rewrite the line
		}

		switch {
		case b == 0x1b:
			o.esc = append(o.esc, b)
		case b == '\n':
			o.commit()
		case b == '\r':
			o.crPending = true
		case b == '\t' || b >= 0x20:
			o.pending = append(o.pending, b)
			if len(o.pending) > maxPendingLen {
				o.commit()
			}
		default:
			// BEL, VT, backspace, other C0 controls: drop.
		}
	}
}

// feedEscape accumulates one escape sequence and keeps it only if it is an
// SGR (color) sequence.
func (o *OutputBuffer) feedEscape(b byte) {
	o.esc = append(o.esc, b)

	if len(o.esc) == 2 {
		switch b {
		case '[': // CSI — continue accumulating
			return
		case ']': // OSC — runs until BEL or ST
			o.inOSC = true
			return
		default: // two-byte sequence (charset selection etc.): drop
			o.resetEscape()
			return
		}
	}

	if o.inOSC {
		// OSC terminates on BEL or ST (ESC \).
		if b == 0x07 || (b == '\\' && len(o.esc) >= 2 && o.esc[len(o.esc)-2] == 0x1b) {
			o.resetEscape()
		}
		return
	}

	// CSI: parameter bytes 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
	if b >= 0x40 && b <= 0x7e {
		if b == 'm' {
			o.pending = append(o.pending, o.esc...) // SGR: keep colors
		}
		o.resetEscape()
	}
}

func (o *OutputBuffer) resetEscape() {
	o.esc = o.esc[:0]
	o.inOSC = false
}

func (o *OutputBuffer) commit() {
	o.lines = append(o.lines, string(o.pending))
	o.pending = o.pending[:0]
	if len(o.lines) > maxBufferLines {
		o.lines = o.lines[len(o.lines)-maxBufferLines:]
	}
}

// String renders the sanitized scrollback, including the live (unterminated)
// last line.
func (o *OutputBuffer) String() string {
	if len(o.pending) == 0 {
		return strings.Join(o.lines, "\n")
	}
	parts := make([]string, 0, len(o.lines)+1)
	parts = append(parts, o.lines...)
	parts = append(parts, string(o.pending))
	return strings.Join(parts, "\n")
}
