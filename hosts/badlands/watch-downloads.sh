#!/usr/bin/env bash
# Throwaway script to find what's creating ~/Downloads
# Runs as a systemd service. Check results with:
#   sudo journalctl -u watch-downloads

USER_HOME="/home/guillaume"
DIR="$USER_HOME/Downloads"

# Remove the directory if it exists
if [ -d "$DIR" ]; then
  rmdir "$DIR" 2>/dev/null || { echo "$DIR is not empty, remove its contents first"; exit 1; }
  echo "Removed $DIR"
fi

echo "Tracing mkdir syscalls for 'Downloads'..."

# Trace mkdir/mkdirat syscalls and filter for "Downloads"
bpftrace -e '
tracepoint:syscalls:sys_enter_mkdir /str(args.pathname) == "Downloads" || str(args.pathname) == "/home/guillaume/Downloads"/ {
  printf("=== CAUGHT IT === pid=%d comm=%s path=%s\n", pid, comm, str(args.pathname));
}
tracepoint:syscalls:sys_enter_mkdirat /str(args.pathname) == "Downloads" || str(args.pathname) == "/home/guillaume/Downloads"/ {
  printf("=== CAUGHT IT === pid=%d comm=%s path=%s\n", pid, comm, str(args.pathname));
}
'
