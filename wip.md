# passwords picker: slow to open

`passwords pick` (`pkgs/passwords/passwords.py`) takes several seconds before the
list shows, and again before the copy. Almost all of it is `pass-cli`: every call
asks Proton's servers instead of reading its local database.

## Timings

snakewater, logged in, 5 vaults, 414 logins, `PROTON_PASS_LINUX_KEYRING=dbus`:

| call | time | when |
|---|---|---|
| `pass-cli info` | 0.19 s | before the list (login/unlock check) |
| `pass-cli vault list --output json` | 0.47 s | before the list |
| `pass-cli item list --share-id … --output json`, per vault (run in parallel) | 0.37–1.31 s | before the list |
| `passwords list`, all of the above | 3.6 s | before the list |
| `pass-cli item view pass://S/I --output json` | 0.41 s | before the field menu |
| `pass-cli item view pass://S/I/password` | 0.4–1.6 s | the copy |

- A traced `item list` (`PASS_LOG_LEVEL=trace`) spends about 3 ms on the keyring
  and its sqlite database, then about 130 ms fetching items, about 135 ms for
  share keys, and fetches folders even for JSON output.
- The same call ran 1.28 s then 0.37 s back to back: network and server variance,
  not contention between the parallel calls (sequential runs vary the same way).
- `pass-cli` has no offline or cached listing mode.

## Next step

Cache the list on disk (titles, ids, vault names; no secrets):

1. `pick` opens the picker from the cache at once.
2. It refreshes the cache in the background for the next open.
3. Drop the `info` check: log in or unlock only when a call fails.
4. The value fetch (0.4–1.5 s) stays, after the pick.

Tradeoff: an item added seconds ago shows up only on the next open.
