"""Command-line interface for Atl."""

import argparse
import json
import sys
from typing import List

from . import db, selectors, runs, simulators


def output(data, format: str = "json"):
    """Output data in requested format."""
    if format == "json":
        print(json.dumps(data, indent=2, default=str))
    elif format == "compact":
        print(json.dumps(data, default=str))
    else:
        # Simple text format
        if isinstance(data, dict):
            for k, v in data.items():
                print(f"{k}: {v}")
        elif isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    print("  ".join(f"{k}={v}" for k, v in item.items()))
                else:
                    print(item)
        else:
            print(data)


def cmd_init(args):
    """Initialize database."""
    db.init_db()
    print("Database initialized")


def cmd_reset(args):
    """Reset database."""
    if not args.force:
        confirm = input("This will delete all data. Type 'yes' to confirm: ")
        if confirm != "yes":
            print("Aborted")
            return
    db.reset_db()
    print("Database reset")


# Selector commands
def cmd_selector_learn(args):
    result = selectors.learn(args.action, args.selector, args.url,
                             json.loads(args.attributes) if args.attributes else None)
    output(result, args.format)


def cmd_selector_recall(args):
    result = selectors.recall(args.action, args.url)
    if result:
        if args.selector_only:
            print(result["selector"])
        else:
            output(result, args.format)
    else:
        if not args.selector_only:
            output({"found": False}, args.format)
        sys.exit(1)


def cmd_selector_fail(args):
    result = selectors.fail(args.action, args.selector, args.url)
    output(result, args.format)


def cmd_selector_list(args):
    if args.domain:
        result = selectors.get_all(args.domain)
    else:
        result = selectors.export_all()
    output(result, args.format)


def cmd_selector_stats(args):
    result = selectors.stats()
    output(result, args.format)


def cmd_selector_clear(args):
    result = selectors.clear(args.domain)
    output(result, args.format)


# Run commands
def cmd_run_start(args):
    result = runs.start(args.run_id, args.workflow, args.simulator)
    output(result, args.format)


def cmd_run_complete(args):
    result = runs.complete(args.run_id, args.status, args.steps or 0)
    output(result, args.format)


def cmd_run_progress(args):
    result = runs.progress(args.run_id, args.step, args.total)
    output(result, args.format)


def cmd_run_list(args):
    result = runs.list_runs(args.status, args.limit)
    output(result, args.format)


def cmd_run_get(args):
    result = runs.get(args.run_id)
    if result:
        output(result, args.format)
    else:
        output({"error": "Run not found"}, args.format)
        sys.exit(1)


def cmd_metrics_capture(args):
    result = runs.add_capture(args.run_id, args.mode, args.bytes)
    output(result, args.format)


def cmd_metrics_action(args):
    result = runs.add_action(args.run_id, args.action_type)
    output(result, args.format)


def cmd_metrics_get(args):
    result = runs.get_metrics(args.run_id)
    if result:
        output(result, args.format)
    else:
        output({"error": "Metrics not found"}, args.format)
        sys.exit(1)


def cmd_metrics_aggregate(args):
    result = runs.aggregate()
    output(result, args.format)


# Simulator commands
def cmd_sim_refresh(args):
    result = simulators.refresh()
    output(result, args.format)


def cmd_sim_list(args):
    result = simulators.list_sims(args.state)
    output(result, args.format)


def cmd_sim_pools(args):
    result = simulators.pools()
    output(result, args.format)


def cmd_sim_acquire(args):
    udid = simulators.acquire(args.pool, args.task_id)
    if udid:
        if args.udid_only:
            print(udid)
        else:
            output({"udid": udid, "pool": args.pool}, args.format)
    else:
        if not args.udid_only:
            output({"error": f"No available simulator in pool {args.pool}"}, args.format)
        sys.exit(1)


def cmd_sim_release(args):
    result = simulators.release(args.udid)
    output(result, args.format)


def cmd_sim_stats(args):
    result = simulators.stats()
    output(result, args.format)


# Status command
def cmd_status(args):
    sim_stats = simulators.stats()
    run_stats = runs.aggregate()
    sel_stats = selectors.stats()

    result = {
        "simulators": sim_stats,
        "runs": run_stats,
        "selectors": sel_stats
    }
    output(result, args.format)


def main(argv: List[str] = None):
    parser = argparse.ArgumentParser(prog="atl", description="Atl automation orchestrator")
    parser.add_argument("--format", "-f", choices=["json", "compact", "text"], default="json")

    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # Init/reset
    subparsers.add_parser("init", help="Initialize database")
    reset_p = subparsers.add_parser("reset", help="Reset database")
    reset_p.add_argument("--force", action="store_true")

    # Status
    subparsers.add_parser("status", help="Show overall status")

    # Selector commands
    sel_p = subparsers.add_parser("selector", help="Selector cache commands")
    sel_sub = sel_p.add_subparsers(dest="selector_cmd")

    learn_p = sel_sub.add_parser("learn", help="Learn a selector")
    learn_p.add_argument("action", help="Action name (search, add-to-cart, etc)")
    learn_p.add_argument("selector", help="CSS selector")
    learn_p.add_argument("url", help="URL or domain")
    learn_p.add_argument("--attributes", "-a", help="JSON attributes")

    recall_p = sel_sub.add_parser("recall", help="Recall a selector")
    recall_p.add_argument("action", help="Action name")
    recall_p.add_argument("url", help="URL or domain")
    recall_p.add_argument("--selector-only", "-s", action="store_true", help="Output only selector")

    fail_p = sel_sub.add_parser("fail", help="Record selector failure")
    fail_p.add_argument("action", help="Action name")
    fail_p.add_argument("selector", help="CSS selector that failed")
    fail_p.add_argument("url", help="URL or domain")

    list_p = sel_sub.add_parser("list", help="List selectors")
    list_p.add_argument("--domain", "-d", help="Filter by domain")

    sel_sub.add_parser("stats", help="Selector statistics")

    clear_p = sel_sub.add_parser("clear", help="Clear selectors")
    clear_p.add_argument("--domain", "-d", help="Clear only this domain")

    # Run commands
    run_p = subparsers.add_parser("run", help="Run tracking commands")
    run_sub = run_p.add_subparsers(dest="run_cmd")

    start_p = run_sub.add_parser("start", help="Start a run")
    start_p.add_argument("run_id", help="Run ID")
    start_p.add_argument("workflow", help="Workflow name")
    start_p.add_argument("--simulator", "-s", help="Simulator UDID")

    complete_p = run_sub.add_parser("complete", help="Complete a run")
    complete_p.add_argument("run_id", help="Run ID")
    complete_p.add_argument("--status", default="completed", choices=["completed", "failed"])
    complete_p.add_argument("--steps", type=int, help="Total steps completed")

    progress_p = run_sub.add_parser("progress", help="Update progress")
    progress_p.add_argument("run_id", help="Run ID")
    progress_p.add_argument("step", type=int, help="Current step")
    progress_p.add_argument("--total", type=int, help="Total steps")

    list_run_p = run_sub.add_parser("list", help="List runs")
    list_run_p.add_argument("--status", "-s", choices=["running", "completed", "failed"])
    list_run_p.add_argument("--limit", "-n", type=int, default=20)

    get_run_p = run_sub.add_parser("get", help="Get run details")
    get_run_p.add_argument("run_id", help="Run ID")

    # Metrics commands
    met_p = subparsers.add_parser("metrics", help="Metrics commands")
    met_sub = met_p.add_subparsers(dest="metrics_cmd")

    cap_p = met_sub.add_parser("capture", help="Record a capture")
    cap_p.add_argument("run_id", help="Run ID")
    cap_p.add_argument("mode", choices=["light", "jpeg", "pdf"])
    cap_p.add_argument("bytes", type=int, help="Byte count")

    act_p = met_sub.add_parser("action", help="Record an action")
    act_p.add_argument("run_id", help="Run ID")
    act_p.add_argument("action_type", choices=["click", "type", "navigation", "scroll"])

    get_met_p = met_sub.add_parser("get", help="Get metrics for a run")
    get_met_p.add_argument("run_id", help="Run ID")

    met_sub.add_parser("aggregate", help="Aggregate all metrics")

    # Simulator commands
    sim_p = subparsers.add_parser("sim", help="Simulator commands")
    sim_sub = sim_p.add_subparsers(dest="sim_cmd")

    sim_sub.add_parser("refresh", help="Refresh simulator list")

    list_sim_p = sim_sub.add_parser("list", help="List simulators")
    list_sim_p.add_argument("--state", "-s", choices=["available", "busy", "offline"])

    sim_sub.add_parser("pools", help="Show simulator pools")

    acquire_p = sim_sub.add_parser("acquire", help="Acquire a simulator")
    acquire_p.add_argument("pool", help="Pool name (e.g., iPhone-393x852)")
    acquire_p.add_argument("task_id", help="Task ID")
    acquire_p.add_argument("--udid-only", "-u", action="store_true")

    release_p = sim_sub.add_parser("release", help="Release a simulator")
    release_p.add_argument("udid", help="Simulator UDID")

    sim_sub.add_parser("stats", help="Simulator statistics")

    # Parse and dispatch
    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        return

    # Initialize DB on first use
    db.init_db()

    # Dispatch
    if args.command == "init":
        cmd_init(args)
    elif args.command == "reset":
        cmd_reset(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "selector":
        if args.selector_cmd == "learn":
            cmd_selector_learn(args)
        elif args.selector_cmd == "recall":
            cmd_selector_recall(args)
        elif args.selector_cmd == "fail":
            cmd_selector_fail(args)
        elif args.selector_cmd == "list":
            cmd_selector_list(args)
        elif args.selector_cmd == "stats":
            cmd_selector_stats(args)
        elif args.selector_cmd == "clear":
            cmd_selector_clear(args)
        else:
            sel_p.print_help()
    elif args.command == "run":
        if args.run_cmd == "start":
            cmd_run_start(args)
        elif args.run_cmd == "complete":
            cmd_run_complete(args)
        elif args.run_cmd == "progress":
            cmd_run_progress(args)
        elif args.run_cmd == "list":
            cmd_run_list(args)
        elif args.run_cmd == "get":
            cmd_run_get(args)
        else:
            run_p.print_help()
    elif args.command == "metrics":
        if args.metrics_cmd == "capture":
            cmd_metrics_capture(args)
        elif args.metrics_cmd == "action":
            cmd_metrics_action(args)
        elif args.metrics_cmd == "get":
            cmd_metrics_get(args)
        elif args.metrics_cmd == "aggregate":
            cmd_metrics_aggregate(args)
        else:
            met_p.print_help()
    elif args.command == "sim":
        if args.sim_cmd == "refresh":
            cmd_sim_refresh(args)
        elif args.sim_cmd == "list":
            cmd_sim_list(args)
        elif args.sim_cmd == "pools":
            cmd_sim_pools(args)
        elif args.sim_cmd == "acquire":
            cmd_sim_acquire(args)
        elif args.sim_cmd == "release":
            cmd_sim_release(args)
        elif args.sim_cmd == "stats":
            cmd_sim_stats(args)
        else:
            sim_p.print_help()


if __name__ == "__main__":
    main()
