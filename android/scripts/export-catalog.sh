#!/bin/bash
# Exports the iOS static catalog for the Android port. The Swift sources stay the only
# hand-edited copy; this compiles them unchanged with swiftc and writes:
#   core/model/src/main/resources/catalog/catalog.json   series, curated lists, metadata
#   core/model/src/test/resources/catalog/discourses.tsv every discourse id and its URLs
#   core/model/src/test/resources/catalog/series.tsv     per-series cover, counts, metadata
#   core/model/src/test/resources/catalog/themes.tsv     theme chip labels (Foundation `capitalized`)
# The TSV files are golden data for CatalogGoldenTest.
#
# Regenerate on a Mac with Xcode command-line tools after editing Catalog.swift,
# SeriesMetadata.swift or any shipped catalog JSON, then commit the outputs:
#   android/scripts/export-catalog.sh
#   (cd android && ./gradlew :core:model:test)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
android_dir="$(dirname "$script_dir")"
resources="$(dirname "$android_dir")/OshoDiscourses/Resources"
work="$(mktemp -d "${TMPDIR:-/tmp}/export-catalog.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A command-line tool's Bundle.main is its own directory, so the JSON sits beside the binary.
cp "$resources/OshoworldCatalog.json" "$resources/ArchiveCatalog.json" \
    "$resources/TranscriptCatalog.json" "$work/"

swiftc -swift-version 5 -O -module-name ExportCatalog \
    "$resources/Catalog.swift" \
    "$resources/SeriesMetadata.swift" \
    "$resources/OshoworldCatalog.swift" \
    "$resources/ArchiveCatalog.swift" \
    "$resources/TranscriptCatalog.swift" \
    "$script_dir/export-catalog/main.swift" \
    -o "$work/export-catalog"

"$work/export-catalog" \
    "$android_dir/core/model/src/main/resources/catalog/catalog.json" \
    "$android_dir/core/model/src/test/resources/catalog"
