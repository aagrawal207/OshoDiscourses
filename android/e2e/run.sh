#!/usr/bin/env bash
# Runs every Maestro flow against one device and writes a JUnit report.
#
#   e2e/run.sh [--install] [--device SERIAL] [--out DIR] [--flow FILE]
#
# --install builds and installs the debug app first. The default device is emulator-5554 and the
# default output is build/e2e. Flows download one 5 MB talk over the real network and delete it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
android_dir="$(dirname "$here")"
device="emulator-5554"
out="$android_dir/build/e2e"
install=false
target="$here/flows"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) install=true; shift ;;
    --device) device="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --flow) target="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SERIAL="$device"
adb="$ANDROID_HOME/platform-tools/adb"
command -v maestro >/dev/null || { echo "maestro is not on PATH (https://maestro.dev)" >&2; exit 2; }
"$adb" -s "$device" get-state >/dev/null

if $install; then
  (cd "$android_dir" && ./gradlew :app:installDebug --max-workers=6 -q)
fi
"$adb" -s "$device" shell pm path com.agraabhi.oshodiscourses >/dev/null \
  || { echo "the debug app is not installed on $device; pass --install" >&2; exit 2; }

# Flows assume portrait, normal text size, light system theme and a network connection.
"$adb" -s "$device" shell settings put system font_scale 1.0
"$adb" -s "$device" shell cmd uimode night no >/dev/null
"$adb" -s "$device" shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true

mkdir -p "$out"
status=0
maestro --device "$device" test \
  --format junit --output "$out/report.xml" \
  --test-output-dir "$out/artifacts" \
  "$target" || status=$?

echo "JUnit report: $out/report.xml"
echo "Screenshots and logs: $out/artifacts"
exit $status
