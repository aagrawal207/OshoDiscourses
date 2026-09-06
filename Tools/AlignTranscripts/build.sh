#!/bin/zsh
# Builds the AlignTranscripts command-line tool into build/AlignTranscripts/,
# compiling the app's own catalog, parser and aligner sources so the timings it
# produces are exactly what the app would compute. Requires macOS 26 (Speech
# framework with SpeechAnalyzer) and Xcode 26's toolchain.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=build/AlignTranscripts
mkdir -p "$out"
shared=(
  OshoDiscourses/Resources/Catalog.swift
  OshoDiscourses/Resources/OshoworldCatalog.swift
  OshoDiscourses/Resources/ArchiveCatalog.swift
  OshoDiscourses/Resources/TranscriptCatalog.swift
  OshoDiscourses/Resources/AlignmentCatalog.swift
  OshoDiscourses/Services/TranscriptParser.swift
  OshoDiscourses/Services/TranscriptFetcher.swift
  OshoDiscourses/Services/TranscriptAligner.swift
  OshoDiscourses/Services/SpeechWordRecognizer.swift
)
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
  -module-name AlignTranscripts \
  "${shared[@]}" Tools/AlignTranscripts/main.swift \
  -o "$out/AlignTranscripts"
# Bundle.main resolves resources next to a bare executable.
cp OshoDiscourses/Resources/{OshoworldCatalog,ArchiveCatalog,TranscriptCatalog}.json "$out/"
echo "built $out/AlignTranscripts"
