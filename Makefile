PLATFORM_IOS = iOS Simulator,id=$(call udid_for,iPhone,iOS-18)
PLATFORM_WATCHOS = watchOS Simulator,id=$(call udid_for,Watch,watchOS-11)

test: test-package

test-package:
	for platform in "$(PLATFORM_IOS)" "$(PLATFORM_WATCHOS)"; do\
		xcodebuild test -scheme VRMKit-Package -destination platform="$$platform" || exit 1;\
	done

define udid_for
$(shell xcrun simctl list --json devices available $(1) | jq -r 'last(.devices | to_entries | sort_by(.key) | .[] | select(.key | contains("$(2)"))) | .value | last.udid')
endef

