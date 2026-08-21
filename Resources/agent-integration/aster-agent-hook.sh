#!/bin/sh
# Aster Agent lifecycle hook. Provider hooks execute this small, auditable bridge with
# `state provider [session-id]` arguments. The hook payload is drained but never persisted or forwarded.
state="${1-}"
provider="${2-}"
session_id="${3-}"
maximum_payload_bytes=262144
LC_ALL=C
export LC_ALL

case "$state" in
  processing|idle|awaiting-input) ;;
  *) exit 0 ;;
esac
case "$provider" in
  claudeCode|codex|openCode|cursorCLI|kimiCode|pi|omp|grokBuild) ;;
  *) exit 0 ;;
esac

# Claude Code 和 Grok 共用 ~/.claude/settings.json，对方 runner 会启动本条目。
# Grok 每次 hook 都注入 GROK_HOOK_EVENT / GROK_SESSION_ID；对不上调用方就静默退出，
# 避免把 Grok pane 标成 Claude（或反过来）。
is_grok=0
if [ -n "${GROK_HOOK_EVENT-}" ] || [ -n "${GROK_SESSION_ID-}" ]; then
  is_grok=1
fi
if [ "$provider" = "grokBuild" ]; then
  if [ "$is_grok" != 1 ]; then
    /bin/cat >/dev/null 2>&1 || true
    exit 0
  fi
elif [ "$is_grok" = 1 ]; then
  /bin/cat >/dev/null 2>&1 || true
  exit 0
fi

# Grok stdin 用 camelCase `sessionId`，现有 `session_id` 提取读不到；优先用注入的 ID。
if [ -z "$session_id" ] && [ -n "${GROK_SESSION_ID-}" ]; then
  session_id="$GROK_SESSION_ID"
fi

# Codex、Claude Code 等 command hook 把稳定 session id 放在 stdin JSON 的顶层
# `session_id`。仅在调用方没有显式传入 ID 时读取；多取一个字节用于拒绝超限载荷，
# 随后的 cat 继续排空 stdin，避免 hook producer 因管道背压而阻塞。SOH marker 让 POSIX
# command substitution 保留 JSON 末尾换行，确保 256 KiB 边界按真实字节数判断。
if [ -z "$session_id" ]; then
  payload_with_marker=$(
    /usr/bin/head -c $((maximum_payload_bytes + 1)) 2>/dev/null
    /usr/bin/printf '\001'
  )
  payload="${payload_with_marker%?}"
  /bin/cat >/dev/null 2>&1 || true
  if [ "${#payload}" -le "$maximum_payload_bytes" ]; then
    session_id=$(
      /usr/bin/printf '%s' "$payload" \
        | /usr/bin/plutil -extract session_id raw -expect string -o - - 2>/dev/null \
        || true
    )
  fi
else
  # 显式 ID 用于不提供 JSON session 字段的 provider；仍排空可能存在的 stdin。
  /bin/cat >/dev/null 2>&1 || true
fi

# 只有 provider 通过显式参数或受管 JSON 顶层字段提供稳定 session id 时才附加。严格
# 字符集和长度同时约束两个来源，防止 prompt 或任意字段越过 OSC 边界。
case "$session_id" in
  ""|*[!A-Za-z0-9._:-]*) session_id="" ;;
esac
if [ "${#session_id}" -gt 128 ]; then
  session_id=""
fi

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
