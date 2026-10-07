set shell := ["bash", "-euo", "pipefail", "-c"]

crates := "wt modules/gui/niri-state modules/headless/omp-panel modules/headless/reviews"

# Lint and test everything
check: lint test

# Every linter, read-only
lint: lint-nix lint-lua lint-rust

# Rewrite files the linters would complain about
fmt:
    git ls-files -z '*.nix' | xargs -0 nixfmt
    stylua nvim
    for crate in {{ crates }}; do (cd "$crate" && cargo fmt); done

lint-nix:
    git ls-files -z '*.nix' | xargs -0 nixfmt --check

lint-lua:
    stylua --check nvim

lint-rust:
    for crate in {{ crates }}; do (cd "$crate" && cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings); done

test: test-rust test-omp

# Includes omp-panel's and wt's tests against real, isolated zellij servers
test-rust:
    for crate in {{ crates }}; do (cd "$crate" && cargo test --quiet); done

test-omp:
    cd ai/omp && { [ -d node_modules ] || npm ci; } && npm test
