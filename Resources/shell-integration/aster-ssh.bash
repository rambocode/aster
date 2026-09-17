# Aster SSH 连接复用包装函数（bash）。语义与 aster-ssh.zsh 相同，独立成文件的原因见该文件。
# bash 由受管 rc 区块直接加载，用户自己的 alias/function 通常在此之前定义；存在即跳过。

# 重复加载守卫：aster-integration.bash 与受管 rc 区块可能都会 source 本文件。
[[ "${_ASTER_SSH_WRAPPER_LOADED:-0}" != "1" ]] || return 0
_ASTER_SSH_WRAPPER_LOADED=1

# 变量缺失或目录不存在说明「SSH 连接复用」关着或安全校验失败，保持系统 ssh 原样。
[[ -n "${ASTER_SSH_CONTROL_DIR:-}" && -d "${ASTER_SSH_CONTROL_DIR}" ]] || return 0

# 用户自定义的 ssh alias 或 function 永远优先，绝不覆盖。
if ! alias ssh >/dev/null 2>&1 && ! declare -F ssh >/dev/null 2>&1; then
  # 函数体保留变量引用：`%C` 由 OpenSSH 按连接参数哈希在调用时展开。
  ssh() {
    command ssh -o ControlMaster=auto -o "ControlPath=${ASTER_SSH_CONTROL_DIR}/%C" \
      -o ControlPersist=60 "$@"
  }
fi
