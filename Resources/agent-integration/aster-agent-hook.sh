#!/bin/sh
# Aster Agent lifecycle hook. Provider hooks execute this small, auditable bridge with
# `state provider [session-id]` arguments. The hook payload is drained but never persisted or forwarded.
maximum_payload_bytes=262144
LC_ALL=C
export LC_ALL

# `statusline claudeCode`：Claude Code 的 statusLine 包装器。stdin 只能读一次：先整段吞进
# 变量，提取 rate limit / context 用量写成 `AgentUsage=…` 一行放进 Aster 的用量目录，再把
# 原 JSON 喂给用户原来的 statusLine 命令并透传其 stdout。Claude 只会显示本脚本的 stdout。
if [ "${1-}" = "statusline" ]; then
  case "${2-}" in
    claudeCode) ;;
    *) /bin/cat >/dev/null 2>&1 || true; exit 0 ;;
  esac
  payload_with_marker=$(
    /usr/bin/head -c $((maximum_payload_bytes + 1)) 2>/dev/null
    /usr/bin/printf '\001'
  )
  payload="${payload_with_marker%?}"
  /bin/cat >/dev/null 2>&1 || true

  # 只取整数百分比与整数 epoch 秒；plutil 输出小数时截断，任何非数字内容一律丢弃。
  extract_int() {
    v=$(
      /usr/bin/printf '%s' "$payload" \
        | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null \
        || true
    )
    v="${v%%.*}"
    case "$v" in ""|*[!0-9]*) v="" ;; esac
    if [ "${#v}" -gt 12 ]; then v=""; fi
    /usr/bin/printf '%s' "$v"
  }

  # Claude 启动 statusLine 命令时脱离控制终端（/dev/tty 不可用），所以不能像 lifecycle hook
  # 那样写 OSC；改为按 Aster 注入的 ASTER_SESSION_ID（pane UUID）写文件，Aster 监听该目录。
  # ASTER_AGENT_USAGE_DIR 仅供测试注入。不在 Aster 里运行（无 pane UUID）时不写任何文件。
  pane_uuid="${ASTER_SESSION_ID-}"
  case "$pane_uuid" in
    ""|*[!A-Fa-f0-9-]*) pane_uuid="" ;;
  esac
  if [ "${#pane_uuid}" -ne 36 ]; then pane_uuid=""; fi
  if [ "${#payload}" -le "$maximum_payload_bytes" ] && [ -n "$pane_uuid" ]; then
    five=$(extract_int rate_limits.five_hour.used_percentage)
    five_reset=$(extract_int rate_limits.five_hour.resets_at)
    week=$(extract_int rate_limits.seven_day.used_percentage)
    week_reset=$(extract_int rate_limits.seven_day.resets_at)
    ctx=$(extract_int context_window.used_percentage)
    usage="AgentUsage=1;Provider=claudeCode"
    if [ -n "$five" ]; then usage="$usage;FiveHour=$five${five_reset:+:$five_reset}"; fi
    if [ -n "$week" ]; then usage="$usage;SevenDay=$week${week_reset:+:$week_reset}"; fi
    if [ -n "$ctx" ]; then usage="$usage;Session=$ctx"; fi
    if [ "$usage" != "AgentUsage=1;Provider=claudeCode" ]; then
      usage_dir="${ASTER_AGENT_USAGE_DIR:-$HOME/Library/Application Support/Aster/agent-usage}"
      if [ -d "$usage_dir" ] && [ ! -L "$usage_dir" ]; then
        # 先写临时文件再 mv，Aster 读到的永远是完整一行。
        tmp_file="$usage_dir/.$pane_uuid.$$.tmp"
        if /usr/bin/printf '%s\n' "$usage" > "$tmp_file" 2>/dev/null; then
          /bin/mv -f "$tmp_file" "$usage_dir/$pane_uuid.usage" 2>/dev/null || /bin/rm -f "$tmp_file"
        fi
      fi
    fi
  fi

  # 透传：side file 里记录了接管前的 statusLine；只有 type=command 且 command 非空才执行。
  # side file 缺失或为 null 时输出空（用户本来就没有 statusLine）。ASTER_STATUSLINE_SIDE_FILE
  # 仅供测试注入。
  side_file="${ASTER_STATUSLINE_SIDE_FILE:-$HOME/Library/Application Support/Aster/agent-integration/claude-statusline.json}"
  original=""
  if [ -f "$side_file" ] && [ ! -L "$side_file" ]; then
    original_type=$(
      /usr/bin/plutil -extract statusLine.type raw -expect string -o - "$side_file" 2>/dev/null \
        || true
    )
    if [ "$original_type" = "command" ]; then
      original=$(
        /usr/bin/plutil -extract statusLine.command raw -expect string -o - "$side_file" 2>/dev/null \
          || true
      )
    fi
  fi
  if [ -n "$original" ]; then
    /usr/bin/printf '%s' "$payload" | /bin/sh -c "$original"
  fi
  exit 0
fi

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
