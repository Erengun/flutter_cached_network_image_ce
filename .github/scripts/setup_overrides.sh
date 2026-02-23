#!/bin/bash
# Generate pubspec_overrides.yaml files so cross-package dependencies resolve
# locally instead of requiring published versions on pub.dev.
# This is essential for monorepo CI where sibling package versions may not yet
# be published.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# cached_network_image (main package) depends on platform_interface + web
cat > "$REPO_ROOT/cached_network_image/pubspec_overrides.yaml" << 'EOF'
dependency_overrides:
  cached_network_image_platform_interface_ce:
    path: ../cached_network_image_platform_interface
  cached_network_image_web_ce:
    path: ../cached_network_image_web
EOF

# cached_network_image/example depends on platform_interface + web (transitively)
cat > "$REPO_ROOT/cached_network_image/example/pubspec_overrides.yaml" << 'EOF'
dependency_overrides:
  cached_network_image_platform_interface_ce:
    path: ../../cached_network_image_platform_interface
  cached_network_image_web_ce:
    path: ../../cached_network_image_web
EOF

# cached_network_image_web depends on platform_interface
cat > "$REPO_ROOT/cached_network_image_web/pubspec_overrides.yaml" << 'EOF'
dependency_overrides:
  cached_network_image_platform_interface_ce:
    path: ../cached_network_image_platform_interface
EOF

echo "Dependency overrides created successfully."
