# Aster SSH 连接复用包装函数（fish）。语义与 aster-ssh.zsh 相同，独立成文件的原因见该文件。

# 重复加载守卫：aster-integration.fish 与受管 conf.d 区块可能都会 source 本文件。
set -q _ASTER_SSH_WRAPPER_LOADED; and return 0
set -g _ASTER_SSH_WRAPPER_LOADED 1

# 变量缺失或目录不存在说明「SSH 连接复用」关着或安全校验失败，保持系统 ssh 原样。
if not set -q ASTER_SSH_CONTROL_DIR; or test -z "$ASTER_SSH_CONTROL_DIR"; or test ! -d "$ASTER_SSH_CONTROL_DIR"
  return 0
end

# fish 的 alias 就是 function，所以 `functions -q` 一次覆盖两种自定义形式。受管 conf.d 早于
# config.fish 执行，用户在 config.fish 里定义的 ssh 会自然覆盖我们的包装，仍然是用户优先。
if not functions -q ssh
  function ssh --description "Aster: reuse authenticated OpenSSH connections"
    command ssh -o ControlMaster=auto -o "ControlPath=$ASTER_SSH_CONTROL_DIR/%C" -o ControlPersist=60 $argv
  end
end
