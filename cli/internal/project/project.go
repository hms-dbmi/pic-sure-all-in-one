// Package project locates the pic-sure-all-in-one checkout root.
package project

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Marker files that identify the repository root. A directory is the root
// iff it contains all of them. scripts/picsure-compose.sh is the
// distinctive one — .env.example + docker-compose.yml alone would match any
// generic compose project and send scripts to the wrong checkout.
var markers = []string{".env.example", "docker-compose.yml", "scripts/picsure-compose.sh"}

// FindRoot returns the repository root.
//
// When override is non-empty it is validated and returned (this backs the
// global --root flag). Otherwise the walk starts at start (typically the
// working directory) and proceeds upward until a directory containing all
// marker files is found.
func FindRoot(start, override string) (string, error) {
	if override != "" {
		abs, err := filepath.Abs(override)
		if err != nil {
			return "", err
		}
		if !isRoot(abs) {
			return "", fmt.Errorf("--root %s does not look like a pic-sure-all-in-one checkout (missing %s)", override, markersList())
		}
		return abs, nil
	}

	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if isRoot(dir) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside a pic-sure-all-in-one checkout: no directory containing %s found from %s upward (use --root to point at one)", markersList(), start)
		}
		dir = parent
	}
}

func isRoot(dir string) bool {
	for _, m := range markers {
		if fi, err := os.Stat(filepath.Join(dir, m)); err != nil || fi.IsDir() {
			return false
		}
	}
	return true
}

func markersList() string {
	return strings.Join(markers, " + ")
}
