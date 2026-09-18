// The system pill: the control centre behind a click, and beside it whatever
// state is worth carrying. The sliders are the pill's identity and always
// there - idle inhibit and notifications are added next to them, never in
// their place. Do-not-disturb is the one substitution: it is what the bell
// became, so it takes the bell's slot and keeps the count.
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
        const badges = [Config.glyph.controls];
        if (Quick.idleInhibit)
            badges.push(Config.glyph.idle);
        const bell = Notifs.dnd ? Config.glyph.dnd : Config.glyph.bell;
        if (Notifs.dnd || Notifs.unread > 0)
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
