// The system pill: the control centre behind a click, and beside it whatever
// state is worth carrying. The sliders are the pill's identity and always
// there - idle inhibit, caffeine and do-not-disturb are added next to them,
// never in their place. Notifications leave no trace on it.
//
// Mod+N reaches every bar through the notifs IPC handler, so the pill answers
// only on the focused output.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    required property string monitor

    interactive: true
    color: Quick.gearColor
    text: {
        const badges = [Config.glyph.controls];
        if (Quick.idleInhibit)
            badges.push(Config.glyph.idle);
        if (Quick.caffeine)
            badges.push(Config.glyph.caffeine);
        if (Notifs.dnd)
            badges.push(Config.glyph.dnd);
        return badges.join(" ");
    }
    tooltip: Notifs.dnd ? "Do not disturb" : "Notifications and settings"

    onClicked: panel.toggle()
    onRightClicked: Notifs.dismissAll()

    ControlCenter {
        id: panel

        target: root
    }

    Connections {
        target: Notifs

        function onCenterToggleRequested(): void {
            if (root.monitor === Niri.focusedOutput)
                panel.toggle();
        }
    }
}
