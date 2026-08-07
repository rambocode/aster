# Aster starts zsh with this temporary ZDOTDIR. Source the user's real .zshenv, restore
# ZDOTDIR, then defer the payload until startup files and prompt plugins have loaded.
if [[ "${ASTER_INTEGRATION:-0}" == "1" && "${ASTER_DISABLE_INTEGRATION:-0}" != "1" ]]; then
  typeset _aster_real_zdotdir="${ASTER_REAL_ZDOTDIR:-$HOME}"
  typeset _aster_real_zdotdir_set="${ASTER_REAL_ZDOTDIR_SET:-0}"
  typeset _aster_injected_zdotdir="${ASTER_SHELL_INTEGRATION_DIR}/zsh"
  if [[ -r "${_aster_real_zdotdir}/.zshenv" ]]; then
    source "${_aster_real_zdotdir}/.zshenv"
  fi
  # `.zshenv` may intentionally redirect later startup files to another ZDOTDIR. Restore the
  # inherited value only while our injected directory is still untouched; preserve user changes.
  if [[ ${+ZDOTDIR} -eq 1 && "$ZDOTDIR" == "$_aster_injected_zdotdir" ]]; then
    if [[ "$_aster_real_zdotdir_set" == "1" ]]; then
      export ZDOTDIR="$_aster_real_zdotdir"
    else
      unset ZDOTDIR
    fi
  fi

  _aster_deferred_shell_integration() {
    precmd_functions=("${(@)precmd_functions:#_aster_deferred_shell_integration}")
    source "${ASTER_SHELL_INTEGRATION_DIR}/aster-integration.zsh"
    # The payload is loaded by the current precmd pass, so explicitly mark this first prompt.
    _aster_zsh_precmd
  }
  typeset -ga precmd_functions
  precmd_functions=(_aster_deferred_shell_integration "${precmd_functions[@]}")
  unset _aster_real_zdotdir _aster_real_zdotdir_set _aster_injected_zdotdir
fi
