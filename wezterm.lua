local wezterm = require("wezterm")

-- This table will hold the configuration.
local config = {}

if wezterm.config_builder then
    config = wezterm.config_builder()
end

config.color_scheme = "GruvboxDark"
config.hide_tab_bar_if_only_one_tab = true
config.font = wezterm.font("hack")
config.font_size = 9.0
config.window_background_opacity = 0.95
config.use_fancy_tab_bar = false
config.pane_focus_follows_mouse = true

config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

local act = wezterm.action

local function isViProcess(name)
    return name:find("n?vim") ~= nil
end

local function conditionalActivatePane(window, pane, pane_direction, key)
    if isViProcess(pane:get_title()) then
        window:perform_action(act.SendKey({ key = key, mods = "CTRL" }), pane)
    else
        window:perform_action(act.ActivatePaneDirection(pane_direction), pane)
    end
end

config.keys = {
    -- Prompt for a name to use for a new workspace and switch to it.
    {
        key = "W",
        mods = "CTRL|SHIFT",
        action = act.PromptInputLine({
            description = wezterm.format({
                { Attribute = { Intensity = "Bold" } },
                { Foreground = { AnsiColor = "Fuchsia" } },
                { Text = "Enter name for new workspace" },
            }),
            action = wezterm.action_callback(function(window, pane, line)
                -- line will be `nil` if they hit escape without entering anything
                -- An empty string if they just hit enter
                -- Or the actual line of text they wrote
                if line then
                    window:perform_action(
                        act.SwitchToWorkspace({
                            name = line,
                        }),
                        pane
                    )
                end
            end),
        }),
    },

    { key = "v", mods = "LEADER", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
    { key = "s", mods = "LEADER", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },

    -- Pane navigation
    { key = "h", mods = "LEADER", action = act.ActivatePaneDirection("Left") },
    { key = "j", mods = "LEADER", action = act.ActivatePaneDirection("Down") },
    { key = "k", mods = "LEADER", action = act.ActivatePaneDirection("Up") },
    { key = "l", mods = "LEADER", action = act.ActivatePaneDirection("Right") },

    -- {
    --     key = "h",
    --     mods = "CTRL",
    --     action = wezterm.action_callback(function(window, pane)
    --         conditionalActivatePane(window, pane, "Left", "h")
    --     end),
    -- },
    -- {
    --     key = "j",
    --     mods = "CTRL",
    --     action = wezterm.action_callback(function(window, pane)
    --         conditionalActivatePane(window, pane, "Down", "j")
    --     end),
    -- },
    -- {
    --     key = "k",
    --     mods = "CTRL",
    --     action = wezterm.action_callback(function(window, pane)
    --         conditionalActivatePane(window, pane, "Up", "k")
    --     end),
    -- },
    -- {
    --     key = "l",
    --     mods = "CTRL",
    --     action = wezterm.action_callback(function(window, pane)
    --         conditionalActivatePane(window, pane, "Right", "l")
    --     end),
    -- },

    -- Send "CTRL-A" to the terminal when pressing CTRL-A, CTRL-A
    { key = "a", mods = "LEADER|CTRL", action = act.SendKey({ key = "a", mods = "CTRL" }) },
}

config.ssh_domains = {
    {
        -- This name identifies the domain
        name = "charybdis",
        -- The hostname or address to connect to. Will be used to match settings
        -- from your ssh config file
        remote_address = "charybdis",
        remote_wezterm_path = "/home/guillaume/bin/wezterm",
    },
}

-- config.unix_domains = {
--     {
--         name = "charybdis",
--         proxy_command = {
--             "ssh",
--             "-T",
--             "-A",
--             "-C",
--             "-Y",
--             "charybdis",
--             "/home/guillaume/bin/wezterm",
--             "cli",
--             "proxy",
--         },
--     },
-- }

return config
