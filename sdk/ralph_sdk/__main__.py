"""Ralph SDK CLI entry point — `python -m ralph_sdk` or `ralph --sdk`."""

from __future__ import annotations

import argparse
import logging
import sys

from ralph_sdk import __version__
from ralph_sdk.agent import RalphAgent
from ralph_sdk.config import RalphConfig


def _build_parser() -> argparse.ArgumentParser:
    """Construct the SDK CLI argument parser."""
    parser = argparse.ArgumentParser(
        prog="ralph-sdk",
        description="Ralph Agent SDK — autonomous development loop (Python mode)",
    )
    parser.add_argument(
        "-V", "--version",
        action="version",
        version=f"ralph-sdk {__version__}",
    )
    parser.add_argument(
        "-d", "--project-dir",
        default=".",
        help="Project directory (default: current directory)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview loop execution without API calls",
    )
    parser.add_argument(
        "-c", "--calls",
        type=int,
        default=None,
        help="Max API calls per hour",
    )
    parser.add_argument(
        "-t", "--timeout",
        type=int,
        default=None,
        help="Timeout per iteration in minutes",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Claude model to use",
    )
    parser.add_argument(
        "--max-turns",
        type=int,
        default=None,
        help="Max turns per iteration",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Show current status and exit",
    )
    parser.add_argument(
        "--reset-circuit",
        action="store_true",
        help="Reset circuit breaker and exit",
    )
    return parser


def _apply_overrides(config: RalphConfig, args: argparse.Namespace) -> None:
    """Apply CLI argument overrides onto the loaded config."""
    if args.dry_run:
        config.dry_run = True
    if args.calls is not None:
        config.max_calls_per_hour = args.calls
    if args.timeout is not None:
        config.timeout_minutes = args.timeout
    if args.model is not None:
        config.model = args.model
    if args.max_turns is not None:
        config.max_turns = args.max_turns
    if args.verbose:
        config.verbose = True


def _handle_early_exit(args: argparse.Namespace) -> int | None:
    """Handle --status / --reset-circuit early-exit subcommands. Returns exit code or None."""
    if args.status:
        import json

        from ralph_sdk.status import RalphStatus
        status = RalphStatus.load(f"{args.project_dir}/.ralph")
        print(json.dumps(status.to_dict(), indent=2))
        return 0

    if args.reset_circuit:
        from ralph_sdk.status import CircuitBreakerState
        cb = CircuitBreakerState.load(f"{args.project_dir}/.ralph")
        cb.reset("Manual reset via SDK CLI")
        cb.save(f"{args.project_dir}/.ralph")
        print("Circuit breaker reset to CLOSED")
        return 0

    return None


def main(argv: list[str] | None = None) -> int:
    """SDK-mode CLI entry point."""
    args = _build_parser().parse_args(argv)

    # Configure logging
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    config = RalphConfig.load(args.project_dir)
    _apply_overrides(config, args)

    early_exit = _handle_early_exit(args)
    if early_exit is not None:
        return early_exit

    # Run the agent (sync wrapper around async loop)
    agent = RalphAgent(config=config, project_dir=args.project_dir)
    result = agent.run_sync()

    if result.error:
        logging.getLogger("ralph.sdk").error("Loop ended with error: %s", result.error)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
