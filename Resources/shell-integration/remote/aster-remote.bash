# Aster remote integration (bash). Installed into the remote home by Aster and sourced from a
# marked block in ~/.bashrc. Reports OSC 7 with the remote host name plus OSC 133 prompt marks.
[[ $- == *i* ]] || return 0
[[ "${ASTER_REMOTE_INTEGRATION_DISABLE:-0}" != "1" ]] || return 0
[[ "${_ASTER_REMOTE_BASH_LOADED:-0}" != "1" ]] || return 0
_ASTER_REMOTE_BASH_LOADED=1
_ASTER_REMOTE_COMMAND_ACTIVE=0
_ASTER_REMOTE_EXPECTING_COMMAND=0
_ASTER_REMOTE_LAST_STATUS=0

_aster_remote_bash_urlencode() {
  # Bash 3.2 has no URL encoder. Iterate in the C locale so every UTF-8 byte and every control
  # byte is either known-safe path syntax or emitted as a two-digit percent escape; a raw BEL or
  # ESC inside a path would otherwise terminate the OSC early.
  local LC_ALL=C input="$1" output="" character encoded
  local index byte_value
  for (( index = 0; index < ${#input}; index++ )); do
    character="${input:index:1}"
    case "$character" in
      [a-zA-Z0-9/._~-]) output="${output}${character}" ;;
      *)
        printf -v byte_value '%d' "'$character"
        printf -v encoded '%%%02X' "$(( byte_value & 255 ))"
        output="${output}${encoded}"
        ;;
    esac
  done
  printf '%s' "$output"
}

_aster_remote_bash_host() {
  # Short host name only: Aster uses it to tell "this path lives on the remote" apart from a
  # local path, and it must never be compared against `ssh -G` results.
  local name="${HOSTNAME:-}"
  [[ -n "$name" ]] || name="$(hostname 2>/dev/null)"
  name="${name%%.*}"
  name="${name//\//}"
  [[ -n "$name" ]] || name="remote"
  _aster_remote_bash_urlencode "$name"
}

_ASTER_REMOTE_HOST="$(_aster_remote_bash_host)"

_aster_remote_bash_osc7() {
  local encoded_path
  encoded_path="$(_aster_remote_bash_urlencode "$PWD")"
  printf '\e]7;file://%s%s\a' "$_ASTER_REMOTE_HOST" "$encoded_path"
}

_aster_remote_bash_debug_trap() {
  local prior_status=$?
  if [[ "$BASH_COMMAND" == "_aster_remote_bash_prompt_command"* ]]; then
    _ASTER_REMOTE_LAST_STATUS=$prior_status
  elif [[ "$_ASTER_REMOTE_EXPECTING_COMMAND" == "1" ]]; then
    _ASTER_REMOTE_EXPECTING_COMMAND=0
    _ASTER_REMOTE_COMMAND_ACTIVE=1
    printf '\e]133;C\a'
  fi
  return "$prior_status"
}

_aster_remote_bash_prompt_command() {
  local command_status=${_ASTER_REMOTE_LAST_STATUS:-$?}
  if [[ "$_ASTER_REMOTE_COMMAND_ACTIVE" == "1" ]]; then
    printf '\e]133;D;%d\a' "$command_status"
    _ASTER_REMOTE_COMMAND_ACTIVE=0
  fi
  printf '\e]133;A\a'
  _aster_remote_bash_osc7
  _ASTER_REMOTE_EXPECTING_COMMAND=1
  return "$command_status"
}

# DEBUG is required on Bash 3.2, which has no PS0. If the user already owns the trap, leave it
# alone: prompt and CWD marks still work, only command-start marking degrades.
if [[ -z "$(trap -p DEBUG)" ]]; then
  trap '_aster_remote_bash_debug_trap' DEBUG
fi
PROMPT_COMMAND="_aster_remote_bash_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
if [[ "$PS1" != *$'\e]133;B\a'* ]]; then
  PS1="${PS1}"$'\[\e]133;B\a\]'
fi
