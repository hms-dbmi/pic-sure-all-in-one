// Package tty answers "may we prompt the user?" without external deps.
package tty

import "os"

// IsInteractive reports whether both stdin and stdout are character devices
// (terminals). Prompting is only allowed when this is true; otherwise
// commands must fail fast naming the flags that replace the prompt.
func IsInteractive() bool {
	return isCharDevice(os.Stdin) && isCharDevice(os.Stdout)
}

func isCharDevice(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
