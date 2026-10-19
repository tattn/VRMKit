#!/bin/bash
# Runs the package tests on the newest simulator of a platform.
#
#   ./scripts/test-on-simulator.sh <sim platform> <runtime platform> <device name> [result bundle]
#   ./scripts/test-on-simulator.sh "watchOS Simulator" watchOS Watch TestResults/watchOS.xcresult
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 3 ]; then
	echo "usage: $0 <sim platform> <runtime platform> <device name> [result bundle]" >&2
	exit 1
fi
SIM_PLATFORM="$1"
RUNTIME_PLATFORM="$2"
DEVICE_NAME="$3"
# A result bundle is what tells a runner that never launched from a failing test.
RESULT_BUNDLE="${4:-$(mktemp -d)/TestResults.xcresult}"

udid_for_latest() {
	xcrun simctl list --json devices available | jq -r --arg name "$DEVICE_NAME" --arg platform "$RUNTIME_PLATFORM" '
		def ver(k): (k | capture("SimRuntime\\." + $platform + "-(?<major>\\d+)-(?<minor>\\d+)")) as $m
			| [$m.major | tonumber, $m.minor | tonumber];
		.devices | to_entries
		| map(select(.key | test("SimRuntime\\." + $platform + "-\\d+-\\d+")))
		| sort_by(ver(.key)) | last
		| .value | map(select(.name | contains($name))) | last
		| .udid // empty'
}

# simctl can list a device whose runtime disk image is not mounted yet, and xcodebuild
# then sees the runtime as (null) and refuses the destination. Booting first makes
# CoreSimulator mount the runtime.
boot() {
	local attempt
	for attempt in 1 2 3; do
		if xcrun simctl bootstatus "$1" -b >/dev/null; then return 0; fi
		echo "Simulator $1 did not boot (attempt $attempt)" >&2
		sleep 10
	done
	return 1
}

# The CI runner's simulator can still drop its runtime while xcodebuild launches the
# test runners, failing every one of them before a single test runs.
only_runners_failed() {
	xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null | jq -e '
		(.testFailures | length) > 0
		and all(.testFailures[]; .testName | test("^(The test runner|xctest) encountered an error$"))' >/dev/null
}

dest_id="$(udid_for_latest)"
if [ -z "$dest_id" ]; then
	echo "No simulator found for $DEVICE_NAME on $RUNTIME_PLATFORM" >&2
	exit 1
fi

for attempt in 1 2; do
	boot "$dest_id"
	rm -rf "$RESULT_BUNDLE"
	status=0
	xcodebuild test -scheme VRMKit-Package -destination "platform=$SIM_PLATFORM,id=$dest_id" \
		-resultBundlePath "$RESULT_BUNDLE" || status=$?
	if [ "$status" -eq 0 ] || [ "$attempt" -eq 2 ] || ! only_runners_failed; then
		exit "$status"
	fi
	echo "The test runners failed to launch on $dest_id; rebooting it and testing again" >&2
	xcrun simctl shutdown "$dest_id" || true
done
