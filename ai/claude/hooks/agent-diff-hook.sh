#!/usr/bin/env bash
# Forward a Claude Code hook event to the nvim that hosts the sidekick session,
# for agent-diff.nvim's inline visualization.
#
# $1 = event name (PreToolUse | PostToolUse | Stop).
#
# Pure observer: always exits 0 with no stdout, so it never emits a permission
# decision and never blocks or slows the tool. sidekick sets $NVIM in Claude's
# subprocess env to the hosting nvim's RPC socket; if it is unset or the socket
# is gone, this is a no-op.

event="$1"
[ -z "$NVIM" ] && exit 0

payload=$(cat)
# base64 the {event,payload} blob so it round-trips through shell + luaeval
# without any quoting hazard (base64 is [A-Za-z0-9+/=] only).
b64=$(printf '%s' "{\"event\":\"${event}\",\"payload\":${payload:-null}}" | base64 -w0)

nvim --server "$NVIM" --remote-expr \
  "luaeval('require(\"agent-diff.claude\").on_event(_A)', '${b64}')" >/dev/null 2>&1 &

exit 0
