#!/bin/sh
# Aster Agent lifecycle hook. Provider hooks execute this small, auditable bridge with
# `state provider [session-id]` arguments. The hook payload is drained but never persisted or forwarded.
state="${1-}"
provider="${2-}"
session_id="${3-}"

case "$state" in
  processing|idle|awaiting-input) ;;
  *) exit 0 ;;
esac
case "$provider" in
  claudeCode|codex|openCode|cursorCLI|kimiCode|pi|omp) ;;
  *) exit 0 ;;
esac

# 只有 provider 已经把稳定 session id 作为独立参数传入时才附加。严格字符集和长度
# 防止 payload、prompt 或任意 JSON 字段越过 OSC 边界。
case "$session_id" in
  ""|*[!A-Za-z0-9._:-]*) session_id="" ;;
esac
if [ "${#session_id}" -gt 128 ]; then
  session_id=""
fi

# Hooks receive JSON on stdin. Drain it so the producer cannot block, while deliberately
# avoiding interpolation into either the terminal sequence or a child command.
/bin/cat >/dev/null 2>&1 || true

# /dev/tty binds the event to the exact Aster Pane even when several agents share a cwd.
# Failure is intentionally non-fatal: removing or closing Aster must not break the agent.
if [ -w /dev/tty ]; then
  if [ -n "$session_id" ]; then
    /usr/bin/printf '\033]6974;AgentState=%s;Provider=%s;SessionID=%s\007' \
      "$state" "$provider" "$session_id" > /dev/tty 2>/dev/null || true
  else
    /usr/bin/printf '\033]6974;AgentState=%s;Provider=%s\007' "$state" "$provider" \
      > /dev/tty 2>/dev/null || true
  fi
fi
exit 0
