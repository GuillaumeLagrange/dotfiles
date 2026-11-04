# nextest setup script: build the module's quickshellTestEnv once and hand it to
# every test as QUICKSHELL_TEST_ENV (see src/lib.rs, which otherwise builds it in
# each test process).
set -euo pipefail

[[ -z ${QUICKSHELL_TEST_ENV:-} ]] || exit 0
# A host without the bar: the tests skip themselves.
[[ -e $HOME/.config/quickshell/bar ]] || exit 0

attr=".#nixosConfigurations.$(</etc/hostname).config.home-manager.users.$USER.quickshellTestEnv"
env=$(cd ../../../.. && nix build --no-link --print-out-paths "$attr")
echo "QUICKSHELL_TEST_ENV=$env" >>"$NEXTEST_ENV"
