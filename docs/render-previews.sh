#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/docs docs/images build/module-cache
python3 - <<'PY'
from pathlib import Path
full = Path('Sources/main.swift').read_text()
marker = '// Application entry point.'
assert marker in full, 'Sources/main.swift lost the entry-point marker the preview renderer cuts at'
source = full.split(marker)[0]
Path('build/docs/main.swift').write_text(source + Path('docs/render-previews.swift').read_text())
PY
source ./sparkle.sh
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/docs/main.swift Sources/Features.swift Sources/StatusPresentation.swift Sources/Updates.swift -o build/docs/render \
    -framework AppKit -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR"
build/docs/render
