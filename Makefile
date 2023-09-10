PLATFORM_IOS = iOS Simulator,id=$(call udid_for,iPhone,iOS-16)

test: test-package test-vrmkit test-vrmscenekit

test-package:
	xcodebuild test -scheme VRMKit-Package -destination platform="$(PLATFORM_IOS)"

define udid_for
$(shell xcrun simctl list --json devices available $(1) | jq -r 'last(.devices | to_entries | sort_by(.key) | .[] | select(.key | contains("$(2)"))) | .value | last.udid')
endef

