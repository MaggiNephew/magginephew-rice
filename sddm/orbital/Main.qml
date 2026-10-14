// ============================================================
//  SDDM login -- the Orbital design (Orbital.qml, shared with the
//  orbital-lock screen in ~/.config/quickshell/lock) wired to SDDM.
// ============================================================
import QtQuick

Item {
    id: root
    width: 1920
    height: 1080

    // copy users / sessions out of SDDM's models
    property var users: []
    property var sessions: []
    property int lastUserIndex: 0

    Repeater {
        model: userModel
        delegate: Item {
            required property string name
            required property int index
            Component.onCompleted: {
                var u = root.users.slice();
                u[index] = name;
                root.users = u;
                if (name === userModel.lastUser) root.lastUserIndex = index;
            }
        }
    }
    Repeater {
        model: sessionModel
        delegate: Item {
            required property string name
            required property int index
            Component.onCompleted: {
                var s = root.sessions.slice();
                s[index] = name;
                root.sessions = s;
            }
        }
    }

    Orbital {
        id: orbital
        anchors.fill: parent
        background: Qt.resolvedUrl(config.background || "background.jpg")
        dim: Number(config.dim || 0.3)
        userNames: root.users
        userIndex: root.lastUserIndex
        sessionNames: root.sessions
        canSuspend: sddm.canSuspend
        canReboot: true      // always offered, like Ryoku; SDDM refuses if not allowed
        canPowerOff: true

        onLoginRequested: function (user, password) { sddm.login(user, password, orbital.sessionIndex); }
        onSuspendRequested: sddm.suspend()
        onRebootRequested: sddm.reboot()
        onPowerOffRequested: sddm.powerOff()

        Component.onCompleted: orbital.sessionIndex = Math.max(0, sessionModel.lastIndex)
    }

    Connections {
        target: sddm
        function onLoginFailed() { orbital.loginFailed("ACCESS DENIED"); }
        function onLoginSucceeded() { orbital.loginSucceeded(); }
    }
}
