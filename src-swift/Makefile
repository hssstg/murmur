BUILD_DIR = .build/debug
APP_NAME = murmur
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
BINARY = $(APP_BUNDLE)/Contents/MacOS/murmur
ENTITLEMENTS = murmur.entitlements
INFO_PLIST = Info.plist

.PHONY: build run test clean

build:
	swift build
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/murmur $(BINARY)
	@if [ -f $(INFO_PLIST) ] && [ -f $(ENTITLEMENTS) ]; then \
		cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/; \
		codesign --force -s - --entitlements $(ENTITLEMENTS) $(APP_BUNDLE); \
		echo "Bundle signed with entitlements."; \
	else \
		echo "Note: $(INFO_PLIST) or $(ENTITLEMENTS) not found — skipping bundle signing (add in Task 13)."; \
	fi

run: build
	pkill murmur 2>/dev/null; open $(APP_BUNDLE)

test:
	swift run MurmurTests

clean:
	swift package clean
	rm -rf $(BUILD_DIR)/$(APP_NAME).app
