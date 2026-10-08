PREFIX ?= /usr/local
APP_NAME = RaindropShot
WORKER_NAME = RaindropShotWorker
APP_BUNDLE = $(APP_NAME).app

.PHONY: all build test app install clean

all: build

build:
	swift build -c release

test:
	swift test

app: build
	@echo "Creating $(APP_BUNDLE)..."
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp .build/release/$(WORKER_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) successfully."

login: app
	./login.sh

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
