# Aster SSH 连接复用包装函数（zsh）。独立成文件，是因为它有两条互不相交的加载路径：
#   1. tmux 子 Shell：受管 rc 区块 source aster-integration.zsh，后者再 source 本文件。
#   2. Ghostty 原生 Pane：ZDOTDIR 指向 Ghostty 自带集成，aster-integration.zsh 根本不会加载，
#      受管 rc 区块因此直接 source 本文件。
# 包装函数留在 aster-integration.zsh 里会让产品默认路径（2）永远拿不到连接复用。

# 重复加载守卫：两条路径在 tmux 里会同时命中，第二次直接返回，不重复判定也不覆盖已有定义。
[[ "${_ASTER_SSH_WRAPPER_LOADED:-0}" != "1" ]] || return 0
_ASTER_SSH_WRAPPER_LOADED=1

# 只有 Aster 注入了通过属主/权限校验的 ControlMaster 目录才包装；变量缺失或目录不存在
# 说明「SSH 连接复用」关着或校验失败，此时保持系统 ssh 原样，不做任何降级。
[[ -n "${ASTER_SSH_CONTROL_DIR:-}" && -d "${ASTER_SSH_CONTROL_DIR}" ]] || return 0

# 用户自定义的 ssh alias 或 function 永远优先，绝不覆盖。
if [[ -z "${aliases[ssh]:-}" ]] && ! typeset -f ssh >/dev/null; then
  # 让前台交互连接创建 ControlMaster，Aster 详情面板的旁路查询才能借用同一条已认证连接。
  # 函数体保留 `${ASTER_SSH_CONTROL_DIR}` 引用而不是展开：`%C` 由 OpenSSH 在每次调用时按连接
  # 参数哈希展开，目录真值变了也不需要重新定义函数。
  ssh() {
    command ssh -o ControlMaster=auto -o "ControlPath=${ASTER_SSH_CONTROL_DIR}/%C" \
      -o ControlPersist=60 "$@"
  }
fi
