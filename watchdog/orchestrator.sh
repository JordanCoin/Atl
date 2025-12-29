#!/bin/bash
# Atl Orchestrator - Centralized state management for automation runs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/orchestrator.json"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# ============================================================================
# SIMULATOR POOL MANAGEMENT
# ============================================================================

# Refresh simulator list from simctl
orch_refresh_sims() {
    local sims=$(xcrun simctl list devices available --json 2>/dev/null)
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build simulator entries
    local sim_json="{}"
    local pools_json="{}"

    while IFS= read -r line; do
        local udid=$(echo "$line" | jq -r '.udid')
        local name=$(echo "$line" | jq -r '.name')
        local state=$(echo "$line" | jq -r '.state')

        # Determine device type and screen size
        local device_type="iPhone"
        local screen_size="393x852"  # Default iPhone size

        if [[ "$name" == *"iPad"* ]]; then
            device_type="iPad"
            if [[ "$name" == *"Pro 13"* ]] || [[ "$name" == *"Air 13"* ]]; then
                screen_size="1032x1376"
            elif [[ "$name" == *"Pro 11"* ]] || [[ "$name" == *"Air 11"* ]]; then
                screen_size="834x1194"
            else
                screen_size="820x1180"
            fi
        elif [[ "$name" == *"Pro Max"* ]]; then
            screen_size="430x932"
        elif [[ "$name" == *"Pro"* ]]; then
            screen_size="393x852"
        elif [[ "$name" == *"Air"* ]]; then
            screen_size="320x693"
        fi

        # Map simctl state to our state
        local orch_state="offline"
        [[ "$state" == "Booted" ]] && orch_state="available"
        [[ "$state" == "Shutdown" ]] && orch_state="offline"

        # Check if sim is busy (has active task in state file)
        local current_task=$(jq -r --arg udid "$udid" '.tasks | to_entries[] | select(.value.simulators[] == $udid and .value.status == "running") | .key' "$STATE_FILE" 2>/dev/null | head -1)
        [[ -n "$current_task" ]] && orch_state="busy"

        # Build pool key
        local pool_key="${device_type}-${screen_size}"

        # Add to simulators
        sim_json=$(echo "$sim_json" | jq --arg udid "$udid" --arg name "$name" --arg type "$device_type" \
            --arg size "$screen_size" --arg state "$orch_state" --arg task "$current_task" --arg now "$now" \
            '. + {($udid): {name: $name, deviceType: $type, screenSize: $size, state: $state, currentTask: (if $task == "" then null else $task end), port: null, lastActivity: $now}}')

        # Add to pools
        pools_json=$(echo "$pools_json" | jq --arg key "$pool_key" --arg udid "$udid" \
            '.[$key] = ((.[$key] // []) + [$udid])')

    done < <(echo "$sims" | jq -c '.devices | to_entries[] | .value[] | {udid, name, state}')

    # Update state file
    jq --argjson sims "$sim_json" --argjson pools "$pools_json" --arg now "$now" \
        '.simulators = $sims | .pools = $pools | .lastUpdated = $now' "$STATE_FILE" > "$STATE_FILE.tmp" && \
        mv "$STATE_FILE.tmp" "$STATE_FILE"

    echo "Refreshed: $(echo "$sim_json" | jq 'length') simulators in $(echo "$pools_json" | jq 'length') pools"
}

# List available simulators
orch_list_sims() {
    local filter="${1:-all}"  # all, available, busy, offline

    if [[ "$filter" == "all" ]]; then
        jq -r '.simulators | to_entries[] | "\(.value.state)\t\(.value.name)\t\(.key)"' "$STATE_FILE" | column -t
    else
        jq -r --arg state "$filter" '.simulators | to_entries[] | select(.value.state == $state) | "\(.value.name)\t\(.key)"' "$STATE_FILE" | column -t
    fi
}

# Get pool info (same-size simulators)
orch_pools() {
    jq -r '.pools | to_entries[] | "\(.key): \(.value | length) sims"' "$STATE_FILE"
}

# Acquire a simulator from a pool
orch_acquire() {
    local pool="${1:-iPhone-393x852}"
    local task_id="${2:-$(uuidgen)}"

    # Find first available sim in pool
    local udid=$(jq -r --arg pool "$pool" \
        '.pools[$pool][] as $u | .simulators[$u] | select(.state == "available") | $u' "$STATE_FILE" 2>/dev/null | head -1)

    if [[ -z "$udid" ]]; then
        echo "ERROR: No available simulator in pool $pool" >&2
        return 1
    fi

    # Mark as busy
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg udid "$udid" --arg task "$task_id" --arg now "$now" \
        '.simulators[$udid].state = "busy" | .simulators[$udid].currentTask = $task | .simulators[$udid].lastActivity = $now' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    echo "$udid"
}

# Release a simulator back to pool
orch_release() {
    local udid="$1"
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check if still booted
    local sim_state=$(xcrun simctl list devices --json 2>/dev/null | jq -r --arg udid "$udid" '.devices[][] | select(.udid == $udid) | .state')
    local new_state="offline"
    [[ "$sim_state" == "Booted" ]] && new_state="available"

    jq --arg udid "$udid" --arg state "$new_state" --arg now "$now" \
        '.simulators[$udid].state = $state | .simulators[$udid].currentTask = null | .simulators[$udid].lastActivity = $now' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    echo "Released $udid -> $new_state"
}

# ============================================================================
# TASK MANAGEMENT
# ============================================================================

# Register a new task
orch_task_start() {
    local task_id="$1"
    local workflow="$2"
    local simulator="$3"
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq --arg id "$task_id" --arg wf "$workflow" --arg sim "$simulator" --arg now "$now" \
        '.tasks[$id] = {workflow: $wf, status: "running", simulators: [$sim], startTime: $now, progress: 0, metrics: {}}' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    echo "Task $task_id started"
}

# Update task progress
orch_task_progress() {
    local task_id="$1"
    local progress="$2"
    local step="${3:-}"

    jq --arg id "$task_id" --argjson prog "$progress" --arg step "$step" \
        '.tasks[$id].progress = $prog | .tasks[$id].currentStep = $step' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Complete a task
orch_task_complete() {
    local task_id="$1"
    local status="${2:-completed}"  # completed or failed
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Get simulator(s) to release
    local sims=$(jq -r --arg id "$task_id" '.tasks[$id].simulators[]' "$STATE_FILE")

    jq --arg id "$task_id" --arg status "$status" --arg now "$now" \
        '.tasks[$id].status = $status | .tasks[$id].endTime = $now | .tasks[$id].progress = 1' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    # Release simulators
    for sim in $sims; do
        orch_release "$sim"
    done

    echo "Task $task_id -> $status"
}

# Update task metrics (merge with existing)
orch_task_metrics() {
    local task_id="$1"
    local metrics_json="$2"

    jq --arg id "$task_id" --argjson m "$metrics_json" \
        '.tasks[$id].metrics = (.tasks[$id].metrics // {}) + $m' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# List active tasks
orch_tasks() {
    local filter="${1:-running}"  # running, completed, failed, all

    if [[ "$filter" == "all" ]]; then
        jq -r '.tasks | to_entries[] | "\(.value.status)\t\(.value.workflow)\t\(.key)"' "$STATE_FILE" | column -t
    else
        jq -r --arg status "$filter" '.tasks | to_entries[] | select(.value.status == $status) | "\(.value.workflow)\t\(.key)"' "$STATE_FILE" | column -t
    fi
}

# ============================================================================
# METRICS AGGREGATION
# ============================================================================

# Aggregate metrics from all completed tasks
orch_aggregate_metrics() {
    local total_runs=$(jq '[.tasks | to_entries[] | select(.value.status == "completed")] | length' "$STATE_FILE")
    local total_bytes=$(jq '[.tasks[].metrics.totalBytes // 0] | add // 0' "$STATE_FILE")
    local total_tokens=$(jq '[.tasks[].metrics.totalTokens // 0] | add // 0' "$STATE_FILE")

    # Estimate cost (Sonnet: $3/1M tokens)
    local total_cost=$(echo "scale=4; $total_tokens * 3 / 1000000" | bc)

    jq --argjson runs "$total_runs" --argjson bytes "$total_bytes" \
       --argjson tokens "$total_tokens" --arg cost "$total_cost" \
        '.metrics = {totalRuns: $runs, totalBytes: $bytes, totalTokens: $tokens, totalCost: ($cost | tonumber)}' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    # Format bytes (macOS compatible)
    local bytes_fmt="$total_bytes"
    if [ "$total_bytes" -gt 1073741824 ]; then
        bytes_fmt="$(echo "scale=1; $total_bytes / 1073741824" | bc)GB"
    elif [ "$total_bytes" -gt 1048576 ]; then
        bytes_fmt="$(echo "scale=1; $total_bytes / 1048576" | bc)MB"
    elif [ "$total_bytes" -gt 1024 ]; then
        bytes_fmt="$(echo "scale=1; $total_bytes / 1024" | bc)KB"
    fi
    echo "Aggregated: $total_runs runs, $bytes_fmt bytes, ~$total_tokens tokens, \$$total_cost"
}

# ============================================================================
# EXPORT
# ============================================================================

# Export all data for analysis
orch_export() {
    local output="${1:-$STATE_DIR/export-$(date +%Y%m%d-%H%M%S).json}"

    # Combine state with all run directories
    local runs_dir="$SCRIPT_DIR/runs"
    local runs_data="[]"

    if [[ -d "$runs_dir" ]]; then
        for run in "$runs_dir"/*/; do
            if [[ -f "$run/manifest.json" ]]; then
                local manifest=$(cat "$run/manifest.json")
                local metrics=$(cat "$run/metrics.json" 2>/dev/null || echo "{}")
                local report=$(cat "$run/report.json" 2>/dev/null || echo "{}")

                runs_data=$(echo "$runs_data" | jq --argjson m "$manifest" --argjson met "$metrics" --argjson r "$report" \
                    '. + [{manifest: $m, metrics: $met, report: $r}]')
            fi
        done
    fi

    # Build export
    jq --argjson runs "$runs_data" '. + {runs: $runs}' "$STATE_FILE" > "$output"

    echo "Exported to $output ($(wc -c < "$output" | xargs) bytes)"
}

# ============================================================================
# STATUS
# ============================================================================

orch_status() {
    echo "=== Atl Orchestrator Status ==="
    echo
    echo "Simulators:"
    jq -r '.simulators | to_entries | group_by(.value.state) | .[] | "  \(.[0].value.state): \(length)"' "$STATE_FILE"
    echo
    echo "Pools:"
    jq -r '.pools | to_entries[] | "  \(.key): \(.value | length) sims"' "$STATE_FILE"
    echo
    echo "Tasks:"
    jq -r '.tasks | to_entries | group_by(.value.status) | .[] | "  \(.[0].value.status): \(length)"' "$STATE_FILE"
    echo
    echo "Totals:"
    jq -r '.metrics | "  Runs: \(.totalRuns) | Bytes: \(.totalBytes) | Cost: $\(.totalCost)"' "$STATE_FILE"
}

# ============================================================================
# CLI
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-status}" in
        refresh)     orch_refresh_sims ;;
        sims)        orch_list_sims "${2:-all}" ;;
        pools)       orch_pools ;;
        acquire)     orch_acquire "$2" "$3" ;;
        release)     orch_release "$2" ;;
        task-start)  orch_task_start "$2" "$3" "$4" ;;
        task-progress) orch_task_progress "$2" "$3" "$4" ;;
        task-complete) orch_task_complete "$2" "${3:-completed}" ;;
        task-metrics)  orch_task_metrics "$2" "$3" ;;
        tasks)       orch_tasks "${2:-running}" ;;
        aggregate)   orch_aggregate_metrics ;;
        export)      orch_export "$2" ;;
        status)      orch_status ;;
        *)
            echo "Usage: orchestrator.sh <command>"
            echo "Commands:"
            echo "  refresh         - Refresh simulator list from simctl"
            echo "  sims [filter]   - List simulators (all|available|busy|offline)"
            echo "  pools           - Show simulator pools by screen size"
            echo "  acquire <pool>  - Acquire a sim from pool"
            echo "  release <udid>  - Release a sim back to pool"
            echo "  task-start <id> <workflow> <sim>"
            echo "  task-progress <id> <progress> [step]"
            echo "  task-complete <id> [status]"
            echo "  tasks [filter]  - List tasks (running|completed|failed|all)"
            echo "  aggregate       - Aggregate metrics from all tasks"
            echo "  export [path]   - Export all data"
            echo "  status          - Show current status"
            ;;
    esac
fi
