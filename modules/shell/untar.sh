set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: untar <archive>"
  echo "Supports tar archives with any compression GNU tar can auto-detect"
  echo "(gzip, bzip2, xz, zstd, ...) as well as plain .tar."
  exit 1
fi

archive="$1"

if [ ! -f "$archive" ]; then
  echo "Error: File '$archive' not found"
  exit 1
fi

# Determine target directory name by stripping the archive's extensions.
# Strip the compression suffix first (if any), then the .tar / shorthand.
base="$(basename -- "$archive")"
target_dir="$base"
case "$target_dir" in
  *.tar.*) target_dir="${target_dir%.*}" ;; # drop compression suffix (.gz/.bz2/.xz/.zst/...)
esac
target_dir="${target_dir%.tar}"
# Shorthand single-suffix forms (.tgz, .tbz2, .txz, .tzst)
target_dir="${target_dir%.tgz}"
target_dir="${target_dir%.tbz2}"
target_dir="${target_dir%.tbz}"
target_dir="${target_dir%.txz}"
target_dir="${target_dir%.tzst}"

# If the name didn't change (no recognised extension), avoid clobbering the
# archive itself by extracting into a generic directory.
if [ "$target_dir" = "$base" ]; then
  target_dir="${base}.extracted"
fi

# Handle name conflicts: never destroy an existing directory silently.
# Find the first free "<name>", "<name>-1", "<name>-2", ... slot.
if [ -e "$target_dir" ]; then
  echo "'$target_dir' already exists."
  n=1
  while [ -e "${target_dir}-${n}" ]; do
    n=$((n + 1))
  done
  target_dir="${target_dir}-${n}"
  echo "Extracting to '$target_dir' instead."
fi

# Create directory and extract. GNU tar's -a/auto-compress detects the
# compression format on its own, so no per-extension flag juggling is needed.
mkdir -p -- "$target_dir"
tar --auto-compress -xf "$archive" -C "$target_dir"

echo "Extracted to: $target_dir"
