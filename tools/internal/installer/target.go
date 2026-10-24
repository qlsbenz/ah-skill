package installer

import (
	"path/filepath"

	"ah-skills/tools/internal/registry"
)

func (in *Installer) resolveTarget(m *registry.Manifest, kind string) (string, error) {
	return filepath.Join(in.ProjectRoot, ".agents", kind), nil
}
