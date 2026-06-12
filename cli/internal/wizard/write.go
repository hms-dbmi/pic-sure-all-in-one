package wizard

import (
	"fmt"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

// RunScript / RunScriptInput mirror the commands package's runner seams so
// each host injects its own execution context (inherited stdio for the CLI,
// captured output for the TUI).
type RunScript func(root, script string, args []string) (int, error)

type RunScriptInput func(root, script string, args []string, input string) (int, error)

// WriteChanged writes only the keys whose desired value differs from
// current, each through scripts/env-set.sh. Secret values go via --stdin so
// they never appear in a process argument list. The single write path for
// every wizard host (spec amendment 1).
func WriteChanged(run RunScript, runInput RunScriptInput, root string, current, desired map[string]string) error {
	for _, key := range ChangedKeys(current, desired) {
		var code int
		var err error
		if IsSecretKey(key) {
			code, err = runInput(root, scripts.EnvSet, []string{key, "--stdin"}, desired[key])
		} else {
			// `--` ends env-set.sh option parsing so a user-typed value
			// beginning with `--` is written verbatim instead of being
			// rejected as an unknown option (B20).
			code, err = run(root, scripts.EnvSet, []string{key, "--", desired[key]})
		}
		if err != nil {
			return fmt.Errorf("%s %s: %w", scripts.EnvSet, key, err)
		}
		if code != 0 {
			return fmt.Errorf("%s %s exited %d", scripts.EnvSet, key, code)
		}
	}
	return nil
}
