package actions

import (
	"strings"
	"testing"
)

func feed(b *OutputBuffer, chunks ...string) {
	for _, c := range chunks {
		b.Feed([]byte(c))
	}
}

func TestOutputBufferCRLFIsNewline(t *testing.T) {
	b := NewOutputBuffer()
	feed(b, "alpha\r\nbeta\r\n")
	if got := b.String(); got != "alpha\nbeta" {
		t.Errorf("String() = %q, want alpha/beta lines (PTYs emit CRLF)", got)
	}
}

func TestOutputBufferCarriageReturnRewritesLine(t *testing.T) {
	// git/docker progress: repeated \r rewrites of the same line.
	b := NewOutputBuffer()
	feed(b, "Receiving objects:   1%\rReceiving objects:  50%\rReceiving objects: 100%, done.\r\nnext\r\n")
	got := b.String()
	if strings.Contains(got, "1%") || strings.Contains(got, "50%") {
		t.Errorf("intermediate progress states leaked: %q", got)
	}
	if got != "Receiving objects: 100%, done.\nnext" {
		t.Errorf("String() = %q", got)
	}
}

func TestOutputBufferLiveRewriteVisible(t *testing.T) {
	// A rewrite still in progress (no newline yet) must show its latest state.
	b := NewOutputBuffer()
	feed(b, "step 1/9\rstep 2/9")
	if got := b.String(); got != "step 2/9" {
		t.Errorf("String() = %q, want the latest rewrite", got)
	}
}

func TestOutputBufferKeepsSGRDropsOtherEscapes(t *testing.T) {
	b := NewOutputBuffer()
	feed(b, "\x1b[32mgreen\x1b[0m plain\n\x1b[2Kerased-prefix\n\x1b]0;title\x07after-osc\n")
	got := b.String()
	if !strings.Contains(got, "\x1b[32mgreen\x1b[0m") {
		t.Errorf("SGR color sequences must survive: %q", got)
	}
	if strings.Contains(got, "\x1b[2K") || strings.Contains(got, "\x1b]") {
		t.Errorf("non-SGR control sequences must be stripped: %q", got)
	}
	if !strings.Contains(got, "erased-prefix") || !strings.Contains(got, "after-osc") {
		t.Errorf("text around stripped sequences lost: %q", got)
	}
}

func TestOutputBufferEscapeSplitAcrossChunks(t *testing.T) {
	b := NewOutputBuffer()
	feed(b, "\x1b[", "32mhi\x1b[0m\r", "\nbye\r\n")
	got := b.String()
	if !strings.Contains(got, "\x1b[32mhi\x1b[0m") || !strings.Contains(got, "bye") {
		t.Errorf("split escape/CRLF mishandled: %q", got)
	}
	if strings.Count(got, "\n") != 1 {
		t.Errorf("want exactly two lines, got %q", got)
	}
}

func TestOutputBufferDropsBareControlChars(t *testing.T) {
	b := NewOutputBuffer()
	feed(b, "a\x07b\x0bc\ttab\n") // BEL, VT dropped; tab kept
	if got := b.String(); got != "abc\ttab" {
		t.Errorf("String() = %q", got)
	}
}

func TestOutputBufferLineCap(t *testing.T) {
	b := NewOutputBuffer()
	for i := 0; i < maxBufferLines+50; i++ {
		b.Feed([]byte("line\n"))
	}
	if n := strings.Count(b.String(), "\n") + 1; n > maxBufferLines {
		t.Errorf("buffer holds %d lines, want cap %d", n, maxBufferLines)
	}
}
