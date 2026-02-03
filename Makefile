PLATFORM_MATRIX ?= \
	"iOS,iOS Simulator,iPhone" \
	"watchOS,watchOS Simulator,Watch" \
	"xrOS,visionOS Simulator,Apple Vision Pro"

.PHONY: test test-package-platform build-examples build-example-ios build-example-vision build-example-macos build-example-watch

EXAMPLE_PROJECT ?= Example/Example.xcodeproj
IOS_SIM_DEST ?= generic/platform=iOS Simulator
VISIONOS_SIM_DEST ?= generic/platform=visionOS Simulator
MACOS_DEST ?= platform=macOS
WATCHOS_SIM_DEST ?= generic/platform=watchOS Simulator

build-examples: build-example-ios build-example-vision build-example-macos build-example-watch

build-example-ios:
	@set -e; \
	echo "==> Building VRMExample (iOS Simulator)"; \
	xcodebuild -project "$(EXAMPLE_PROJECT)" -scheme VRMExample -destination "$(IOS_SIM_DEST)" build

build-example-vision:
	@set -e; \
	echo "==> Building VisionExample (visionOS Simulator)"; \
	xcodebuild -project "$(EXAMPLE_PROJECT)" -scheme VisionExample -destination "$(VISIONOS_SIM_DEST)" build

build-example-macos:
	@set -e; \
	echo "==> Building MacExample (macOS)"; \
	xcodebuild -project "$(EXAMPLE_PROJECT)" -scheme MacExample -destination "$(MACOS_DEST)" build

build-example-watch:
	@set -e; \
	echo "==> Building WatchExample (watchOS Simulator)"; \
	xcodebuild -project "$(EXAMPLE_PROJECT)" -scheme "WatchExample Watch App" -destination "$(WATCHOS_SIM_DEST)" build

test:
	@set -e; \
	for entry in $(PLATFORM_MATRIX); do \
		old_ifs="$$IFS"; IFS=,; set -- $$entry; IFS="$$old_ifs"; \
		platform="$$1"; sim="$$2"; device="$$3"; \
		echo "==> Testing $${platform} ($${device})"; \
		$(MAKE) test-package-platform \
			SIM_PLATFORM="$$sim" \
			RUNTIME_PLATFORM="$$platform" \
			DEVICE_NAME="$$device" || exit 1; \
	done

test-package-platform:
	@if [ -n "$(SIM_PLATFORM)" ] && [ -n "$(RUNTIME_PLATFORM)" ] && [ -n "$(DEVICE_NAME)" ]; then \
		dest_id="$(call udid_for_latest,$(DEVICE_NAME),$(RUNTIME_PLATFORM))"; \
		if [ -z "$$dest_id" ]; then \
			echo "No simulator found for $(DEVICE_NAME) on $(RUNTIME_PLATFORM)" >&2; \
			exit 1; \
		fi; \
		dest="platform=$(SIM_PLATFORM),id=$$dest_id"; \
		xcodebuild test -scheme VRMKit-Package -destination "$$dest"; \
	else \
		echo "SIM_PLATFORM/RUNTIME_PLATFORM/DEVICE_NAME is required" >&2; \
		exit 1; \
	fi

define udid_for_latest
$(shell xcrun simctl list --json devices available | jq -r --arg name "$(1)" --arg platform "$(2)" 'def ver(k): (k | capture("SimRuntime\\." + $$platform + "-(?<major>\\d+)-(?<minor>\\d+)")) as $$m | [$$m.major|tonumber, $$m.minor|tonumber]; .devices | to_entries | map(select(.key | test("SimRuntime\\." + $$platform + "-\\d+-\\d+"))) | sort_by(ver(.key)) | last | .value | map(select(.name | contains($$name))) | last | .udid // empty')
endef
