#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/menu-test build/module-cache
python3 - <<'PY'
from pathlib import Path
full = Path('Sources/main.swift').read_text()
marker = '// Application entry point.'
assert marker in full, 'Sources/main.swift lost the entry-point marker the tests cut at'
source = full.split(marker)[0]
Path('build/menu-test/main.swift').write_text(source + Path('Tests/menu-refresh.swift').read_text() + Path('Tests/features.swift').read_text() + Path('Tests/status-presentation.swift').read_text() + Path('Tests/android.swift').read_text() + Path('Tests/analytics.swift').read_text())
PY
source ./sparkle.sh
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" build/menu-test/main.swift Sources/Features.swift Sources/Android.swift Sources/StatusPresentation.swift Sources/Updates.swift Sources/Analytics.swift -o build/menu-test/check \
    -framework AppKit -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR"
build/menu-test/check | tee build/menu-test/results.txt
grep -q 'PASS: all status presentation checks completed' build/menu-test/results.txt
