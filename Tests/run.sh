#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/menu-test build/module-cache
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/main.swift').read_text().split('// A real backend probe,')[0]
Path('build/menu-test/main.swift').write_text(source + Path('Tests/menu-refresh.swift').read_text() + Path('Tests/features.swift').read_text() + Path('Tests/status-presentation.swift').read_text())
PY
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/menu-test/main.swift Sources/Features.swift Sources/StatusPresentation.swift -o build/menu-test/check -framework AppKit
build/menu-test/check | tee build/menu-test/results.txt
grep -q 'PASS: all status presentation checks completed' build/menu-test/results.txt
