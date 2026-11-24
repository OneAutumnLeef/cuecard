# Notch Prompter: build, test and install with only the Command Line Tools.
# Build output lives in ~/Library/Caches/MacTele (outside iCloud Drive).

CACHE    := $(HOME)/Library/Caches/MacTele
SCRATCH  := $(CACHE)/build/root
APP      := $(CACHE)/apps/NotchPrompter.app
CLT_FW   := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB  := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
# Swift Testing ships with the Command Line Tools but isn't on the default search path.
TESTING  := -Xswiftc -F -Xswiftc $(CLT_FW) -Xlinker -F -Xlinker $(CLT_FW) \
            -Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB)

.PHONY: test app run install icon signing clean

test:
	swift test --scratch-path "$(SCRATCH)" $(TESTING)

app:
	DISPLAY_NAME="Notch Prompter" ICON="Resources/AppIcon.icns" VERSION="0.4.0" URL_SCHEME="notchprompter" \
	  scripts/build-app.sh . NotchPrompter dev.mactele.prompter release

run: app
	-pkill -x NotchPrompter; sleep 0.3
	open "$(APP)"

install: app
	scripts/install.sh "$(APP)"

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

signing:
	scripts/setup-signing.sh

clean:
	rm -rf "$(CACHE)/build/root" "$(APP)"
