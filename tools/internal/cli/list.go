package cli

import (
	"fmt"
	"os"
	"path/filepath"

	"ah-skills/tools/internal/fsutil"
	"ah-skills/tools/internal/registry"
)

func runList(args []string) error {
	what := "all"
	if len(args) > 0 {
		what = args[0]
	}
	if what != "all" && what != "domains" && what != "skills" {
		return fmt.Errorf("unknown list target %q (want domains|skills)", what)
	}

	harnessRoot, err := registry.ResolveHarnessRoot(".")
	if err != nil {
		return err
	}
	reg, err := registry.LoadRegistry(harnessRoot)
	if err != nil {
		return err
	}

	if what == "all" || what == "domains" {
		fmt.Println("domains:")
		for _, name := range reg.DomainNames() {
			m := reg.Domains[name]
			status := "available"
			for _, envVar := range m.RequiresEnv {
				if os.Getenv(envVar) == "" {
					status = fmt.Sprintf("blocked — needs $%s", envVar)
					break
				}
			}
			if status == "available" {
				for _, bin := range m.RequiresBin {
					if !fsutil.HasBin(bin) {
						status = fmt.Sprintf("blocked — needs %q binary", bin)
						break
					}
				}
			}
			fmt.Printf("  %-10s %-24s %s\n", name, "["+status+"]", m.Description)
		}
	}
	if what == "all" || what == "skills" {
		fmt.Println("skills:")
		for _, name := range reg.DomainNames() {
			skillsDir := filepath.Join(harnessRoot, "domains", name, "skills")
			entries, err := os.ReadDir(skillsDir)
			if err != nil {
				continue
			}
			for _, e := range entries {
				if e.IsDir() {
					fmt.Printf("  %-30s (%s)\n", e.Name(), name)
				}
			}
		}
	}
	return nil
}
