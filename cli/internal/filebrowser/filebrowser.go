// Package filebrowser wraps the Bubbles filepicker into a small, self-contained
// Bubble Tea component for the "Load your data" wizard's file/dir picker. The
// wrapper exists so the wizard does not have to know the filepicker's
// event-driven selection protocol (DidSelectFile must be called on every msg)
// or replicate the absolute-path / "no matching files" handling — it just
// drives Update and polls Selected().
package filebrowser

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/filepicker"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

// fixedChrome is the number of fixed lines the wrapper draws around the
// filepicker's own list: the current-directory path header, the navigation
// key-hint line, and a status slot (the disabled-file error / "no matching
// files" notice). The status slot is always reserved — rendered empty when
// there is nothing to say — so the component's height is constant regardless of
// error state and never overflows the box the parent reserved. SetSize adds the
// optional title line on top of this.
const fixedChrome = 3

// Options configures a Model. The zero value is valid: it browses the current
// working directory and allows any file.
type Options struct {
	// AllowedExts limits selectable files to these extensions (e.g.
	// {".csv", ".tsv"}). Each must include the leading dot. Empty means any
	// file is selectable. Ignored when DirMode is set.
	AllowedExts []string

	// DirMode makes directories selectable instead of files. AllowedExts is
	// cleared in this mode (extension filtering is meaningless for dirs).
	DirMode bool

	// StartDir is the directory the picker opens in. Empty defaults to the
	// process working directory (or "." if that cannot be determined), matching
	// the filepicker's own default.
	StartDir string

	// Title is the heading drawn above the picker. Empty omits the heading.
	Title string
}

// Model is the file browser component. Construct it with New.
type Model struct {
	fp    filepicker.Model
	title string

	// dirMode mirrors Options.DirMode so View can word the nav hint for the
	// active mode ("use this dir" vs "select") without re-deriving it from the
	// filepicker's DirAllowed/FileAllowed flags.
	dirMode bool

	// w is the box width handed to SetSize. View needs it to left-elide a long
	// current-directory path so the header never overflows the frame.
	w int

	// selectedPath is the absolute path the user chose; selected reports whether
	// a choice has been made. The parent learns of a selection by polling
	// Selected() after each Update rather than via a custom tea.Msg: the
	// filepicker's selection is itself only observable by calling DidSelectFile
	// on the msg passed to Update (it is not a message the filepicker emits), so
	// a poll on the same model the parent already holds is both simpler and
	// avoids inventing a message that would have to round-trip through the
	// program loop before the parent could act on it.
	selectedPath string
	selected     bool

	// err holds the most recent disabled-file or directory-read error so View
	// can surface it inline. It is sticky until the next successful navigation
	// clears it.
	err error

	// lastScanDir / hasSelectable cache a cheap directory scan keyed by the
	// filepicker's CurrentDirectory. The filepicker keeps its entry list and
	// its readDir messages unexported, so the wrapper cannot ask it whether the
	// current directory holds anything selectable; we re-scan ourselves only
	// when CurrentDirectory changes to drive the "no matching files" hint.
	lastScanDir   string
	hasSelectable bool
}

// New builds a Model from opts. The filepicker is configured but not yet
// reading the directory — call Init for that.
func New(opts Options) Model {
	fp := filepicker.New()

	start := opts.StartDir
	if start == "" {
		// Mirror filepicker's own "." fallback, but prefer an explicit cwd so the
		// header and navigation start from a real, resolvable path rather than a
		// relative "." that reads oddly once the user steps into a subdir.
		if wd, err := os.Getwd(); err == nil {
			start = wd
		} else {
			start = "."
		}
	}
	fp.CurrentDirectory = start

	if opts.DirMode {
		fp.DirAllowed = true
		fp.FileAllowed = false
		fp.AllowedTypes = []string{} // extension filtering is meaningless for dirs
	} else {
		fp.DirAllowed = false
		fp.FileAllowed = true
		fp.AllowedTypes = append([]string{}, opts.AllowedExts...)
	}

	// Brand the selection cursor/row so the picker reads as part of the PIC-SURE
	// palette; everything else keeps the filepicker defaults (which already
	// degrade under NO_COLOR via lipgloss).
	fp.Styles.Cursor = fp.Styles.Cursor.Foreground(styles.Brand)
	fp.Styles.Selected = lipgloss.NewStyle().Foreground(styles.Brand).Bold(true)

	return Model{fp: fp, title: opts.Title, dirMode: opts.DirMode}
}

// Init starts the initial directory read.
func (m Model) Init() tea.Cmd {
	return m.fp.Init()
}

// SetSize lays the picker out within a w×h box. The width is kept so View can
// left-elide a long current-directory path to fit the frame; the height sets how
// many rows the filepicker's list shows. The interior height is the box height
// minus the wrapper's chrome (path header + nav hint + status slot, plus the
// title line when present); a non-positive interior is clamped to 1 so the
// filepicker never computes a negative window.
func (m *Model) SetSize(w, h int) {
	m.w = w
	chrome := fixedChrome
	if m.title != "" {
		chrome++
	}
	interior := h - chrome
	if interior < 1 {
		interior = 1
	}
	// AutoHeight would otherwise overwrite Height from WindowSizeMsg; we own the
	// sizing here, so disable it and set Height directly via SetHeight (which
	// also reclamps the scroll window).
	m.fp.AutoHeight = false
	m.fp.SetHeight(interior)
}

// Update advances the filepicker and records a selection or error when one
// occurs on this msg. The filepicker only sets its internal Path inside its own
// Update, so we must Update first and *then* test the returned model for a
// selection on the same msg — hence DidSelectFile is called on the post-Update
// model.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	prevDir := m.fp.CurrentDirectory

	var cmd tea.Cmd
	m.fp, cmd = m.fp.Update(msg)

	if ok, path := m.fp.DidSelectFile(msg); ok {
		// Resolve to absolute so the parent gets a path that is stable regardless
		// of the process working directory — the filepicker joins entries onto
		// CurrentDirectory, which may be relative (".") when StartDir was empty
		// and Getwd failed.
		if abs, err := filepath.Abs(path); err == nil {
			path = abs
		}
		m.selectedPath = path
		m.selected = true
		m.err = nil
		return m, cmd
	}

	if ok, path := m.fp.DidSelectDisabledFile(msg); ok {
		m.err = &selectError{path: path}
	}

	// A directory change (navigation) clears any sticky disabled-file error.
	if m.fp.CurrentDirectory != prevDir {
		m.err = nil
	}

	// Re-warm the selectable-entry cache when the directory we last scanned no
	// longer matches the picker's current one. Doing it here (where the model is
	// mutable and returned) keeps View — which runs on a value receiver and
	// cannot persist a cache — a pure read of pre-computed state.
	if m.lastScanDir != m.fp.CurrentDirectory {
		m.lastScanDir = m.fp.CurrentDirectory
		m.hasSelectable = scanSelectable(m.fp.CurrentDirectory, m.fp.AllowedTypes, m.fp.ShowHidden)
	}

	return m, cmd
}

// Selected reports the absolute path the user chose, if any. The parent polls
// this after each Update; ok is false until a selection has been made.
func (m Model) Selected() (path string, ok bool) {
	return m.selectedPath, m.selected
}

// Err returns the most recent surfaced error (a disabled-file selection or a
// directory read failure), or nil. It is cleared on the next navigation or
// successful selection.
func (m Model) Err() error {
	return m.err
}

// Dir returns the directory the picker is currently showing. This is the value
// set at construction time (from Options.StartDir, or os.Getwd() if empty) and
// is updated as the user navigates. Tests use it to assert that the browser
// opens at the expected root rather than the process working directory.
func (m Model) Dir() string {
	return m.fp.CurrentDirectory
}

// View renders, top to bottom: an optional title, the current-directory path
// header, the filepicker's list, the navigation key-hint line, and a status
// slot (disabled-file error or "no matching files" notice). The status slot is
// always present (empty when there is nothing to surface) so the rendered height
// matches what SetSize reserved and the component never overflows its box.
func (m Model) View() string {
	var b strings.Builder

	if m.title != "" {
		b.WriteString(styles.Title.Render(m.title))
		b.WriteByte('\n')
	}

	b.WriteString(m.pathHeader())
	b.WriteByte('\n')

	b.WriteString(m.fp.View())
	b.WriteByte('\n')

	b.WriteString(m.navHint())
	b.WriteByte('\n')

	b.WriteString(m.statusLine())
	return b.String()
}

// pathHeader renders the directory the picker is currently in, brand-styled and
// left-elided to the box width so the tail (where the user is) stays visible
// even for a deep path. With no width yet (View called before SetSize) the path
// is shown untruncated.
func (m Model) pathHeader() string {
	path := m.fp.CurrentDirectory
	if m.w > 0 {
		path = elideLeft(path, m.w)
	}
	return styles.Title.Render(path)
}

// navHint is the always-present key-hint line. It leads with the "←/h .." up
// affordance the picker otherwise hides, then the descend and confirm keys; the
// confirm verb reflects the mode ("use this dir" in dir mode, "select" for a
// file). Dim so it reads as chrome, not content.
func (m Model) navHint() string {
	confirm := "enter select"
	if m.dirMode {
		confirm = "enter use this dir"
	}
	hint := "←/h ..  ·  →/l open  ·  " + confirm
	return hintStyle.Render(hint)
}

// statusLine is the reserved bottom slot: a permission/disabled-file error if
// one is pending, otherwise a "no matching files" notice when the current
// directory holds nothing the user can select. The notice is suppressed in dir
// mode (any directory is itself a valid place to be) and when an error is
// already shown. Returns the empty string when there is nothing to surface — the
// slot's line is still emitted by View so the layout height stays constant.
func (m Model) statusLine() string {
	if m.err != nil {
		return styles.Bad.Render(m.err.Error())
	}
	if !m.fp.DirAllowed && !m.dirHasSelectable() {
		return styles.Warn.Render("no matching files in this directory")
	}
	return ""
}

// hintStyle dims the navigation key-hint so it reads as chrome. Faint degrades
// to plain text under NO_COLOR via lipgloss, same as the rest of the palette.
var hintStyle = lipgloss.NewStyle().Faint(true)

// elideLeft truncates path from the left to fit width w, prefixing "…" so the
// tail (the current directory) stays visible. It is rune/display-width aware
// (via the ansi package, which also accounts for wide characters), so a path
// with multibyte components is never split mid-grapheme or measured by byte
// length. A path already within w is returned unchanged.
func elideLeft(path string, w int) string {
	if w <= 0 {
		return path
	}
	width := ansi.StringWidth(path)
	if width <= w {
		return path
	}
	const prefix = "…"
	// Drop just enough leading width that "…" + the remaining tail fits in w:
	// the result width is 1 (prefix) + (width - drop), so drop = width - w + 1.
	//
	// TruncateLeft drops graphemes until the accumulated width *exceeds* drop, so
	// a display-width-2 grapheme straddling the cut boundary is kept whole and the
	// result can come back one column too wide. Re-truncate with a larger drop
	// until the rendered width fits — each extra unit removes at least one column,
	// so this converges in at most one extra step for a single straddling wide
	// grapheme.
	for drop := width - w + 1; drop < width; drop++ {
		out := ansi.TruncateLeft(path, drop, prefix)
		if ansi.StringWidth(out) <= w {
			return out
		}
	}
	// Degenerate fallback (w smaller than the prefix itself): the prefix alone.
	return prefix
}

// dirHasSelectable reports whether CurrentDirectory contains at least one entry
// the user could select. It reads the cache Update warms; if the cache is stale
// (e.g. View is called before any Update — the unsized/un-inited path) it falls
// back to a live scan so the hint is never wrong, just not memoized.
func (m Model) dirHasSelectable() bool {
	if m.lastScanDir == m.fp.CurrentDirectory {
		return m.hasSelectable
	}
	return scanSelectable(m.fp.CurrentDirectory, m.fp.AllowedTypes, m.fp.ShowHidden)
}

// scanSelectable reports whether dir holds a non-hidden file matching one of
// exts (empty exts means any file qualifies). It mirrors the filepicker's own
// canSelect/hidden logic so the hint agrees with what the list actually offers.
func scanSelectable(dir string, exts []string, showHidden bool) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !showHidden && strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if matchesExt(e.Name(), exts) {
			return true
		}
	}
	return false
}

func matchesExt(name string, exts []string) bool {
	if len(exts) == 0 {
		return true
	}
	for _, ext := range exts {
		if strings.HasSuffix(name, ext) {
			return true
		}
	}
	return false
}

// selectError reports that the user tried to select a file the picker disallows
// (wrong extension), carrying the offending path for an actionable message.
type selectError struct{ path string }

func (e *selectError) Error() string {
	return "cannot select " + filepath.Base(e.path) + ": not an allowed file type"
}
