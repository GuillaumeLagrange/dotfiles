# gullywash

## Nix binary cache

`https://nix-cache.gullywash.glagrange.eu` serves gullywash's `/nix/store`:

- harmonia (`nix-cache.nix`) listens on port 5000, open only to the Docker bridges (`br-+`);
- Traefik, in `~/homelab_stack` (outside this repo), terminates HTTPS and checks basic auth, then forwards to
  `host.docker.internal:5000`. Its config is labels on the `traefik` service in `apps/docker-compose.yml`.

Paths are signed by `nix-cache.gullywash.glagrange.eu-1`; clients refuse anything not signed by it.

### Recreating it

What the Nix config and the compose file cannot hold, all on gullywash:

1. Signing key. Only the public half goes in this repo.

   ```sh
   nix key generate-secret --key-name nix-cache.gullywash.glagrange.eu-1 > harmonia.secret
   nix key convert-secret-to-public < harmonia.secret   # the public key, for the clients
   sudo install -D -m 600 harmonia.secret /var/lib/secrets/harmonia.secret && rm harmonia.secret
   ```

2. Password for the `nix` user. bcrypt ignores everything past 72 bytes, so 72 characters is the useful maximum.

   ```sh
   PW=$(LC_ALL=C head -c 4096 /dev/urandom | tr -dc A-Za-z0-9 | cut -c1-72)
   nix shell nixpkgs#apacheHttpd -c htpasswd -nbB -C 12 nix "$PW"
   ```

   Put the output in `~/homelab_stack/apps/.env`, in single quotes so compose leaves the `$` alone:
   `NIX_CACHE_AUTH='nix:$2y$12$…'`. Keep `$PW` in the password manager: the hash cannot give it back, and every
   client needs it.

3. Apply: switch gullywash to this config, then `cd ~/homelab_stack && docker compose up -d --no-deps traefik`.
   DNS for `nix-cache.gullywash.glagrange.eu` must point to gullywash, like the other subdomains.

### Clients

The `desktop` group (`modules/desktop/nix-cache.nix`) adds the cache, its public key and
`netrc-file = /etc/nix/netrc` to every desktop host. The netrc is written by hand, once per machine, readable by
root only (the nix-daemon reads it):

```sh
echo "machine nix-cache.gullywash.glagrange.eu login nix password $PW" | sudo sh -c 'umask 077; cat > /etc/nix/netrc'
```

Without it the cache answers 401 and Nix uses cache.nixos.org alone.

### Checking it

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://nix-cache.gullywash.glagrange.eu/nix-cache-info   # 401
curl -su "nix:$PW" https://nix-cache.gullywash.glagrange.eu/nix-cache-info                          # StoreDir: /nix/store
```

502 or 504 with the right password: Traefik is fine but cannot reach harmonia (`systemctl status harmonia.socket`,
firewall rule `iptables -S nixos-fw | grep 5000`).

### Changing the password

Step 2 again, then `docker compose up -d --no-deps traefik`, then rewrite every client's `/etc/nix/netrc`.

## GitHub Actions runner

`github-runner.nix` registers gullywash as a self-hosted runner (labels `self-hosted`, `gullywash`) for this repo.
`.github/workflows/build.yml` runs on it for every push and builds the hosts and homes. The builds of `main` stay
rooted in `/var/lib/ci-roots/main/`, those of Dependabot's nightly flake update PR (`.github/dependabot.yml`, one
PR for every input, refreshed until merged) in `/var/lib/ci-roots/flake-update/`, so the cache keeps serving them.

### Recreating it

1. Fine-grained personal access token (<https://github.com/settings/personal-access-tokens/new>): repository
   access limited to `GuillaumeLagrange/dotfiles`, permission "Administration: Read and write". On gullywash:

   ```sh
   read -rs TOKEN && printf %s "$TOKEN" | sudo sh -c 'umask 077; cat > /var/lib/secrets/github-runner.token'
   ```

2. Switch gullywash. The runner appears under the repo's Settings → Actions → Runners.

3. The repo is public: Settings → Actions → General → "Require approval for all external contributors", so no
   fork's pull request runs a workflow on gullywash without my approval
   (`gh api -X PUT repos/GuillaumeLagrange/dotfiles/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`).

When the token expires, write the new one the same way; the runner re-registers at its next start
(`sudo systemctl restart github-runner-gullywash`).
