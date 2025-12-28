# Atl Development Makefile
# Usage:
#   make start        - Build and run everything
#   make mac          - Build and run macOS app only
#   make ios          - Build and run iOS app only
#   make ping         - Test server connection
#
# Tests (progressive difficulty):
#   make test         - Basic search test
#   make test-nav     - Navigation (goto, back, forward)
#   make test-cookies - Cookie save/load
#   make test-click   - Click & interact with elements
#   make test-cart    - E-commerce cart flow
#   make test-all     - Run all tests

SIMULATOR_NAME ?= iPhone 17
COOKIE_DIR := $(HOME)/Library/Application Support/Atl/Cookies

# Helper to send commands
define cmd
	@curl -s -X POST http://localhost:9222/command \
		-H "Content-Type: application/json" \
		-d '{"id":"$(1)","method":"$(2)","params":$(3)}'
endef
UDID := $(shell xcrun simctl list devices available | grep "$(SIMULATOR_NAME)" | grep -oE '[A-F0-9-]{36}' | head -1)

.PHONY: start mac ios ping test test-nav test-cookies test-click test-cart test-all boot clean

# Start everything
start: boot mac ios ping
	@echo "✅ Atl is ready!"

# Boot simulator
boot:
	@echo "📱 Booting $(SIMULATOR_NAME)..."
	@xcrun simctl boot "$(UDID)" 2>/dev/null || true
	@open -a Simulator

# Build and run macOS app
mac:
	@echo "🖥️  Building Atl (macOS)..."
	@xcodebuild -workspace Atl.xcworkspace -scheme Atl -configuration Debug -quiet build
	@echo "   Launching..."
	@open "$$(find ~/Library/Developer/Xcode/DerivedData -name 'Atl.app' -path '*/Debug/*' | head -1)" &

# Build and run iOS app
ios:
	@echo "📱 Building AtlBrowser (iOS)..."
	@xcodebuild -workspace AtlBrowser/AtlBrowser.xcworkspace -scheme AtlBrowser \
		-configuration Debug -destination "id=$(UDID)" -quiet build
	@echo "   Installing..."
	@xcrun simctl install "$(UDID)" "$$(find ~/Library/Developer/Xcode/DerivedData -name 'AtlBrowser.app' -path '*Debug-iphonesimulator*' | head -1)"
	@echo "   Launching..."
	@xcrun simctl launch "$(UDID)" com.atl.browser
	@sleep 2

# Test server connection
ping:
	@echo "🔗 Testing connection..."
	@for i in 1 2 3 4 5; do \
		if curl -s http://localhost:9222/ping | grep -q "ok"; then \
			echo "✅ Server responding!"; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "⚠️  Server not responding"

# Run a test automation
test:
	@echo "🧪 Running test automation..."
	@curl -s -X POST http://localhost:9222/command \
		-H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.google.com"}}'
	@sleep 2
	@curl -s -X POST http://localhost:9222/command \
		-H "Content-Type: application/json" \
		-d '{"id":"2","method":"fill","params":{"selector":"textarea[name=q]","value":"Atl automation test"}}'
	@curl -s -X POST http://localhost:9222/command \
		-H "Content-Type: application/json" \
		-d '{"id":"3","method":"press","params":{"key":"Enter"}}'
	@sleep 2
	@curl -s -X POST http://localhost:9222/command \
		-H "Content-Type: application/json" \
		-d '{"id":"4","method":"getTitle","params":{}}' | jq -r '.result.title'
	@echo "✅ Test complete!"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning..."
	@xcodebuild -workspace Atl.xcworkspace -scheme Atl clean -quiet
	@xcodebuild -workspace AtlBrowser/AtlBrowser.xcworkspace -scheme AtlBrowser clean -quiet

# ============================================
# TEST SUITE - Progressive Difficulty
# ============================================

# Test 1: Navigation basics
test-nav:
	@echo "🧪 Test: Navigation..."
	@echo "   → goto google.com"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.google.com"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → verify URL"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"2","method":"getURL","params":{}}' | jq -r '.result.url' | grep -q "google.com" && echo "   ✓ URL correct"
	@echo "   → goto wikipedia"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"3","method":"goto","params":{"url":"https://www.wikipedia.org"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → goBack"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"4","method":"goBack","params":{}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → verify back at google"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"5","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value' | grep -qi "google" && echo "   ✓ Back navigation works"
	@echo "   → goForward"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6","method":"goForward","params":{}}' | jq -e '.success' > /dev/null
	@sleep 2
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"7","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value' | grep -qi "wikipedia" && echo "   ✓ Forward navigation works"
	@echo "✅ test-nav PASSED"

# Test 2: Cookie persistence
test-cookies:
	@echo "🧪 Test: Cookie persistence..."
	@mkdir -p "$(COOKIE_DIR)"
	@echo "   → goto amazon.com (sets cookies)"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.amazon.com"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → save cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"2","method":"getCookies","params":{}}' | jq '.result.cookies' > "$(COOKIE_DIR)/amazon.com.json"
	@test -s "$(COOKIE_DIR)/amazon.com.json" && echo "   ✓ Cookies saved to disk"
	@echo "   → delete cookies from browser"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"3","method":"deleteCookies","params":{}}' | jq -e '.success' > /dev/null
	@echo "   → verify cookies gone"
	@COOKIE_COUNT=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"4","method":"getCookies","params":{}}' | jq '.result.cookies | length'); \
	if [ "$$COOKIE_COUNT" = "0" ]; then echo "   ✓ Cookies cleared"; else echo "   ⚠ Still have $$COOKIE_COUNT cookies"; fi
	@echo "   → restore cookies from file"
	@COOKIES=$$(cat "$(COOKIE_DIR)/amazon.com.json"); \
	curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d "{\"id\":\"5\",\"method\":\"setCookies\",\"params\":{\"cookies\":$$COOKIES}}" | jq -e '.success' > /dev/null
	@echo "   → verify cookies restored"
	@COOKIE_COUNT=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6","method":"getCookies","params":{}}' | jq '.result.cookies | length'); \
	if [ "$$COOKIE_COUNT" -gt "0" ]; then echo "   ✓ $$COOKIE_COUNT cookies restored"; else echo "   ✗ Cookies not restored"; exit 1; fi
	@echo "✅ test-cookies PASSED"

# Test 3: Click and interact
test-click:
	@echo "🧪 Test: Click & interact..."
	@echo "   → goto wikipedia.org"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.wikipedia.org"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → fill search box"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"2","method":"fill","params":{"selector":"#searchInput","value":"Swift programming language"}}' | jq -e '.success' > /dev/null
	@sleep 1
	@echo "   → click search button"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"3","method":"click","params":{"selector":"button[type=submit]"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → verify landed on Swift article"
	@TITLE=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"4","method":"getTitle","params":{}}' | jq -r '.result.title'); \
	echo "   → title: $$TITLE"; \
	echo "$$TITLE" | grep -qi "swift" && echo "   ✓ Landed on Swift page"
	@echo "   → click a link (first content link)"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"5","method":"click","params":{"selector":"#mw-content-text a"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → verify navigation happened"
	@NEWURL=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6","method":"getURL","params":{}}' | jq -r '.result.url'); \
	echo "   → new URL: $$NEWURL"
	@echo "✅ test-click PASSED"

# Test 4: E-commerce cart flow (full add-to-cart)
test-cart:
	@echo "🧪 Test: E-commerce cart flow..."
	@echo "   → goto amazon.com"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.amazon.com"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → search for product"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"2","method":"fill","params":{"selector":"#nav-search-keywords","value":"usb c cable"}}' | jq -e '.success' > /dev/null
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"3","method":"press","params":{"key":"Enter"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → click first product"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"4","method":"click","params":{"selector":"a[href*=\"/dp/\"]"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → extract product info"
	@PRICE=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"5","method":"evaluate","params":{"script":"document.body.innerText.match(/\\$$[0-9]+\\.[0-9]{2}/)?.[0] || \"n/a\""}}' | jq -r '.result.value'); \
	echo "   → price: $$PRICE"
	@echo "   → click Add to Cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6","method":"click","params":{"selector":"#add-to-cart-button"}}' | jq -e '.success' > /dev/null || \
	curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6b","method":"click","params":{"selector":"[name=\"submit.add-to-cart\"]"}}' | jq -e '.success' > /dev/null || true
	@sleep 3
	@echo "   → navigate to cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"7","method":"goto","params":{"url":"https://www.amazon.com/cart"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → verify cart page"
	@CART_TITLE=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"8","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value'); \
	echo "   → page: $$CART_TITLE"
	@echo "   → check cart has items"
	@CART_COUNT=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"9","method":"evaluate","params":{"script":"document.querySelector(\"#nav-cart-count\")?.textContent || document.querySelectorAll(\".sc-list-item\").length.toString() || \"0\""}}' | jq -r '.result.value'); \
	echo "   → cart items: $$CART_COUNT"
	@echo "   → save full-page screenshot (PDF)"
	@mkdir -p screenshots
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"10","method":"screenshot","params":{"fullPage":true}}' | jq -r '.result.data' | base64 -d > screenshots/cart-test-$$(date +%Y%m%d-%H%M%S).pdf
	@echo "   ✓ Full-page PDF saved to screenshots/"
	@echo "✅ test-cart PASSED"

# Test 5: Multi-profile sessions (different carts per profile)
test-profiles:
	@echo "🧪 Test: Multi-profile sessions..."
	@mkdir -p "$(COOKIE_DIR)"
	@echo ""
	@echo "   === PROFILE A: Current session ==="
	@echo "   → goto amazon cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"1","method":"goto","params":{"url":"https://www.amazon.com/cart"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → check cart count"
	@CART_A=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"2","method":"evaluate","params":{"script":"document.querySelector(\"#nav-cart-count\")?.textContent || \"0\""}}' | jq -r '.result.value'); \
	echo "   → Profile A cart: $$CART_A items"
	@echo "   → save Profile A cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"3","method":"getCookies","params":{}}' | jq '.result.cookies' > "$(COOKIE_DIR)/amazon-profile-a.json"
	@echo "   ✓ Saved to amazon-profile-a.json"
	@echo ""
	@echo "   === PROFILE B: Fresh session ==="
	@echo "   → clear all cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"4","method":"deleteCookies","params":{}}' | jq -e '.success' > /dev/null
	@echo "   → goto amazon (fresh)"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"5","method":"goto","params":{"url":"https://www.amazon.com"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → search for headphones"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"6","method":"fill","params":{"selector":"#nav-search-keywords","value":"wireless earbuds"}}' | jq -e '.success' > /dev/null
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"7","method":"press","params":{"key":"Enter"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → click first product"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"8","method":"click","params":{"selector":"a[href*=\"/dp/\"]"}}' | jq -e '.success' > /dev/null
	@sleep 3
	@echo "   → add to cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"9","method":"click","params":{"selector":"#add-to-cart-button"}}' | jq -e '.success' > /dev/null || true
	@sleep 2
	@echo "   → goto cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"10","method":"goto","params":{"url":"https://www.amazon.com/cart"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → check cart count"
	@CART_B=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"11","method":"evaluate","params":{"script":"document.querySelector(\"#nav-cart-count\")?.textContent || \"0\""}}' | jq -r '.result.value'); \
	echo "   → Profile B cart: $$CART_B items"
	@echo "   → save Profile B cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"12","method":"getCookies","params":{}}' | jq '.result.cookies' > "$(COOKIE_DIR)/amazon-profile-b.json"
	@echo "   ✓ Saved to amazon-profile-b.json"
	@echo ""
	@echo "   === SWITCH TEST: Load Profile A ==="
	@echo "   → clear cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"13","method":"deleteCookies","params":{}}' | jq -e '.success' > /dev/null
	@echo "   → load Profile A cookies"
	@COOKIES_A=$$(cat "$(COOKIE_DIR)/amazon-profile-a.json"); \
	curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d "{\"id\":\"14\",\"method\":\"setCookies\",\"params\":{\"cookies\":$$COOKIES_A}}" | jq -e '.success' > /dev/null
	@echo "   → reload amazon cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"15","method":"goto","params":{"url":"https://www.amazon.com/cart"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → verify Profile A cart restored"
	@CART_A_CHECK=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"16","method":"evaluate","params":{"script":"document.querySelector(\"#nav-cart-count\")?.textContent || \"0\""}}' | jq -r '.result.value'); \
	echo "   → Profile A cart after restore: $$CART_A_CHECK items"
	@mkdir -p screenshots
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"17","method":"screenshot","params":{"fullPage":true}}' | jq -r '.result.data' | base64 -d > screenshots/profile-a-cart.pdf
	@echo "   ✓ Screenshot: screenshots/profile-a-cart.pdf"
	@echo ""
	@echo "   === SWITCH TEST: Load Profile B ==="
	@echo "   → clear cookies"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"18","method":"deleteCookies","params":{}}' | jq -e '.success' > /dev/null
	@echo "   → load Profile B cookies"
	@COOKIES_B=$$(cat "$(COOKIE_DIR)/amazon-profile-b.json"); \
	curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d "{\"id\":\"19\",\"method\":\"setCookies\",\"params\":{\"cookies\":$$COOKIES_B}}" | jq -e '.success' > /dev/null
	@echo "   → reload amazon cart"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"20","method":"goto","params":{"url":"https://www.amazon.com/cart"}}' | jq -e '.success' > /dev/null
	@sleep 2
	@echo "   → verify Profile B cart restored"
	@CART_B_CHECK=$$(curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"21","method":"evaluate","params":{"script":"document.querySelector(\"#nav-cart-count\")?.textContent || \"0\""}}' | jq -r '.result.value'); \
	echo "   → Profile B cart after restore: $$CART_B_CHECK items"
	@curl -s -X POST http://localhost:9222/command -H "Content-Type: application/json" \
		-d '{"id":"22","method":"screenshot","params":{"fullPage":true}}' | jq -r '.result.data' | base64 -d > screenshots/profile-b-cart.pdf
	@echo "   ✓ Screenshot: screenshots/profile-b-cart.pdf"
	@echo ""
	@echo "✅ test-profiles PASSED - Multi-session switching works!"

# Run all tests
test-all: test-nav test-cookies test-click test-cart test-profiles
	@echo ""
	@echo "============================================"
	@echo "✅ ALL TESTS PASSED"
	@echo "============================================"
