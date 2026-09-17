# Aster remote integration (zsh). Installed into the remote home by Aster and sourced from a
# marked block in ${ZDOTDIR:-$HOME}/.zshrc. Reports OSC 7 with the remote host name plus OSC 133.
[[ -o interactive ]] || return 0
[[ "${ASTER_REMOTE_INTEGRATION_DISABLE:-0}" != "1" ]] || return 0
[[ "${_ASTER_REMOTE_ZSH_LOADED:-0}" != "1" ]] || return 0
typeset -g _ASTER_REMOTE_ZSH_LOADED=1
typeset -g _ASTER_REMOTE_COMMAND_ACTIVE=0

autoload -Uz add-zsh-hook

_aster_remote_zsh_urlencode() {
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

_aster_remote_zsh_host() {
  # Short host name only; it is a display/identity hint for Aster, never an address to connect to.
  local name="${HOST:-}"
  [[ -n "$name" ]] || name="$(hostname 2>/dev/null)"
  name="${name%%.*}"
  name="${name//\//}"
  [[ -n "$name" ]] || name="remote"
  _aster_remote_zsh_urlencode "$name"
  typeset -g _ASTER_REMOTE_HOST="$REPLY"
}

_aster_remote_zsh_host

_aster_remote_zsh_osc7() {
  _aster_remote_zsh_urlencode "$PWD"
  printf '\e]7;file://%s%s\a' "$_ASTER_REMOTE_HOST" "$REPLY"
}

_aster_remote_zsh_precmd() {
  local command_status=$?
  if [[ "$_ASTER_REMOTE_COMMAND_ACTIVE" == "1" ]]; then
    printf '\e]133;D;%d\a' "$command_status"
    typeset -g _ASTER_REMOTE_COMMAND_ACTIVE=0
  fi
  printf '\e]133;A\a'
  _aster_remote_zsh_osc7
  if [[ "$PS1" != *$'\e]133;B\a'* ]]; then
    PS1="${PS1}"$'%{\e]133;B\a%}'
  fi
  return "$command_status"
}

_aster_remote_zsh_preexec() {
  typeset -g _ASTER_REMOTE_COMMAND_ACTIVE=1
  printf '\e]133;C\a'
}

add-zsh-hook precmd _aster_remote_zsh_precmd
add-zsh-hook preexec _aster_remote_zsh_preexec
