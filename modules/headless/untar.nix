{
  pkgs,
  ...
}:
pkgs.writeShellScriptBin "untar" ''
  set -euo pipefail

  if [ $# -eq 0 ]; then
    echo "Usage: untar <archive.tar[.gz]>"
    exit 1
  fi

  archive="$1"

  if [ ! -f "$archive" ]; then
    echo "Error: File '$archive' not found"
    exit 1
  fi

  # Determine tar flags based on extension
  tar_flags="-xf"
  if [[ "$archive" == *.tar.gz || "$archive" == *.tgz ]]; then
    tar_flags="-xzf"
  fi

  # Determine target directory name by stripping extensions
  target_dir="$archive"
  target_dir="''${target_dir%.tar.gz}"
  target_dir="''${target_dir%.tar}"
  target_dir="''${target_dir%.tgz}"

  # Check if directory exists and prompt for removal
  if [ -d "$target_dir" ]; then
    echo "Directory '$target_dir' already exists."
    rm -ri "$target_dir" || {
      echo "Extraction cancelled."
      exit 1
    }
  fi

  # Create directory and extract
  mkdir -p "$target_dir"
  tar $tar_flags "$archive" -C "$target_dir"

  echo "Extracted to: $target_dir"
''
