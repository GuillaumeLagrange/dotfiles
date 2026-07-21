#!/usr/bin/env bash
# Runs a zellij-resurrected command through an interactive zsh so per-directory chpwd
# hooks (direnv, tab rename, ...) fire. A shell that starts already inside a directory
# does not trigger chpwd, so bounce out and back to force it before running the command.
# The command arrives base64-encoded from resurrect-wrap.sh (see that script for why).
# When the command exits the pane is left as an interactive shell rather than closing.
cmd=$(printf '%s' "$1" | base64 -d)

# zellij titles the pane after the command it runs, which would be this launcher plus its
# base64 blob. Restore the real command as the pane name instead.
if [ -n "$ZELLIJ_PANE_ID" ]; then
  zellij action rename-pane "$cmd" >/dev/null 2>&1
fi

exec zsh -ic 'd=$PWD; cd / && cd "$d"; '"$cmd"'; exec zsh -i'
