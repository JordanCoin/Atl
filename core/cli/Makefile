PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -m 755 .build/release/atl $(PREFIX)/bin/atl

uninstall:
	rm -f $(PREFIX)/bin/atl

clean:
	swift package clean
