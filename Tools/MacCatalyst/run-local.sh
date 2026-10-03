#!/bin/bash
# Build Osho Talks for Mac Catalyst with ad-hoc signing and launch it.
#   Tools/MacCatalyst/run-local.sh [build|test|launch] [extra app arguments...]
# The App Store build on this Mac owns com.agraabhi.oshodiscourses and its sandbox
# container, so local runs use a separate bundle ID and never touch that data.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ACTION="${1:-launch}"; shift || true
DERIVED=build/DerivedData-catalyst
LOCAL_ID=com.agraabhi.oshodiscourses.catalyst-local
APP="$DERIVED/Build/Products/Debug-maccatalyst/OshoDiscourses.app"
# PRODUCT_BUNDLE_IDENTIFIER must be on the command line: an -xcconfig value does
# not reach Info.plist expansion over the target's own setting.
COMMON=(-project OshoDiscourses.xcodeproj -scheme OshoDiscourses
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED"
  -xcconfig Tools/MacCatalyst/LocalRun.xcconfig PRODUCT_BUNDLE_IDENTIFIER="$LOCAL_ID")
case "$ACTION" in
  build) xcodebuild "${COMMON[@]}" build ;;
  # Unit tests drive the host app's real stores (downloads, defaults), so they get
  # their own container instead of wiping the local run's data.
  test) xcodebuild "${COMMON[@]}" PRODUCT_BUNDLE_IDENTIFIER="$LOCAL_ID.tests" \
          -collect-test-diagnostics never "$@" test ;;
  launch)
    xcodebuild "${COMMON[@]}" build -quiet
    pkill -f "$APP/Contents/MacOS/OshoDiscourses" && sleep 2 || true
    if [ $# -gt 0 ]; then open "$APP" --args "$@"; else open "$APP"; fi
    echo "Container: ~/Library/Containers/$LOCAL_ID/Data"
    ;;
  *) echo "usage: $0 [build|test|launch] [app arguments...]" >&2; exit 64 ;;
esac
