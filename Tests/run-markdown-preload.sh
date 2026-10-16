#!/bin/zsh
set -eu
TIMELINE_PROJECT_DIR="${0:A:h:h}"
TIMELINE_TEST_DIR="${1:-${TMPDIR:-/tmp}/Timeline-MarkdownPreload-$$}"
TIMELINE_TEST_APP="$TIMELINE_TEST_DIR/PreloadCheck.app"
mkdir -p "$TIMELINE_TEST_APP/Contents/MacOS" "$TIMELINE_TEST_APP/Contents/Resources"
ditto "$TIMELINE_PROJECT_DIR/Timeline/Resources/Markdown" "$TIMELINE_TEST_APP/Contents/Resources/Markdown"
python3 - "$TIMELINE_PROJECT_DIR" "$TIMELINE_TEST_APP" "$TIMELINE_TEST_DIR" <<'PY'
from pathlib import Path
import plistlib, sys
project, app, output = map(Path, sys.argv[1:])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'PreloadCheck', 'CFBundleIdentifier': 'local.timeline.preload-check',
    'CFBundleName': 'Timeline Preload Check', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
}))
(output/'Combined.swift').write_text(
    (project/'Timeline/MarkdownPreviewView.swift').read_text() + '\n' +
    (project/'Tests/MarkdownPreloadHarness.swift').read_text())
PY
swiftc -O -parse-as-library "$TIMELINE_TEST_DIR/Combined.swift" -o "$TIMELINE_TEST_APP/Contents/MacOS/PreloadCheck"
"$TIMELINE_TEST_APP/Contents/MacOS/PreloadCheck"
