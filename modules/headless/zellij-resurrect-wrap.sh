#!/usr/bin/env bash
# zellij post_command_discovery_hook: emit the command that zellij will run in place of
# the discovered one. zellij splits this output on whitespace and keeps quote characters
# literally (it is not a POSIX shell), so the output must be tokens with no spaces or
# quotes of their own. The original command is base64-encoded (space/quote free) and
# handed to the launcher, which decodes and runs it through an interactive shell.
cmd=$RESURRECT_COMMAND
printf '%s %s' "$HOME/.config/zellij/resurrect-launch.sh" "$(printf '%s' "$cmd" | base64 -w0)"
