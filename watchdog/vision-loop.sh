#!/bin/bash
# Vision Loop - Claude-in-the-loop browser automation
#
# This provides primitives for vision-based automation where Claude:
# 1. Sees full-page PDFs
# 2. Decides what action to take
# 3. Executes via JS injection (only method that works for WebView)
# 4. Verifies the result
#
# Usage: Source this file, then call functions
#   source watchdog/vision-loop.sh
#   vision_init "my-workflow"
#   vision_goto "https://amazon.com"
#   vision_capture "01-homepage"
#   # Claude reads PDF, decides action
#   vision_click_text "Sign in"
#   vision_capture "02-after-click"

set -e

# ============================================================================
# Configuration
# ============================================================================
COMMAND_SERVER="${COMMAND_SERVER:-http://localhost:9222}"
VISION_BASE_DIR="${VISION_BASE_DIR:-/Users/jordan/MakersStudio/Projects/Atl/watchdog/runs}"
VISION_RUN_ID=""
VISION_RUN_DIR=""
VISION_STEP=0
VISION_TASK_ID=""
VISION_SIM_UDID=""

# Source orchestrator for centralized state management
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/orchestrator.sh" ]; then
    source "$SCRIPT_DIR/orchestrator.sh"
fi

# ============================================================================
# Initialization
# ============================================================================

# Initialize a new vision workflow run
# Usage: vision_init "workflow-name" [simulator-udid]
vision_init() {
    local workflow_name="${1:-vision-workflow}"
    local sim_udid="${2:-}"

    VISION_RUN_ID="${workflow_name}-$(date +%Y%m%d-%H%M%S)"
    VISION_RUN_DIR="$VISION_BASE_DIR/$VISION_RUN_ID"
    VISION_STEP=0
    VISION_TASK_ID="$VISION_RUN_ID"
    VISION_SIM_UDID="$sim_udid"

    mkdir -p "$VISION_RUN_DIR"
    echo "{\"runId\":\"$VISION_RUN_ID\",\"startTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"workflow\":\"$workflow_name\",\"simulator\":\"$sim_udid\"}" > "$VISION_RUN_DIR/manifest.json"
    _metrics_init

    # Register run with Python/SQLite
    if [ -n "$sim_udid" ]; then
        python3 -m atl -f compact run start "$VISION_RUN_ID" "$workflow_name" --simulator "$sim_udid" >/dev/null 2>&1 || true
    else
        python3 -m atl -f compact run start "$VISION_RUN_ID" "$workflow_name" >/dev/null 2>&1 || true
    fi

    echo "$VISION_RUN_DIR"
}

# Get current run directory
vision_run_dir() {
    echo "$VISION_RUN_DIR"
}

# ============================================================================
# Metrics Tracking - Cost & Usage Analytics
# ============================================================================
#
# Tracks per-run:
#   - Captures by mode (light, jpeg, pdf)
#   - Bytes read (for token estimation)
#   - Actions taken
#   - Selector cache hits/misses
#   - Estimated token cost
#
# Token estimation (conservative):
#   - Text: ~4 tokens per character (varies by content)
#   - Images: ~1 token per 4 bytes (Claude vision)
#
# Pricing (as of Dec 2024, Sonnet):
#   - Input: $3 per 1M tokens
#   - Output: $15 per 1M tokens (not tracked here)

# Metrics are now tracked in SQLite via Python CLI
# These wrapper functions maintain shell API compatibility

# Initialize metrics for current run (now handled by run start)
# Called automatically by vision_init
_metrics_init() {
    # Metrics are created automatically when run starts
    # Keep local file for backwards compatibility with vision_cost/vision_summary
    if [ -z "$VISION_RUN_DIR" ]; then return; fi
    METRICS_FILE="$VISION_RUN_DIR/metrics.json"
    cat > "$METRICS_FILE" << 'EOF'
{
  "captures": {"light": 0, "jpeg": 0, "pdf": 0},
  "bytes": {"light": 0, "jpeg": 0, "pdf": 0, "total": 0},
  "actions": {"clicks": 0, "types": 0, "navigations": 0, "scrolls": 0},
  "selectors": {"cacheHits": 0, "cacheMisses": 0, "learned": 0},
  "timing": {"totalWaitMs": 0, "readyChecks": 0},
  "errors": 0
}
EOF
}

# Log a capture event
# Usage: _metrics_capture "light" 17000
_metrics_capture() {
    local mode="$1"
    local bytes="$2"

    # Update SQLite via Python CLI
    if [ -n "$VISION_RUN_ID" ]; then
        python3 -m atl -f compact metrics capture "$VISION_RUN_ID" "$mode" "$bytes" >/dev/null 2>&1 || true
    fi

    # Also update local file for backwards compat
    if [ -n "$METRICS_FILE" ] && [ -f "$METRICS_FILE" ]; then
        local temp=$(mktemp)
        jq --arg mode "$mode" --argjson bytes "$bytes" '
            .captures[$mode] += 1 |
            .bytes[$mode] += $bytes |
            .bytes.total += $bytes
        ' "$METRICS_FILE" > "$temp" && mv "$temp" "$METRICS_FILE"
    fi
}

# Log an action event
# Usage: _metrics_action "clicks"
_metrics_action() {
    local action="$1"
    # Map shell action names to CLI action types (click, type, navigation, scroll)
    local action_type="${action%s}"  # Remove trailing 's' (clicks -> click)

    # Update SQLite via Python CLI
    if [ -n "$VISION_RUN_ID" ]; then
        python3 -m atl -f compact metrics action "$VISION_RUN_ID" "$action_type" >/dev/null 2>&1 || true
    fi

    # Also update local file for backwards compat
    if [ -n "$METRICS_FILE" ] && [ -f "$METRICS_FILE" ]; then
        local temp=$(mktemp)
        jq --arg action "$action" '.actions[$action] += 1' "$METRICS_FILE" > "$temp" && mv "$temp" "$METRICS_FILE"
    fi
}

# Log selector cache hit/miss
# Usage: _metrics_selector "hit" or _metrics_selector "miss" or _metrics_selector "learned"
_metrics_selector() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then return; fi
    local event="$1"

    local temp=$(mktemp)
    case "$event" in
        hit) jq '.selectors.cacheHits += 1' "$METRICS_FILE" > "$temp" ;;
        miss) jq '.selectors.cacheMisses += 1' "$METRICS_FILE" > "$temp" ;;
        learned) jq '.selectors.learned += 1' "$METRICS_FILE" > "$temp" ;;
    esac
    mv "$temp" "$METRICS_FILE"
}

# Log wait/ready timing
# Usage: _metrics_wait 530 8
_metrics_wait() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then return; fi
    local ms="$1"
    local checks="${2:-1}"

    local temp=$(mktemp)
    jq --argjson ms "$ms" --argjson checks "$checks" '
        .timing.totalWaitMs += $ms |
        .timing.readyChecks += $checks
    ' "$METRICS_FILE" > "$temp" && mv "$temp" "$METRICS_FILE"
}

# Log an error
_metrics_error() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then return; fi
    local temp=$(mktemp)
    jq '.errors += 1' "$METRICS_FILE" > "$temp" && mv "$temp" "$METRICS_FILE"
}

# Get current metrics
# Usage: vision_metrics
vision_metrics() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then
        echo '{"error": "no active run, call vision_init first"}'
        return 1
    fi
    cat "$METRICS_FILE"
}

# Get cost estimate for current run
# Usage: vision_cost
vision_cost() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then
        echo '{"error": "no active run"}'
        return 1
    fi

    # Token estimation:
    # - Light (text): ~0.25 tokens per byte (4 chars per token avg)
    # - JPEG/PDF (images): ~0.25 tokens per byte (vision encoding)
    # Pricing: $3 per 1M input tokens (Sonnet)

    jq '
        # Calculate tokens
        (.bytes.light * 0.25) as $lightTokens |
        (.bytes.jpeg * 0.25) as $jpegTokens |
        (.bytes.pdf * 0.25) as $pdfTokens |
        ($lightTokens + $jpegTokens + $pdfTokens) as $totalTokens |

        # Calculate cost ($3 per 1M tokens)
        ($totalTokens / 1000000 * 3) as $cost |

        {
            tokens: {
                light: ($lightTokens | floor),
                jpeg: ($jpegTokens | floor),
                pdf: ($pdfTokens | floor),
                total: ($totalTokens | floor)
            },
            cost: {
                usd: ($cost * 100 | floor | . / 100),
                formatted: ("$" + (($cost * 100 | floor | . / 100) | tostring))
            },
            captures: .captures,
            bytes: .bytes
        }
    ' "$METRICS_FILE"
}

# Get detailed run summary with cost projection
# Usage: vision_summary
vision_summary() {
    if [ -z "$METRICS_FILE" ] || [ ! -f "$METRICS_FILE" ]; then
        echo '{"error": "no active run"}'
        return 1
    fi

    local start_time=$(jq -r '.startTime' "$VISION_RUN_DIR/manifest.json" 2>/dev/null)

    # Calculate duration in seconds (macOS compatible)
    local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%s" 2>/dev/null)
    if [ -z "$start_epoch" ] || [ "$start_epoch" = "0" ]; then
        # Fallback: use file modification time
        start_epoch=$(stat -f%m "$VISION_RUN_DIR/manifest.json" 2>/dev/null || echo 0)
    fi
    local now_epoch=$(date "+%s")
    local duration_sec=$((now_epoch - start_epoch))
    [ "$duration_sec" -lt 0 ] && duration_sec=0

    jq --arg duration "$duration_sec" --arg runId "$VISION_RUN_ID" '
        # Token & cost calculation
        (.bytes.light * 0.25) as $lightTokens |
        (.bytes.jpeg * 0.25) as $jpegTokens |
        (.bytes.pdf * 0.25) as $pdfTokens |
        ($lightTokens + $jpegTokens + $pdfTokens) as $totalTokens |
        ($totalTokens / 1000000 * 3) as $cost |

        # Totals
        (.captures.light + .captures.jpeg + .captures.pdf) as $totalCaptures |
        (.actions.clicks + .actions.types + .actions.navigations + .actions.scrolls) as $totalActions |

        # Rate calculation (per hour)
        (($duration | tonumber) / 3600) as $hours |
        (if $hours > 0 then ($totalCaptures / $hours) else 0 end) as $capturesPerHour |
        (if $hours > 0 then ($cost / $hours) else 0 end) as $costPerHour |

        {
            runId: $runId,
            duration: {
                seconds: ($duration | tonumber),
                formatted: (
                    (($duration | tonumber) / 3600 | floor | tostring) + "h " +
                    ((($duration | tonumber) % 3600 / 60) | floor | tostring) + "m"
                )
            },
            captures: {
                total: $totalCaptures,
                byMode: .captures,
                perHour: ($capturesPerHour | floor)
            },
            bytes: {
                total: .bytes.total,
                formatted: (
                    if .bytes.total > 1048576 then
                        ((.bytes.total / 1048576 * 10 | floor) / 10 | tostring) + "MB"
                    else
                        ((.bytes.total / 1024 * 10 | floor) / 10 | tostring) + "KB"
                    end
                )
            },
            tokens: ($totalTokens | floor),
            cost: {
                current: ("$" + (($cost * 100 | floor | . / 100) | tostring)),
                perHour: ("$" + (($costPerHour * 100 | floor | . / 100) | tostring)),
                projected6h: ("$" + (($costPerHour * 6 * 100 | floor | . / 100) | tostring))
            },
            actions: {
                total: $totalActions,
                breakdown: .actions
            },
            selectors: .selectors,
            errors: .errors
        }
    ' "$METRICS_FILE"
}

# ============================================================================
# Page Ready Detection
# ============================================================================

# Wait for page to be fully ready (DOM stable, network idle)
# Usage: vision_wait_ready [timeout] [stabilityMs] [selector]
# Returns: JSON with ready status, timing, and diagnostics
vision_wait_ready() {
    local timeout="${1:-10}"
    local stability_ms="${2:-500}"
    local selector="${3:-}"

    local params="{\"timeout\":$timeout,\"stabilityMs\":$stability_ms"
    if [ -n "$selector" ]; then
        params="$params,\"selector\":\"$selector\""
    fi
    params="$params}"

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"ready\",\"method\":\"waitForReady\",\"params\":$params}" | jq -c '.result'
}

# ============================================================================
# Navigation
# ============================================================================

# Navigate to URL and wait for page ready
# Usage: vision_goto "https://amazon.com" [timeout] [selector]
vision_goto() {
    local url="$1"
    local timeout="${2:-10}"
    local selector="${3:-}"

    _metrics_action "navigations"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"nav\",\"method\":\"goto\",\"params\":{\"url\":\"$url\"}}" | jq -c '{success}'

    # Wait for page ready instead of fixed sleep
    local ready_result=$(vision_wait_ready "$timeout" 500 "$selector")

    # Log wait timing
    local waited_ms=$(echo "$ready_result" | jq -r '.waitedMs // 0')
    local checks=$(echo "$ready_result" | jq -r '.checks // 0')
    _metrics_wait "$waited_ms" "$checks"

    echo "$ready_result"
}

# Get current URL
vision_url() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"url","method":"evaluate","params":{"script":"window.location.href"}}' | jq -r '.result.value'
}

# Get page title
vision_title() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"title","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value'
}

# ============================================================================
# Vision Capture - Multiple Modes for Different Use Cases
# ============================================================================
#
# Capture Modes (ordered by size/cost):
#   light  - Text + interactives only (~9KB, 99% smaller)
#   vision - JPEG viewport Q80 (~360KB, 67% smaller)
#   full   - JPEG full page Q80 (~700KB, 36% smaller)
#   debug  - PDF full page (~1.1MB, current default)
#
# Use 'light' for routine navigation, 'vision' when you need to see layout

# Light capture - text + interactives only (~9KB)
# Use when Claude just needs to know what's clickable, not see it
# Usage: vision_capture_light
vision_capture_light() {
    local response=$(curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"light","method":"captureLight","params":{}}')

    # Get byte count from raw response (more reliable than jq with control chars)
    local bytes=${#response}
    _metrics_capture "light" "$bytes"

    # Output the result portion
    echo "$response" | jq -c '.result' 2>/dev/null || echo "$response"
}

# JPEG capture - smaller than PDF, still visual
# Usage: vision_capture_jpeg [quality] [fullPage]
# quality: 40-90 (default 80)
# fullPage: true/false (default false = viewport only)
vision_capture_jpeg() {
    local quality="${1:-80}"
    local full_page="${2:-false}"

    local response=$(curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"jpeg\",\"method\":\"captureJPEG\",\"params\":{\"quality\":$quality,\"fullPage\":$full_page}}")

    # Get actual image size from response
    local size=$(echo "$response" | jq -r '.result.size // 0')
    _metrics_capture "jpeg" "$size"

    # Return metadata (without the base64 image data for console output)
    echo "$response" | jq -c '{url:.result.url,title:.result.title,size:.result.size,width:.result.width,height:.result.height}'
}

# Save JPEG capture to file
# Usage: vision_save_jpeg "filename.jpg" [quality] [fullPage]
vision_save_jpeg() {
    local filename="$1"
    local quality="${2:-80}"
    local full_page="${3:-false}"

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"jpeg\",\"method\":\"captureJPEG\",\"params\":{\"quality\":$quality,\"fullPage\":$full_page}}" \
        | jq -r '.result.jpeg' | base64 -d > "$filename"

    ls -lah "$filename" | awk '{print "{\"file\":\"'$filename'\",\"size\":\""$5"\"}"}'
}

# Capture full page PDF for Claude to analyze (original method - for debugging)
# Usage: vision_capture "step-name"
# Returns: Path to saved PDF
vision_capture() {
    local name="${1:-step-$VISION_STEP}"
    VISION_STEP=$((VISION_STEP + 1))
    local step_name=$(printf "%02d-%s" $VISION_STEP "$name")

    local response=$(curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"capture\",\"method\":\"captureForVision\",\"params\":{\"savePath\":\"$VISION_RUN_DIR\",\"name\":\"$step_name\"}}")

    local pdf_path=$(echo "$response" | jq -r '.result.savedTo')
    local url=$(echo "$response" | jq -r '.result.url')
    local title=$(echo "$response" | jq -r '.result.title')

    # Get PDF file size for metrics
    if [ -f "$pdf_path" ]; then
        local size=$(stat -f%z "$pdf_path" 2>/dev/null || echo 0)
        _metrics_capture "pdf" "$size"
    fi

    # Output for Claude to see
    echo "{\"step\":$VISION_STEP,\"name\":\"$step_name\",\"pdf\":\"$pdf_path\",\"url\":\"$url\",\"title\":\"$title\"}"
}

# Smart capture - chooses mode based on context
# Usage: vision_capture_smart [mode]
# mode: light, vision, full, debug (default: light)
vision_capture_smart() {
    local mode="${1:-light}"

    case "$mode" in
        light)
            vision_capture_light
            ;;
        vision)
            vision_capture_jpeg 80 false
            ;;
        full)
            vision_capture_jpeg 80 true
            ;;
        debug)
            vision_capture "capture"
            ;;
        *)
            echo "{\"error\":\"unknown mode: $mode\",\"valid\":[\"light\",\"vision\",\"full\",\"debug\"]}"
            ;;
    esac
}

# ============================================================================
# Actions - JS Injection (Only Method That Works for WebView)
# ============================================================================

# Click element by visible text (searches textContent, value, title, aria-label, name)
# Usage: vision_click_text "Add to cart"
vision_click_text() {
    local text="$1"
    _metrics_action "clicks"
    cat > /tmp/vision-click.json << EOF
{"id":"click","method":"evaluate","params":{"script":"(function(){const t='$text'.toLowerCase();const els=[...document.querySelectorAll('button,a,input[type=submit],input[type=button],[role=button]')].filter(e=>(e.textContent||'').toLowerCase().includes(t)||(e.value||'').toLowerCase().includes(t)||(e.title||'').toLowerCase().includes(t)||(e.getAttribute('aria-label')||'').toLowerCase().includes(t)||(e.name||'').toLowerCase().includes(t));if(els[0]){els[0].scrollIntoView({block:'center'});els[0].click();return {success:true,element:els[0].tagName,text:els[0].textContent?.substring(0,50)||els[0].title?.substring(0,50)||''}}return {success:false,error:'not found'}})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-click.json | jq -c '.result.value'
}

# Click element by CSS selector
# Usage: vision_click "#add-to-cart-button"
vision_click() {
    local selector="$1"
    # Escape quotes for JSON
    selector="${selector//\"/\\\"}"
    _metrics_action "clicks"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"click\",\"method\":\"click\",\"params\":{\"selector\":\"$selector\"}}" | jq -c '{success}'
}

# Click link containing text
# Usage: vision_click_link "View cart"
vision_click_link() {
    local text="$1"
    _metrics_action "clicks"
    cat > /tmp/vision-click.json << EOF
{"id":"click","method":"evaluate","params":{"script":"(function(){const t='$text'.toLowerCase();const els=[...document.querySelectorAll('a')].filter(e=>(e.textContent||'').toLowerCase().includes(t));if(els[0]){els[0].scrollIntoView({block:'center'});els[0].click();return {success:true,href:els[0].href,text:els[0].textContent?.substring(0,50)}}return {success:false,error:'link not found'}})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-click.json | jq -c '.result.value'
}

# Type text into focused element or selector
# Usage: vision_type "search query" "#search-box"
vision_type() {
    local text="$1"
    local selector="${2:-}"
    _metrics_action "types"

    if [ -n "$selector" ]; then
        # Focus the element first
        curl -s -X POST "$COMMAND_SERVER/command" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"focus\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.focus()\"}}" > /dev/null
    fi

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"type\",\"method\":\"type\",\"params\":{\"text\":\"$text\"}}" | jq -c '{success}'
}

# Fill input field
# Usage: vision_fill "#search" "usb cable"
vision_fill() {
    local selector="$1"
    local value="$2"
    # Escape quotes for JSON
    selector="${selector//\"/\\\"}"
    value="${value//\"/\\\"}"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"fill\",\"method\":\"fill\",\"params\":{\"selector\":\"$selector\",\"value\":\"$value\"}}" | jq -c '{success}'
}

# Press key
# Usage: vision_press "Enter"
vision_press() {
    local key="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"key\",\"method\":\"press\",\"params\":{\"key\":\"$key\"}}" | jq -c '{success}'
}

# Scroll page
# Usage: vision_scroll "down" 500
vision_scroll() {
    local direction="${1:-down}"
    local amount="${2:-300}"
    local delta=$amount
    [ "$direction" = "up" ] && delta=-$amount
    _metrics_action "scrolls"

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"scroll\",\"method\":\"evaluate\",\"params\":{\"script\":\"window.scrollBy(0,$delta)\"}}" | jq -c '{success:.success}'
}

# Scroll element into view
# Usage: vision_scroll_to "#product-details"
vision_scroll_to() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"scroll\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.scrollIntoView({block:'center'})\"}}" | jq -c '{success:.success}'
}

# ============================================================================
# Page Analysis - Help Claude Understand the Page
# ============================================================================

# Get all interactive elements (buttons, links, inputs)
# Usage: vision_get_interactives
vision_get_interactives() {
    cat > /tmp/vision-query.json << 'EOF'
{"id":"query","method":"evaluate","params":{"script":"(function(){const els=[];document.querySelectorAll('button,a[href],input[type=submit],input[type=button],[role=button]').forEach((e,i)=>{if(i>30)return;const r=e.getBoundingClientRect();if(r.width===0||r.height===0)return;const t=e.textContent?.trim()||e.value||e.title||e.getAttribute('aria-label')||'';if(!t)return;els.push({tag:e.tagName,text:t.substring(0,60),type:e.type||null})});return els})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-query.json | jq '.result.value'
}

# Check if text exists on page
# Usage: vision_has_text "Added to cart"
vision_has_text() {
    local text="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"check\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.body.textContent.toLowerCase().includes('$text'.toLowerCase())\"}}" | jq -r '.result.value'
}

# Get text content of element
# Usage: vision_get_text "#price"
vision_get_text() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"text\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.textContent?.trim()||null\"}}" | jq -r '.result.value'
}

# Count elements matching selector
# Usage: vision_count ".product-card"
vision_count() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"count\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelectorAll('$selector').length\"}}" | jq -r '.result.value'
}

# ============================================================================
# Set-of-Mark - Label Elements with Numbers for Claude to Reference
# ============================================================================

# Mark all interactive elements with numbered labels
# Usage: vision_mark
vision_mark() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"mark","method":"markElements","params":{}}' | jq -c '{count:.result.count}'
}

# Remove all marks
# Usage: vision_unmark
vision_unmark() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"unmark","method":"unmarkElements","params":{}}' | jq -c '{cleared:.result.cleared}'
}

# Click element by mark number
# Usage: vision_click_mark 5
vision_click_mark() {
    local label="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"click\",\"method\":\"clickMark\",\"params\":{\"label\":$label}}" | jq -c '{clicked:.result.clicked}'
}

# ============================================================================
# Selector Cache - Learn and Remember Working Selectors Per Domain
# ============================================================================
#
# The selector cache persists working selectors per domain with reliability scores.
# Use it to:
# 1. Learn what selectors work after successful actions
# 2. Recall cached selectors before trying to find new ones
# 3. Track reliability (success/fail counts) over time
#

# Learn a successful selector for an action
# Usage: selector_learn "add-to-cart" "#add-to-cart-button" [url]
# url defaults to current page
selector_learn() {
    local action="$1"
    local selector="$2"
    local url="${3:-$(vision_url)}"

    # Use Python/SQLite instead of iOS app sandbox
    python3 -m atl -f compact selector learn "$action" "$selector" "$url"
}

# Learn selector with attributes for better matching
# Usage: selector_learn_with_attrs "add-to-cart" "#atc" "url" '{"text":"Add to Cart","class":"btn-primary"}'
selector_learn_with_attrs() {
    local action="$1"
    local selector="$2"
    local url="$3"
    local attrs="$4"

    python3 -m atl -f compact selector learn "$action" "$selector" "$url" --attributes "$attrs"
}

# Recall cached selector for an action
# Usage: selector_recall "add-to-cart" [url]
# Returns: {selector, reliability, successCount, ...} or null
selector_recall() {
    local action="$1"
    local url="${2:-$(vision_url)}"

    # Use Python/SQLite - returns just the selector or exits 1 if not found
    python3 -m atl -f compact selector recall "$action" "$url" 2>/dev/null
}

# Record a selector failure (decreases reliability)
# Usage: selector_fail "add-to-cart" "#old-button" [url]
selector_fail() {
    local action="$1"
    local selector="$2"
    local url="${3:-$(vision_url)}"

    # Use Python/SQLite
    python3 -m atl -f compact selector fail "$action" "$selector" "$url"
}

# Get all cached selectors for current domain
# Usage: selector_get_all [url]
selector_get_all() {
    local url="${1:-$(vision_url)}"
    # Extract domain from URL for filtering
    local domain=$(echo "$url" | sed -E 's#^https?://([^/]+).*#\1#')

    python3 -m atl selector list --domain "$domain"
}

# List all domains with cached selectors
# Usage: selector_domains
selector_domains() {
    # List all selectors grouped by domain
    python3 -m atl selector list | jq -r 'keys[]' 2>/dev/null
}

# Get cache statistics
# Usage: selector_stats
selector_stats() {
    python3 -m atl selector stats
}

# Clear cache for a domain
# Usage: selector_clear "amazon.com"
selector_clear() {
    local domain="$1"
    python3 -m atl -f compact selector clear --domain "$domain"
}

# Export entire cache (for backup/analysis)
# Usage: selector_export > cache-backup.json
selector_export() {
    python3 -m atl selector list
}

# Smart click - tries cached selector first, falls back to text search
# Usage: selector_click "add-to-cart" "Add to Cart"
# Returns: {success, usedCache, selector}
selector_click() {
    local action="$1"
    local fallback_text="$2"

    # Try cached selector first
    local cached=$(selector_recall "$action")

    if [ "$cached" != "null" ] && [ -n "$cached" ]; then
        local selector=$(echo "$cached" | jq -r '.selector')
        # Try to click it
        local result=$(vision_click "$selector")
        local success=$(echo "$result" | jq -r '.success')

        if [ "$success" = "true" ]; then
            # Update success count
            selector_learn "$action" "$selector" >/dev/null
            echo "{\"success\":true,\"usedCache\":true,\"selector\":\"$selector\"}"
            return 0
        else
            # Record failure
            selector_fail "$action" "$selector" >/dev/null
        fi
    fi

    # Fall back to text search
    local result=$(vision_click_text "$fallback_text")
    local success=$(echo "$result" | jq -r '.success')

    if [ "$success" = "true" ]; then
        # Learn from success - we don't know the exact selector, but we can note the action worked
        echo "{\"success\":true,\"usedCache\":false,\"method\":\"text\",\"text\":\"$fallback_text\"}"
        return 0
    fi

    echo "{\"success\":false,\"usedCache\":false,\"error\":\"both cache and fallback failed\"}"
    return 1
}

# ============================================================================
# Workflow Completion
# ============================================================================

# Finalize workflow and save summary
# Usage: vision_complete "success" "Added item to cart"
vision_complete() {
    local run_status="${1:-success}"
    local run_message="${2:-Workflow completed}"

    local manifest="$VISION_RUN_DIR/manifest.json"
    local temp=$(mktemp)

    jq --arg status "$run_status" \
       --arg message "$run_message" \
       --arg endTime "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg steps "$VISION_STEP" \
       '. + {status:$status,message:$message,endTime:$endTime,totalSteps:($steps|tonumber)}' \
       "$manifest" > "$temp" && mv "$temp" "$manifest"

    # Complete run in Python/SQLite
    if [ -n "$VISION_RUN_ID" ]; then
        # Map status to CLI status
        local cli_status="completed"
        [[ "$run_status" != "success" ]] && cli_status="failed"
        python3 -m atl -f compact run complete "$VISION_RUN_ID" --status "$cli_status" --steps "$VISION_STEP" >/dev/null 2>&1 || true
    fi

    echo "{\"runId\":\"$VISION_RUN_ID\",\"status\":\"$run_status\",\"steps\":$VISION_STEP,\"dir\":\"$VISION_RUN_DIR\"}"
}

# ============================================================================
# Utility
# ============================================================================

# Wait for specified seconds
# Usage: vision_wait 2
vision_wait() {
    local seconds="${1:-1}"
    sleep "$seconds"
}

# Print usage
vision_help() {
    cat << 'HELP'
Vision Loop - Claude-in-the-loop browser automation

WORKFLOW:
  vision_init "name"              Initialize workflow run
  vision_capture "step-name"      Capture PDF for Claude to read
  vision_complete "status" "msg"  Finalize workflow

CAPTURE MODES (ordered by size):
  vision_capture_light            Text + interactives (~9KB, 99% smaller)
  vision_capture_jpeg [q] [full]  JPEG viewport/full (~360KB/700KB)
  vision_save_jpeg "file.jpg"     Save JPEG to file
  vision_capture "step"           PDF full page (~1.1MB, for debug)
  vision_capture_smart [mode]     Choose: light|vision|full|debug

  Size comparison:
    light  ~9KB    Use for routine navigation
    vision ~360KB  When layout matters (viewport JPEG)
    full   ~700KB  Full scrollable page (JPEG)
    debug  ~1.1MB  PDF for archiving/debugging

PAGE READY (replaces fixed sleep):
  vision_wait_ready [timeout] [stabilityMs] [selector]
                                  Wait for DOM stable + network idle
                                  Returns: {ready,waitedMs,checks,...}
  vision_goto "url" [timeout] [selector]
                                  Navigate + auto wait for ready

NAVIGATION:
  vision_goto "url"               Navigate to URL (auto waits for ready)
  vision_url                      Get current URL
  vision_title                    Get page title

ACTIONS (JS injection - only method that works for WebView):
  vision_click_text "text"        Click by visible text
  vision_click "#selector"        Click by CSS selector
  vision_click_link "text"        Click link containing text
  vision_type "text" "#input"     Type into element
  vision_fill "#input" "value"    Fill input field
  vision_press "Enter"            Press key
  vision_scroll "down" 300        Scroll page
  vision_scroll_to "#element"     Scroll element into view

ANALYSIS:
  vision_get_interactives         List clickable elements
  vision_has_text "text"          Check if text exists
  vision_get_text "#selector"     Get element text
  vision_count ".selector"        Count matching elements

SET-OF-MARK:
  vision_mark                     Label elements with numbers
  vision_unmark                   Remove labels
  vision_click_mark 5             Click element #5

SELECTOR CACHE (per-domain learning):
  selector_learn "action" "sel"   Learn successful selector
  selector_recall "action"        Get cached selector (or null)
  selector_fail "action" "sel"    Record failure (decreases reliability)
  selector_click "action" "text"  Smart click: cache first, fallback to text
  selector_get_all                Get all cached selectors for domain
  selector_domains                List domains with cached data
  selector_stats                  Get cache statistics
  selector_export                 Export all cache data as JSON
  selector_clear "domain"         Clear cache for domain

METRICS & COST TRACKING:
  vision_metrics                  Get raw metrics JSON
  vision_cost                     Get token/cost estimate
  vision_summary                  Full summary with projections

  Metrics tracked per run:
    - Captures by mode (light/jpeg/pdf)
    - Bytes read (for token estimation)
    - Actions (clicks, types, scrolls, navigations)
    - Selector cache hits/misses
    - Wait timing

  Cost estimation:
    - ~0.25 tokens per byte
    - $3 per 1M tokens (Sonnet input)

EXAMPLE:
  source watchdog/vision-loop.sh
  vision_init "cart-flow"
  vision_goto "https://amazon.com/s?k=usb+cable"  # Auto-waits for ready
  vision_capture "search-results"    # Claude reads this PDF
  vision_click_text "Add to cart"    # Claude decides this action
  vision_wait_ready 5                # Wait for DOM to settle after action
  vision_capture "after-add"         # Claude verifies result
  vision_goto "https://amazon.com/cart"
  vision_capture "cart"              # Claude confirms item in cart
  vision_complete "success" "Item added to cart"
HELP
}

# If run directly, show help
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vision_help
fi
