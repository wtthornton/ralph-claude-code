#!/usr/bin/env bash
# Close stale GitHub issues on frankbria/ralph-claude-code
# Run by a user with write access to the upstream repo.
# Usage: bash scripts/close-stale-issues.sh

REPO="frankbria/ralph-claude-code"

echo "=== Closing completed issues (implemented via epic/story system) ==="
for issue in 14 15 16 17 18 19 20 21 22 23 32 33 34 35 36 37 38 39 40 41 49 69 70 71 72 73 74; do
  echo "Closing #$issue..."
  gh issue close "$issue" --repo "$REPO" \
    --comment "Completed via epic/story system. All 148/148 stories across 40 epics are done. See IMPLEMENTATION_STATUS.md for details."
done

echo ""
echo "=== Closing deferred sandbox issues (not planned) ==="
for issue in 75 76 77 78 79 80; do
  echo "Closing #$issue as not-planned..."
  gh issue close "$issue" --repo "$REPO" --reason "not planned" \
    --comment "Deferred to TheStudio Premium. See IMPLEMENTATION_STATUS.md."
done

echo ""
echo "=== Closing issues fixed in v2.1.0 ==="
for issue in 110 154 221 224; do
  echo "Closing #$issue..."
  gh issue close "$issue" --repo "$REPO" \
    --comment "Fixed in v2.1.0. See IMPLEMENTATION_STATUS.md for details."
done

echo ""
echo "Done. Closed 37 stale issues."
