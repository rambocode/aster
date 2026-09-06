#!/bin/sh
# Aster Agent lifecycle hook. Provider hooks execute this small, auditable bridge with
# `state provider [session-id]` arguments. The hook payload is drained but never persisted or forwarded.
maximum_payload_bytes=262144
LC_ALL=C
export LC_ALL

state="${1-}"
provider="${2-}"
session_id="${3-}"

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

# 目标 tty 把事件绑定到确切的 Aster Pane（多个 Agent 共用 cwd 时也不会串）。
# Claude Code 2.1.x 以「无控制终端」方式启动 hook 子进程：`[ -w /dev/tty ]` 仍为真，
# 但真正打开时报 "Device not configured"，事件因此从未到达 Aster。claude 进程本身
# 仍挂在 Pane 的 pty 上，所以先试 /dev/tty，打不开就沿父进程链找第一个带 tty 的
# 祖先，把 OSC 写到它的 /dev/ttysNNN。失败一律静默：卸载或关闭 Aster 不能拖垮 Agent。
resolve_target_tty() {
  if ( : > /dev/tty ) 2>/dev/null; then
    /usr/bin/printf '/dev/tty'
    return 0
  fi
  pid=$$
  depth=0
  while [ "$depth" -lt 8 ] && [ -n "$pid" ] && [ "$pid" != 1 ]; do
    name=$(/bin/ps -o tty= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')
    case "$name" in
      ''|'??'|'-') ;;
      *)
        if [ -w "/dev/$name" ]; then
          /usr/bin/printf '/dev/%s' "$name"
          return 0
        fi
        ;;
    esac
    pid=$(/bin/ps -o ppid= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')
    depth=$((depth + 1))
  done
  return 1
}

target_tty=$(resolve_target_tty) || exit 0
if [ -n "$session_id" ]; then
  /usr/bin/printf '\033]6974;AgentState=%s;Provider=%s;SessionID=%s\007' \
    "$state" "$provider" "$session_id" > "$target_tty" 2>/dev/null || true
else
  /usr/bin/printf '\033]6974;AgentState=%s;Provider=%s\007' "$state" "$provider" \
    > "$target_tty" 2>/dev/null || true
fi
exit 0
