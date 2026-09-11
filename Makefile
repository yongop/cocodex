.PHONY: build app run demo test preview benchmark disk-usage clean-cache

build:
	swift build

app:
	bash scripts/build-app.sh

run: app
	open dist/Co-Count.app --args --show

demo: app
	open dist/Co-Count.app --args --demo --window

test:
	bash scripts/test.sh

preview: app
	mkdir -p docs/images
	dist/Co-Count.app/Contents/MacOS/Co-Count --snapshot "$(CURDIR)/docs/images/preview-light.png"
	dist/Co-Count.app/Contents/MacOS/Co-Count --snapshot "$(CURDIR)/docs/images/preview-dark.png" --dark

benchmark:
	bash scripts/benchmark.sh

disk-usage:
	du -sh . .build dist docs

# Rebuildable Swift/Clang module caches and IDE indexes only. Keep sources and app bundles.
clean-cache:
	@if [ -d .build ]; then find .build -type d \( -name ModuleCache -o -name index \) -prune -exec rm -r {} +; fi

.PHONY: benchmark-history
benchmark-history:
	bash scripts/benchmark-history.sh
