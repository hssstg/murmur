BUILD_DIR = .build/debug
APP_NAME = Murmur
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
BINARY = $(APP_BUNDLE)/Contents/MacOS/murmur
ENTITLEMENTS = murmur.entitlements
INFO_PLIST = Info.plist

.PHONY: build run test clean

build:
	swift build 2>&1
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/murmur $(BINARY)
	cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/
	codesign --force -s - --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)

run: build
	pkill murmur 2>/dev/null; open $(APP_BUNDLE)

test:
	swift test 2>&1

clean:
	swift package clean
	rm -rf $(BUILD_DIR)/$(APP_NAME).app
