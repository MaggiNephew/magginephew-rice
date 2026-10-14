// ============================================================
//  Orbital lock -- Quickshell session lock (Ryoku-style design)
//  Started by ~/.local/bin/orbital-lock (SUPER+L and hypridle).
//
//  The compositor keeps the session locked until this client sets
//  `locked: false`, so a crash can never unlock the screen; the launcher
//  restarts the client (Hyprland has misc.allow_session_lock_restore on).
//
//  ORBITAL_TEST=1 shows the design in a normal window instead of locking:
//  the password check is real, but nothing is locked and the power
//  buttons are disabled. Esc closes it.
// ============================================================
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam

ShellRoot {
    id: shell

    readonly property bool testMode: Quickshell.env("ORBITAL_TEST") === "1"
    readonly property string user: Quickshell.env("USER")
    readonly property string wallpaper: "file://" + Quickshell.env("HOME") + "/Pictures/wallpapers/lock-mono.jpg"

    // every Orbital (one per monitor) listens to these
    signal authFailed(string message)
    signal authSucceeded()

    // ---- password check: the system "login" PAM stack ----
    // (what /etc/pam.d/hyprlock pointed to; used directly so this keeps
    //  working without the hyprlock package)
    property string pendingPassword: ""
    PamContext {
        id: pam
        configDirectory: "/etc/pam.d"
        config: "login"
        user: shell.user

        onPamMessage: {
            if (responseRequired) {
                respond(shell.pendingPassword);
                shell.pendingPassword = "";
            }
        }
        onCompleted: function (result) {
            shell.pendingPassword = "";
            if (result === PamResult.Success) shell.authSucceeded();
            else shell.authFailed(result === PamResult.MaxTries ? "TOO MANY TRIES" : "ACCESS DENIED");
        }
        onError: function (error) {
            shell.pendingPassword = "";
            shell.authFailed("AUTH ERROR");
        }
    }

    function tryLogin(password) {
        if (pam.active) return;
        pendingPassword = password;
        if (!pam.start()) {
            pendingPassword = "";
            authFailed("AUTH ERROR");
        }
    }

    // ---- unlock: release the compositor lock first, then exit ----
    property bool unlocking: false
    function unlock() {
        if (unlocking) return;
        unlocking = true;
        if (testMode) {
            console.log("orbital-lock test: password accepted");
            Qt.quit();
            return;
        }
        lock.locked = false;
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 150; onTriggered: Qt.quit() }

    function power(argv) {
        if (testMode) { console.log("orbital-lock test: would run " + argv.join(" ")); return; }
        Quickshell.execDetached(argv);
    }

    // one design instance, wired to the auth above
    component Design: Orbital {
        id: design
        background: shell.wallpaper
        dim: 0.3
        userNames: [shell.user]
        canSuspend: true
        canReboot: true
        canPowerOff: true
        onLoginRequested: function (user, password) { shell.tryLogin(password); }
        onUnlockFinished: shell.unlock()
        onSuspendRequested: shell.power(["systemctl", "suspend"])
        onRebootRequested: shell.power(["systemctl", "reboot"])
        onPowerOffRequested: shell.power(["systemctl", "poweroff"])
        Connections {
            target: shell
            function onAuthFailed(message) { design.loginFailed(message); }
            function onAuthSucceeded() { design.loginSucceeded(); }
        }
    }

    // ---- the real lock: one surface per monitor ----
    WlSessionLock {
        id: lock
        locked: !shell.testMode
        WlSessionLockSurface {
            color: "black"
            Design { anchors.fill: parent }
        }
    }

    // ---- preview window (ORBITAL_TEST=1) ----
    // a full-screen overlay on the focused monitor, like the real lock but not a lock
    LazyLoader {
        active: shell.testMode
        PanelWindow {
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "black"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "orbital-lock-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            Design { anchors.fill: parent }
            Shortcut { sequence: "Esc"; onActivated: Qt.quit() }
        }
    }
}
