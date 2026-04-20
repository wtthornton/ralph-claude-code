#!/bin/bash
# lib/pricing.sh — Anthropic model pricing table + per-turn cost calculator.
#
# Background (2026-04): Claude Code 2.1.x Stop-hook stdin does not carry cost
# or usage. The official per-turn transcript at ~/.claude/projects/<slug>/*.jsonl
# contains `.message.usage` on every assistant message but no "type":"result"
# line, so total_cost_usd cannot be read back directly. The stream-json capture
# at .ralph/logs/claude_output_*.log does contain it, but is subject to a race
# (tee for the next loop opens before the stop hook fires). This module gives
# the hook a deterministic fallback: sum tokens off the transcript, apply
# pricing here, and stop depending on result lines at all.
#
# Source: platform.claude.com/docs/en/about-claude/pricing (verified 2026-04-20).
# Rates are per 1M tokens, USD. Update when Anthropic publishes new pricing.
#
# Usage:
#   source lib/pricing.sh
#   cost=$(pricing_compute_cost "$model" "$input" "$output" "$cache_read" "$cache_create_5m" "$cache_create_1h")
#
# Returns cost in USD with 6-decimal precision, or "0.000000" if the model is
# unknown (abstain rather than guess — a wrong cost is worse than a zero).

# Per-1M-token rates. Columns: input, output, cache_read, cache_write_5m, cache_write_1h.
# Models not in this table return 0 and emit a stderr warning.
pricing_rates_for_model() {
  local model="$1"
  case "$model" in
    claude-opus-4-7*)       echo "5.00 25.00 0.50 6.25 10.00" ;;
    claude-opus-4-6*)       echo "5.00 25.00 0.50 6.25 10.00" ;;
    claude-sonnet-4-6*)     echo "3.00 15.00 0.30 3.75 6.00" ;;
    claude-sonnet-4-5*)     echo "3.00 15.00 0.30 3.75 6.00" ;;
    claude-haiku-4-5*)      echo "1.00 5.00 0.10 1.25 2.00" ;;
    *)
      echo "WARN: pricing_rates_for_model: unknown model '$model' — cost will be 0" >&2
      echo "0 0 0 0 0"
      ;;
  esac
}

# pricing_compute_cost <model> <input> <output> <cache_read> <cache_create_5m> <cache_create_1h>
# All token counts are raw integers. Output is a decimal string with 6 places.
pricing_compute_cost() {
  local model="$1"
  local input="${2:-0}"
  local output="${3:-0}"
  local cache_read="${4:-0}"
  local cache_create_5m="${5:-0}"
  local cache_create_1h="${6:-0}"

  # Sanitize — anything non-numeric collapses to 0 so we never feed garbage to awk.
  [[ "$input" =~ ^[0-9]+$ ]] || input=0
  [[ "$output" =~ ^[0-9]+$ ]] || output=0
  [[ "$cache_read" =~ ^[0-9]+$ ]] || cache_read=0
  [[ "$cache_create_5m" =~ ^[0-9]+$ ]] || cache_create_5m=0
  [[ "$cache_create_1h" =~ ^[0-9]+$ ]] || cache_create_1h=0

  read -r r_in r_out r_cr r_cw5 r_cw1 < <(pricing_rates_for_model "$model")

  awk -v i="$input" -v o="$output" -v cr="$cache_read" \
      -v cw5="$cache_create_5m" -v cw1="$cache_create_1h" \
      -v ri="$r_in" -v ro="$r_out" -v rcr="$r_cr" -v rcw5="$r_cw5" -v rcw1="$r_cw1" \
      'BEGIN { printf "%.6f", (i*ri + o*ro + cr*rcr + cw5*rcw5 + cw1*rcw1) / 1000000 }'
}
