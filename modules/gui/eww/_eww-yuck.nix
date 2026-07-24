# Generates eww.yuck with absolute store paths for every command. eww's
# deflisten does not reliably resolve bare command names against PATH, so all
# data sources and click handlers reference `${bins.*}` absolute paths.
{ bins }:
# yuck
''
  ;; eww bar — recreation of the waybar setup, generated from _eww-yuck.nix.
  ;; One `bar` window per niri output (opened by bar-launch.sh). Left side comes
  ;; from a single niri event-stream tap; right side from pollers + pushes.

  ;; ── Data sources ────────────────────────────────────────────────────────────

  (deflisten nstate :initial `{"workspaces":[],"by_output":{}}`
    "${bins.niriState}")

  ;; Full media state — event-driven (D-Bus signals), emits only on real change.
  ;; Drives the pill (mpris.active) and the panel rows (mpris.players).
  (deflisten mpris :initial `{"present":false,"players":[]}` "${bins.mpris} state")
  ;; Per-player live position (seek bar) and scrolling title frame. Both gate on
  ;; the panel being open, so they cost nothing while it's closed.
  (deflisten mprispos    :initial `{}` "${bins.mpris} pos")
  (deflisten mprisscroll :initial `{}` "${bins.mpris} scroll")
  ;; Panel visibility — set by hover (last-write-wins, no races).
  (defvar mpris_open false)
  (deflisten audio :initial `{"volume":0,"muted":false,"text":"","class":"unmuted","sink":""}` "${bins.pulseaudio}")

  ;; Pushed by screen-tools.nix on record start/stop.
  (defvar screenrecord `{"recording":false,"text":""}`)

  ;; Sampled metrics — no event source, so polling is the right model.
  (defpoll claude   :interval "300s" :initial `{"text":"󰜡 --","tooltip":"","class":"low","percentage":0}` "${bins.claudeUsage}")
  (defpoll disk     :interval "30s"  :initial `{"free":"…","tooltip":""}` "${bins.disk}")
  (defpoll cpu      :interval "3s"   :initial `{"usage":0,"tooltip":""}` "${bins.cpu}")
  (defpoll memswap  :interval "5s"   :initial `{"text":"","class":"ok","tooltip":""}` "${bins.memorySwap}")
  (defpoll battery  :interval "30s"  :initial `{"capacity":0,"charging":false,"class":"hidden","text":"","tooltip":""}` "${bins.battery}")

  ;; Settings state — pushed via `eww update` (toggle handlers + settings-watch).
  ;; Seed the bare gear glyph so the badge draws on first paint; the watch push
  ;; then layers on toggle badges and the active-profile tint.
  (defvar settings `{"text":"󰒓","class":"balanced"}`)
  (defvar idlest   `{"on":false,"class":"off"}`)
  (defvar dndst    `{"on":false,"class":"off"}`)
  (defvar profst   `{"profile":"balanced","icon":"󰾅"}`)

  (defpoll clock_main :interval "10s" :initial "…" `${bins.date} +'󰃰 %B %d, %H:%M'`)
  (defpoll clock_alt  :interval "10s" :initial "…" `${bins.date} +'󰥔 %H:%M'`)

  ;; UI-only state.
  (defvar clock_compact false)   ;; toggled by right-clicking the clock
  ;; Popup visibility — set by hover (last-write-wins, no races).
  (defvar cal_open false)
  (defvar settings_open false)

  ;; Custom calendar: a two-month sliding window (left = cal_offset months from
  ;; now, right = +1). Seeded/navigated by `calendar-eww push <base>`, which
  ;; pushes these three together. GtkCalendar can't render a legible today pill,
  ;; so the grid is drawn from scratch.
  (defvar cal_offset 0)
  (defvar cal_left  `{"title":"","month":0,"year":0,"weeks":[]}`)
  (defvar cal_right `{"title":"","month":0,"year":0,"weeks":[]}`)

  ;; ── Left modules ────────────────────────────────────────────────────────────

  ;; Per-bar workspaces: only this monitor's workspaces shown (waybar
  ;; all-outputs=false). eww has no list filter, so off-output buttons render
  ;; but stay hidden.
  (defwidget workspaces [monitor]
    (box :class "workspaces" :space-evenly false :spacing 0
      (for ws in {nstate.workspaces}
        (eventbox :visible {ws.output == monitor}
                  :onclick "${bins.niri} msg action focus-workspace ''${ws.name}"
          (button
            :class "ws ''${ws.is_urgent ? "urgent" :
                         ws.is_focused ? "focused" :
                         ws.is_active  ? "active"  :
                         ws.is_empty   ? "empty"   : "inactive"}"
            (label :text {ws.name}))))))

  (defwidget niri-windows [monitor]
    (eventbox :onclick "${bins.niri} msg action toggle-overview"
      (box :class "niri-windows ''${(nstate.by_output?.[monitor]?.windows?.count ?: 0) > 0 ? "has-windows" : "empty"}"
        :visible {(nstate.by_output?.[monitor]?.windows?.count ?: 0) > 0}
        (label :text {nstate.by_output?.[monitor]?.windows?.dots ?: ""}))))

  (defwidget window-title [monitor]
    (box :class "window ''${(nstate.by_output?.[monitor]?.title ?: "") != "" ? "filled" : "empty"}"
      :visible {(nstate.by_output?.[monitor]?.title ?: "") != ""}
      (label :text {nstate.by_output?.[monitor]?.title ?: ""} :limit-width 100 :show-truncated true)))

  ;; ── Right modules ───────────────────────────────────────────────────────────

  (defwidget screenrecord-w []
    (eventbox :onclick "${bins.screenrecord}"
      (box :class "screenrecord ''${screenrecord.recording ? "recording" : "idle"}"
        :visible {screenrecord.recording}
        (label :text {screenrecord.text}))))

  ;; Bar pill: source icon + title—artist + play/pause button. Reads the active
  ;; player (mpris.active). Hover opens the panel; leaving closes it (debounced).
  ;; play/pause reflects on the next `state` emit (~200ms D-Bus echo).
  (defwidget mpris-w [monitor]
    (eventbox :visible {mpris.present ?: false}
      :onhover     "${bins.setsid} -f ${bins.mprisOpen} ''${monitor}"
      :onhoverlost "${bins.setsid} -f ${bins.mprisClose}"
      (box :class "mpris ''${mpris.active.color ?: "grey"} ''${(mpris.active.status ?: "Paused") == "Playing" ? "playing" : "paused"}"
        :space-evenly false :spacing 7
        (label :class "mpris-icon" :text {mpris.active.icon ?: ""})
        (label :class "mpris-title"
          :text "''${mpris.active.title ?: ""}''${(mpris.active.artist ?: "") != "" ? "  —  " : ""}''${mpris.active.artist ?: ""}"
          :limit-width 34 :show-truncated true)
        (button :class "mpris-toggle"
          :onclick "${bins.mpris} playpause ''${mpris.active.player}"
          {(mpris.active.status ?: "Paused") == "Playing" ? "${bins.pauseGlyph}" : "${bins.playGlyph}"}))))

  ;; Native SNI tray (eww's `systray` widget). Same slot/size as waybar's tray.
  (defwidget tray-w []
    (box :class "tray"
      (systray :orientation "h" :spacing 8 :icon-size 14 :prepend-new false)))

  ;; Refresh calls `eww update` (and hits the network), so run detached via the
  ;; claude-refresh helper to avoid blocking the daemon / eww's onclick timeout.
  (defwidget claude-w []
    (eventbox
      :onclick      "${bins.setsid} -f ${bins.claudeRefresh} --force-refresh"
      :onrightclick "${bins.setsid} -f ${bins.claudeRefresh} --restart"
      :tooltip {claude.tooltip}
      (box :class "claude ''${claude.class}"
        (label :text {claude.text}))))

  (defwidget disk-w []
    (box :class "disk" :tooltip {disk.tooltip}
      (label :text "󰋊 ''${disk.free}")))

  (defwidget cpu-w []
    (box :class "cpu" :tooltip {cpu.tooltip}
      (label :text "󰍛 ''${cpu.usage}%")))

  (defwidget memswap-w []
    (box :class "memswap ''${memswap.class}" :tooltip {memswap.tooltip}
      (label :markup {memswap.text})))

  (defwidget battery-w []
    (box :class "battery ''${battery.class}" :visible {battery.class != "hidden"} :tooltip {battery.tooltip}
      (label :text {battery.text})))

  (defwidget audio-w []
    (eventbox
      ;; setsid --fork detaches pavucontrol so eww's ~1s onclick timeout can't
      ;; kill it before the window is up.
      :onclick  "${bins.setsid} --fork ${bins.pavucontrol}"
      :onscroll `[ "{}" = up ] && d=1%+ || d=1%-; ${bins.wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0; ${bins.wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ $d`
      :tooltip {audio.sink}
      (box :class "audio ''${audio.class}"
        (label :text {audio.text}))))

  ;; Settings gear: glyph tinted to the active profile; hover opens the panel.
  (defwidget settings-w [monitor]
    (eventbox
      :onhover     "${bins.setsid} -f ${bins.settingsOpen} ''${monitor}"
      :onhoverlost "${bins.setsid} -f ${bins.settingsClose}"
      (box :class "settings ''${settings.class}"
        (label :markup {settings.text}))))

  (defwidget clock-w [monitor]
    (eventbox
      :onhover      "${bins.setsid} -f ${bins.calOpen} ''${monitor}"
      :onhoverlost  "${bins.setsid} -f ${bins.calClose}"
      :onrightclick "${bins.eww} update clock_compact=''${!clock_compact}"
      (box :class "clock"
        (label :text {clock_compact ? clock_alt : clock_main}))))

  ;; ── Bar ─────────────────────────────────────────────────────────────────────

  (defwidget bar-left [monitor]
    (box :halign "start" :space-evenly false :spacing 0
      (workspaces :monitor monitor)
      (niri-windows :monitor monitor)
      (window-title :monitor monitor)))

  (defwidget bar-right [monitor]
    (box :halign "end" :space-evenly false :spacing 0
      (screenrecord-w)
      (mpris-w :monitor monitor)
      (tray-w)
      (claude-w)
      (disk-w)
      (cpu-w)
      (memswap-w)
      (battery-w)
      (audio-w)
      (settings-w :monitor monitor)
      (clock-w :monitor monitor)))

  (defwindow bar [monitor]
    :monitor monitor
    :geometry (geometry :width "100%" :height "28px" :anchor "bottom center")
    :stacking "fg"
    :exclusive true
    (centerbox :class "bar"
      (bar-left :monitor monitor)
      (box)
      (bar-right :monitor monitor)))

  ;; ── Popups ──────────────────────────────────────────────────────────────────
  ;; All three (media panel, calendar, settings) open on hovering their bar
  ;; widget and close when the pointer leaves both the widget and the popup.
  ;; Hovering a popup only refreshes its keepalive flag (the `*-keep` helper);
  ;; calling `eww` from those handlers would re-open the window on every
  ;; child-widget crossing, which flickers.

  ;; Custom-drawn month grid. The script emits only data (day number, other/
  ;; today flags, week number); every visual is a CSS class here, so styling
  ;; lives entirely in eww.scss.
  (defwidget month-grid [m]
    (box :class "month" :orientation "v" :space-evenly false :spacing 2
      ;; Weekday header row (blank corner for the week-number column).
      (box :class "weekdays" :space-evenly true
        (label :class "wk-corner" :text "")
        (label :class "wday" :text "Mo") (label :class "wday" :text "Tu")
        (label :class "wday" :text "We") (label :class "wday" :text "Th")
        (label :class "wday" :text "Fr") (label :class "wday" :text "Sa")
        (label :class "wday" :text "Su"))
      (box :orientation "v" :space-evenly false :spacing 1
        (for week in {m.weeks}
          (box :class "week" :space-evenly true
            (label :class "wknum" :text {week.num})
            (for d in {week.days}
              (label :class "day ''${d.today ? "today" : d.other ? "other" : "normal"}"
                :text {d.day})))))))

  ;; Nav arrows re-push the grid (calls `eww update`), so detach to avoid the
  ;; daemon-deadlock any onclick that calls eww back would otherwise hit.
  (defwidget cal-nav [base]
    (box :class "cal-header" :orientation "h" :space-evenly false
      (button :class "cal-arrow" :halign "start"
        :onclick "${bins.setsid} -f ${bins.calendar} push ''${base - 1}" "${bins.larrow}")
      (box :hexpand true :halign "center" (children))
      (button :class "cal-arrow" :halign "end"
        :onclick "${bins.setsid} -f ${bins.calendar} push ''${base + 1}" "${bins.rarrow}")))

  (defwindow calendar-popup [monitor]
    :monitor monitor
    :geometry (geometry :anchor "bottom right" :x "8px" :y "30px")
    :stacking "fg"
    (eventbox
      :onhover     "${bins.calKeep}"
      :onhoverlost "${bins.setsid} -f ${bins.calClose}"
      (box :class "popup calendar-popup" :orientation "v" :space-evenly false :spacing 10
        ;; Header:  ‹   June 2026     July 2026   ›  — year on each month so it's
        ;; symmetric and correct when the window straddles a year boundary.
        (cal-nav :base cal_offset
          (box :class "cal-titles" :orientation "h" :space-evenly true :hexpand true
            (label :class "cal-title" :text "''${cal_left.title} ''${cal_left.year}")
            (label :class "cal-title" :text "''${cal_right.title} ''${cal_right.year}")))
        (box :orientation "h" :space-evenly false :spacing 20
          (month-grid :m cal_left)
          (month-grid :m cal_right)))))

  ;; Settings/power panel: rows with a label and a right-aligned state pill.
  ;; `raction` is the optional right-click action (empty string = none).
  (defwidget toggle-row [label state class action raction]
    (eventbox :onclick action :onrightclick raction :class "settings-row"
      (box :orientation "h" :space-evenly false :spacing 12
        (label :class "row-label" :halign "start" :hexpand true :text label)
        (label :class "row-pill ''${class}" :text state))))

  (defwindow settings-popup [monitor]
    :monitor monitor
    :geometry (geometry :anchor "bottom right" :x "8px" :y "30px")
    :stacking "fg"
    (eventbox
      :onhover     "${bins.settingsKeep}"
      :onhoverlost "${bins.setsid} -f ${bins.settingsClose}"
      (box :class "popup settings-panel" :orientation "v" :space-evenly false :spacing 2
        (label :class "panel-title" :halign "start" :text "Quick Settings")
        (toggle-row
          :label "Idle inhibit"
          :state {idlest.on ? "ON" : "OFF"}
          :class {idlest.on ? "on" : "off"}
          :action "${bins.setsid} -f ${bins.settings} toggle-idle"
          :raction "")
        (toggle-row
          :label "Do Not Disturb"
          :state {dndst.on ? "ON" : "OFF"}
          :class {dndst.on ? "on" : "off"}
          :action "${bins.setsid} -f ${bins.settings} toggle-dnd"
          :raction "")
        ;; Left-click = more powerful, right-click = more saving.
        (toggle-row
          :label "Power profile"
          :state {profst.profile}
          :class {profst.profile}
          :action  "${bins.setsid} -f ${bins.settings} profile-up"
          :raction "${bins.setsid} -f ${bins.settings} profile-down"))))

  ;; ── Now-playing panel ────────────────────────────────────────────────────────
  ;; One color-railed row per player: art thumb (fallback glyph if none), source
  ;; icon, scrolling title (click = jump to that player's window), artist, a
  ;; read-only progress bar, and inline transport.
  ;;
  ;; NB: index the per-player maps with bracket syntax — `pos[p.player]`. eww's
  ;; `?.[key]` safe-access does NOT resolve a variable key inside a for-generated
  ;; widget (it silently yields nothing).

  ;; Read-only progress display; no click-to-seek. Tracks with no mpris:length
  ;; (live streams) have no meaningful progress, so the bar and end time are
  ;; hidden and a LIVE badge shows next to the elapsed time.
  (defwidget mpris-seek [p pos]
    (box :class "np-seek-row" :space-evenly false :spacing 8
      (label :class "np-time" :text {pos[p.player].posText ?: p.posText})
      (progress :class "np-seek" :hexpand true :visible {p.has_length}
        :value {pos[p.player].prog ?: p.prog})
      (label :class "np-live" :text "LIVE" :visible {!p.has_length} :hexpand true :halign "start")
      (label :class "np-time" :text {p.lenText} :visible {p.has_length})))

  (defwidget mpris-row [p pos scroll]
    (box :class "np-row ''${p.color} ''${p.playing ? "playing" : "paused"}"
      :orientation "h" :space-evenly false :spacing 12
      (box :class "np-rail")
      (box :class "np-art" :valign "center"
        (box :visible {p.art != ""}
          (image :path {p.art} :image-width 52 :image-height 52))
        (label :class "np-art-fallback" :visible {p.art == ""} :text {p.icon}))
      (box :orientation "v" :space-evenly false :spacing 3 :hexpand true
        (box :space-evenly false :spacing 6 :hexpand true
          (label :class "np-src" :text {p.icon})
          ;; The backend pads every scroll frame to a fixed char count, and
          ;; .np-title-clip pins the pixel width, so the row never resizes as the
          ;; frame changes (emoji are much wider than a char).
          (box :class "np-title-clip" :halign "start" :hexpand false
            (button :class "np-title" :halign "start"
              :onclick "${bins.setsid} -f ${bins.mprisJump} ''${p.player}"
              (label :class "np-title-text" :halign "start" :wrap false
                :text {scroll[p.player] ?: p.title}))))
        (label :class "np-artist" :halign "start" :text {p.artist}
          :limit-width 40 :show-truncated true :visible {p.artist != ""})
        (mpris-seek :p p :pos pos))
      (box :class "np-ctrl" :orientation "h" :space-evenly false :spacing 6 :valign "center"
        (button :class "np-btn" :onclick "${bins.mpris} previous ''${p.player}" "${bins.prevGlyph}")
        (button :class "np-btn np-play"
          :onclick "${bins.mpris} playpause ''${p.player}"
          {p.playing ? "${bins.pauseGlyph}" : "${bins.playGlyph}"})
        (button :class "np-btn" :onclick "${bins.mpris} next ''${p.player}" "${bins.nextGlyph}"))))

  ;; Anchored above the bar. The pill sits mid-right, but its x drifts with the
  ;; tray/claude widths, so a fixed offset there would desync; bottom-center is
  ;; stable and reads as intentional for a media panel.
  (defwindow mpris-popup [monitor]
    :monitor monitor
    :geometry (geometry :anchor "bottom center" :y "30px")
    :stacking "fg"
    ;; Panel hover only refreshes the keepalive flag (mprisKeep = touch, no eww
    ;; call): GTK fires hover/hover-lost as the pointer crosses child widgets, and
    ;; re-opening the window on each of those events makes it flicker.
    (eventbox
      :onhover     "${bins.mprisKeep}"
      :onhoverlost "${bins.setsid} -f ${bins.mprisClose}"
      (box :class "popup mpris-popup" :orientation "v" :space-evenly false :spacing 2
        (label :class "panel-title" :halign "start" :text "Now Playing")
        (box :orientation "v" :space-evenly false :spacing 8
          (for p in {mpris.players}
            (mpris-row :p p :pos mprispos :scroll mprisscroll)))
        (label :class "np-empty" :halign "center" :text "Nothing playing"
          :visible {arraylength(mpris.players) == 0}))))
''
