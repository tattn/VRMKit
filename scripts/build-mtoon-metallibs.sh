#!/bin/bash
# Precompiles the RealityKit MToon shader into per-platform Metal libraries.
#
# CustomMaterial shaders must be compiled offline (TN3133): SwiftPM/Xcode Metal
# compilation of package targets is not reliable across build environments
# (swift build does not compile .metal, and Xcode 26+ requires a separately
# installed Metal Toolchain). The resulting .metallib files are committed to
# the repository and loaded at runtime with MTLDevice.makeLibrary(URL:).
#
# Run this script whenever anything the metallibs are built from changes --
# the shader sources, the compile settings below, or this script:
#   ./scripts/build-mtoon-metallibs.sh
#
# Pass --check to only verify that the recorded build inputs match the current
# ones (no Metal toolchain required), which is what CI runs:
#   ./scripts/build-mtoon-metallibs.sh --check
set -euo pipefail

cd "$(dirname "$0")/.."

SHADERS="Sources/VRMRealityKit/Shaders"
SOURCE="$SHADERS/MToon.metal"
CORE_HEADER="$SHADERS/MToonCore.h"
RESOURCES="Sources/VRMRealityKit/Resources"
# Spelled out rather than taken from $0, which varies with how the script is invoked.
SCRIPT="scripts/build-mtoon-metallibs.sh"

# Pin the Metal Shading Language version instead of relying on the compiler
# default (which advances with new toolchains). MSL 2.4 matches the minimum
# deployment targets below (macOS 12 / iOS 15) and the RealityKit shader API.
# Override with MSL_STD after verifying compatibility on the oldest targets.
MSL_STD="${MSL_STD:-metal2.4}"
COMPILE_FLAGS=(-Wall -Wextra -Werror)

# sdk | -std= prefix | deployment target flag | output metallib.
# Minimum OS versions match the CustomMaterial availability used by VRMEntityLoader.
TARGETS=(
    "macosx|macos-|-mmacosx-version-min=12.0|MToon-macos.metallib"
    "iphoneos|ios-|-mios-version-min=15.0|MToon-ios.metallib"
    "iphonesimulator|ios-|-miphonesimulator-version-min=15.0|MToon-iossim.metallib"
)

# Everything the compiled metallibs depend on. Hashing only the shader sources
# would report "up to date" after a change to the language version, a
# deployment target, a compile flag or this script.
MANIFEST_FILE="$SHADERS/MToonMetallibInputs.txt"

build_inputs() {
    echo "msl-std=$MSL_STD"
    echo "flags=${COMPILE_FLAGS[*]}"
    printf 'target=%s\n' "${TARGETS[@]}"
    shasum -a 256 "$CORE_HEADER" "$SOURCE" "$SCRIPT"
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f "$MANIFEST_FILE" ]; then
        echo "Missing $MANIFEST_FILE. Run ./$SCRIPT." >&2
        exit 1
    fi
    if ! diff -u "$MANIFEST_FILE" <(build_inputs); then
        echo "MToon metallib build inputs changed without regenerating the metallibs." >&2
        echo "Run ./$SCRIPT and commit the regenerated resources." >&2
        exit 1
    fi
    echo "Bundled MToon metallibs are up to date."
    exit 0
fi

# The MToon entry points are [[visible]] functions, which are not entry points
# as far as the Metal compiler is concerned, so the per-entry-point limits are
# never checked when they are compiled on their own. RealityKit links them into
# the shaders it generates at runtime, where exceeding a limit fails the
# pipeline silently and the mesh simply stops drawing -- so the limit that the
# sampler table is up against is checked here, by compiling the shader's
# sampling code as a real fragment function.
PROBE_SOURCE="$(mktemp -t MToonEntryPointProbe).metal"
trap 'rm -f "$PROBE_SOURCE"' EXIT
cat > "$PROBE_SOURCE" <<PROBE
#include "MToon.metal"

// Reaches every constant sampler the surface shaders reach, from a function the
// compiler does enforce the entry-point limits on.
fragment half4 mtoonEntryPointProbe(float4 position [[position]],
                                    texture2d<half> texture [[texture(0)]],
                                    constant float4 &samplerParameters [[buffer(0)]])
{
    return mtoonSample(texture, position.xy, half4(samplerParameters))
         + texture.sample(mtoonParameterSampler, position.xy);
}
PROBE

verify_entry_point_limits() {
    local sdk="$1" std_prefix="$2" min_flag="$3"
    echo "Verifying entry-point limits for $sdk"
    if ! xcrun -sdk "$sdk" metal \
        "${COMPILE_FLAGS[@]}" \
        "-std=${std_prefix}${MSL_STD}" \
        "$min_flag" \
        -I "$SHADERS" \
        -o /dev/null \
        -c "$PROBE_SOURCE"; then
        echo "$SOURCE exceeds a Metal entry-point limit on $sdk; RealityKit would fail to build the pipeline at runtime." >&2
        exit 1
    fi
}

mkdir -p "$RESOURCES"

for target in "${TARGETS[@]}"; do
    IFS='|' read -r sdk std_prefix min_flag output <<< "$target"
    verify_entry_point_limits "$sdk" "$std_prefix" "$min_flag"
    echo "Compiling $SOURCE for $sdk -> $output (-std=${std_prefix}${MSL_STD})"
    xcrun -sdk "$sdk" metal \
        "${COMPILE_FLAGS[@]}" \
        "-std=${std_prefix}${MSL_STD}" \
        "$min_flag" \
        -o "$RESOURCES/$output" \
        "$SOURCE"
done

# Record the build inputs so CI can detect stale metallibs.
build_inputs > "$MANIFEST_FILE"

echo "Done. Regenerated metallibs:"
ls -la "$RESOURCES"/MToon-*.metallib "$MANIFEST_FILE"
