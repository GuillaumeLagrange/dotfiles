pragma Singleton
// Moves an open panel to the focused output, as the launcher follows it: the
// panel left behind closes and asks its twin on that output's bar to open.
import Quickshell

Singleton {
    signal handoff(string kind, string output)
}
