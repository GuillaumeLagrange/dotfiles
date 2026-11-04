set shell := ["bash", "-euo", "pipefail", "-c"]

crates := "wt modules/gui/niri-state modules/gui/quickshell/tests modules/headless/omp-panel modules/headless/reviews"

# Lint and test everything
check: lint test

# Install the pre-commit hooks of .pre-commit-config.yaml (prek)
hooks:
    git config --unset core.hooksPath || true
    prek install

# Every linter, read-only
lint: lint-nix lint-lua lint-rust

# Rewrite every file with its language's formatter
format:
    git ls-files -z '*.nix' | xargs -0r nixfmt
    stylua nvim
    for crate in {{ crates }}; do (cd "$crate" && cargo fmt); done
    git ls-files -z '*.py' | xargs -0r nix run nixpkgs#ruff -- format
    git ls-files -z '*.sh' | xargs -0r nix run nixpkgs#shfmt -- -w -i 2 -ci
    git ls-files -z '*.qml' | xargs -0r nix shell nixpkgs#qt6.qtdeclarative -c qmlformat -i
    git ls-files -z '*.ts' | xargs -0r nix run nixpkgs#biome -- format --write --line-width 120

lint-nix:
    git ls-files -z '*.nix' | xargs -0 nixfmt --check

lint-lua:
    stylua --check nvim

lint-rust:
    for crate in {{ crates }}; do (cd "$crate" && cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings); done

test: test-rust test-omp

# Includes omp-panel's and wt's tests against real, isolated zellij servers, and the bar's against headless niri
test-rust:
    for crate in {{ crates }}; do (cd "$crate" && cargo nextest run); done

test-omp:
    cd ai/omp && { [ -d node_modules ] || npm ci; } && npm test
