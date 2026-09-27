---
name: browser
description: >
  How to drive a browser on these machines: the omp `browser` tool runs its own
  managed Chromium by default; the user's Chromium can be driven through the omp
  relay extension. Firefox cannot be driven.
alwaysApply: true
---

# Browser testing

- Reach for an API or CLI first (`gh api`, `curl`, `read` on a URL). Use the
  browser only for what the web page alone shows: rendering, layout, UI-only state.
- Two ways to get a browser:
  - **Managed Chromium** (default `browser.open`): omp-owned profile, installed on
    first use. Use it for anything that needs no login.
  - **The user's Chromium via the relay** (`app.relay: true`): the OMP Browser
    Relay extension is installed unpacked from `~/.omp/browser-relay/extension`
    (rewrite it with `omp browser-relay install`). The relay starts on demand.
    Use it when the task needs the user's logged-in sessions. Always pass
    `app.target` matching a tab the user opened for the task; never adopt their
    visible tab or navigate it away.
  - The user's Firefox cannot be driven. Do not ask them to install Chrome.
- **Login without the relay**: open a managed tab with
  `browser.open({ name, url: '<login page>', headed: true, persist: true })`, ask
  the user to log in in that window, continue once they say so. Cookies stay in
  the managed profile, so later tabs are already logged in.
- A logged-in session (relay or managed) acts as the user. Stay read-only unless
  the user asked for the action, and never touch accounts or repos outside the task.
- If the user closes a managed window, its tab is gone and the next call fails with
  "Session closed". Open a new tab instead of retrying the old handle.
- API gotchas:
  - `tab.text()` needs a selector: `tab.text('body')`.
  - `tab.waitFor` takes a selector, not a duration. Wait on a selector or text,
    or `Bun.sleep(ms)` when nothing observable exists.
  - Element ids from `tab.observe()` are invalid after navigation or re-render;
    observe again, then act in the same cell.
- Many sites (GitHub's PR "Changes" view among them) render lazily: text below the
  fold or in collapsed sections isn't in the DOM. Scroll through the page
  collecting `document.body.innerText`, or open the panel that lists the content.
- Take a screenshot to back any claim about what the page shows, and
  `browser.close({ name })` when done.
