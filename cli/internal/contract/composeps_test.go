package contract

import "testing"

const psNDJSON = `{"Service":"wildfly","State":"running","Health":"","ExitCode":0,"Image":"hms-dbmi/pic-sure-wildfly:LATEST"}
{"Service":"hpds","State":"running","Health":"healthy","ExitCode":0}
{"Service":"picsure-db","State":"exited","Health":"unhealthy","ExitCode":137}`

const psArray = `[{"Service":"wildfly","State":"running","Health":"","ExitCode":0},{"Service":"hpds","State":"running","Health":"healthy","ExitCode":0},{"Service":"picsure-db","State":"exited","Health":"unhealthy","ExitCode":137}]`

func TestParseComposePSBothShapes(t *testing.T) {
	for name, input := range map[string]string{"ndjson": psNDJSON, "array": psArray} {
		t.Run(name, func(t *testing.T) {
			services, err := ParseComposePS([]byte(input))
			if err != nil {
				t.Fatal(err)
			}
			if len(services) != 3 {
				t.Fatalf("got %d services, want 3", len(services))
			}
			if services[0].Service != "wildfly" || services[0].Health != "" {
				t.Errorf("services[0] = %+v", services[0])
			}
			if services[1].Health != "healthy" {
				t.Errorf("services[1] = %+v", services[1])
			}
			if services[2].ExitCode != 137 || services[2].State != "exited" {
				t.Errorf("services[2] = %+v", services[2])
			}
		})
	}
}

func TestParseComposePSEmpty(t *testing.T) {
	for _, input := range []string{"", "\n", "  \n "} {
		services, err := ParseComposePS([]byte(input))
		if err != nil {
			t.Fatal(err)
		}
		if len(services) != 0 {
			t.Errorf("input %q: got %d services, want 0", input, len(services))
		}
	}
}

func TestParseComposePSGarbage(t *testing.T) {
	if _, err := ParseComposePS([]byte("not json at all")); err == nil {
		t.Error("expected error for garbage input")
	}
}
