"""Logins of every password manager here, behind one picker.

  passwords pick                      choose a login, then the field to copy
  passwords list                      the logins as JSON lines, for another picker
  passwords copy PROVIDER ID FIELD    copy one field (password, username, email, totp)

Proton Pass always, 1Password when its `op` is installed. Each is logged in or
unlocked first, asking through the picker for what its CLI would read from a
terminal. The picker is the `Vicinae` class: another one only needs `choose` and
`secret`.
"""

import argparse
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

PASS_CLI = "@passCli@"
VICINAE = "@vicinae@"
WL_COPY = "@wlCopy@"
WL_PASTE = "@wlPaste@"
NOTIFY_SEND = "@notifySend@"
XDG_OPEN = "@xdgOpen@"

CLEAR_AFTER = 45
TIMEOUT = 30
# Long enough to answer the password manager's own unlock prompt or log in in the browser.
INTERACTIVE_TIMEOUT = 300

FIELDS = {
    "password": "Password",
    "username": "Username",
    "email": "Email",
    "totp": "One-time code",
}

ERRORS = (OSError, ValueError, KeyError, subprocess.TimeoutExpired)


class Failure(Exception):
    pass


class Cancelled(Exception):
    pass


class Vicinae:
    def choose(self, title, lines):
        """Index of the chosen line, or None."""
        out = subprocess.run(
            [VICINAE, "dmenu", "-n", title, "-f", "index", "--no-quick-look"],
            input="\n".join(lines),
            capture_output=True,
            text=True,
        ).stdout.strip()
        return int(out) if out.isdigit() else None

    def secret(self, title, placeholder):
        out = subprocess.run(
            [
                VICINAE,
                "dmenu",
                "--password",
                "-n",
                title,
                "-p",
                placeholder,
                "--no-quick-look",
            ],
            input="",
            capture_output=True,
            text=True,
        ).stdout.rstrip("\n")
        if not out:
            raise Cancelled
        return out


def notify(summary, body=""):
    subprocess.run([NOTIFY_SEND, "-a", "Passwords", summary, body])


def error_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1].removeprefix("Error: ") if lines else "failed"


def converse(argv, env, replies, timeout):
    """Run argv on a terminal of its own, for CLIs that prompt on /dev/tty.

    replies: (regex, callback) pairs, matched against the output since the last
    match; the callback gets the match and returns what to type, or None.
    Returns (exit code, output)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, env)
    out, seen = "", 0
    deadline = time.monotonic() + timeout
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Failure(f"{os.path.basename(argv[0])} timed out")
            if not select.select([fd], [], [], left)[0]:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError:  # EIO: the child closed the terminal
                break
            if not chunk:
                break
            out += chunk.decode(errors="replace")
            for pattern, reply in replies:
                match = re.search(pattern, out[seen:])
                if match:
                    seen += match.end()
                    text = reply(match)
                    if text is not None:
                        os.write(fd, (text + "\n").encode())
        _, status = os.waitpid(pid, 0)
        pid = None
        return os.waitstatus_to_exitcode(status), out
    finally:
        os.close(fd)
        if pid is not None:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)


def find_key(node, key):
    """The first dict under `key` anywhere in decoded JSON."""
    if isinstance(node, dict):
        if isinstance(node.get(key), dict):
            return node[key]
        node = list(node.values())
    for child in node if isinstance(node, list) else ():
        found = find_key(child, key)
        if found is not None:
            return found
    return None


class Proton:
    key = "proton"
    name = "Proton Pass"

    def __init__(self, picker):
        self.picker = picker
        # The kernel keyring the CLI defaults to is wiped on reboot; gnome-keyring is not.
        self.env = os.environ | {
            "PROTON_PASS_LINUX_KEYRING": "dbus",
            "PROTON_PASS_NO_UPDATE_CHECK": "1",
        }
        self.logins = {}

    def available(self):
        return True

    def output(self, *args):
        result = subprocess.run(
            [PASS_CLI, *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            env=self.env,
            timeout=TIMEOUT,
        )
        if result.returncode:
            raise Failure(error_line(result.stderr))
        return result.stdout

    def unlock(self):
        try:
            self.output("info")
        except Failure as e:
            reason = str(e).lower()
            if "lock" in reason:
                self.unlock_session()
            elif "authenticated" in reason or "session" in reason:
                self.login()
            else:
                raise

    def login(self):
        def open_url(match):
            subprocess.Popen([XDG_OPEN, match[1]], start_new_session=True)
            notify(self.name, "Log in in the browser")

        code, out = converse(
            [PASS_CLI, "login"],
            self.env,
            [
                (r"(https://\S+)\s", open_url),
                (
                    r"(?i)extra password[^\n]*:",
                    lambda _: self.picker.secret(self.name, "Extra password"),
                ),
            ],
            INTERACTIVE_TIMEOUT,
        )
        if code:
            raise Failure(error_line(out))

    def unlock_session(self):
        lock_code = self.picker.secret(self.name, "Lock code")
        code, out = converse(
            [PASS_CLI, "session", "unlock"],
            self.env,
            [(r"(?i)lock code[^\n]*:", lambda _: lock_code)],
            TIMEOUT,
        )
        if code:
            raise Failure(error_line(out))

    def items(self):
        vaults = json.loads(self.output("vault", "list", "--output", "json"))["vaults"]

        def vault_items(vault):
            listed = self.output(
                "item",
                "list",
                "--share-id",
                vault["share_id"],
                "--filter-type",
                "login",
                "--filter-state",
                "active",
                "--output",
                "json",
            )
            return [
                {
                    "id": f"{item['share_id']}/{item['id']}",
                    "title": item["title"],
                    "subtitle": vault.get("name", ""),
                }
                for item in json.loads(listed)["items"]
            ]

        with ThreadPoolExecutor() as pool:
            return [item for listed in pool.map(vault_items, vaults) for item in listed]

    def login_of(self, item_id):
        if item_id not in self.logins:
            view = json.loads(
                self.output("item", "view", f"pass://{item_id}", "--output", "json")
            )
            self.logins[item_id] = find_key(view, "Login")
        return self.logins[item_id]

    def fields(self, item_id):
        login = self.login_of(item_id)
        if login is None:
            return [(key, None) for key in FIELDS]
        values = {
            "password": login.get("password"),
            "username": login.get("username"),
            "email": login.get("email"),
            "totp": login.get("totp_uri"),
        }
        return [
            (key, values[key] if key in ("username", "email") else None)
            for key in FIELDS
            if values[key]
        ]

    def value(self, item_id, key):
        if key == "totp":
            codes = json.loads(
                self.output(
                    "item", "totp", f"pass://{item_id}/totp", "--output", "json"
                )
            )
            return next(iter(codes.values()))
        login = self.logins.get(item_id)
        if login and login.get(key):
            return login[key]
        return self.output("item", "view", f"pass://{item_id}/{key}").rstrip("\n")


class OnePassword:
    key = "1password"
    name = "1Password"

    def __init__(self, picker):
        # The setgid wrapper: only it may talk to the desktop app.
        self.op = shutil.which(
            "op", path=f"/run/wrappers/bin:{os.environ.get('PATH', '')}"
        )
        self.details = {}

    def available(self):
        return self.op is not None

    def output(self, *args, timeout=TIMEOUT):
        result = subprocess.run(
            [self.op, *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode:
            raise Failure(error_line(result.stderr))
        return result.stdout

    def unlock(self):
        # Through the desktop app's CLI integration, which shows its own unlock prompt.
        try:
            self.output("signin", timeout=INTERACTIVE_TIMEOUT)
        except Failure:
            app = shutil.which("1password")
            if app is None:
                raise
            # The integration needs the app running; a second instance only wakes the first.
            subprocess.Popen(
                [app, "--silent"],
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(5)
            self.output("signin", timeout=INTERACTIVE_TIMEOUT)

    def items(self):
        listed = json.loads(
            self.output(
                "item", "list", "--categories", "Login,Password", "--format", "json"
            )
        )
        return [
            {
                "id": f"{item['vault']['id']}/{item['id']}",
                "title": item["title"],
                "subtitle": " · ".join(
                    part
                    for part in (
                        item.get("additional_information"),
                        item["vault"].get("name"),
                    )
                    if part
                ),
            }
            for item in listed
        ]

    def get(self, item_id, *args):
        vault, item = item_id.split("/", 1)
        return self.output("item", "get", item, "--vault", vault, *args)

    def item_fields(self, item_id):
        if item_id not in self.details:
            self.details[item_id] = json.loads(
                self.get(item_id, "--format", "json", "--reveal")
            )
        return self.details[item_id].get("fields", [])

    def fields(self, item_id):
        found = {}
        for field in self.item_fields(item_id):
            purpose, value = field.get("purpose"), field.get("value")
            if purpose == "PASSWORD" and value:
                found["password"] = None
            elif purpose == "USERNAME" and value:
                found["username"] = value
            elif field.get("type") == "OTP":
                found["totp"] = None
        return [(key, found[key]) for key in FIELDS if key in found]

    def value(self, item_id, key):
        if key == "totp":
            return self.get(item_id, "--otp").strip()
        for field in self.item_fields(item_id):
            if field.get("purpose") == key.upper() and field.get("value"):
                return field["value"]
        raise Failure(f"no {FIELDS[key].lower()}")


def providers(picker):
    return [p for p in (Proton(picker), OnePassword(picker)) if p.available()]


def logins(picker):
    """Every login, as (provider, item); a provider that fails is left out."""
    out = []
    for provider in providers(picker):
        try:
            provider.unlock()
            out += [(provider, item) for item in provider.items()]
        except Cancelled:
            continue
        except (Failure, *ERRORS) as e:
            notify(f"{provider.name} unavailable", str(e))
    return out


def copy(value, what):
    subprocess.run([WL_COPY, "--sensitive"], input=value, text=True, check=True)
    notify(f"Copied {what}", f"Cleared in {CLEAR_AFTER}s")
    if os.fork():
        return
    os.setsid()
    time.sleep(CLEAR_AFTER)
    current = subprocess.run(
        [WL_PASTE, "--no-newline"], capture_output=True, text=True
    ).stdout
    if current == value:
        subprocess.run([WL_COPY, "--clear"])
    os._exit(0)


def oneline(text):
    return " ".join(text.split())


def pick(picker):
    found = logins(picker)
    if not found:
        return
    many = len({provider.key for provider, _ in found}) > 1
    lines = []
    for provider, item in found:
        detail = " · ".join(
            part for part in (item["subtitle"], provider.name if many else "") if part
        )
        lines.append(
            oneline(f"{item['title']}  —  {detail}" if detail else item["title"])
            or "(untitled)"
        )
    index = picker.choose("Passwords", lines)
    if index is None:
        return
    provider, item = found[index]

    fields = provider.fields(item["id"])
    if not fields:
        raise Failure(f"{item['title']} has nothing to copy")
    index = picker.choose(
        oneline(item["title"]) or "Fields",
        [
            FIELDS[key] + (f": {oneline(shown)}" if shown else "")
            for key, shown in fields
        ],
    )
    if index is None:
        return
    key = fields[index][0]
    copy(provider.value(item["id"], key), f"{FIELDS[key].lower()} of {item['title']}")


def main():
    parser = argparse.ArgumentParser(prog="passwords")
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("pick")
    commands.add_parser("list")
    copy_parser = commands.add_parser("copy")
    copy_parser.add_argument("provider")
    copy_parser.add_argument("id")
    copy_parser.add_argument("field", choices=list(FIELDS))
    args = parser.parse_args()

    picker = Vicinae()
    try:
        if args.command == "list":
            for provider, item in logins(picker):
                print(json.dumps({"provider": provider.key, **item}))
        elif args.command == "copy":
            provider = next(
                (p for p in providers(picker) if p.key == args.provider), None
            )
            if provider is None:
                raise Failure(f"no provider {args.provider}")
            provider.unlock()
            copy(provider.value(args.id, args.field), FIELDS[args.field].lower())
        else:
            pick(picker)
    except Cancelled:
        return 1
    except (Failure, *ERRORS) as e:
        notify("Passwords", str(e))
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
