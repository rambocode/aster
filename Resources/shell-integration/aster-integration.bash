# Aster bash integration. Sourced only from an inert, clearly marked user rc block.
[[ $- == *i* ]] || return 0
[[ "${ASTER_DISABLE_INTEGRATION:-0}" != "1" ]] || return 0
[[ "${_ASTER_BASH_INTEGRATION_LOADED:-0}" != "1" ]] || return 0
_ASTER_BASH_INTEGRATION_LOADED=1
_ASTER_COMMAND_ACTIVE=0
_ASTER_EXPECTING_COMMAND=0
_ASTER_LAST_STATUS=0

_aster_bash_urlencode_path() {
  # macOS Bash 3.2 has no URL encoder. Iterate in the C locale so every UTF-8 byte and every
  # control byte is either known-safe path syntax or emitted as a two-digit percent escape.
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

_aster_bash_osc7() {
  local encoded_path
  encoded_path="$(_aster_bash_urlencode_path "$PWD")"
  printf '\e]7;file://localhost%s\a' "$encoded_path"
}

_aster_bash_aliases() {
  local name payload="" separator="" count=0
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != *[^a-zA-Z0-9_.+-]* ]] || continue
    payload="${payload}${separator}${name}"
    separator=","
    count=$((count + 1))
    [[ $count -ge 500 || ${#payload} -ge 8000 ]] && break
  done < <(compgen -A alias)
  printf '\e]6973;Aliases=%s\a' "$payload"
}

_aster_bash_debug_trap() {
  local prior_status=$?
  if [[ "$BASH_COMMAND" == "_aster_bash_prompt_command"* ]]; then
    _ASTER_LAST_STATUS=$prior_status
  elif [[ "$_ASTER_EXPECTING_COMMAND" == "1" ]]; then
    _ASTER_EXPECTING_COMMAND=0
    _ASTER_COMMAND_ACTIVE=1
    printf '\e]133;C\a'
  fi
  return "$prior_status"
}

_aster_bash_prompt_command() {
  local command_status=${_ASTER_LAST_STATUS:-$?}
  if [[ "$_ASTER_COMMAND_ACTIVE" == "1" ]]; then
    printf '\e]133;D;%d\a' "$command_status"
    _ASTER_COMMAND_ACTIVE=0
  fi
  printf '\e]133;A\a'
  _aster_bash_osc7
  _aster_bash_aliases
  _ASTER_EXPECTING_COMMAND=1
  return "$command_status"
}

# DEBUG is required on macOS Bash 3.2, which does not support PS0. If the user already owns
# the trap, leave it untouched rather than breaking debugger/tooling behavior; prompt/CWD marks
# remain available and command-start marking degrades gracefully.
if [[ -z "$(trap -p DEBUG)" ]]; then
  trap '_aster_bash_debug_trap' DEBUG
fi
PROMPT_COMMAND="_aster_bash_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
if [[ "$PS1" != *$'\e]133;B\a'* ]]; then
  PS1="${PS1}"$'\[\e]133;B\a\]'
fi
