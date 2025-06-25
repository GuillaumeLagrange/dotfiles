{
  pkgs,
  ...
}:
pkgs.writeShellScriptBin "git-push-stack" ''
  set -euo pipefail

  # Usage function
  usage() {
    echo "Usage: git-push-stack [base-ref] [options]"
    echo ""
    echo "Push all branches in the current stack to origin"
    echo ""
    echo "Arguments:"
    echo "  base-ref          Base reference (default: origin/main)"
    echo ""
    echo "Options:"
    echo "  -n, --dry-run     Show what would be pushed without actually pushing"
    echo "  -v, --verbose     Show detailed output"
    echo "  -y, --yes         Skip confirmation prompt"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  git-push-stack                    # Push stack based on origin/main"
    echo "  git-push-stack origin/develop     # Push stack based on origin/develop"
    echo "  git-push-stack -n                 # Dry run to see what would be pushed"
  }

  # Parse arguments
  base_ref="origin/main"
  dry_run=false
  verbose=false
  skip_confirm=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n|--dry-run)
        dry_run=true
        shift
        ;;
      -v|--verbose)
        verbose=true
        shift
        ;;
      -y|--yes)
        skip_confirm=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        echo "Error: Unknown option $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        base_ref="$1"
        shift
        ;;
    esac
  done

  # Logging functions
  log_verbose() {
    if [ "$verbose" = true ]; then
      echo "[VERBOSE] $*" >&2
    fi
  }

  log_info() {
    echo "[INFO] $*" >&2
  }

  log_error() {
    echo "[ERROR] $*" >&2
  }

  # Check if we're in a git repository
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not in a git repository"
    exit 1
  fi

  # Check if we're in detached HEAD state
  if ! current_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
    log_error "Currently in detached HEAD state. Please checkout a branch first."
    exit 1
  fi

  log_verbose "Current branch: $current_branch"
  log_verbose "Base reference: $base_ref"

  # Verify base ref exists
  if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    log_error "Base reference '$base_ref' does not exist"
    log_error "Make sure you've fetched the latest changes: git fetch origin"
    exit 1
  fi

  # Get the merge base
  if ! base_commit=$(git merge-base HEAD "$base_ref" 2>/dev/null); then
    log_error "Could not find merge base between HEAD and $base_ref"
    exit 1
  fi

  log_verbose "Base commit: $base_commit"

  # Check if there are any commits in the stack
  if ! git rev-list --count "$base_commit..HEAD" | grep -q '^[1-9]'; then
    log_info "No commits found between $base_ref and HEAD. Nothing to push."
    exit 0
  fi

  # Get all commits in the stack
  stack_commits=$(git rev-list "$base_commit..HEAD")
  log_verbose "Stack commits: $(echo "$stack_commits" | wc -l) commits"

  # Find all local branches that point to commits in our stack
  stack_branches=()

  # Add current branch
  stack_branches+=("$current_branch")

  # Find other branches pointing to commits in the stack
  while IFS= read -r commit; do
    while IFS= read -r branch_line; do
      # Parse branch name, handling potential formatting
      branch=$(echo "$branch_line" | sed 's/^[* ] *//' | awk '{print $1}')
      if [[ -n "$branch" && "$branch" != "$current_branch" ]]; then
        # Check if this branch is already in our array
        if [[ ! " ''${stack_branches[*]} " =~ " $branch " ]]; then
          stack_branches+=("$branch")
        fi
      fi
    done < <(git branch --points-at "$commit" 2>/dev/null || true)
  done < <(echo "$stack_commits")

  # Remove duplicates and sort
  IFS=$'\n' sorted_branches=($(printf '%s\n' "''${stack_branches[@]}" | sort -u))
  stack_branches=("''${sorted_branches[@]}")

  if [ ''${#stack_branches[@]} -eq 0 ]; then
    log_error "No branches found to push"
    exit 1
  fi

  # Show what will be pushed
  log_info "Found ''${#stack_branches[@]} branch(es) in stack:"
  for branch in "''${stack_branches[@]}"; do
    if [ "$branch" = "$current_branch" ]; then
      log_info "  * $branch (current)"
    else
      log_info "    $branch"
    fi
    
    if [ "$verbose" = true ]; then
      # Show branch status
      if git ls-remote --exit-code origin "$branch" >/dev/null 2>&1; then
        ahead_behind=$(git rev-list --left-right --count "origin/$branch...$branch" 2>/dev/null || echo "? ?")
        behind=$(echo "$ahead_behind" | cut -d' ' -f1)
        ahead=$(echo "$ahead_behind" | cut -d' ' -f2)
        log_verbose "    ↑$ahead ↓$behind compared to origin/$branch"
      else
        log_verbose "    (new branch)"
      fi
    fi
  done

  # Dry run mode
  if [ "$dry_run" = true ]; then
    log_info "DRY RUN: Would execute the following commands:"
    for branch in "''${stack_branches[@]}"; do
      echo "  git push origin --force-with-lease \"$branch\""
    done
    exit 0
  fi

  # Confirmation prompt
  if [ "$skip_confirm" = false ]; then
    echo ""
    read -p "Push ''${#stack_branches[@]} branch(es) to origin? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted"
      exit 0
    fi
  fi

  # Check if origin remote exists
  if ! git remote get-url origin >/dev/null 2>&1; then
    log_error "Remote 'origin' does not exist"
    exit 1
  fi

  # Push each branch
  failed_pushes=()
  successful_pushes=()

  for branch in "''${stack_branches[@]}"; do
    log_info "Pushing branch: $branch"
    
    if git push origin --force-with-lease "$branch" 2>&1; then
      successful_pushes+=("$branch")
      log_verbose "✓ Successfully pushed $branch"
    else
      failed_pushes+=("$branch")
      log_error "✗ Failed to push $branch"
    fi
  done

  # Summary
  echo ""
  log_info "Push summary:"
  log_info "  Successful: ''${#successful_pushes[@]}"
  log_info "  Failed: ''${#failed_pushes[@]}"

  if [ ''${#failed_pushes[@]} -gt 0 ]; then
    log_error "Failed branches: ''${failed_pushes[*]}"
    exit 1
  fi

  log_info "All branches pushed successfully!"
''
