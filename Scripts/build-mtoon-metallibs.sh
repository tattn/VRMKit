#!/bin/bash
# Precompiles the RealityKit MToon shader into per-platform Metal libraries.
#
# CustomMaterial shaders must be compiled offline (TN3133): SwiftPM/Xcode Metal
# compilation of package targets is not reliable across build environments
# (swift build does not compile .metal, and Xcode 26+ requires a separately
# installed Metal Toolchain). The resulting .metallib files are committed to
# the repository and loaded at runtime with MTLDevice.makeLibrary(URL:).
#
# Run this script whenever Sources/VRMRealityKit/Shaders/MToon.metal changes:
#   ./Scripts/build-mtoon-metallibs.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Sources/VRMRealityKit/Shaders/MToon.metal"
RESOURCES="Sources/VRMRealityKit/Resources"

mkdir -p "$RESOURCES"

compile() {
    local sdk="$1"
    local min_flag="$2"
    local output="$3"
    echo "Compiling $SOURCE for $sdk -> $output"
    xcrun -sdk "$sdk" metal "$min_flag" -o "$RESOURCES/$output" "$SOURCE"
}

# Minimum OS versions match the CustomMaterial availability used by VRMEntityLoader.
compile macosx          -mmacosx-version-min=12.0            MToon-macos.metallib
compile iphoneos        -mios-version-min=15.0               MToon-ios.metallib
compile iphonesimulator -miphonesimulator-version-min=15.0   MToon-iossim.metallib

# Record the shader source hash so tests can detect stale metallibs.
shasum -a 256 "$SOURCE" | awk '{print $1}' > "$RESOURCES/MToonShaderSource.sha256"

echo "Done. Regenerated metallibs:"
ls -la "$RESOURCES"/MToon-*.metallib "$RESOURCES/MToonShaderSource.sha256"
