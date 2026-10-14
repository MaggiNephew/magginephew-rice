// ============================================================
//  Orbital -- lock / login design over the black & white wallpaper
//
//  Adapted from the "clockwork / orbital" theme of qylock by Darkkal44
//  (https://github.com/Darkkal44/qylock), as shipped by Ryoku Linux.
//  GPL-3.0, see LICENSE-qylock. Font: Outfit (SIL Open Font License).
//
//  UI only. The host (shell.qml for the Quickshell lock, or the SDDM
//  Main.qml) does the authentication:
//    UI -> host:  loginRequested(user, password), rebootRequested(), ...
//    host -> UI:  loginFailed(message), loginSucceeded()
//    UI -> host:  unlockFinished()  once the unlock flourish has played
// ============================================================
import QtQuick
import QtQuick.Effects

Item {
    id: root

    // ---- inputs from the host ----
    property url background: ""
    property real dim: 0.5
    property var userNames: []          // login names; more than one shows a picker
    property int userIndex: 0
    property var sessionNames: []       // empty hides the session switch (lock screen)
    property int sessionIndex: 0
    property bool canSuspend: true
    property bool canReboot: true
    property bool canPowerOff: true
    property bool animateClock: true

    // ---- requests to the host ----
    signal loginRequested(string user, string password)
    signal suspendRequested()
    signal rebootRequested()
    signal powerOffRequested()
    signal unlockFinished()

    readonly property real s: height / 768
    readonly property string userName: userNames.length > 0 ? userNames[Math.min(userIndex, userNames.length - 1)] : ""

    // ---- palette: monochrome over the photo ----
    readonly property color mainText: "#ffffff"
    readonly property color dimText: "#8c8c8c"
    readonly property color subColor: "#9a9a9a"
    readonly property color pillColor: Qt.rgba(0.03, 0.03, 0.03, 0.82)
    readonly property color pillBorder: isWindup ? "#666666" : "#2e2e2e"
    readonly property color pillInnerLine: isWindup ? "#ffffff" : "#3a3a3a"
    readonly property color inputWaitColor: "#6a6a6a"
    readonly property real marginR: 80 * s

    FontLoader { id: outfit; source: Qt.resolvedUrl("Outfit-Black.ttf") }
    readonly property string font: outfit.status === FontLoader.Ready ? outfit.name : "sans-serif"

    // ---- time (60 fps only while the second ring needs to move smoothly) ----
    property int curH: 0
    property int curM: 0
    property int curS: 0
    property int curMS: 0
    property var today: new Date()
    readonly property real localTimeMS: curH * 3600000 + curM * 60000 + curS * 1000 + curMS
    function tick() {
        var d = new Date();
        curH = d.getHours(); curM = d.getMinutes(); curS = d.getSeconds(); curMS = d.getMilliseconds();
        if (d.getDate() !== today.getDate()) today = d;
    }
    Timer { interval: 16; running: root.animateClock && root.visible; repeat: true; onTriggered: root.tick() }
    Component.onCompleted: { tick(); focusTimer.start(); playLockReveal(); }
    Timer { id: focusTimer; interval: 300; onTriggered: passInput.forceActiveFocus() }
    function focusInput() { passInput.forceActiveFocus() }

    // ---- wind-up / unlock animation state ----
    property bool isWindup: false
    property bool authOk: false
    property real windupOffset: 0
    readonly property real windupProgress: windupOffset / 150000
    property real boomScale: 1.0
    property real boomOpacity: 0.0
    property real jitterX: 0
    property real jitterY: 0
    property real sparkIntensity: 0.0
    readonly property real smoothSecAngle: -((localTimeMS % 60000) / 60000.0) * 360.0 - windupOffset * 10.0
    readonly property real smoothMinAngle: -((localTimeMS % 3600000) / 3600000.0) * 360.0 - windupOffset * 5.0

    // (the old wind-up shake + sparks are gone: on success it goes straight into the black hole)
    NumberAnimation {
        id: windupAnim; target: root; property: "windupOffset"
        from: 0; to: 150000; duration: 1600; easing.type: Easing.InQuint
        onFinished: if (root.authOk) boom.start()
    }
    // ---- unlock: everything spirals into the black hole, then fades to black ----
    property real suck: 0.0                       // 0 = normal, 1 = fully swallowed
    readonly property real holeX: 40 * root.s     // = dial.cx (dial is anchored to the left edge)
    readonly property real holeY: height * 0.5    // = dial.cy
    // shared by the clock and the login panel (the wallpaper stays; the black hole grows over it)
    Scale {
        id: suckScale
        origin.x: root.holeX; origin.y: root.holeY
        xScale: Math.max(0.001, 1.0 - root.suck); yScale: xScale
    }
    Rotation {
        id: suckRot
        origin.x: root.holeX; origin.y: root.holeY
        angle: -root.suck * root.suck * 420       // accelerating spiral
    }
    ParallelAnimation {
        id: boom
        NumberAnimation { target: root; property: "suck"; from: 0; to: 1.0; duration: 1300; easing.type: Easing.InBack; easing.overshoot: 1.4 }
        SequentialAnimation {
            PauseAnimation { duration: 950 }
            NumberAnimation { target: root; property: "boomOpacity"; to: 1.0; duration: 350; easing.type: Easing.InQuad }
        }
        onFinished: root.unlockFinished()
    }
    // no answer at all: give the field back
    Timer { id: authWatchdog; interval: 12000; onTriggered: root.loginFailed("NO RESPONSE") }

    function startLogin() {
        if (isWindup) return;
        if (passInput.text.length === 0) { errText.text = ""; passInput.forceActiveFocus(); return; }
        errText.text = "";
        authOk = false;
        isWindup = true;            // locks the field + shows "UNLOCKING" while PAM checks
        authWatchdog.restart();
        loginRequested(userName, passInput.text);
    }
    function resetWindup() {
        windupAnim.stop(); boom.stop(); authWatchdog.stop();
        isWindup = false; authOk = false;
        windupOffset = 0; boomScale = 1.0; boomOpacity = 0.0; suck = 0;
        sparkIntensity = 0; jitterX = 0; jitterY = 0;
    }
    function loginFailed(message) {
        resetWindup();
        errText.text = (message || "ACCESS DENIED").toUpperCase();
        passInput.text = "";
        passInput.forceActiveFocus();
        shake.restart();
    }
    function loginSucceeded() {
        authWatchdog.stop();
        authOk = true;
        isWindup = true;
        boom.start();               // straight into the black hole
    }

    // ============================================================
    //  BACKGROUND: photo, dimmed, darker behind the dial and the login
    // ============================================================
    Rectangle { anchors.fill: parent; color: "black" }
    Image {
        anchors.fill: parent
        source: root.background
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        smooth: true
    }
    Rectangle { anchors.fill: parent; color: "black"; opacity: root.dim }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.7) }
            GradientStop { position: 0.4; color: Qt.rgba(0, 0, 0, 0.2) }
            GradientStop { position: 0.7; color: Qt.rgba(0, 0, 0, 0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.45) }
        }
    }

    // ============================================================
    //  BLACK HOLE (shaders/blackhole.frag) at the center of the dial;
    //  the minute/second rings orbit it. On unlock it grows and swallows the screen.
    //  Tunables: bhRadius (overall size), size (hole zoom), gain (brightness), fadeStart (soft edge)
    // ============================================================
    ShaderEffect {
        id: blackHole
        // grows from its normal size to well past the far screen edge, swallowing the wallpaper
        readonly property real baseR: 540 * root.s
        readonly property real fullR: Math.max(root.width, root.height) * 1.5
        readonly property real bhRadius: baseR + (fullR - baseR) * Math.max(0, root.suck)
        width: bhRadius * 2
        height: bhRadius * 2
        x: root.holeX - bhRadius
        y: root.holeY - bhRadius
        property real iTime: 0
        property real size: 0.55 + 0.5 * Math.max(0, root.suck)   // core widens to cover the screen
        property real gain: 0.9 + 0.9 * Math.sin(Math.PI * Math.max(0, Math.min(1, root.suck)))
        property real fadeStart: 0.72
        fragmentShader: Qt.resolvedUrl("shaders/blackhole.frag.qsb")
        blending: true
        FrameAnimation {
            running: blackHole.visible && root.visible
            // spins faster during the wind-up and the swallow
            onTriggered: blackHole.iTime += frameTime * (1.0 + root.windupProgress * 3.0 + root.suck * 6.0)
        }
    }

    // ============================================================
    //  ORBITAL CLOCK
    // ============================================================
    Item {
        id: blast
        anchors.fill: parent
        x: root.jitterX
        y: root.jitterY
        transform: [suckScale, suckRot]

        Item {
            id: dial
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 800 * root.s
            height: parent.height
            readonly property real cx: 40 * root.s
            readonly property real cy: height * 0.5
            readonly property real minR: 320 * root.s
            readonly property real secR: 480 * root.s

            // the pill where both rings pass through "now"
            Rectangle {
                id: pill
                z: 1
                x: dial.cx + 230 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 330 * root.s
                height: 90 * root.s
                radius: 45 * root.s
                color: root.pillColor
                border.color: root.pillBorder
                border.width: Math.max(1, 1 * root.s)
                Rectangle {
                    x: 170 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(1, 1 * root.s)
                    height: 35 * root.s
                    color: root.pillInnerLine
                }
            }

            // sparks during the wind-up
            Repeater {
                model: 60
                delegate: Rectangle {
                    z: 50
                    property real randA: Math.random() * 6.28
                    property real randV: 400 * root.s + Math.random() * 900 * root.s
                    x: (dial.cx + 400 * root.s) + Math.cos(randA) * (randV * root.sparkIntensity)
                    y: dial.cy + Math.sin(randA) * (randV * root.sparkIntensity)
                    width: (1 + Math.random() * 2) * root.s
                    height: (1 + 12 * root.sparkIntensity) * root.s
                    rotation: randA * 180 / Math.PI + 90
                    radius: width / 2
                    color: "white"
                    opacity: root.sparkIntensity * (Math.random() > 0.4 ? 1.0 : 0.2)
                    visible: root.sparkIntensity > 0
                }
            }

            // minute ring (inner) and second ring (outer)
            component Ring: Repeater {
                id: ring
                property real angle: 0
                property real radius: 100
                property real numberGap: 35
                property real majorLen: 18
                property real minorLen: 10
                property real majorWidth: 2
                property real numberSize: 22
                model: 60
                delegate: Item {
                    required property int index
                    z: 10
                    readonly property real base: index * 6
                    readonly property real relAngle: {
                        var a = (base + ring.angle) % 360;
                        if (a > 180) a -= 360;
                        if (a < -180) a += 360;
                        return a;
                    }
                    readonly property real spotlight: Math.max(0, 1.0 - Math.abs(relAngle) / 4.0)
                    readonly property bool isMajor: index % 5 === 0
                    readonly property real disp: (base + ring.angle) * Math.PI / 180
                    readonly property real tx: dial.cx + ring.radius * Math.cos(disp)
                    readonly property real ty: dial.cy + ring.radius * Math.sin(disp)
                    visible: tx > -600 * root.s && tx < 1800 * root.s
                    Rectangle {
                        x: parent.tx - width / 2
                        y: parent.ty - height / 2
                        width: (parent.isMajor ? ring.majorWidth : 1) * root.s
                        height: (parent.isMajor ? ring.majorLen : ring.minorLen) * root.s
                        color: Qt.rgba(1, 1, 1, parent.spotlight > 0 ? 1.0 : (parent.isMajor ? 0.45 : 0.22))
                        rotation: parent.disp * 180 / Math.PI + 90
                    }
                    Text {
                        visible: parent.isMajor
                        readonly property real nRad: ring.radius - ring.numberGap * root.s
                        x: dial.cx + nRad * Math.cos(parent.disp) - width / 2
                        y: dial.cy + nRad * Math.sin(parent.disp) - height / 2
                        text: String(parent.index).padStart(2, "0")
                        font.family: root.font
                        font.pixelSize: ring.numberSize * root.s
                        font.weight: parent.spotlight > 0.5 ? Font.Bold : Font.Normal
                        color: Qt.rgba(1, 1, 1, parent.spotlight > 0 ? (0.45 + parent.spotlight * 0.55) : 0.35)
                        rotation: parent.disp * 180 / Math.PI
                    }
                }
            }
            Ring { angle: root.smoothMinAngle; radius: dial.minR; numberGap: 35; majorLen: 18; minorLen: 10; majorWidth: 2; numberSize: 22 }
            Ring { angle: root.smoothSecAngle; radius: dial.secR; numberGap: 30; majorLen: 13; minorLen: 8; majorWidth: 1.5; numberSize: 16 }

            // big hour
            Text {
                anchors.right: pill.left
                anchors.rightMargin: 40 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.curH).padStart(2, "0")
                font.family: root.font
                font.pixelSize: 110 * root.s
                font.weight: Font.Black
                color: root.mainText
            }
            // date
            Column {
                anchors.left: pill.right
                anchors.leftMargin: 110 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5 * root.s
                Text {
                    text: Qt.formatDate(root.today, "dd MMM yyyy").toUpperCase()
                    font.family: root.font
                    font.pixelSize: 13 * root.s
                    font.letterSpacing: 4 * root.s
                    color: root.subColor
                }
                Text {
                    text: Qt.formatDate(root.today, "dddd").toUpperCase()
                    font.family: root.font
                    font.pixelSize: 18 * root.s
                    font.letterSpacing: 8 * root.s
                    font.weight: Font.Bold
                    color: root.mainText
                }
            }
        }
    }

    // fade to black at the end of the swallow (was a white flash)
    Rectangle { anchors.fill: parent; color: "black"; opacity: root.boomOpacity; z: 9999 }

    // ============================================================
    //  HUD: actions (top right) + login (bottom right)
    // ============================================================
    component Action: Item {
        id: act
        property string label: ""
        signal clicked()
        width: actTxt.width + 20 * root.s
        height: 15 * root.s
        Text {
            id: actTxt
            anchors.right: parent.right
            anchors.rightMargin: actMouse.containsMouse ? 15 * root.s : 0
            text: act.label.toUpperCase()
            color: actMouse.containsMouse ? root.mainText : root.dimText
            font.family: root.font
            font.pixelSize: 10 * root.s
            font.letterSpacing: 3 * root.s
            Behavior on color { ColorAnimation { duration: 200 } }
            Behavior on anchors.rightMargin { NumberAnimation { duration: 200 } }
        }
        Text {
            text: "✦"
            anchors.left: actTxt.right
            anchors.leftMargin: 4 * root.s
            anchors.verticalCenter: actTxt.verticalCenter
            color: root.mainText
            opacity: actMouse.containsMouse ? 1 : 0
            font.pixelSize: 8 * root.s
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
        MouseArea {
            id: actMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: act.clicked()
        }
    }
    component Sep: Rectangle {
        width: Math.max(1, 1 * root.s)
        height: 10 * root.s
        color: "#444444"
        anchors.verticalCenter: parent.verticalCenter
    }

    Item {
        id: hud
        anchors.fill: parent
        opacity: Math.max(0, 1.0 - root.suck * 1.4)
        transform: [suckScale, suckRot]

        Row {
            anchors.right: parent.right
            anchors.rightMargin: root.marginR
            anchors.top: parent.top
            anchors.topMargin: 50 * root.s
            spacing: 25 * root.s

            Action {
                visible: root.sessionNames.length > 0
                label: root.sessionNames.length > 0 ? root.sessionNames[root.sessionIndex] : ""
                onClicked: root.sessionIndex = (root.sessionIndex + 1) % root.sessionNames.length
            }
            // a separator only between two visible actions
            Sep { visible: root.sessionNames.length > 0 && (root.canSuspend || root.canReboot || root.canPowerOff) }
            Action { visible: root.canSuspend; label: "Suspend"; onClicked: root.suspendRequested() }
            Sep { visible: root.canSuspend && (root.canReboot || root.canPowerOff) }
            Action { visible: root.canReboot; label: "Reboot"; onClicked: root.rebootRequested() }
            Sep { visible: root.canReboot && root.canPowerOff }
            Action { visible: root.canPowerOff; label: "Shutdown"; onClicked: root.powerOffRequested() }
        }

        Column {
            id: loginPanel
            anchors.right: parent.right
            anchors.rightMargin: root.marginR
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 80 * root.s
            width: 350 * root.s
            spacing: 8 * root.s

            // user picker (opens upward) + user name
            property bool menuOpen: false
            Item {
                width: parent.width
                height: 32 * root.s
                z: 5000

                Column {
                    anchors.bottom: userLabel.top
                    anchors.bottomMargin: 15 * root.s
                    anchors.right: parent.right
                    spacing: 6 * root.s
                    visible: loginPanel.menuOpen
                    Repeater {
                        model: root.userNames
                        delegate: Text {
                            required property string modelData
                            required property int index
                            anchors.right: parent.right
                            text: modelData.toUpperCase()
                            font.family: root.font
                            font.pixelSize: 13 * root.s
                            font.letterSpacing: 2 * root.s
                            color: root.userIndex === index || itemMouse.containsMouse ? root.mainText : "#555555"
                            MouseArea {
                                id: itemMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.userIndex = index; loginPanel.menuOpen = false; passInput.forceActiveFocus(); }
                            }
                        }
                    }
                }
                Text {
                    id: userLabel
                    anchors.right: parent.right
                    anchors.rightMargin: (userMouse.containsMouse || loginPanel.menuOpen) ? 25 * root.s : 0
                    text: (root.userName || "USER").toUpperCase()
                    font.family: root.font
                    font.pixelSize: 18 * root.s
                    font.weight: Font.Bold
                    font.letterSpacing: 8 * root.s
                    color: (userMouse.containsMouse || loginPanel.menuOpen) ? root.mainText : "#bdbdbd"
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on anchors.rightMargin { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
                Text {
                    text: "✦"
                    anchors.left: userLabel.right
                    anchors.leftMargin: 8 * root.s
                    anchors.verticalCenter: userLabel.verticalCenter
                    color: root.mainText
                    opacity: (userMouse.containsMouse || loginPanel.menuOpen) ? 1 : 0
                    font.pixelSize: 12 * root.s
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
                MouseArea {
                    id: userMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.userNames.length > 1
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: loginPanel.menuOpen = !loginPanel.menuOpen
                }
            }

            // password: one ✦ star per typed character, then a needle cursor.
            // The real text stays in a hidden password-mode field (never shown, can't be copied).
            Item {
                width: parent.width
                height: 30 * root.s
                clip: true      // long passwords scroll off to the left
                TextInput {
                    id: passInput
                    anchors.fill: parent
                    echoMode: TextInput.Password
                    color: "transparent"
                    selectionColor: "transparent"
                    selectedTextColor: "transparent"
                    font.pixelSize: 14 * root.s
                    horizontalAlignment: TextInput.AlignRight
                    verticalAlignment: TextInput.AlignVCenter
                    focus: true
                    enabled: !root.isWindup
                    cursorVisible: false
                    cursorDelegate: Item { width: 0; height: 0 }
                    Keys.onReturnPressed: root.startLogin()
                    Keys.onEnterPressed: root.startLogin()
                    Keys.onEscapePressed: { text = ""; errText.text = ""; }

                    onTextChanged: if (text.length > 0) errText.text = ""

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8 * root.s
                        Repeater {
                            model: passInput.text.length
                            // a star per character (same ✦ as next to the user name): fades + pops in when typed
                            delegate: Text {
                                text: "✦"
                                color: "#cfcfcf"
                                font.pixelSize: 16 * root.s
                                anchors.verticalCenter: parent.verticalCenter
                                opacity: 0
                                scale: 0.6
                                NumberAnimation on opacity { from: 0; to: 1; duration: 180 }
                                NumberAnimation on scale { from: 0.6; to: 1; duration: 180; easing.type: Easing.OutBack }
                            }
                        }
                        Rectangle {
                            id: needle
                            width: Math.max(1, 1.5 * root.s)
                            height: 12 * root.s
                            color: root.mainText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: passInput.activeFocus && passInput.text.length > 0
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: needle.visible
                                NumberAnimation { from: 1; to: 0.1; duration: 450 }
                                NumberAnimation { from: 0.1; to: 1; duration: 450 }
                            }
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "TYPE PASSWORD"
                        font.family: root.font
                        font.pixelSize: 10 * root.s
                        font.letterSpacing: 4 * root.s
                        color: root.inputWaitColor
                        opacity: passInput.text.length === 0 ? 0.9 : 0
                        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.InOutSine } }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: passInput.forceActiveFocus()
                }
            }

            // unlock button
            Item {
                width: parent.width
                height: 40 * root.s
                Text {
                    id: unlockBtn
                    anchors.right: parent.right
                    anchors.rightMargin: unlockMouse.containsMouse ? 25 * root.s : 0
                    text: root.isWindup ? "UNLOCKING" : "UNLOCK"
                    font.family: root.font
                    font.pixelSize: 11 * root.s
                    font.letterSpacing: 4 * root.s
                    font.weight: Font.Bold
                    color: unlockMouse.containsMouse || passInput.text.length > 0 ? root.mainText : root.dimText
                    Behavior on anchors.rightMargin { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
                Text {
                    text: "✦"
                    anchors.left: unlockBtn.right
                    anchors.leftMargin: 8 * root.s
                    anchors.verticalCenter: unlockBtn.verticalCenter
                    color: root.mainText
                    opacity: unlockMouse.containsMouse ? 1 : 0
                    font.pixelSize: 10 * root.s
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
                MouseArea {
                    id: unlockMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startLogin()
                }
            }

            Text {
                id: errText
                width: parent.width
                height: 15 * root.s
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignBottom
                text: ""
                color: root.mainText
                font.family: root.font
                font.pixelSize: 10 * root.s
                font.letterSpacing: 2 * root.s
                font.weight: Font.Bold
            }
        }
    }

    SequentialAnimation {
        id: shake
        NumberAnimation { target: loginPanel; property: "anchors.rightMargin"; to: root.marginR + 10 * root.s; duration: 50; easing.type: Easing.InOutSine }
        NumberAnimation { target: loginPanel; property: "anchors.rightMargin"; to: root.marginR - 10 * root.s; duration: 50; easing.type: Easing.InOutSine }
        NumberAnimation { target: loginPanel; property: "anchors.rightMargin"; to: root.marginR + 6 * root.s; duration: 50; easing.type: Easing.InOutSine }
        NumberAnimation { target: loginPanel; property: "anchors.rightMargin"; to: root.marginR; duration: 50; easing.type: Easing.InOutSine }
    }

    // ============================================================
    //  CIRCULAR REVEAL when the lock appears
    // ============================================================
    readonly property real revealDiag: Math.sqrt(width * width + height * height)
    property real revealR: 0
    property bool revealActive: false

    Rectangle {
        id: curtain
        anchors.fill: parent
        color: "black"
        visible: false
        layer.enabled: root.revealActive
    }
    Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: root.revealActive
        Rectangle {
            anchors.centerIn: parent
            width: root.revealR * 2
            height: width
            radius: width / 2
            color: "white"
        }
    }
    MultiEffect {
        anchors.fill: parent
        z: 20000
        visible: root.revealActive
        source: curtain
        maskEnabled: true
        maskInverted: true
        maskSource: revealMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
    NumberAnimation {
        id: revealIn
        target: root; property: "revealR"
        from: 0; to: root.revealDiag / 2 + 10; duration: 1150; easing.type: Easing.InOutCubic
        onFinished: root.revealActive = false
    }
    function playLockReveal() {
        revealR = 0;
        revealActive = true;
        revealIn.restart();
    }
}
