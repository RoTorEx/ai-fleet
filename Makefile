.PHONY: dist-dir build bundle-app run check clean stop-app reinstall vibe-kernel-path vibe-kernel-set vibe-pull

APP_NAME := AIFleet
APP_BUNDLE_ID := dev.ai-fleet
PROJECT_NAME := $(notdir $(CURDIR))
CONSTRUCTION_SIDE := $(HOME)/construction_side
DIST_DIR := $(CONSTRUCTION_SIDE)/$(PROJECT_NAME).noindex/dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
APP_CONTENTS := $(APP_BUNDLE)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources

dist-dir:
	@mkdir -p "$(DIST_DIR)"

build:
	swift build -c release

bundle-app: dist-dir build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_MACOS)" "$(APP_RESOURCES)"
	@cp .build/release/ai-fleet "$(APP_MACOS)/$(APP_NAME)"
	@chmod +x $(APP_MACOS)/$(APP_NAME)
	@xcrun actool AppBundle/Assets.xcassets --compile "$(APP_RESOURCES)" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "$(APP_RESOURCES)/partial.plist" >/dev/null 2>&1
	@cp AppBundle/Info.plist "$(APP_CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Merge $(APP_RESOURCES)/partial.plist" "$(APP_CONTENTS)/Info.plist" >/dev/null 2>&1 || true
	@rm -f "$(APP_RESOURCES)/partial.plist"
	@codesign --force --deep --sign - "$(APP_BUNDLE)" >/dev/null 2>&1 || true
	@echo "Bundled $(APP_BUNDLE)"

run:
	swift run

check:
	swift build --target AIFleet

clean:
	rm -rf .build "$(DIST_DIR)"

stop-app:
	@if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
		echo "Stopping running $(APP_NAME)"; \
		osascript -e 'tell application id "$(APP_BUNDLE_ID)" to quit' >/dev/null 2>&1 || true; \
		for attempt in 1 2 3 4 5 6 7 8 9 10; do \
			pgrep -x "$(APP_NAME)" >/dev/null 2>&1 || break; \
			sleep 0.2; \
		done; \
		if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
			pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true; \
		fi; \
		for attempt in 1 2 3 4 5 6 7 8 9 10; do \
			pgrep -x "$(APP_NAME)" >/dev/null 2>&1 || break; \
			sleep 0.2; \
		done; \
	fi

reinstall: bundle-app
	@$(MAKE) stop-app
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@open "/Applications/$(APP_NAME).app"
	@echo "Reinstalled and launched /Applications/$(APP_NAME).app"

vibe-kernel-path:
	@test -f .vibe/KERNEL_SOURCE || { echo "Missing .vibe/KERNEL_SOURCE. Run: make vibe-kernel-set" >&2; exit 1; }
	@sed -n '1p' .vibe/KERNEL_SOURCE

vibe-kernel-set:
	@mkdir -p .vibe; \
	if [ -n "$(KERNEL)" ]; then kernel_root="$(KERNEL)"; else printf "Kernel path: "; read -r kernel_root; fi; \
	case "$$kernel_root" in /*) ;; *) echo "ERROR: kernel path must be absolute." >&2; exit 1;; esac; \
	test -f "$$kernel_root/tools/vibe-pull" || { echo "ERROR: invalid kernel path: $$kernel_root" >&2; exit 1; }; \
	printf "%s\n" "$$kernel_root" > .vibe/KERNEL_SOURCE

vibe-pull:
	@test -f .vibe/KERNEL_SOURCE || { echo "Missing .vibe/KERNEL_SOURCE. Run: make vibe-kernel-set" >&2; exit 1; }
	@kernel_root="$$(sed -n '1p' .vibe/KERNEL_SOURCE)"; \
	python3 "$$kernel_root/tools/vibe-pull" .
