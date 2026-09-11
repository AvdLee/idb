#!/bin/bash

set -euo pipefail

artifact_root="${1:-SPM/xcframeworks/FBSimulatorControl.xcframework}"

if [[ ! -d "$artifact_root" ]]; then
  echo "error: XCFramework directory does not exist: $artifact_root" >&2
  exit 2
fi

otool_path="$(xcrun --find otool)"
nm_path="$(xcrun --find nm)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/idb-axp-scan.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

binary_count=0
failure_count=0

while IFS= read -r binary; do
  binary_count=$((binary_count + 1))
  load_commands="$temporary_directory/load-commands-$binary_count.txt"
  undefined_symbols="$temporary_directory/undefined-symbols-$binary_count.txt"

  if ! "$otool_path" -l "$binary" >"$load_commands" 2>&1; then
    echo "error: failed to inspect Mach-O load commands: $binary" >&2
    failure_count=$((failure_count + 1))
    continue
  fi

  if ! /usr/bin/awk '
    $1 == "cmd" { command = $2 }
    /AccessibilityPlatformTranslation[.]framework/ && command != "LC_LOAD_WEAK_DYLIB" { exit 1 }
  ' "$load_commands"; then
    echo "error: AccessibilityPlatformTranslation is not weak-linked: $binary" >&2
    failure_count=$((failure_count + 1))
  fi

  if ! "$nm_path" -m -u "$binary" >"$undefined_symbols" 2>&1; then
    echo "error: failed to inspect undefined symbols: $binary" >&2
    failure_count=$((failure_count + 1))
    continue
  fi

  if ! /usr/bin/awk '
    /_OBJC_(CLASS|METACLASS)_\$_AXP[A-Za-z0-9_]+/ && $0 !~ /weak external/ { exit 1 }
  ' "$undefined_symbols"; then
    echo "error: strongly imported AXP Objective-C class symbol found: $binary" >&2
    failure_count=$((failure_count + 1))
  fi
done < <(/usr/bin/find "$artifact_root" -type f -name FBSimulatorControl -print)

if [[ "$binary_count" -eq 0 ]]; then
  echo "error: no FBSimulatorControl framework binaries found under $artifact_root" >&2
  exit 2
fi

if [[ "$failure_count" -ne 0 ]]; then
  echo "FBSimulatorControl runtime-linkage verification failed." >&2
  exit 1
fi

echo "Verified $binary_count FBSimulatorControl binary slice(s): AccessibilityPlatformTranslation and AXP imports are weak."
