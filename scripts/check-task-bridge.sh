#!/bin/sh
# Runs the Task harness (Packages/TaskHarness) and the Task pane's real page bridge (Sources/Varnick/TaskPage.swift) together against the practice
# shop (scripts/task-practice-shop.py): a hidden web view, scripted answers in place of Jev and Claude, and nothing past 127.0.0.1. It is not
# Varnick and starts none: a throwaway process with no window that is ever shown, no focus taken and no profile of yours. Takes a minute to build.
#
#     scripts/check-task-bridge.sh [port=8795]
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
port=${1:-8795}
work=$(mktemp -d) || exit 1
trap 'kill $shop 2>/dev/null; wait $shop 2>/dev/null; rm -rf "$work"' EXIT
mkdir "$work/src"
cp "$repo"/Packages/TaskHarness/Sources/TaskHarness/*.swift "$work/src/"
# The sources of the library and the bridge are compiled as one module here, so the import of the library is left out.
sed '/^import TaskHarness$/d' "$repo/Sources/Varnick/TaskPage.swift" > "$work/src/TaskPage.swift"
sed '/^import TaskHarness$/d' "$repo/Packages/TaskHarness/Sources/task-check/Scripted.swift" > "$work/src/Scripted.swift"
swiftc -O -swift-version 5 -o "$work/bridge-check" "$repo/scripts/task-bridge-check/main.swift" "$work"/src/*.swift
python3 -I -B "$repo/scripts/task-practice-shop.py" "$port" > /dev/null &
shop=$!
sleep 1
"$work/bridge-check" "$port"
