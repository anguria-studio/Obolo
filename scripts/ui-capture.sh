#!/bin/bash
#
# Captures one window of a running app to a PNG, without bringing it to the front
# and without capturing the rest of the screen.
#
# Usage: scripts/ui-capture.sh <pid> <output.png> [window-title-substring]
#
# Use this only for questions that the accessibility tree cannot answer (colour,
# contrast, animation). For layout, state and text, use scripts/ui-dump.swift.

set -euo pipefail

PID="${1:?pid}"
OUT="${2:?output path}"
TITLE="${3:-}"

WINDOW_ID="$(swift - "$PID" "$TITLE" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let title = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list {
    guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let name = window[kCGWindowName as String] as? String ?? ""
    if title.isEmpty || name.localizedCaseInsensitiveContains(title) {
        print(window[kCGWindowNumber as String] as! Int)
        exit(0)
    }
}
exit(1)
SWIFT
)" || { echo "error: no on-screen window for pid $PID${TITLE:+ matching \"$TITLE\"}" >&2; exit 1; }

screencapture -x -o -l "$WINDOW_ID" "$OUT"
echo "$OUT"
