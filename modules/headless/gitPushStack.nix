{
  pkgs,
  ...
}:
pkgs.writeShellScriptBin "git-push-stack" ''
  # Get base ref from first argument, default to origin/main if not provided
  base_ref=''${1:-origin/main}

  # Get the current branch name
  current_branch=$(git branch --show-current)

  # Get commits in your stack
  base_commit=$(git merge-base HEAD "$base_ref")

  # Get all branches pointing to commits in the stack
  stack_branches=$(git rev-list $base_commit..HEAD | \
      xargs -I {} git branch --points-at {} | \
      grep -v "^\*" | \
      awk '{print $1}' | \
      sort -u)

  # Combine current branch with stack branches and remove duplicates
  all_branches=$(echo -e "$current_branch\n$stack_branches" | sort -u)

  # Push each branch
  for branch in $all_branches; do
      if [ -n "$branch" ]; then
          echo "Pushing branch: $branch"
          git push origin --force-with-lease "$branch"
      fi
  done
''
