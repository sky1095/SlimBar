#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/profile-test build/module-cache
python3 - <<'PY'
from pathlib import Path
full = Path('Sources/main.swift').read_text()
marker = '// Application entry point.'
assert marker in full, 'Sources/main.swift lost the entry-point marker the tests cut at'
source = full.split(marker)[0]
Path('build/profile-test/main.swift').write_text(source + Path('Tests/profile-cycle.swift').read_text())
PY
source ./sparkle.sh
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/profile-test/main.swift Sources/Features.swift Sources/StatusPresentation.swift Sources/Updates.swift -o build/profile-test/check \
    -framework AppKit -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR"
build/profile-test/check "$@"
