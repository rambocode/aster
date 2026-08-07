# Aster fish integration. fish emits stable prompt/preexec/postexec events; the prompt wrapper
# is refreshed at the prompt event so config.fish-defined prompts are also covered.
status is-interactive; or return 0
test "$ASTER_DISABLE_INTEGRATION" != "1"; or return 0
set -q _ASTER_FISH_INTEGRATION_LOADED; and return 0
set -g _ASTER_FISH_INTEGRATION_LOADED 1
set -g _ASTER_FISH_COMMAND_ACTIVE 0

function _aster_fish_osc7
  # fish converts to UTF-8 before URL escaping, so control bytes cannot terminate OSC 7.
  set -l encoded_path (string escape --style=url -- $PWD)
  printf '\e]7;file://localhost%s\a' $encoded_path
end

function _aster_fish_aliases
  set -l names
  for definition in (alias)
    set -l name (string replace -r '^alias ([A-Za-z0-9_.+\-]+) .*$' '$1' -- $definition)
    if test "$name" != "$definition"
      set -a names $name
    end
    test (count $names) -ge 500; and break
  end
  set -l payload (string join ',' -- $names)
  set payload (string sub --length 8000 -- $payload)
  printf '\e]6973;Aliases=%s\a' $payload
end

function _aster_fish_prompt
  printf '\e]133;A\a'
  _aster_fish_osc7
  _aster_fish_aliases
  _aster_user_fish_prompt
  printf '\e]133;B\a'
end

function _aster_fish_wrap_prompt --on-event fish_prompt
  functions -q fish_prompt; or return 0
  # Inspect the function body instead of its source metadata: copied functions can report
  # different detail locations across fish versions, which could otherwise wrap our wrapper.
  if not functions fish_prompt | string match -q '*_aster_user_fish_prompt*'
    functions -e _aster_user_fish_prompt 2>/dev/null
    functions -c fish_prompt _aster_user_fish_prompt
    functions -c _aster_fish_prompt fish_prompt
  end
end

function _aster_fish_preexec --on-event fish_preexec
  set -g _ASTER_FISH_COMMAND_ACTIVE 1
  printf '\e]133;C\a'
end

function _aster_fish_postexec --on-event fish_postexec
  set -l command_status $status
  if test "$_ASTER_FISH_COMMAND_ACTIVE" = "1"
    printf '\e]133;D;%d\a' $command_status
    set -g _ASTER_FISH_COMMAND_ACTIVE 0
  end
end
