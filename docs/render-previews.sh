#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/docs docs/images build/module-cache
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/main.swift').read_text().split('// A real backend probe,')[0]
Path('build/docs/main.swift').write_text(source + Path('docs/render-previews.swift').read_text())
PY
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/docs/main.swift Sources/Features.swift Sources/StatusPresentation.swift -framework AppKit -o build/docs/render
build/docs/render
