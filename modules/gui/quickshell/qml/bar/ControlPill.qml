// The system pill: unread count, the toggles that are on, and the control
// centre behind a click. A bell rather than a gear - it is the only glyph here
// that carries state, and the panel is mostly notifications.
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

    readonly property bool alerting: Notifs.unread > 0 && !Notifs.dnd

    interactive: true
    // Unread takes the tint over the power profile: the profile is a standing
    // state, the count is news.
    color: root.alerting ? Theme.yellow : Quick.gearColor
    text: {
        const badges = [];
        if (Quick.idleInhibit)
            badges.push(Config.glyph.idle);
        const bell = Notifs.dnd ? Config.glyph.dnd : Config.glyph.bell;
        badges.push(Notifs.unread > 0 ? bell + " " + Notifs.unread : bell);
        return badges.join(" ");
    }
    tooltip: Notifs.dnd ? "Do not disturb" : (Notifs.unread > 0 ? Notifs.unread + " new" : "Notifications and settings")

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
