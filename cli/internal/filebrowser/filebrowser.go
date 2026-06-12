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

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

// chromeHeight is the number of lines the wrapper draws around the filepicker
// itself (title + the inline hint/error line). SetSize subtracts it from the
// height handed to us so the filepicker's own list never overruns the box the
// parent reserved for the whole component.
const chromeHeight = 2

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

	return Model{fp: fp, title: opts.Title}
}

// Init starts the initial directory read.
func (m Model) Init() tea.Cmd {
	return m.fp.Init()
}

// SetSize lays the picker out within a w×h box. Only the height matters to the
// filepicker (it sets how many rows the list shows); width is reserved for the
// parent's framing. A non-positive interior height is clamped to 1 so the
// filepicker never computes a negative window.
func (m *Model) SetSize(w, h int) {
	_ = w
	interior := h - chromeHeight
	if m.title == "" {
		interior = h - 1 // no title line, only the hint line
	}
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

// View renders the title, the filepicker, and an inline hint/error line.
func (m Model) View() string {
	var b strings.Builder

	if m.title != "" {
		b.WriteString(styles.Title.Render(m.title))
		b.WriteByte('\n')
	}

	b.WriteString(m.fp.View())
	b.WriteByte('\n')

	b.WriteString(m.hintLine())
	return b.String()
}

// hintLine is the bottom status line: a permission/disabled-file error if one
// is pending, otherwise a "no matching files" notice when the current directory
// holds nothing the user can select. The notice is suppressed in dir mode (any
// directory is itself a valid place to be) and when an error is already shown.
func (m Model) hintLine() string {
	if m.err != nil {
		return styles.Bad.Render(m.err.Error())
	}
	if !m.fp.DirAllowed && !m.dirHasSelectable() {
		return styles.Warn.Render("no matching files in this directory")
	}
	return ""
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
