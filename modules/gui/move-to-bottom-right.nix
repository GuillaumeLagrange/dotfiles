{
  pkgs,
}:

let
  swaymsg = "${pkgs.sway}/bin/swaymsg";
  bc = "${pkgs.bc}/bin/bc";
in
pkgs.writeShellScriptBin "move-to-bottom-right.sh" ''
  PERCENT="0.30"

  # Get the id of the focused window
  window_id=$(${swaymsg} -t get_tree | jq '.. | select(.type?) | select(.focused==true).id')

  if [ -z "$window_id" ]; then
    echo "No window found."
    exit 1
  fi

  # Get the screen dimensions
  screen_width=$(${swaymsg} --t get_outputs | jq '.[] | select(.focused).rect.width')
  screen_height=$(${swaymsg} -t get_outputs | jq '.[] | select(.focused).rect.height')

  # Get the current window dimensions
  window_rect=$(${swaymsg} -t get_tree | jq '.. | select(.type?) | select(.focused==true).rect')
  window_width=$(echo "$window_rect" | jq '.width')
  window_height=$(echo "$window_rect" | jq '.height')

  # Calculate the new width and height while keeping the aspect ratio
  new_width=$(echo "$screen_width * $PERCENT / 1" | ${bc})
  new_height=$(echo "$window_height * $new_width / $window_width" | ${bc})

  # Calculate the position to move the window to the bottom-right corner
  x_position=$(echo "$screen_width - $new_width / 1 - 12" | ${bc})
  # TODO: Manage extremely high ratios not working because y becomes negative
  y_position=$(echo "$screen_height - $new_height / 1 - 32" | ${bc})

  # Resize and reposition the window
  ${swaymsg} resize set width "$new_width" height "$new_height"
  ${swaymsg} move position "$x_position" "$y_position"
''
