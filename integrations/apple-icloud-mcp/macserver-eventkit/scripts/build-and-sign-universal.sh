#!/usr/bin/env bash
# build-and-sign-universal.sh
# Multi-architecture compilation, lipo bundling, and strict code signing for EventKitBridgeServer.
# Target: Intel x86_64 (MacServer) & Apple Silicon arm64 (M5 Host)
# macOS 14.0+ deployment target with Hardened Runtime and embedded Info.plist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$PACKAGE_DIR/Info.plist"
BUILD_DIR_X86="$PACKAGE_DIR/.build-x86_64"
BUILD_DIR_ARM="$PACKAGE_DIR/.build-arm64"
OUTPUT_DIR="$PACKAGE_DIR/.build/release"
OUTPUT_BIN="$OUTPUT_DIR/EventKitBridgeServer"
METADATA_JSON="$PACKAGE_DIR/BUILD_METADATA.json"
IDENTIFIER="com.muse.macserver-eventkit"

echo "=== EventKitBridgeServer Multi-Architecture Build & Code Signing Pipeline ==="
echo "Package directory: $PACKAGE_DIR"
echo "Info.plist:        $INFO_PLIST"
echo "Target binary:     $OUTPUT_BIN"

if [ ! -f "$INFO_PLIST" ]; then
  echo "FATAL: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

plutil -lint "$INFO_PLIST" >/dev/null || {
  echo "FATAL: Info.plist failed syntax validation" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"

# 1. Clean previous build scratches
echo "--> 1. Building x86_64 thin release binary..."
swift build \
  --package-path "$PACKAGE_DIR" \
  --triple x86_64-apple-macosx \
  -c release \
  --scratch-path "$BUILD_DIR_X86" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST"

BIN_X86="$BUILD_DIR_X86/out/Products/Release/EventKitBridgeServer"
if [ ! -f "$BIN_X86" ]; then
  echo "FATAL: x86_64 binary not produced at $BIN_X86" >&2
  exit 1
fi
echo "  [OK] x86_64 binary built."

# 2. Build arm64 thin release binary
echo "--> 2. Building arm64 thin release binary..."
swift build \
  --package-path "$PACKAGE_DIR" \
  --triple arm64-apple-macosx \
  -c release \
  --scratch-path "$BUILD_DIR_ARM" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST"

BIN_ARM="$BUILD_DIR_ARM/out/Products/Release/EventKitBridgeServer"
if [ ! -f "$BIN_ARM" ]; then
  echo "FATAL: arm64 binary not produced at $BIN_ARM" >&2
  exit 1
fi
echo "  [OK] arm64 binary built."

# 3. Create Universal Mach-O Fat Binary via lipo
echo "--> 3. Merging thin binaries into Universal binary via lipo..."
lipo -create -output "$OUTPUT_BIN" "$BIN_X86" "$BIN_ARM"
chmod 755 "$OUTPUT_BIN"

LIPO_INFO=$(lipo -info "$OUTPUT_BIN")
echo "  Lipo output: $LIPO_INFO"
if ! echo "$LIPO_INFO" | grep -q "x86_64" || ! echo "$LIPO_INFO" | grep -q "arm64"; then
  echo "FATAL: Universal binary does not contain both x86_64 and arm64 architectures!" >&2
  exit 1
fi
echo "  [OK] Universal binary contains both architectures."

# 4. Strict Code Signing of Universal Binary
# IMPORTANT: codesign on fat binary signs both architectures simultaneously with specified identifier and runtime options.
echo "--> 4. Code signing Universal binary (Hardened Runtime + Identifier: $IDENTIFIER)..."
codesign -s - --identifier "$IDENTIFIER" --options runtime --force "$OUTPUT_BIN"

# 5. Strict Signature Verification on ALL Architectures
# Enforce: codesign --verify --strict --all-architectures MUST pass. codesign -dv alone is strictly insufficient.
echo "--> 5. Strict Code Signature Verification (--verify --strict --all-architectures)..."
if ! codesign --verify --strict --all-architectures -vvv "$OUTPUT_BIN"; then
  echo "FATAL: Code signing verification failed on universal binary!" >&2
  exit 1
fi
echo "  [PASS] All architectures strictly verified and valid on disk."

# 6. Extract and Record Architecture Metadata
echo "--> 6. Extracting metadata..."
UNIVERSAL_SHA=$(shasum -a 256 "$OUTPUT_BIN" | awk '{print $1}')
DESIGNATED_REQ=$(codesign -d -r- "$OUTPUT_BIN" 2>&1 | tail -n 1)

# x86_64 details
X86_CDHASH=$(codesign -dvvv --arch=x86_64 "$OUTPUT_BIN" 2>&1 | grep "^CDHash=" | cut -d= -f2)
X86_FLAGS=$(codesign -dvvv --arch=x86_64 "$OUTPUT_BIN" 2>&1 | grep "^CodeDirectory" | sed -E 's/.*flags=([^ ]+).*/\1/')
X86_MINOS=$(otool -arch x86_64 -l "$OUTPUT_BIN" | awk '/LC_BUILD_VERSION/{getline; getline; getline; print $2}' | tr -d '\n')
X86_INFOPLIST=$(otool -arch x86_64 -l "$OUTPUT_BIN" | grep -c "sectname __info_plist" || true)

# arm64 details
ARM_CDHASH=$(codesign -dvvv --arch=arm64 "$OUTPUT_BIN" 2>&1 | grep "^CDHash=" | cut -d= -f2)
ARM_FLAGS=$(codesign -dvvv --arch=arm64 "$OUTPUT_BIN" 2>&1 | grep "^CodeDirectory" | sed -E 's/.*flags=([^ ]+).*/\1/')
ARM_MINOS=$(otool -arch arm64 -l "$OUTPUT_BIN" | awk '/LC_BUILD_VERSION/{getline; getline; getline; print $2}' | tr -d '\n')
ARM_INFOPLIST=$(otool -arch arm64 -l "$OUTPUT_BIN" | grep -c "sectname __info_plist" || true)

if [ "$X86_INFOPLIST" -lt 1 ] || [ "$ARM_INFOPLIST" -lt 1 ]; then
  echo "FATAL: Embedded __info_plist section missing from one or both slices!" >&2
  exit 1
fi

echo "=========================================================="
echo "Universal Binary SHA256: $UNIVERSAL_SHA"
echo "Designated Requirement:  $DESIGNATED_REQ"
echo "--- x86_64 Architecture ---"
echo "  CDHash:        $X86_CDHASH"
echo "  Flags:         $X86_FLAGS"
echo "  Min OS Target: macOS $X86_MINOS"
echo "  Info.plist:    Embedded (__TEXT,__info_plist)"
echo "--- arm64 Architecture ---"
echo "  CDHash:        $ARM_CDHASH"
echo "  Flags:         $ARM_FLAGS"
echo "  Min OS Target: macOS $ARM_MINOS"
echo "  Info.plist:    Embedded (__TEXT,__info_plist)"
echo "=========================================================="

# 7. Write Structured BUILD_METADATA.json (binary hashes + source provenance)
# Provenance (commit / dirty state / toolchain) is mandatory: without it there is no
# evidence that a deployed binary corresponds to a reviewable commit. See R1-01.
echo "--> 7. Writing BUILD_METADATA.json with source provenance..."
python3 "$SCRIPT_DIR/write_build_metadata.py" \
  --identifier "$IDENTIFIER" \
  --repo-root "$PACKAGE_DIR" \
  --binary-sha256 "$UNIVERSAL_SHA" \
  --designated-requirement "$DESIGNATED_REQ" \
  --x86-cdhash "$X86_CDHASH" \
  --x86-flags "$X86_FLAGS" \
  --x86-minos "$X86_MINOS" \
  --arm-cdhash "$ARM_CDHASH" \
  --arm-flags "$ARM_FLAGS" \
  --arm-minos "$ARM_MINOS" \
  --out "$METADATA_JSON"

# 8. Strict Verification of Generated Metadata JSON
echo "--> 8. Validating generated JSON integrity..."
if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$METADATA_JSON" 2>/dev/null; then
  echo "FATAL: BUILD_METADATA.json failed JSON syntax validation!" >&2
  exit 1
fi
echo "  [PASS] BUILD_METADATA.json verified valid JSON syntax."

echo "Build metadata written to $METADATA_JSON"
echo "=== Build and Signing Pipeline Complete ==="
