APP := build/tinyClicker.app
BUNDLE_ID := com.yong.tinyClicker

.PHONY: all build build-universal run icon clean permission-reset help

all: build

# `build` always wipes the stale TCC Accessibility entry first — each rebuild
# produces a new code identity, so the previous grant is dead anyway.
build: permission-reset
	@./scripts/build-app.sh

# Universal arm64 + x86_64 binary. Used by the release workflow so a single
# .app runs on both Apple Silicon and Intel Macs. Slower than `make build`.
# Requires full Xcode (multi-arch builds need xcbuild); Command Line Tools
# alone are not enough.
build-universal: permission-reset
	@UNIVERSAL=1 ./scripts/build-app.sh

run: build
	@open -n $(APP)

icon:
	@swift scripts/generate-icon.swift

clean:
	@rm -rf build .build
	@swift package clean 2>/dev/null || true

# Wipe the stale TCC Accessibility entry for tinyClicker so the next launch
# starts clean. Auto-invoked by `build` since each rebuild's new code identity
# makes the previous grant dead anyway.
permission-reset:
	@tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "==> Reset TCC Accessibility entry for $(BUNDLE_ID)"

help:
	@echo "Targets:"
	@echo "  make                    Build $(APP) (default; host arch only)"
	@echo "  make build-universal    Build universal arm64+x86_64 .app (for distribution)"
	@echo "  make run                Build and launch the app"
	@echo "  make icon               Regenerate Resources/icon.icns"
	@echo "  make permission-reset   Wipe stale Accessibility grant (run if banner is stuck)"
	@echo "  make clean              Remove build artifacts"
