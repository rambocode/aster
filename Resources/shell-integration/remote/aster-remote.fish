# Aster remote integration (fish). Installed by Aster into ~/.config/fish/conf.d/aster.fish,
# which fish auto-loads; no rc file is modified. Reports OSC 7 with the remote host name.
status is-interactive; or return 0
test "$ASTER_REMOTE_INTEGRATION_DISABLE" != "1"; or return 0
set -q _ASTER_REMOTE_FISH_LOADED; and return 0
set -g _ASTER_REMOTE_FISH_LOADED 1
set -g _ASTER_REMOTE_FISH_COMMAND_ACTIVE 0

# Short host name only, computed once: it identifies the machine to Aster and is never used as
# a connect address. `string escape --style=url` also protects it from stray control bytes.
set -l _aster_remote_raw_host (hostname 2>/dev/null)
set -l _aster_remote_short_host (string replace -r '\..*$' '' -- "$_aster_remote_raw_host")
set _aster_remote_short_host (string replace -a '/' '' -- "$_aster_remote_short_host")
if test -z "$_aster_remote_short_host"
  set _aster_remote_short_host remote
end
set -g _ASTER_REMOTE_HOST (string escape --style=url -- $_aster_remote_short_host)

function _aster_remote_fish_osc7
  # fish converts to UTF-8 before URL escaping, so control bytes cannot terminate OSC 7.
  set -l encoded_path (string escape --style=url -- $PWD)
  printf '\e]7;file://%s%s\a' $_ASTER_REMOTE_HOST $encoded_path
end

function _aster_remote_fish_prompt
  printf '\e]133;A\a'
  _aster_remote_fish_osc7
  _aster_remote_user_fish_prompt
  printf '\e]133;B\a'
end

function _aster_remote_fish_wrap_prompt --on-event fish_prompt
  functions -q fish_prompt; or return 0
  # Inspect the function body instead of its source metadata: copied functions can report
  # different detail locations across fish versions, which could otherwise wrap our wrapper.
  if not functions fish_prompt | string match -q '*_aster_remote_user_fish_prompt*'
    functions -e _aster_remote_user_fish_prompt 2>/dev/null
    functions -c fish_prompt _aster_remote_user_fish_prompt
    functions -c _aster_remote_fish_prompt fish_prompt
  end
end

function _aster_remote_fish_preexec --on-event fish_preexec
  set -g _ASTER_REMOTE_FISH_COMMAND_ACTIVE 1
  printf '\e]133;C\a'
end

function _aster_remote_fish_postexec --on-event fish_postexec
  set -l command_status $status
  if test "$_ASTER_REMOTE_FISH_COMMAND_ACTIVE" = "1"
    printf '\e]133;D;%d\a' $command_status
    set -g _ASTER_REMOTE_FISH_COMMAND_ACTIVE 0
  end
end
