PREFIX ?= /usr/local

.PHONY: build test app install uninstall clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

# Installs Reclaim.app into /Applications and links the CLI into $(PREFIX)/bin.
install: app
	rm -rf /Applications/Reclaim.app
	cp -R dist/Reclaim.app /Applications/
	mkdir -p $(PREFIX)/bin
	ln -sf /Applications/Reclaim.app/Contents/Resources/reclaim $(PREFIX)/bin/reclaim
	@echo "Installed /Applications/Reclaim.app and $(PREFIX)/bin/reclaim"

uninstall:
	rm -rf /Applications/Reclaim.app
	rm -f $(PREFIX)/bin/reclaim

clean:
	rm -rf .build dist
