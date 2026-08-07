# Aster zsh integration. This file is bundled, readable, and code-signed with the app.
[[ -o interactive ]] || return 0
[[ "${ASTER_DISABLE_INTEGRATION:-0}" != "1" ]] || return 0
[[ "${_ASTER_ZSH_INTEGRATION_LOADED:-0}" != "1" ]] || return 0
typeset -g _ASTER_ZSH_INTEGRATION_LOADED=1
typeset -g _ASTER_COMMAND_ACTIVE=0

autoload -Uz add-zsh-hook

_aster_zsh_urlencode_path() {
  # Byte-wise encoding keeps UTF-8 valid and guarantees BEL/ESC can never terminate OSC 7.
  local LC_ALL=C input="$1" output="" character encoded
  local -i index byte_value
  for (( index = 1; index <= ${#input}; index++ )); do
    character="${input[index]}"
    case "$character" in
      [a-zA-Z0-9/._~-]) output+="$character" ;;
      *)
        printf -v byte_value '%d' "'$character"
        printf -v encoded '%%%02X' "$(( byte_value & 255 ))"
        output+="$encoded"
        ;;
    esac
  done
  REPLY="$output"
}

_aster_zsh_osc7() {
  _aster_zsh_urlencode_path "$PWD"
  # Pane 进程始终是本机路径；固定 localhost 避免可变环境值进入控制序列。
  printf '\e]7;file://localhost%s\a' "$REPLY"
}

_aster_zsh_aliases() {
  local name payload="" separator=""
  local -i count=0
  for name in ${(k)aliases}; do
    [[ -n "$name" && "$name" != *[^a-zA-Z0-9_.+-]* ]] || continue
    payload+="${separator}${name}"
    separator=","
    (( ++count >= 500 || ${#payload} >= 8000 )) && break
  done
  printf '\e]6973;Aliases=%s\a' "$payload"
}

_aster_zsh_precmd() {
  local command_status=$?
  if [[ "$_ASTER_COMMAND_ACTIVE" == "1" ]]; then
    printf '\e]133;D;%d\a' "$command_status"
    typeset -g _ASTER_COMMAND_ACTIVE=0
  fi
  printf '\e]133;A\a'
  _aster_zsh_osc7
  _aster_zsh_aliases
  if [[ "$PS1" != *$'\e]133;B\a'* ]]; then
    PS1="${PS1}"$'%{\e]133;B\a%}'
  fi
  return "$command_status"
}

_aster_zsh_preexec() {
  typeset -g _ASTER_COMMAND_ACTIVE=1
  printf '\e]133;C\a'
}

add-zsh-hook precmd _aster_zsh_precmd
add-zsh-hook preexec _aster_zsh_preexec
