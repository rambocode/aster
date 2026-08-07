# Loaded through a session-only XDG_DATA_DIRS prefix. Remove that prefix before child processes
# inherit the environment, then load the signed Aster payload from its canonical bundle path.
if test "$ASTER_INTEGRATION" = "1"; and test "$ASTER_DISABLE_INTEGRATION" != "1"
  source "$ASTER_SHELL_INTEGRATION_DIR/aster-integration.fish"
end

if set -q ASTER_FISH_DATA_DIR; and set -q XDG_DATA_DIRS
  set -l retained
  for directory in (string split ':' -- $XDG_DATA_DIRS)
    if test "$directory" != "$ASTER_FISH_DATA_DIR"
      set -a retained $directory
    end
  end
  set -gx XDG_DATA_DIRS (string join ':' -- $retained)
end
set -e ASTER_FISH_DATA_DIR
