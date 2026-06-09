// Command validate checks JSON on stdin against the script contract.
// Used by the smoke harness: `go run ./smoke/validate status < doc.json`.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: validate status|preflight < document.json")
		os.Exit(2)
	}
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "validate:", err)
		os.Exit(1)
	}
	switch os.Args[1] {
	case "status":
		_, err = contract.ParseStatus(data)
	case "preflight":
		_, err = contract.ParsePreflight(data)
	default:
		fmt.Fprintln(os.Stderr, "usage: validate status|preflight < document.json")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "validate:", err)
		os.Exit(1)
	}
}
