{
  # Caffeine: closing the lid locks and blanks instead of suspending
  # (modules/gui/niri lid-close, swayidle's suspend timeout also stands down),
  # with the side LEDs blinking blue so it shows through a closed lid.
  # Every 10 minutes of closed lid it suspends unless an omp is working.
  # caffeine-auto drives it from a mode the bar's control centre sets: off, on,
  # or auto (on while connected to a Wi-Fi network in ~/.config/caffeine/config).
  flake.modules.nixos.granary =
    { pkgs, ... }:
    let
      # Both side LEDs: this EC only answers for the battery LED, not left/right.
      led = "/sys/class/leds/chromeos:multicolor:charging";
      bat = "/sys/class/power_supply/BAT1";
      ac = "/sys/class/power_supply/ACAD";
      lowBattery = 20;

      watchdog = pkgs.writeShellApplication {
        name = "caffeine-watchdog";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.systemd
        ];
        text = ''
          led='${led}'
          bat='${bat}'
          ac='${ac}'
          lids=(/proc/acpi/button/lid/*/state)
          lid=''${lids[0]}
          if [[ ! -e $lid ]]; then
            echo "no ACPI lid switch" >&2
            exit 1
          fi

          suspend() {
            echo "$1, suspending"
            systemctl suspend-then-hibernate --check-inhibitors=no
            exit 0
          }

          closed() { [[ $(<"$lid") == *closed ]]; }

          # Pane files from ai/omp/extensions/omp-panel.ts; a dead pid is a crashed omp.
          ompWorking() {
            local f pid state
            for f in /run/user/*/omp-panel/*/*.json; do
              [[ -e $f ]] || continue
              read -r pid state < <(jq -r '"\(.pid) \(.state)"' "$f" 2>/dev/null) || continue
              [[ $state == working && -d /proc/$pid ]] && return 0
            done
            return 1
          }

          closedFor=0
          check() {
            if closed; then closedFor=$((closedFor + 1)); else closedFor=0; fi
            if ((closedFor > 0 && closedFor % 600 == 0)) && ! ompWorking; then
              suspend "lid closed with no omp working"
            fi
            if [[ $(<"$ac/online") == 0 ]] && (($(<"$bat/capacity") < ${toString lowBattery})); then
              suspend "battery below ${toString lowBattery}%"
            fi
          }

          # multi_index order: red green blue yellow white amber
          echo "0 0 100 0 0 0" >"$led/multi_intensity"
          beat=0
          ec=1
          while :; do
            if ! closed; then
              if ((!ec)); then echo chromeos-auto >"$led/trigger"; fi
              ec=1
            elif ((beat == 0)); then
              echo none >"$led/trigger"
              echo 100 >"$led/brightness"
              ec=0
            # Off beat: the EC's own charge colour on AC, dark on battery.
            elif [[ $(<"$ac/online") == 1 ]]; then
              echo chromeos-auto >"$led/trigger"
            else
              echo 0 >"$led/brightness"
            fi
            beat=$((1 - beat))
            sleep 1
            check
          done
        '';
      };

      restoreLed = pkgs.writeShellScript "caffeine-restore-led" ''
        echo chromeos-auto >'${led}/trigger'
      '';

      # /run/caffeine/active holds 1 while the unit runs: the bar and caffeine-auto
      # watch it instead of polling systemd.
      activeFile = "/run/caffeine/active";
      markActive = v: pkgs.writeShellScript "caffeine-active-${v}" "echo ${v} >${activeFile}";

      # The mode file is the contract with the bar (modules/gui/quickshell
      # services/Quick.qml), which writes it; a missing or unknown mode is auto.
      # Everything it reacts to is an event; nothing is polled.
      auto = pkgs.writeShellApplication {
        name = "caffeine-auto";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.glib
          pkgs.inotify-tools
          pkgs.networkmanager
          pkgs.systemd
        ];
        text = ''
          conf=''${XDG_CONFIG_HOME:-$HOME/.config}/caffeine/config
          if [[ ! -e $conf ]]; then
            mkdir -p "$(dirname "$conf")"
            cat >"$conf" <<'EOF'
          # caffeine-auto: in auto mode, caffeine is on while connected to one of these Wi-Fi networks.
          # One "ssid=<name>" per line, matched exactly. Reloaded when it changes.
          #ssid=Office Wifi
          EOF
            echo "wrote sample config to $conf"
          fi

          state=''${XDG_STATE_HOME:-$HOME/.local/state}/caffeine
          modeFile=$state/mode
          mkdir -p "$state"
          [[ -e $modeFile ]] || printf auto >"$modeFile"

          ssids=()
          loadConf() {
            ssids=()
            local line
            while IFS= read -r line || [[ -n $line ]]; do
              [[ -z $line || $line == \#* ]] && continue
              if [[ $line == ssid=* ]]; then
                ssids+=("''${line#ssid=}")
              else
                echo "$conf: ignoring '$line'" >&2
              fi
            done <"$conf"
          }

          mode() {
            local m=""
            { m=$(<"$modeFile"); } 2>/dev/null || true
            case $m in
              off | on) echo "$m" ;;
              *) echo auto ;;
            esac
          }

          # Terse output escapes ':' and '\' in the SSID.
          currentSsid() {
            local line ssid
            while IFS= read -r line; do
              [[ $line == yes:* ]] || continue
              ssid=''${line#yes:}
              ssid=''${ssid//\\:/:}
              printf '%s\n' "''${ssid//\\\\/\\}"
              return
            done < <(nmcli -t -f ACTIVE,SSID device wifi list --rescan no 2>/dev/null)
          }

          onTrigger() {
            local ssid s
            ssid=$(currentSsid)
            [[ -n $ssid ]] || return 1
            for s in "''${ssids[@]}"; do
              if [[ $s == "$ssid" ]]; then return 0; fi
            done
            return 1
          }

          # The watchdog would suspend straight away, and again after every resume.
          lowBattery() {
            [[ $(<'${ac}/online') == 0 ]] && (($(<'${bat}/capacity') < ${toString lowBattery}))
          }

          # Starting the unit mid-sleep would cancel the sleep it conflicts with,
          # and the network and the unit itself both change while going down.
          sleeping() {
            [[ $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PreparingForSleep) == "b true" ]]
          }

          active() { systemctl is-active --quiet caffeine.service; }
          caffeine() { systemctl --no-ask-password "$1" caffeine.service || echo "could not $1 caffeine" >&2; }

          check() {
            local m want=0
            sleeping && return
            m=$(mode)
            if [[ $m == on ]] || { [[ $m == auto ]] && onTrigger; }; then want=1; fi
            if ((want)) && ! active && ! lowBattery; then
              echo "mode $m, starting caffeine"
              caffeine start
            elif ((!want)) && active; then
              echo "mode $m, stopping caffeine"
              caffeine stop
            fi
          }

          # Any line is a cue to re-check: network changes, config and mode
          # writes (editors and atomic saves rename), the unit starting or
          # stopping, resume, and AC or battery changes for the low-battery
          # guard. Should one source die, the rest are killed so the read sees
          # EOF and systemd restarts us.
          exec 3< <(
            nmcli monitor &
            inotifywait -m -q -e close_write,moved_to --format '%w%f' "$(dirname "$conf")" "$state" '${dirOf activeFile}' &
            gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 &
            udevadm monitor --udev --subsystem-match=power_supply &
            wait -n
            mapfile -t pids < <(jobs -p)
            kill "''${pids[@]}" 2>/dev/null || true
          )
          loadConf
          check
          while IFS= read -r event <&3; do
            if [[ $event == "$conf" ]]; then loadConf; fi
            check
          done
          echo "an event source exited" >&2
          exit 1
        '';
      };
    in
    {
      home-manager.users.guillaume.systemd.user.services.caffeine-auto = {
        Unit.Description = "Caffeine mode: off, on, or on trigger Wi-Fi networks";
        Unit.After = [ "network.target" ];
        Service = {
          ExecStart = "${auto}/bin/caffeine-auto";
          Restart = "always";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };

      systemd.services.caffeine = {
        description = "Caffeine: ignore the lid switch";
        # Any sleep ends the mode, so the LED is back to the EC before it.
        conflicts = [ "sleep.target" ];
        before = [ "sleep.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch --who=caffeine --why=Caffeine --mode=block ${watchdog}/bin/caffeine-watchdog";
          ExecStartPost = markActive "1";
          ExecStopPost = [
            restoreLed
            (markActive "0")
          ];
        };
      };

      systemd.tmpfiles.rules = [
        "d ${dirOf activeFile} 0755 root root -"
        "f ${activeFile} 0644 root root - 0"
      ];

      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "caffeine.service" &&
              subject.user == "guillaume") {
            var verb = action.lookup("verb");
            if (verb == "start" || verb == "stop") return polkit.Result.YES;
          }
        });
      '';
    };
}
