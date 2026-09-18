#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/profile-test build/module-cache
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/main.swift').read_text().split('// A real backend probe,')[0]
Path('build/profile-test/main.swift').write_text(source + Path('Tests/profile-cycle.swift').read_text())
PY
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/profile-test/main.swift Sources/Features.swift Sources/StatusPresentation.swift -o build/profile-test/check -framework AppKit
build/profile-test/check "$@"
