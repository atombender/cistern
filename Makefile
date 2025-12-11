.PHONY: build release debug clean zip

BUILD_DIR := build
APP_NAME := Cistern
SCHEME := Cistern
PROJECT := Cistern.xcodeproj

build: release

debug:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		build

release:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		build

zip: release
	cd $(BUILD_DIR)/Build/Products/Release && \
		zip -r $(APP_NAME).zip $(APP_NAME).app
	mv $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).zip .
	@echo "Created $(APP_NAME).zip"

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(APP_NAME).zip
