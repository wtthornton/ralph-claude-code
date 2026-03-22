# Story OBSERVE-2: Local Notification System

**Epic:** [RALPH-OBSERVE](epic-observability.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `ralph_loop.sh`, new `lib/notify.sh`

---

## Problem

When Ralph runs long autonomous sessions (hours), users have no way to know when work completes, fails, or hits a circuit breaker trip without watching the terminal. This is especially painful on overnight or background runs.

## Solution

Add a lightweight notification system scoped to **local alerts and simple webhook callbacks**. External channel integrations (Slack, email, Discord) are TheStudio premium features built on its SSE event infrastructure.

## Implementation

1. Create `lib/notify.sh` with notification dispatch:
   ```bash
   notify() {
     local event="$1"  # completed | failed | circuit_tripped | rate_limited
     local message="$2"

     # Terminal notification (always)
     echo "[RALPH] $event: $message"

     # OS notification (if available)
     if command -v notify-send &>/dev/null; then
       notify-send "Ralph: $event" "$message"
     elif command -v osascript &>/dev/null; then
       osascript -e "display notification \"$message\" with title \"Ralph: $event\""
     fi

     # Webhook (if configured)
     if [ -n "$RALPH_WEBHOOK_URL" ]; then
       curl -s -X POST "$RALPH_WEBHOOK_URL" \
         -H "Content-Type: application/json" \
         -d "{\"event\": \"$event\", \"message\": \"$message\", \"project\": \"$PROJECT_DIR\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" &
     fi

     # Sound (if configured)
     if [ "$RALPH_NOTIFY_SOUND" = "true" ]; then
       printf '\a'  # terminal bell
     fi
   }
   ```

2. Integrate notifications at key lifecycle points:
   - Loop completed (exit signal received)
   - Loop failed (non-zero exit, crash)
   - Circuit breaker tripped
   - Rate limit hit (5-hour quota)

3. Configuration in `.ralphrc` / `ralph.config.json`:
   ```bash
   RALPH_WEBHOOK_URL=""           # Optional webhook endpoint
   RALPH_NOTIFY_SOUND="false"     # Terminal bell on events
   RALPH_NOTIFY_OS="true"         # OS-level notifications
   ```

### Key Design Decisions

1. **No external service dependencies:** Notifications use OS-native tools (`notify-send`, `osascript`) and optional webhook. No Slack/email SDKs.
2. **Webhook is the extension point:** Users who want Slack/Discord can point the webhook at Zapier, n8n, or a simple relay. TheStudio provides native channel integrations.
3. **Fire-and-forget:** Webhook calls are async (`&` background). Notification failure never blocks the loop.
4. **WSL support:** `notify-send` works in WSL2 with `wslu` installed. Falls back gracefully.

## Testing

```bash
@test "notify sends terminal message" {
  source lib/notify.sh
  run notify "completed" "All tasks done"
  [[ "$output" == *"[RALPH] completed: All tasks done"* ]]
}

@test "notify calls webhook when configured" {
  export RALPH_WEBHOOK_URL="http://localhost:9999/hook"
  # Start mock server
  nc -l 9999 > /tmp/webhook_payload &
  source lib/notify.sh
  notify "completed" "All tasks done"
  wait
  grep -q '"event": "completed"' /tmp/webhook_payload
}

@test "notify degrades gracefully without OS tools" {
  # Remove notify-send and osascript from PATH
  export PATH="/usr/bin"
  source lib/notify.sh
  run notify "completed" "test"
  [ "$status" -eq 0 ]
}
```

## Acceptance Criteria

- [ ] Terminal notification on loop completion, failure, circuit breaker trip, rate limit
- [ ] OS notification via `notify-send` (Linux) or `osascript` (macOS) when available
- [ ] Webhook POST to `RALPH_WEBHOOK_URL` when configured
- [ ] Webhook payload includes event type, message, project path, timestamp
- [ ] Notification failure never blocks the main loop
- [ ] Graceful degradation when OS notification tools are not available
- [ ] Configuration via `.ralphrc` and `ralph.config.json`
