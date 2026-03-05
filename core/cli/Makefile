PREFIX ?= $(HOME)/.atl
SHELL_RC := $(or $(wildcard $(HOME)/.zshrc),$(wildcard $(HOME)/.bashrc))
PATH_LINE := export PATH="$$HOME/.atl/bin:$$PATH"

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -m 755 .build/release/atl $(PREFIX)/bin/atl
	@# Symlink into common PATH dirs for immediate availability
	@if [ -d "$(HOME)/.local/bin" ]; then \
		ln -sf $(PREFIX)/bin/atl $(HOME)/.local/bin/atl; \
	fi
	@if [ -w /usr/local/bin ]; then \
		ln -sf $(PREFIX)/bin/atl /usr/local/bin/atl; \
	fi
	@# Ensure ~/.atl/bin is on PATH for future shells
	@if [ -n "$(SHELL_RC)" ] && ! grep -q '\.atl/bin' "$(SHELL_RC)"; then \
		echo '' >> "$(SHELL_RC)"; \
		echo '# ATL CLI' >> "$(SHELL_RC)"; \
		echo '$(PATH_LINE)' >> "$(SHELL_RC)"; \
	fi
	@echo "✓ atl installed"

uninstall:
	rm -f $(PREFIX)/bin/atl
	rm -f $(HOME)/.local/bin/atl
	rm -f /usr/local/bin/atl
	@echo "✓ atl removed"

clean:
	swift package clean
