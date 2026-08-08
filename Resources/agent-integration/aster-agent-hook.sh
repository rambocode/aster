#!/bin/sh
# Aster Agent lifecycle hook. Provider hooks execute this small, auditable bridge with
# `state provider` arguments. The hook payload is drained but never persisted or forwarded.
state="${1-}"
provider="${2-}"

case "$state" in
  processing|idle|awaiting-input) ;;
  *) exit 0 ;;
esac
case "$provider" in
  claudeCode|codex|openCode|cursorCLI|kimiCode|pi|omp) ;;
  *) exit 0 ;;
esac

# Hooks receive JSON on stdin. Drain it so the producer cannot block, while deliberately
# avoiding interpolation into either the terminal sequence or a child command.
/bin/cat >/dev/null 2>&1 || true

# /dev/tty binds the event to the exact Aster Pane even when several agents share a cwd.
# Failure is intentionally non-fatal: removing or closing Aster must not break the agent.
if [ -w /dev/tty ]; then
  /usr/bin/printf '\033]6974;AgentState=%s;Provider=%s\007' "$state" "$provider" \
    > /dev/tty 2>/dev/null || true
fi
exit 0
