// ============================================================
//  Quickshell shell -- monochrome rice (black / gray / white)
//  bar + launcher + notification center + notification popups
// ============================================================
pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Services.Mpris
import Quickshell.Services.SystemTray
import Quickshell.Bluetooth

ShellRoot {
    id: root

    // ---- monochrome palette ----
    readonly property color cBg:       "#0a0a0a"
    readonly property color cBg1:      "#131313"
    readonly property color cSurface:  "#1f1f1f"
    readonly property color cSurface2: "#2a2a2a"
    readonly property color cOutline:  "#333333"
    readonly property color cMuted:    "#777777"
    readonly property color cFg2:      "#999999"
    readonly property color cFg:       "#e2e2e2"
    readonly property color cWhite:    "#ffffff"

    readonly property string fontFamily: "3270 Nerd Font Mono"

    // ---- notification server ----
    NotificationServer {
        id: notifServer
        actionsSupported: true
        imageSupported: true
        persistenceSupported: true

        onNotification: function(notification) {
            notification.tracked = true;
            root.showToast(notification);
        }
    }

    function clearNotifications() {
        var ns = notifServer.trackedNotifications.values.slice();
        for (var i = 0; i < ns.length; i++)
            if (ns[i]) ns[i].dismiss();
    }

    // ============================================================
    //  BAR
    // ============================================================

    // nerd-font glyph from a code point (md-* icons sit above U+FFFF)
    function g(cp) { return String.fromCodePoint(cp); }

    function roman(n) {
        if (n <= 0) return String(n);
        var vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
        var syms = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"];
        var out = "";
        for (var i = 0; i < vals.length; i++)
            while (n >= vals[i]) { out += syms[i]; n -= vals[i]; }
        return out;
    }

    function launch(cmd) {
        Quickshell.execDetached(["bash", "-c", cmd]);
    }

    readonly property var modeNames: ({
        "low-power": "Eco",
        "quiet": "Quiet",
        "balanced": "Balanced",
        "balanced-performance": "Performance",
        "performance": "Turbo"
    })

    // ---- live stats (scripts/bar-stats.sh prints one JSON line every 2 s) ----
    QtObject {
        id: stats
        property int cpu: 0
        property int memUsed: 0
        property int memTotal: 1
        property int temp: 0
        property string profile: ""
        property int brightness: -1
        property string netType: "none"
        property string netName: ""
        property int netSignal: 0
        property string vpnProvider: ""    // "" = no VPN connected
        property string vpnServer: ""
        property int vpnSince: 0           // unix time the VPN came up (0 = off)
        property string vpnIp: ""          // exit IP (looked up once per connect)
        property string vpnLocation: ""    // "City, CC" of the exit IP
        property string cam: ""            // apps with /dev/video* open, comma separated
    }

    Process {
        id: statsProc
        command: [Quickshell.shellDir + "/scripts/bar-stats.sh"]
        running: true
        stdout: SplitParser {
            onRead: function (line) {
                try {
                    var d = JSON.parse(line);
                    for (var k in d) stats[k] = d[k];
                } catch (e) {}
            }
        }
        // restart the feed if it ever dies
        onExited: statsRestart.start()
    }
    Timer {
        id: statsRestart
        interval: 3000
        onTriggered: statsProc.running = true
    }

    // one-shot command runner that refreshes the stats feed afterwards
    Process { id: actionProc }
    function run(argv) {
        actionProc.command = argv;
        actionProc.running = true;
    }

    // ---- audio / battery / media ----
    // the `music` command's background player (mpv + mpv-mpris); does nothing if not installed
    Timer {
        running: true
        interval: 1500
        onTriggered: Quickshell.execDetached(["sh", "-c",
            "[ -x \"$HOME/.local/bin/music\" ] && exec \"$HOME/.local/bin/music\" daemon"])
    }
    PwObjectTracker { objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource] }
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var battery: UPower.displayDevice
    // player picked in the media popup (null = follow whatever is playing)
    property var mediaSel: null
    readonly property var player: {
        var ps = Mpris.players.values;
        if (mediaSel !== null && ps.indexOf(mediaSel) >= 0) return mediaSel;
        for (var i = 0; i < ps.length; i++)
            if (ps[i].isPlaying) return ps[i];
        return ps.length > 0 ? ps[0] : null;
    }
    // MPRIS position is not pushed by players; poll it while something plays
    Timer {
        interval: mediaPopup.visible ? 500 : 2000
        running: root.player !== null && root.player.isPlaying
        repeat: true
        triggeredOnStart: true
        onTriggered: if (root.player) root.player.positionChanged()
    }
    function fmtTime(sec) {
        if (!(sec > 0)) return "0:00";
        sec = Math.floor(sec);
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s2 = sec % 60;
        var ss = (s2 < 10 ? "0" : "") + s2;
        return h > 0 ? h + ":" + (m < 10 ? "0" : "") + m + ":" + ss : m + ":" + ss;
    }
    // real output devices (speakers, headphones, HDMI, bluetooth), not app streams
    readonly property var audioSinks: Pipewire.nodes.values.filter(function (n) {
        return n.isSink && !n.isStream && n.audio !== null;
    })
    function sinkIcon(n) {
        var k = ((n && n.name) || "") + " " + ((n && n.description) || "");
        if (/bluez|bluetooth/i.test(k)) return root.g(0xF00B0);
        if (/hdmi|displayport/i.test(k)) return root.g(0xF0379);
        if (/headphone|headset|usb/i.test(k)) return root.g(0xF02CB);
        return root.g(0xF04C3);
    }
    function volIcon(v, muted) {
        if (muted || v <= 0) return root.g(0xF0581);
        return v < 0.34 ? root.g(0xF057F) : v < 0.67 ? root.g(0xF0580) : root.g(0xF057E);
    }
    // audio visualizer for the media popup: cava in raw mode (skipped if cava is missing)
    property var cavaBars: []
    Process {
        id: cavaProc
        running: root.player !== null && root.player.isPlaying
        command: ["sh", "-c", "command -v cava >/dev/null 2>&1 || exit 0; exec cava -p \"$1\"",
                  "sh", Quickshell.shellDir + "/scripts/cava-media.conf"]
        stdout: SplitParser {
            onRead: function (line) {
                var a = line.split(";");
                if (a.length && a[a.length - 1] === "") a.pop();
                root.cavaBars = a.map(Number);
            }
        }
        onRunningChanged: if (!running) root.cavaBars = []
    }
    // tray items that STAY on the bar (matched against the item's id + title);
    // every other app (Zoom, JetBrains Toolbox, Claude, Steam, …) goes in the
    // hidden-icons flyout. Proton VPN has its own row in the flyout instead.
    // nothing stays on the bar any more: the stats pill shows the network itself
    readonly property var barTrayRe: /(?!)/
    function trayKey(it) { return (it.id || "") + " " + (it.title || ""); }
    function onBar(it) {
        return it !== null && it !== root.protonTray && barTrayRe.test(trayKey(it));
    }
    function inFlyout(it) {
        return it !== null && it !== root.protonTray && !barTrayRe.test(trayKey(it));
    }

    // ---- VPN details ----
    property real nowSec: Date.now() / 1000
    Timer {
        interval: 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.nowSec = Date.now() / 1000
    }
    function fmtUptime(sec) {
        if (sec < 60) return "just now";
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
        return h > 0 ? h + "h " + m + "m" : m + "m";
    }
    readonly property string vpnUptime: stats.vpnSince > 0 ? fmtUptime(nowSec - stats.vpnSince) : ""
    // "Zürich, CH  ·  185.159.157.12  ·  1h 12m"
    readonly property string vpnDetails: [stats.vpnLocation, stats.vpnIp, vpnUptime]
        .filter(function (x) { return x !== ""; }).join("  ·  ")

    // Proton VPN's tray item; its icon is reused by the VPN pill
    readonly property var protonTray: {
        var its = SystemTray.items.values;
        for (var i = 0; i < its.length; i++) {
            var it = its[i];
            if (/proton/i.test((it.id || "") + " " + (it.title || ""))) return it;
        }
        return null;
    }
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property int btConnected: {
        var n = 0, ds = Bluetooth.devices.values;
        for (var i = 0; i < ds.length; i++)
            if (ds[i].connected) n++;
        return n;
    }

    // ---- reusable pill: icon + optional label, click / right-click / scroll ----
    component Pill: Rectangle {
        id: pill
        property string icon: ""
        property string iconSource: ""   // image icon (e.g. a tray icon); overrides `icon`
        property string label: ""
        property string tip: ""
        property bool accent: false
        property bool wide: false        // full-width row with left-aligned content (flyout)
        property bool compact: false     // smaller row for the flyout
        property color iconColor: accent ? root.cBg : root.cWhite
        signal clicked()
        signal rightClicked()
        signal middleClicked()
        signal scrolled(int delta)

        implicitWidth: pillRow.implicitWidth + 20
        height: compact ? 22 : 30
        radius: compact ? 6 : 8
        color: accent ? root.cWhite : (pillMouse.containsMouse ? root.cSurface2 : root.cSurface)
        border.color: accent ? root.cWhite : (pillMouse.containsMouse ? root.cMuted : root.cOutline)
        border.width: 1
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
            id: pillRow
            anchors.centerIn: pill.wide ? undefined : parent
            anchors.left: pill.wide ? parent.left : undefined
            anchors.leftMargin: pill.compact ? 8 : 10
            anchors.verticalCenter: pill.wide ? parent.verticalCenter : undefined
            spacing: pill.compact ? 7 : pill.wide ? 10 : 6
            readonly property int iconPx: pill.compact ? 13 : 17
            Image {
                visible: pill.iconSource !== ""
                source: pill.iconSource
                width: pillRow.iconPx
                height: pillRow.iconPx
                sourceSize.width: pillRow.iconPx
                sourceSize.height: pillRow.iconPx
                smooth: true
                anchors.verticalCenter: parent.verticalCenter
                layer.enabled: true
                layer.effect: MultiEffect { saturation: -1.0 }
            }
            Text {
                text: pill.icon
                visible: text !== "" && pill.iconSource === ""
                // fixed width in flyout rows so the labels line up
                width: pill.wide ? pillRow.iconPx : implicitWidth
                horizontalAlignment: Text.AlignHCenter
                color: pill.iconColor
                font.family: root.fontFamily
                font.pixelSize: pill.compact ? 13 : 16
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: pill.label
                visible: text !== ""
                color: pill.accent ? root.cBg : root.cFg
                font.family: root.fontFamily
                font.pixelSize: pill.compact ? 11 : 14
                font.bold: pill.accent
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: pillMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onClicked: function (mouse) {
                if (mouse.button === Qt.RightButton) pill.rightClicked();
                else if (mouse.button === Qt.MiddleButton) pill.middleClicked();
                else pill.clicked();
            }
            onWheel: function (wheel) { pill.scrolled(wheel.angleDelta.y > 0 ? 1 : -1); }
            onContainsMouseChanged: {
                if (containsMouse && pill.tip !== "") tooltip.showFor(pill, pill.tip);
                else if (tooltip.target === pill) tooltip.hide();
            }
        }
    }

    // ---- privacy: apps that have the microphone / camera open ----
    function linkUsers(want) {
        var out = [], lgs = Pipewire.linkGroups.values;
        for (var i = 0; i < lgs.length; i++) {
            var s = lgs[i].source, t = lgs[i].target;
            // a hardware source (not an app, not a speaker monitor) feeding an app
            if (!s || !t || s.isStream || s.isSink || !t.isStream) continue;
            var isCam = s.audio === null && /v4l2|video|camera|libcamera/i.test(s.name || "");
            if ((want === "mic") !== (s.audio !== null) || (want === "cam" && !isCam)) continue;
            var nm = t.description || t.nickname || t.name || "app";
            if (out.indexOf(nm) < 0) out.push(nm);
        }
        return out;
    }
    readonly property var micApps: linkUsers("mic")
    readonly property var camApps: {
        var out = linkUsers("cam"), ps = stats.cam ? stats.cam.split(",") : [];
        for (var i = 0; i < ps.length; i++)
            if (out.indexOf(ps[i]) < 0) out.push(ps[i]);
        return out;
    }

    // ---- music line either side of the clock: one smooth line through the free space,
    //      waving with the music (bass next to the clock), flat when nothing plays;
    //      it runs 8px under the media pill, the clock and the stats pills (they sit on top) ----
    component ClockWave: Canvas {
        id: cw
        property bool mirrored: false   // left side: the line runs from the clock leftwards
        property var levels: []         // one channel, bass first (0..100)
        property var cur: []            // smoothed levels actually drawn (0..1)
        height: 30
        anchors.verticalCenter: parent.verticalCenter
        visible: width > 30 && root.player !== null
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }

        onLevelsChanged: {
            var n = levels.length, c = cur.slice(0, n);
            for (var i = 0; i < n; i++) {
                var t = Math.max(0, Math.min(1, (levels[i] || 0) / 100)), v = c[i] || 0;
                c[i] = v + (t - v) * 0.45;            // ease towards the new value
            }
            cur = c;
            requestPaint();
        }
        // when the music stops, let the wave settle back to a flat line
        Timer {
            interval: 33
            repeat: true
            running: cw.levels.length === 0 && cw.cur.length > 0
            onTriggered: {
                var c = cw.cur.map(function (v) { return v * 0.8; });
                cw.cur = Math.max.apply(null, c) < 0.01 ? [] : c;
                cw.requestPaint();
            }
        }
        onWidthChanged: requestPaint()
        onVisibleChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, mid = height / 2, amp = height / 2 - 3, n = cur.length;
            var pts = [];
            if (n === 0) {
                pts = [[0, mid], [w, mid]];
            } else {
                var steps = n + 1;
                for (var i = 0; i <= steps; i++) {
                    var t = i / steps;                                  // 0 at the clock, 1 at the far end
                    var lvl = i > 0 && i <= n ? cur[i - 1] : 0;
                    var taper = Math.min(1, t * 8) * Math.min(1, (1 - t) * 2.5);
                    var y = mid + (i % 2 ? -1 : 1) * lvl * amp * taper; // alternate up / down -> a wave
                    pts.push([mirrored ? w - t * w : t * w, y]);
                }
            }
            ctx.strokeStyle = root.cFg2;
            ctx.lineWidth = 1.6;
            ctx.lineCap = "butt";
            ctx.lineJoin = "round";
            ctx.beginPath();
            ctx.moveTo(pts[0][0], pts[0][1]);
            for (var k = 1; k < pts.length - 1; k++) {
                var xc = (pts[k][0] + pts[k + 1][0]) / 2, yc = (pts[k][1] + pts[k + 1][1]) / 2;
                ctx.quadraticCurveTo(pts[k][0], pts[k][1], xc, yc);
            }
            ctx.lineTo(pts[pts.length - 1][0], pts[pts.length - 1][1]);
            ctx.stroke();
        }
    }

    // ============================================================
    //  START MENU data: pinned apps (saved), recent files, tools
    // ============================================================
    // first-run pins: matched against installed apps (desktop id, then name)
    readonly property var pinDefaults: ["brave", "kitty", "dolphin", "zed", "pycharm", "anthropic|claude",
                                        "vesktop|discord", "steam", "blender", "proton.*vpn|protonvpn", "btop", "nvim"]
    property var pins: []            // desktop ids, saved in ~/.config/quickshell/start-menu.json
    FileView {
        id: pinStore
        path: Quickshell.env("HOME") + "/.config/quickshell/start-menu.json"
        printErrors: false
        onLoaded: {
            try {
                var d = JSON.parse(text());
                if (d && d.pins && d.pins.length !== undefined) root.pins = d.pins;
            } catch (e) {}
        }
    }
    function findApp(pattern) {
        var apps = DesktopEntries.applications.values, re = new RegExp(pattern, "i");
        for (var i = 0; i < apps.length; i++) if (re.test(apps[i].id || "")) return apps[i];
        for (var j = 0; j < apps.length; j++) if (re.test(apps[j].name || "")) return apps[j];
        return null;
    }
    readonly property var allApps: DesktopEntries.applications.values
        .filter(function (e) { return e && e.noDisplay !== true; })
        .sort(function (a, b) { return String(a.name).toLowerCase().localeCompare(String(b.name).toLowerCase()); })
    readonly property var pinnedApps: {
        var apps = root.allApps, out = [], i, e;
        if (root.pins.length > 0) {
            for (i = 0; i < root.pins.length; i++) {
                e = null;
                for (var k = 0; k < apps.length; k++) if (apps[k].id === root.pins[i]) { e = apps[k]; break; }
                if (e) out.push(e);
            }
        } else {
            for (i = 0; i < root.pinDefaults.length; i++) {
                e = root.findApp(root.pinDefaults[i]);
                if (e && out.indexOf(e) < 0) out.push(e);
            }
        }
        return out.slice(0, 18);
    }
    function isPinned(e) { return root.pinnedApps.indexOf(e) >= 0; }
    function togglePin(e) {
        if (!e) return;
        var ids = root.pinnedApps.map(function (x) { return x.id; });
        var i = ids.indexOf(e.id);
        if (i >= 0) ids.splice(i, 1); else ids.push(e.id);
        root.pins = ids;
        pinStore.setText(JSON.stringify({ pins: ids }, null, 2) + "\n");
    }
    function startApp(e) {
        if (!e) return;
        launcher.usage[e.id] = (launcher.usage[e.id] || 0) + 1;
        if (e.runInTerminal) Quickshell.execDetached(["kitty", "-e"].concat(e.command));
        else e.execute();
    }

    // ---- recent files (GTK / Qt "recently used" list) ----
    property string recentXbel: ""
    FileView {
        id: recentStore
        path: Quickshell.env("HOME") + "/.local/share/recently-used.xbel"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.recentXbel = text()
    }
    function mimeGlyph(mime, name) {
        if (/^image\//.test(mime)) return root.g(0xF0EB0);
        if (/^video\//.test(mime)) return root.g(0xF0E2C);
        if (/^audio\//.test(mime)) return root.g(0xF0E2A);
        if (/pdf/.test(mime)) return root.g(0xF0226);
        if (/zip|tar|compressed|archive|x-7z|rar/.test(mime)) return root.g(0xF07B9);
        if (/markdown/.test(mime) || /\.md$/i.test(name)) return root.g(0xF0F5B);
        if (/shellscript|x-executable/.test(mime)) return root.g(0xF018D);
        if (/python|javascript|json|x-c|java|rust|x-go|qml|html|css|xml|yaml|toml/.test(mime)) return root.g(0xF102B);
        if (/^text\//.test(mime)) return root.g(0xF09EE);
        return root.g(0xF0224);
    }
    readonly property var recentFiles: {
        var out = [], seen = {}, parts = root.recentXbel.split("<bookmark ");
        for (var i = 1; i < parts.length; i++) {
            var p = parts[i];
            var href = (/href="([^"]+)"/.exec(p) || [])[1] || "";
            var mod = (/modified="([^"]+)"/.exec(p) || [])[1] || "";
            var mime = (/mime-type type="([^"]+)"/.exec(p) || [])[1] || "";
            if (href.indexOf("file://") !== 0 || mime === "inode/directory" || seen[href]) continue;
            seen[href] = true;
            var path;
            try { path = decodeURIComponent(href.slice(7)); } catch (e) { path = href.slice(7); }
            var cut = path.lastIndexOf("/");
            var name = path.slice(cut + 1);
            if (name === "") continue;
            var dir = path.slice(0, cut).replace(Quickshell.env("HOME"), "~");
            out.push({ path: path, name: name, dir: dir, mime: mime, mod: mod, glyph: root.mimeGlyph(mime, name) });
        }
        out.sort(function (a, b) { return a.mod < b.mod ? 1 : a.mod > b.mod ? -1 : 0; });
        return out.slice(0, 6);
    }

    // ---- quick folders + tools (things that are not already on the bar) ----
    readonly property string homeDir: Quickshell.env("HOME")
    readonly property var startFolders: [
        { name: "Home",      glyph: root.g(0xF02DC), run: "dolphin ~" },
        { name: "Documents", glyph: root.g(0xF09EE), run: "dolphin ~/Documents" },
        { name: "Downloads", glyph: root.g(0xF01DA), run: "dolphin ~/Downloads" },
        { name: "Pictures",  glyph: root.g(0xF0976), run: "dolphin ~/Pictures" },
        { name: "Projects",  glyph: root.g(0xF0169), run: "dolphin ~/Projects" },
        { name: "Config",    glyph: root.g(0xF19FD), run: "dolphin ~/.config" }
    ]
    readonly property var startTools: [
        { name: "Cyber tools", glyph: root.g(0xF0D9A), run: "kitty -e cyber" },
        { name: "Screenshot",  glyph: root.g(0xF0E51), run: "sleep 0.4; $HOME/.local/bin/screenshot.sh region edit" },
        { name: "Clipboard",   glyph: root.g(0xF0A38), run: "cliphist list | wofi --dmenu | cliphist decode | wl-copy" },
        { name: "Wallpaper",   glyph: root.g(0xF0E09), run: "$HOME/.local/bin/wall-ro" },
        { name: "Color picker", glyph: root.g(0xF020A), run: "sleep 0.4; command -v hyprpicker >/dev/null && hyprpicker -a || notify-send 'Color picker' 'Install hyprpicker: sudo pacman -S hyprpicker'" },
        { name: "Appearance",  glyph: root.g(0xF0E0C), run: "qt6ct" }
    ]
    readonly property var startPower: [
        { name: "Lock",      glyph: root.g(0xF0341), run: "loginctl lock-session" },
        { name: "Log out",   glyph: root.g(0xF0343), run: "uwsm stop" },
        { name: "Sleep",     glyph: root.g(0xF0904), run: "systemctl suspend" },
        { name: "Restart",   glyph: root.g(0xF0709), run: "systemctl reboot" },
        { name: "Shut down", glyph: root.g(0xF0425), run: "systemctl poweroff" }
    ]
    property string startUptime: ""
    Process {
        id: uptimeProc
        command: ["uptime", "-p"]
        stdout: SplitParser { onRead: function (l) { root.startUptime = l.replace(/^up\s+/, ""); } }
    }

    // ---- start menu building blocks ----
    component StartHeader: Item {
        id: sh
        property string title: ""
        property string action: ""
        property string actionGlyph: ""
        property bool actionFirst: false     // "‹ Back" vs "All apps ›"
        signal actionClicked()
        height: 22
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: sh.title
            color: root.cWhite
            font.family: root.fontFamily
            font.pixelSize: 13
            font.bold: true
        }
        Rectangle {
            visible: sh.action !== ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: shRow.implicitWidth + 16
            height: 22
            radius: 6
            color: shMouse.containsMouse ? root.cSurface2 : root.cSurface
            border.color: shMouse.containsMouse ? root.cMuted : root.cOutline
            border.width: 1
            Row {
                id: shRow
                anchors.centerIn: parent
                spacing: 4
                layoutDirection: sh.actionFirst ? Qt.RightToLeft : Qt.LeftToRight
                Text {
                    text: sh.action
                    color: root.cFg
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: sh.actionGlyph
                    color: root.cFg
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea {
                id: shMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sh.actionClicked()
            }
        }
    }

    // app icon: black & white, colour fades in on hover (like the album art)
    component StartIcon: Item {
        id: si
        property var entry: null
        property string glyph: ""
        property bool hot: false
        property int px: 28
        width: px
        height: px
        Image {
            id: siImg
            anchors.fill: parent
            sourceSize.width: si.px * 2
            sourceSize.height: si.px * 2
            source: si.entry && si.entry.icon ? Quickshell.iconPath(si.entry.icon, true) : ""
            visible: source != "" && status === Image.Ready
            smooth: true
            layer.enabled: true
            layer.effect: MultiEffect {
                saturation: si.hot ? 0.0 : -1.0
                Behavior on saturation { NumberAnimation { duration: 200 } }
            }
        }
        Text {
            visible: !siImg.visible
            anchors.centerIn: parent
            text: si.glyph !== "" ? si.glyph : root.g(0xF003B)
            color: si.hot ? root.cWhite : root.cFg
            font.family: root.fontFamily
            font.pixelSize: Math.round(si.px * 0.75)
        }
    }

    component StartAppTile: Rectangle {
        id: sat
        property var entry: null
        signal open()
        signal pin()
        height: 74
        radius: 8
        color: satMouse.containsMouse ? root.cSurface : "transparent"
        border.color: satMouse.containsMouse ? root.cOutline : "transparent"
        border.width: 1
        Column {
            anchors.centerIn: parent
            width: parent.width - 8
            spacing: 6
            StartIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                entry: sat.entry
                hot: satMouse.containsMouse
                px: 32
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: sat.entry ? sat.entry.name : ""
                color: satMouse.containsMouse ? root.cWhite : root.cFg
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: satMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function (m) { if (m.button === Qt.RightButton) sat.pin(); else sat.open(); }
        }
    }

    component StartGlyphTile: Rectangle {
        id: sgt
        property string glyph: ""
        property string label: ""
        signal clicked()
        height: 66
        radius: 8
        color: sgtMouse.containsMouse ? root.cSurface : "transparent"
        border.color: sgtMouse.containsMouse ? root.cOutline : "transparent"
        border.width: 1
        Column {
            anchors.centerIn: parent
            width: parent.width - 8
            spacing: 6
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 32
                height: 32
                radius: 16
                color: sgtMouse.containsMouse ? root.cWhite : root.cSurface2
                border.color: root.cOutline
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: sgt.glyph
                    color: sgtMouse.containsMouse ? root.cBg : root.cWhite
                    font.family: root.fontFamily
                    font.pixelSize: 17
                }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: sgt.label
                color: sgtMouse.containsMouse ? root.cWhite : root.cFg
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: sgtMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sgt.clicked()
        }
    }

    component StartChip: Rectangle {
        id: sc
        property string glyph: ""
        property string label: ""
        signal clicked()
        width: scRow.implicitWidth + 20
        height: 28
        radius: 14
        color: scMouse.containsMouse ? root.cSurface2 : root.cSurface
        border.color: scMouse.containsMouse ? root.cMuted : root.cOutline
        border.width: 1
        Row {
            id: scRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                text: sc.glyph
                color: root.cWhite
                font.family: root.fontFamily
                font.pixelSize: 14
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: sc.label
                color: root.cFg
                font.family: root.fontFamily
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: scMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sc.clicked()
        }
    }

    // list row: icon / glyph, title, muted subtitle; used for recent files, all apps, search
    component StartRow: Rectangle {
        id: sr
        property var entry: null
        property string glyph: ""
        property string title: ""
        property string sub: ""
        property bool pinned: false
        property bool selected: false
        readonly property bool hovered: srMouse.containsMouse
        signal clicked()
        signal rightClicked()
        height: 40
        radius: 8
        color: selected || srMouse.containsMouse ? root.cSurface : "transparent"
        border.color: selected ? root.cMuted : srMouse.containsMouse ? root.cOutline : "transparent"
        border.width: 1
        StartIcon {
            id: srIcon
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            entry: sr.entry
            glyph: sr.glyph
            hot: sr.hovered || sr.selected
            px: 22
        }
        Column {
            anchors.left: srIcon.right
            anchors.leftMargin: 10
            anchors.right: srPin.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            Text {
                width: parent.width
                text: sr.title
                color: root.cWhite
                font.family: root.fontFamily
                font.pixelSize: 12
                elide: Text.ElideMiddle
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: sr.sub
                color: root.cMuted
                font.family: root.fontFamily
                font.pixelSize: 10
                elide: Text.ElideLeft
            }
        }
        Text {
            id: srPin
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: sr.pinned
            width: visible ? implicitWidth : 0
            text: root.g(0xF0403)
            color: root.cFg2
            font.family: root.fontFamily
            font.pixelSize: 13
        }
        MouseArea {
            id: srMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function (m) { if (m.button === Qt.RightButton) sr.rightClicked(); else sr.clicked(); }
        }
    }

    // ---- round button used by the media popup ----
    component MediaBtn: Rectangle {
        id: mb
        property string icon: ""
        property bool lit: false       // toggle state (shuffle / repeat)
        property bool big: false      // the play/pause button
        property bool ok: true        // player supports this action
        property string tip: ""
        signal clicked()
        width: big ? 32 : 24
        height: width
        radius: width / 2
        color: big ? (mbMouse.containsMouse ? root.cFg : root.cWhite)
                   : lit ? root.cSurface2 : mbMouse.containsMouse && ok ? root.cSurface : "transparent"
        border.color: big ? root.cWhite : lit ? root.cMuted : "transparent"
        border.width: 1
        scale: mbMouse.pressed ? 0.9 : 1.0
        Behavior on scale { NumberAnimation { duration: 90 } }
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.centerIn: parent
            text: mb.icon
            color: mb.big ? root.cBg : !mb.ok ? root.cOutline : (mb.lit || mbMouse.containsMouse) ? root.cWhite : root.cFg2
            font.family: root.fontFamily
            font.pixelSize: mb.big ? 18 : 14
        }
        MouseArea {
            id: mbMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: mb.ok
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.clicked()
        }
    }

    // ============================================================
    //  UPDATES: ~/.local/bin/update-check (checkupdates + yay -Qua) writes
    //  $XDG_RUNTIME_DIR/rice-updates.json every 30 min; the bar badge reads it.
    // ============================================================
    readonly property string updFile: Quickshell.env("XDG_RUNTIME_DIR") + "/rice-updates.json"
    readonly property string updBin: Quickshell.env("HOME") + "/.local/bin/update-check"
    property var upd: ({ repo: 0, aur: 0, pkgs: [], error: "" })
    readonly property int updCount: (upd.repo || 0) + (upd.aur || 0)
    function updCheck() {
        if (updProc.running) return;
        updProc.running = true;
    }
    function updRunUpgrade() {
        tooltip.hide();
        // safe-update: Arch news + battery checks, snapshot, update that survives the desktop dying,
        // boot-file checks with repair / undo; it refreshes the badge's file itself at the end
        root.launch("kitty --class rice-update --title 'System update' -e \"$HOME/.local/bin/safe-update\"");
    }
    Process {
        id: updProc
        command: ["bash", "-c", "f=\"$XDG_RUNTIME_DIR/rice-updates.json\"; \"$HOME/.local/bin/update-check\" > \"$f.tmp\" && mv \"$f.tmp\" \"$f\""]
        onExited: updStore.reload()
    }
    FileView {
        id: updStore
        path: root.updFile
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                var d = JSON.parse(text());
                if (d && d.pkgs !== undefined) root.upd = d;
            } catch (e) {}
        }
    }
    Timer {     // first check shortly after login (network up), then every 30 minutes
        interval: 90000
        running: true
        onTriggered: { root.updCheck(); interval = 1800000; repeat = true; restart(); }
    }
    Timer {     // cheap: pick up the result of an update run in the terminal
        interval: 60000
        running: true
        repeat: true
        onTriggered: updStore.reload()
    }

    // ---- thin slider used by the media popup (seek + volume) ----
    component MediaSlider: Item {
        id: sl
        property real value: 0          // 0..1
        property bool interactive: true
        property bool dragging: false
        property real dragValue: 0
        signal moved(real v)            // while dragging (volume)
        signal committed(real v)        // on release (seek)
        signal wheeled(int d)
        readonly property real shown: dragging ? dragValue : Math.max(0, Math.min(1, value))
        readonly property bool hot: slMouse.containsMouse || dragging
        height: 16
        Rectangle {
            id: slTrack
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: sl.hot ? 6 : 4
            radius: height / 2
            color: root.cSurface2
            Behavior on height { NumberAnimation { duration: 100 } }
            Rectangle {
                width: parent.width * sl.shown
                height: parent.height
                radius: parent.radius
                color: sl.hot ? root.cWhite : root.cFg
            }
        }
        Rectangle {
            visible: sl.interactive && sl.hot
            width: 12
            height: 12
            radius: 6
            color: root.cWhite
            anchors.verticalCenter: parent.verticalCenter
            x: Math.max(0, Math.min(sl.width - width, sl.width * sl.shown - width / 2))
        }
        MouseArea {
            id: slMouse
            anchors.fill: parent
            anchors.topMargin: -4
            anchors.bottomMargin: -4
            hoverEnabled: true
            enabled: sl.interactive
            cursorShape: sl.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
            function at(mx) { return Math.max(0, Math.min(1, mx / sl.width)); }
            onPressed: function (m) { sl.dragging = true; sl.dragValue = at(m.x); sl.moved(sl.dragValue); }
            onPositionChanged: function (m) { if (sl.dragging) { sl.dragValue = at(m.x); sl.moved(sl.dragValue); } }
            onReleased: function (m) { sl.dragValue = at(m.x); sl.committed(sl.dragValue); sl.dragging = false; }
            onCanceled: sl.dragging = false
            onWheel: function (w) { sl.wheeled(w.angleDelta.y > 0 ? 1 : -1); }
        }
    }

    PanelWindow {
        id: bar

        anchors {
            top: true
            left: true
            right: true
        }
        margins {
            top: 6
            left: 8
            right: 8
        }
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 41   // bar is 42 + 6 margin; 41 leaves a 7px gap above windows (with gaps_out 8)
        implicitHeight: 42

        color: "transparent"
        WlrLayershell.namespace: "rice-bar"
        WlrLayershell.layer: WlrLayer.Top

        // dock background (rounded, thin light-gray border)
        Rectangle {
            id: dockBg
            anchors.fill: parent
            radius: 13
            color: Qt.rgba(0.05, 0.05, 0.05, 0.92)
            border.color: "#999999"
            border.width: 1
        }

        // ---------------- left: logo, workspaces, media ----------------
        Row {
            id: leftGroup
            z: 1
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Pill {
                id: logoPill
                icon: root.g(0xF08C7)   // arch
                accent: startMenu.visible
                tip: startMenu.visible ? "" : "Start · right-click for a terminal"
                onClicked: startMenu.toggle()
                onRightClicked: root.launch("kitty")
            }

            // workspaces (only in-use ones, current highlighted, roman numerals); scroll to switch
            Row {
                id: workspaces
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Repeater {
                    model: Hyprland.workspaces

                    delegate: Rectangle {
                        required property var modelData
                        readonly property int wsId: modelData ? modelData.id : 0
                        readonly property bool active: modelData ? (modelData.focused === true) : false

                        visible: wsId > 0
                        width: Math.max(23, wsText.implicitWidth + 11)
                        height: 23
                        radius: 5
                        color: active ? root.cWhite : root.cSurface2
                        border.color: active ? root.cWhite : root.cOutline
                        border.width: 1

                        Text {
                            id: wsText
                            anchors.centerIn: parent
                            text: root.roman(wsId)
                            color: active ? root.cBg : root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            font.bold: active
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Hyprland.dispatch("hl.dsp.focus({workspace = " + wsId + "})")
                            onWheel: function (wheel) {
                                Hyprland.dispatch('hl.dsp.focus({workspace = "' + (wheel.angleDelta.y > 0 ? "e-1" : "e+1") + '"})');
                            }
                        }
                    }
                }
            }

            // now playing (hidden when nothing is playing): click opens the media popup
            Pill {
                id: mediaPill
                visible: root.player !== null
                icon: root.player && root.player.isPlaying ? root.g(0xF03E4) : root.g(0xF040A)   // pause / play
                label: {
                    if (!root.player) return "";
                    var t = root.player.trackTitle || root.player.identity || "";
                    var a = root.player.trackArtist || "";
                    var s = a !== "" ? t + " · " + a : t;
                    return s.length > 38 ? s.slice(0, 37) + "…" : s;
                }
                accent: mediaPopup.visible
                tip: mediaPopup.visible ? "" : "Click for player · middle-click play/pause · scroll next/previous"
                onClicked: mediaPopup.toggle()
                onMiddleClicked: if (root.player) root.player.togglePlaying()
                onRightClicked: if (root.player) root.player.togglePlaying()
                onScrolled: function (d) {
                    if (!root.player) return;
                    if (d > 0) root.player.previous(); else root.player.next();
                }
                // thin progress line along the bottom of the pill
                Rectangle {
                    visible: root.player !== null && root.player.lengthSupported && root.player.length > 0
                    anchors.left: parent.left
                    anchors.leftMargin: 5
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    height: 2
                    radius: 1
                    width: visible ? (parent.width - 10) * Math.min(1, root.player.position / root.player.length) : 0
                    color: mediaPopup.visible ? root.cMuted : root.cFg2
                    Behavior on width { NumberAnimation { duration: 400 } }
                }
            }
        }

        // ---------------- center: date + clock ----------------
        Rectangle {
            id: clockPill
            z: 1
            height: 30
            width: clockRow.implicitWidth + 20
            radius: 8
            color: clockMouse.containsMouse ? root.cSurface2 : root.cSurface
            border.color: clockMouse.containsMouse ? root.cMuted : root.cOutline
            border.width: 1
            anchors.centerIn: parent
            Behavior on color { ColorAnimation { duration: 120 } }

            property var now: new Date()
            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: clockPill.now = new Date()
            }

            Row {
                id: clockRow
                anchors.centerIn: parent
                spacing: 8
                Text {
                    text: Qt.formatDate(clockPill.now, "ddd d MMM")
                    color: root.cFg
                    font.family: root.fontFamily
                    font.pixelSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: Qt.formatTime(clockPill.now, "hh:mm")
                    color: root.cWhite
                    font.family: root.fontFamily
                    font.pixelSize: 15
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                id: clockMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: calendar.toggle()
                onContainsMouseChanged: {
                    if (containsMouse && !calendar.visible) tooltip.showFor(clockPill, Qt.formatDate(clockPill.now, "dddd, d MMMM yyyy") + "  \u00b7  click for calendar");
                    else if (tooltip.target === clockPill) tooltip.hide();
                }
            }
        }

        ClockWave {
            mirrored: true
            levels: root.cavaBars.slice(0, Math.floor(root.cavaBars.length / 2)).reverse()
            anchors.right: clockPill.left
            anchors.rightMargin: -8
            width: Math.max(0, clockPill.x - (leftGroup.x + leftGroup.width) + 16)
        }
        ClockWave {
            levels: root.cavaBars.slice(Math.floor(root.cavaBars.length / 2))
            anchors.left: clockPill.right
            anchors.leftMargin: -8
            width: Math.max(0, rightGroup.x - (clockPill.x + clockPill.width) + 16)
        }

        // ---------------- right: tray, system, notifications ----------------
        Row {
            id: rightGroup
            z: 1
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            // pending updates: hidden while there are none
            Pill {
                id: updPill
                readonly property bool needsTool: (root.upd.error || "").indexOf("pacman-contrib") >= 0
                visible: root.updCount > 0 || updPill.needsTool
                icon: root.g(updPill.needsTool && root.updCount === 0 ? 0xF05D6 : 0xF03D5)
                label: root.updCount > 0 ? String(root.updCount) : ""
                tip: {
                    if (updPill.needsTool && root.updCount === 0) return root.upd.error;
                    var p = root.upd.pkgs || [], lines = p.slice(0, 15);
                    if (p.length > 15) lines.push("… and " + (p.length - 15) + " more");
                    var head = root.updCount + " update" + (root.updCount === 1 ? "" : "s") +
                               " (" + root.upd.repo + " repo, " + root.upd.aur + " AUR)";
                    return [head].concat(lines).concat(["", "click: update in a terminal  ·  right-click: check again"]).join("\n");
                }
                onClicked: root.updRunUpgrade()
                onRightClicked: root.updCheck()
            }

            // soundboard button + privacy indicator: gray mic normally, white while any app
            // has the microphone (or camera) open; click opens the soundboard under it
            Pill {
                id: micPill
                readonly property bool mic: root.micApps.length > 0
                readonly property bool cam: root.camApps.length > 0
                accent: mic || cam || sbPopup.visible
                icon: root.g(mic || cam ? 0xF036C : 0xF00E6) + (cam ? " " + root.g(0xF05A0) : "")
                tip: sbPopup.visible ? "" : [mic ? "Microphone in use: " + root.micApps.join(", ") : "",
                      cam ? "Camera in use: " + root.camApps.join(", ") : "", "click for the soundboard"]
                     .filter(function (x) { return x !== ""; }).join("  ·  ")
                onClicked: sbPopup.toggle()
            }

            // system tray (empty while barTrayRe matches nothing; hidden so it adds no gap)
            Row {
                visible: SystemTray.items.values.some(function (it) { return root.onBar(it); })
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: SystemTray.items
                    delegate: Item {
                        id: trayItem
                        required property var modelData
                        // while connected, Proton's icon lives in the VPN pill instead;
                        // flyout items (Steam, …) live behind the arrow
                        visible: root.onBar(modelData)
                        width: 21
                        height: 21
                        anchors.verticalCenter: parent.verticalCenter
                        Image {
                            anchors.fill: parent
                            source: trayItem.modelData.icon
                            sourceSize.width: 21
                            sourceSize.height: 21
                            smooth: true
                            // monochrome rice: drop the icon's colour
                            layer.enabled: true
                            layer.effect: MultiEffect { saturation: -1.0 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                            onClicked: function (mouse) {
                                var it = trayItem.modelData;
                                if (mouse.button === Qt.RightButton || it.onlyMenu) {
                                    if (it.hasMenu) {
                                        var p = trayItem.mapToItem(bar.contentItem, 0, trayItem.height + 8);
                                        it.display(bar, p.x, p.y);
                                    }
                                } else if (mouse.button === Qt.MiddleButton) {
                                    it.secondaryActivate();
                                } else {
                                    it.activate();
                                }
                            }
                            onWheel: function (wheel) { trayItem.modelData.scroll(wheel.angleDelta.y, false); }
                            onContainsMouseChanged: {
                                var t = trayItem.modelData.tooltipTitle || trayItem.modelData.title;
                                if (containsMouse && t) tooltip.showFor(trayItem, t);
                                else if (tooltip.target === trayItem) tooltip.hide();
                            }
                        }
                    }
                }
            }

            // cpu / temp / ram: its own pill so each icon can be sized (and rotated) separately
            Rectangle {
                id: statsPill
                implicitWidth: statsRow.implicitWidth + 20
                height: 30
                radius: 8
                color: statsMouse.containsMouse ? root.cSurface2 : root.cSurface
                border.color: statsMouse.containsMouse ? root.cMuted : root.cOutline
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }

                readonly property string memText: (stats.memUsed / 1024).toFixed(1)

                // wifi strength (lock version while a VPN is up), ethernet, or offline
                readonly property string netIcon: {
                    if (stats.netType === "ethernet") return root.g(0xF0200);
                    if (stats.netType !== "wifi") return root.g(0xF05AA);
                    var lvl = stats.netSignal >= 75 ? 3 : stats.netSignal >= 50 ? 2 : stats.netSignal >= 25 ? 1 : 0;
                    var plain = [0xF091F, 0xF0922, 0xF0925, 0xF0928], locked = [0xF0921, 0xF0924, 0xF0927, 0xF092A];
                    return root.g((stats.vpnProvider !== "" ? locked : plain)[lvl]);
                }
                readonly property string netText: {
                    var t = stats.netType === "wifi" ? "Wi-Fi " + stats.netName + " (" + stats.netSignal + "%)"
                          : stats.netType === "ethernet" ? "Ethernet " + stats.netName : "Offline";
                    return stats.vpnProvider !== "" ? t + " · VPN " + stats.vpnProvider : t;
                }

                Row {
                    id: statsRow
                    anchors.centerIn: parent
                    spacing: 5

                    Text {
                        text: statsPill.netIcon
                        color: stats.netType === "none" ? root.cMuted : root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 18
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item { width: 4; height: 1 }

                    Text {   // nf-md-cpu_64_bit
                        text: root.g(0xF0EE0)
                        color: stats.temp >= 90 ? "#ff6b6b" : root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 19
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: stats.cpu + "%"
                        color: root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item { width: 4; height: 1 }

                    Text {   // thermometer
                        text: root.g(0xF050F)
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 19
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: stats.temp + "°"
                        color: root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item { width: 4; height: 1 }

                    // nf-fa-memory, turned 90° clockwise; the wrapper swaps width/height
                    // so the row leaves room for the rotated glyph. Its width is trimmed
                    // below the full line height so the icon sits close to the number.
                    Item {
                        width: 16
                        height: ramIcon.implicitWidth
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            id: ramIcon
                            anchors.centerIn: parent
                            text: root.g(0xEFC5)
                            rotation: 90
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 23   // this glyph draws small, so it gets a larger size
                        }
                    }
                    Text {
                        text: statsPill.memText + "G"
                        color: root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: statsMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.launch("kitty -e btop")
                    onContainsMouseChanged: {
                        var t = statsPill.netText + " · CPU " + stats.cpu + "% · " + stats.temp + "°C · RAM " + statsPill.memText + " / "
                              + (stats.memTotal / 1024).toFixed(0) + " GB · click for btop";
                        if (containsMouse) tooltip.showFor(statsPill, t);
                        else if (tooltip.target === statsPill) tooltip.hide();
                    }
                }
            }
            // (leftover from the old stats pill, safe to delete)root.g(0xF0EE0)   // nf-md-cpu_64_bit; old glyph:""          // cpu

            // bluetooth: click opens the bluetooth popup, middle-click toggles power
            Pill {
                id: btPill
                visible: root.btAdapter !== null
                icon: !root.btAdapter || !root.btAdapter.enabled ? root.g(0xF00B2)
                      : root.btConnected > 0 ? root.g(0xF00B1) : root.g(0xF00AF)
                label: root.btConnected > 0 ? String(root.btConnected) : ""
                accent: btPopup.visible
                iconColor: btPopup.visible ? root.cBg : root.btAdapter && root.btAdapter.enabled ? root.cWhite : root.cMuted
                tip: btPopup.visible || !root.btAdapter ? ""
                     : (!root.btAdapter.enabled ? "Bluetooth off" : root.btConnected + " connected")
                       + " · click for devices · middle-click on/off · right-click bluetoothctl"
                onClicked: btPopup.toggle()
                onMiddleClicked: root.btSetPower(!(root.btAdapter && root.btAdapter.enabled))
                onRightClicked: root.launch("kitty -e bluetoothctl")
            }

            // battery
            Pill {
                visible: root.battery !== null && root.battery.isLaptopBattery
                readonly property real pct: root.battery ? (root.battery.percentage > 1 ? root.battery.percentage : root.battery.percentage * 100) : 0
                readonly property bool charging: root.battery ? (root.battery.state === UPowerDeviceState.Charging || root.battery.state === UPowerDeviceState.FullyCharged || root.battery.state === UPowerDeviceState.PendingCharge) : false
                function fmt(sec) {
                    if (!sec || sec <= 0) return "";
                    var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
                    return h > 0 ? h + "h " + m + "m" : m + "m";
                }
                icon: {
                    if (charging) return root.g(0xF0084);
                    var icons = [0xF008E, 0xF007A, 0xF007B, 0xF007C, 0xF007D, 0xF007E, 0xF007F, 0xF0080, 0xF0081, 0xF0082, 0xF0079];
                    return root.g(icons[Math.max(0, Math.min(10, Math.round(pct / 10)))]);
                }
                label: Math.round(pct) + "%"
                iconColor: !charging && pct <= 15 ? "#ff6b6b" : root.cWhite
                tip: {
                    if (!root.battery) return "";
                    if (root.battery.state === UPowerDeviceState.FullyCharged) return "Fully charged";
                    if (charging) return "Charging" + (fmt(root.battery.timeToFull) ? " · full in " + fmt(root.battery.timeToFull) : "");
                    return "On battery" + (fmt(root.battery.timeToEmpty) ? " · " + fmt(root.battery.timeToEmpty) + " left" : "")
                         + (root.battery.changeRate > 0 ? " · " + root.battery.changeRate.toFixed(1) + " W" : "");
                }
            }

            // hidden-icons arrow (like Windows): opens the quick-settings flyout
            Pill {
                id: arrowPill
                icon: flyout.visible ? root.g(0xF0143) : root.g(0xF0140)   // chevron up / down
                accent: flyout.visible
                tip: flyout.visible ? "" : "Show hidden icons"
                onClicked: flyout.toggle()
            }

            // notification toggle: filled bell when there are notifications, outline when empty
            Pill {
                readonly property int count: notifServer.trackedNotifications.values.length
                icon: count > 0 ? root.g(0xF009A) : root.g(0xF009C)   // bell / bell-outline; old empty-state glyph:""
                accent: notificationCenter.visible
                tip: count > 0 ? count + " notifications · right-click to clear" : "No notifications"
                onClicked: notificationCenter.visible = !notificationCenter.visible
                onRightClicked: root.clearNotifications()
            }
        }
    }

    // ---- hover tooltip shared by every bar item ----
    PopupWindow {
        id: tooltip
        property Item target: null
        property string text: ""
        visible: false
        color: "transparent"
        anchor.window: bar
        implicitWidth: tipText.implicitWidth + 20
        implicitHeight: tipText.implicitHeight + 12

        function showFor(item, t) {
            target = item;
            text = t;
            tipDelay.restart();
        }
        function hide() {
            tipDelay.stop();
            visible = false;
            target = null;
        }

        Timer {
            id: tipDelay
            interval: 450
            onTriggered: {
                if (!tooltip.target) return;
                var p = tooltip.target.mapToItem(bar.contentItem, tooltip.target.width / 2, tooltip.target.height);
                tooltip.anchor.rect.x = Math.max(4, Math.min(bar.width - tooltip.implicitWidth - 4, p.x - tooltip.implicitWidth / 2));
                tooltip.anchor.rect.y = p.y + 10;
                tooltip.visible = true;
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: root.cBg1
            border.color: root.cOutline
            border.width: 1
            Text {
                id: tipText
                anchors.centerIn: parent
                text: tooltip.text
                color: root.cFg
                font.family: root.fontFamily
                font.pixelSize: 12
            }
        }
    }

    // ============================================================
    //  START MENU (opened by the Arch logo): search, pinned apps / all apps,
    //  quick folders, tools, recent files, power. Nothing that is already on the bar.
    //  keys: type to search · ↑↓ pick · Enter open · Esc back / close
    // ============================================================
    PanelWindow {
        id: startMenu
        visible: false
        color: "transparent"
        // full screen and transparent while open: the menu panel sits top-left, and a
        // click anywhere else (bar, windows, desktop, the logo again) closes it
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true
        WlrLayershell.namespace: "rice-start"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        property string view: "home"     // "home" | "all" | "search"
        property var results: []
        property int sel: 0
        property string hint: ""          // footer text while hovering a power button

        function toggle() {
            tooltip.hide();
            flyout.visible = false;
            btPopup.close("start menu");
            mediaPopup.close();
            if (visible) { close(); return; }
            visible = true;
        }
        function close() { visible = false; }
        function run(cmd) { close(); root.launch(cmd); }
        function openApp(e) { close(); root.startApp(e); }
        function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
        function openFile(f) { run("xdg-open " + shq(f.path)); }

        onVisibleChanged: {
            if (visible) {
                view = "home";
                searchInput.text = "";
                hint = "";
                uptimeProc.running = true;
                searchInput.forceActiveFocus();
            }
        }

        // any click outside the menu panel closes it
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: startMenu.close()
            onWheel: function (w) { w.accepted = true; }
        }

        // ---- search over apps, tools, folders, power and recent files ----
        function refresh(text) {
            var q = text.trim().toLowerCase();
            if (q === "") { results = []; sel = 0; if (view === "search") view = "home"; return; }
            view = "search";
            var out = [];
            var apps = launcher.fuzzyRank(q);
            for (var i = 0; i < apps.length && out.length < 6; i++)
                out.push({ kind: "app", title: apps[i].name, sub: apps[i].genericName || launcher.categoryLabel(apps[i].categories), entry: apps[i] });
            var groups = [[root.startTools, "Tool"], [root.startFolders, "Folder"], [root.startPower, "Power"]];
            for (var g = 0; g < groups.length; g++)
                for (var j = 0; j < groups[g][0].length; j++) {
                    var t = groups[g][0][j];
                    if (t.name.toLowerCase().indexOf(q) >= 0)
                        out.push({ kind: "run", title: t.name, sub: groups[g][1], glyph: t.glyph, run: t.run });
                }
            for (var k = 0; k < root.recentFiles.length; k++) {
                var f = root.recentFiles[k];
                if (f.name.toLowerCase().indexOf(q) >= 0)
                    out.push({ kind: "file", title: f.name, sub: f.dir, glyph: f.glyph, file: f });
            }
            results = out.slice(0, 9);
            sel = 0;
        }
        function activate(r) {
            if (!r) return;
            if (r.kind === "app") openApp(r.entry);
            else if (r.kind === "file") openFile(r.file);
            else run(r.run);
        }

        Rectangle {
            id: startBg
            x: 8           // lines up with the bar's left edge
            y: 56          // bar: 6 margin + 42 height, then an 8px gap
            width: 560
            height: startCol.implicitHeight + 28
            radius: 14
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Column {
                id: startCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 12

                // ---- search box ----
                Rectangle {
                    width: parent.width
                    height: 36
                    radius: 18
                    color: root.cSurface
                    border.color: searchInput.activeFocus ? root.cMuted : root.cOutline
                    border.width: 1
                    Text {
                        id: searchGlyph
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.g(0xF0349)
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 16
                    }
                    TextInput {
                        id: searchInput
                        anchors.left: searchGlyph.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        selectionColor: root.cWhite
                        selectedTextColor: root.cBg
                        clip: true
                        onTextChanged: startMenu.refresh(text)
                        Text {
                            visible: searchInput.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Search apps, tools, folders and recent files"
                            color: root.cMuted
                            font: searchInput.font
                        }
                        Keys.onPressed: function (e) {
                            var v = startMenu.view;
                            if (e.key === Qt.Key_Escape) {
                                if (searchInput.text !== "") searchInput.text = "";
                                else if (v === "all") startMenu.view = "home";
                                else startMenu.close();
                            } else if (v === "search" && e.key === Qt.Key_Down) {
                                startMenu.sel = Math.min(startMenu.results.length - 1, startMenu.sel + 1);
                            } else if (v === "search" && e.key === Qt.Key_Up) {
                                startMenu.sel = Math.max(0, startMenu.sel - 1);
                            } else if (v === "search" && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
                                startMenu.activate(startMenu.results[startMenu.sel]);
                            } else return;
                            e.accepted = true;
                        }
                    }
                }

                // ---- body: home / all apps / search (fixed height so the menu never jumps) ----
                Item {
                    width: parent.width
                    height: homeCol.implicitHeight

                    // ===== home =====
                    Column {
                        id: homeCol
                        // stays laid out while hidden so the body keeps its height
                        opacity: startMenu.view === "home" ? 1 : 0
                        enabled: startMenu.view === "home"
                        width: parent.width
                        spacing: 10

                        StartHeader {
                            width: parent.width
                            title: "Pinned"
                            action: "All apps"
                            actionGlyph: root.g(0xF0142)
                            onActionClicked: startMenu.view = "all"
                        }
                        Grid {
                            id: pinGrid
                            width: parent.width
                            columns: 6
                            rowSpacing: 4
                            readonly property real tileW: width / columns
                            Repeater {
                                model: root.pinnedApps
                                delegate: StartAppTile {
                                    required property var modelData
                                    entry: modelData
                                    width: pinGrid.tileW
                                    onOpen: startMenu.openApp(modelData)
                                    onPin: root.togglePin(modelData)
                                }
                            }
                        }
                        Text {
                            visible: root.pinnedApps.length === 0
                            text: "Right-click an app in All apps to pin it here"
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 11
                        }

                        StartHeader { width: parent.width; title: "Folders" }
                        Row {
                            spacing: 6
                            Repeater {
                                model: root.startFolders
                                delegate: StartChip {
                                    required property var modelData
                                    glyph: modelData.glyph
                                    label: modelData.name
                                    onClicked: startMenu.run(modelData.run)
                                }
                            }
                        }

                        StartHeader { width: parent.width; title: "Tools" }
                        Grid {
                            id: toolGrid
                            width: parent.width
                            columns: 6
                            readonly property real tileW: width / columns
                            Repeater {
                                model: root.startTools
                                delegate: StartGlyphTile {
                                    required property var modelData
                                    width: toolGrid.tileW
                                    glyph: modelData.glyph
                                    label: modelData.name
                                    onClicked: startMenu.run(modelData.run)
                                }
                            }
                        }

                        StartHeader { width: parent.width; title: "Recent"; visible: root.recentFiles.length > 0 }
                        Grid {
                            id: recentGrid
                            visible: root.recentFiles.length > 0
                            width: parent.width
                            columns: 2
                            rowSpacing: 2
                            columnSpacing: 6
                            Repeater {
                                model: root.recentFiles
                                delegate: StartRow {
                                    required property var modelData
                                    width: (recentGrid.width - recentGrid.columnSpacing) / 2
                                    glyph: modelData.glyph
                                    title: modelData.name
                                    sub: modelData.dir
                                    onClicked: startMenu.openFile(modelData)
                                }
                            }
                        }
                    }

                    // ===== all apps (A-Z, right-click to pin / unpin) =====
                    Column {
                        visible: startMenu.view === "all"
                        anchors.fill: parent
                        spacing: 8
                        StartHeader {
                            id: allHeader
                            width: parent.width
                            title: "All apps"
                            action: "Back"
                            actionGlyph: root.g(0xF0141)
                            actionFirst: true
                            onActionClicked: startMenu.view = "home"
                        }
                        Text {
                            text: "Right-click an app to pin or unpin it"
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            leftPadding: 4
                        }
                        ListView {
                            id: allList
                            width: parent.width
                            height: parent.height - allHeader.height - 14 - parent.spacing * 2
                            clip: true
                            model: root.allApps
                            boundsBehavior: Flickable.StopAtBounds
                            // A-Z: a letter heading above the first app of each letter
                            delegate: Column {
                                id: allItem
                                required property var modelData
                                required property int index
                                readonly property string letter: String(modelData.name || "?").charAt(0).toUpperCase()
                                readonly property bool firstOfLetter: index === 0
                                    || String(root.allApps[index - 1].name || "?").charAt(0).toUpperCase() !== letter
                                width: allList.width - 8
                                Text {
                                    visible: allItem.firstOfLetter
                                    text: allItem.letter
                                    color: root.cMuted
                                    font.family: root.fontFamily
                                    font.pixelSize: 11
                                    font.bold: true
                                    leftPadding: 10
                                    topPadding: 6
                                    bottomPadding: 2
                                }
                                StartRow {
                                    width: parent.width
                                    entry: allItem.modelData
                                    title: allItem.modelData.name
                                    sub: allItem.modelData.genericName || launcher.categoryLabel(allItem.modelData.categories)
                                    pinned: root.isPinned(allItem.modelData)
                                    onClicked: startMenu.openApp(allItem.modelData)
                                    onRightClicked: root.togglePin(allItem.modelData)
                                }
                            }
                        }
                    }

                    // ===== search results =====
                    Column {
                        visible: startMenu.view === "search"
                        anchors.fill: parent
                        spacing: 2
                        Text {
                            visible: startMenu.results.length === 0
                            text: "No matches"
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            topPadding: 8
                            leftPadding: 10
                        }
                        Repeater {
                            model: startMenu.results
                            delegate: StartRow {
                                required property var modelData
                                required property int index
                                width: parent.width
                                entry: modelData.kind === "app" ? modelData.entry : null
                                glyph: modelData.glyph || ""
                                title: modelData.title
                                sub: modelData.sub
                                selected: index === startMenu.sel
                                onClicked: startMenu.activate(modelData)
                                onHoveredChanged: if (hovered) startMenu.sel = index
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                // ---- footer: who / uptime, power ----
                Item {
                    width: parent.width
                    height: 34
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Rectangle {
                            width: 30
                            height: 30
                            radius: 15
                            color: root.cWhite
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                anchors.centerIn: parent
                                text: (Quickshell.env("USER") || "?").charAt(0).toUpperCase()
                                color: root.cBg
                                font.family: root.fontFamily
                                font.pixelSize: 15
                                font.bold: true
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                text: Quickshell.env("USER") || ""
                                color: root.cWhite
                                font.family: root.fontFamily
                                font.pixelSize: 13
                                font.bold: true
                            }
                            Text {
                                text: startMenu.hint !== "" ? startMenu.hint
                                      : root.startUptime !== "" ? "up " + root.startUptime : ""
                                color: root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 11
                            }
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Repeater {
                            model: root.startPower
                            delegate: MediaBtn {
                                required property var modelData
                                width: 30
                                icon: modelData.glyph
                                onClicked: startMenu.run(modelData.run)
                                HoverHandler {
                                    onHoveredChanged: {
                                        if (hovered) startMenu.hint = modelData.name;
                                        else if (startMenu.hint === modelData.name) startMenu.hint = "";
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    //  CALENDAR (opened by the clock): month grid, scroll / ‹ › to change month,
    //  click a day to see it, Today jumps back. Click outside or Esc closes.
    // ============================================================
    PanelWindow {
        id: calendar
        visible: false
        color: "transparent"
        // full screen + transparent while open: a click outside the card closes it
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true
        WlrLayershell.namespace: "rice-calendar"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        property var today: new Date()
        property int year: today.getFullYear()
        property int month: today.getMonth()          // 0-11
        property var picked: today
        readonly property var monthNames: ["January", "February", "March", "April", "May", "June", "July",
                                           "August", "September", "October", "November", "December"]
        readonly property var dayNames: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

        function toggle() {
            tooltip.hide();
            flyout.visible = false;
            btPopup.close("calendar");
            mediaPopup.close();
            startMenu.close();
            if (visible) { visible = false; return; }
            today = new Date();
            year = today.getFullYear();
            month = today.getMonth();
            picked = today;
            visible = true;
        }
        function shift(d) {
            var m = month + d;
            year += Math.floor(m / 12);
            month = ((m % 12) + 12) % 12;
        }
        function sameDay(a, b) {
            return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
        }
        // 42 cells (6 weeks), Sunday first
        readonly property var cells: {
            var first = new Date(year, month, 1);
            var start = new Date(year, month, 1 - first.getDay());
            var out = [];
            for (var i = 0; i < 42; i++)
                out.push(new Date(start.getFullYear(), start.getMonth(), start.getDate() + i));
            return out;
        }
        function weekOfYear(d) {   // ISO week number
            var t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
            var n = t.getUTCDay() || 7;
            t.setUTCDate(t.getUTCDate() + 4 - n);
            var y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
            return Math.ceil(((t - y0) / 86400000 + 1) / 7);
        }
        function dayOfYear(d) {
            return Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(d.getFullYear(), 0, 1)) / 86400000) + 1;
        }
        function relative(d) {
            var t = new Date(today.getFullYear(), today.getMonth(), today.getDate());
            var x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
            var n = Math.round((x - t) / 86400000);
            if (n === 0) return "today";
            if (n === 1) return "tomorrow";
            if (n === -1) return "yesterday";
            return n > 0 ? "in " + n + " days" : Math.abs(n) + " days ago";
        }

        // click anywhere outside the card closes it
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: calendar.visible = false
            onWheel: function (w) { w.accepted = true; }
        }

        Item {
            anchors.fill: parent
            focus: calendar.visible
            Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Escape) calendar.visible = false;
                else if (e.key === Qt.Key_Left || e.key === Qt.Key_PageUp) calendar.shift(-1);
                else if (e.key === Qt.Key_Right || e.key === Qt.Key_PageDown) calendar.shift(1);
                else if (e.key === Qt.Key_Home || e.key === Qt.Key_T) { calendar.year = calendar.today.getFullYear(); calendar.month = calendar.today.getMonth(); calendar.picked = calendar.today; }
                else return;
                e.accepted = true;
            }
        }

        Rectangle {
            id: calCard
            width: 300
            height: calCol.implicitHeight + 28
            x: Math.round((parent.width - width) / 2)
            y: 56          // bar: 6 margin + 42 height, then an 8px gap
            radius: 12
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: function (w) { calendar.shift(w.angleDelta.y > 0 ? -1 : 1); }
            }

            Column {
                id: calCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 10

                // big date
                Column {
                    width: parent.width
                    spacing: 2
                    Text {
                        text: Qt.formatDate(calendar.today, "dddd")
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        font.letterSpacing: 1.5
                    }
                    Text {
                        text: Qt.formatDate(calendar.today, "d MMMM yyyy")
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 20
                        font.bold: true
                    }
                }

                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                // month header
                Item {
                    width: parent.width
                    height: 24
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: calendar.monthNames[calendar.month] + " " + calendar.year
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Repeater {
                            model: [[root.g(0xF0141), -1], ["Today", 0], [root.g(0xF0142), 1]]
                            delegate: Rectangle {
                                id: navBtn
                                required property var modelData
                                readonly property bool isToday: modelData[1] === 0
                                readonly property bool atToday: calendar.year === calendar.today.getFullYear()
                                                                 && calendar.month === calendar.today.getMonth()
                                width: isToday ? navText.implicitWidth + 14 : 24
                                height: 22
                                radius: 6
                                visible: !isToday || !atToday
                                color: navMouse.containsMouse ? root.cSurface2 : root.cSurface
                                border.color: navMouse.containsMouse ? root.cMuted : root.cOutline
                                border.width: 1
                                Text {
                                    id: navText
                                    anchors.centerIn: parent
                                    text: navBtn.modelData[0]
                                    color: root.cFg
                                    font.family: root.fontFamily
                                    font.pixelSize: navBtn.isToday ? 10 : 15
                                }
                                MouseArea {
                                    id: navMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (navBtn.isToday) {
                                            calendar.year = calendar.today.getFullYear();
                                            calendar.month = calendar.today.getMonth();
                                            calendar.picked = calendar.today;
                                        } else calendar.shift(navBtn.modelData[1]);
                                    }
                                }
                            }
                        }
                    }
                }

                // weekday names + days
                Grid {
                    id: calGrid
                    columns: 7
                    width: parent.width
                    readonly property real cw: width / 7
                    Repeater {
                        model: calendar.dayNames
                        delegate: Text {
                            required property string modelData
                            required property int index
                            width: calGrid.cw
                            height: 20
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData
                            color: index === 0 || index === 6 ? root.cMuted : root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                    }
                    Repeater {
                        model: calendar.cells
                        delegate: Item {
                            id: dayCell
                            required property var modelData
                            readonly property bool inMonth: modelData.getMonth() === calendar.month
                            readonly property bool isToday: calendar.sameDay(modelData, calendar.today)
                            readonly property bool isPicked: calendar.sameDay(modelData, calendar.picked)
                            width: calGrid.cw
                            height: 32
                            Rectangle {
                                anchors.centerIn: parent
                                width: 30
                                height: 28
                                radius: 7
                                color: dayCell.isToday ? root.cWhite
                                       : dayCell.isPicked ? root.cSurface2
                                       : dayMouse.containsMouse ? root.cSurface : "transparent"
                                border.color: dayCell.isPicked && !dayCell.isToday ? root.cMuted : "transparent"
                                border.width: 1
                            }
                            Text {
                                anchors.centerIn: parent
                                text: dayCell.modelData.getDate()
                                color: dayCell.isToday ? root.cBg : dayCell.inMonth ? root.cFg : root.cOutline
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                font.bold: dayCell.isToday
                            }
                            MouseArea {
                                id: dayMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    calendar.picked = dayCell.modelData;
                                    if (!dayCell.inMonth) { calendar.year = dayCell.modelData.getFullYear(); calendar.month = dayCell.modelData.getMonth(); }
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                // the picked day
                Item {
                    width: parent.width
                    height: 18
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDate(calendar.picked, "ddd d MMM") + "  ·  " + calendar.relative(calendar.picked)
                        color: root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 11
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "week " + calendar.weekOfYear(calendar.picked) + "  ·  day " + calendar.dayOfYear(calendar.picked)
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                    }
                }
            }
        }
    }

    // ============================================================
    //  CLIPBOARD HISTORY (Super+C): cliphist entries, type to filter,
    //  ↑↓ / click to pick, Enter copies, Del removes, images get thumbnails
    // ============================================================
    PanelWindow {
        id: clipPanel
        visible: false
        color: "transparent"
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true
        WlrLayershell.namespace: "rice-clipboard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        property var entries: []          // [{id, text, image, kind}]
        property string query: ""
        property int sel: 0
        property bool loading: false
        readonly property string thumbDir: Quickshell.env("XDG_RUNTIME_DIR") + "/cliphist-thumbs"
        readonly property var shown: {
            var q = query.toLowerCase().trim();
            if (!q) return entries;
            return entries.filter(function (e) { return e.text.toLowerCase().indexOf(q) >= 0; });
        }

        function toggle() {
            if (visible) { visible = false; return; }
            tooltip.hide();
            flyout.visible = false;
            startMenu.close();
            mediaPopup.close();
            calendar.visible = false;
            clipSearch.text = "";
            sel = 0;
            visible = true;
            reload();
            clipSearch.forceActiveFocus();
        }
        function reload() {
            if (clipList.running) return;
            clipList.buf = [];
            loading = true;
            clipList.running = true;
        }
        function pick(e) {
            if (!e) return;
            visible = false;
            Quickshell.execDetached(["sh", "-c", "printf '%s\\t%s\\n' \"$1\" \"$2\" | cliphist decode | wl-copy", "sh", e.id, e.raw]);
        }
        function remove(e) {
            if (!e) return;
            Quickshell.execDetached(["sh", "-c", "printf '%s\\t%s\\n' \"$1\" \"$2\" | cliphist delete", "sh", e.id, e.raw]);
            entries = entries.filter(function (x) { return x.id !== e.id; });
            sel = Math.min(sel, shown.length - 1);
        }
        function wipe() {
            Quickshell.execDetached(["cliphist", "wipe"]);
            entries = [];
        }

        // "12345\tsome text" / "12346\t[[ binary data 52 KiB png 1920x1080 ]]"
        Process {
            id: clipList
            property var buf: []
            command: ["cliphist", "list"]
            stdout: SplitParser {
                onRead: function (line) {
                    var tab = line.indexOf("\t");
                    if (tab < 0) return;
                    var id = line.slice(0, tab), raw = line.slice(tab + 1);
                    var m = /^\[\[ binary data (.+?) (png|jpe?g|webp|gif|bmp) (\d+)x(\d+) \]\]$/i.exec(raw);
                    clipList.buf.push({ id: id, raw: raw, image: !!m,
                                        text: m ? "image  ·  " + m[2].toUpperCase() + "  " + m[3] + "×" + m[4] + "  ·  " + m[1] : raw,
                                        ext: m ? m[2].toLowerCase() : "" });
                }
            }
            onExited: {
                clipPanel.entries = clipList.buf.slice(0, 300);
                clipPanel.loading = false;
                // decode the first image entries to thumbnails once (kept until logout)
                var imgs = clipPanel.entries.filter(function (e) { return e.image; }).slice(0, 40);
                if (imgs.length) {
                    var args = ["sh", "-c",
                        "d=\"$1\"; shift; mkdir -p \"$d\"; while [ $# -gt 1 ]; do " +
                        "[ -s \"$d/$1\" ] || printf '%s\\t%s\\n' \"$1\" \"$2\" | cliphist decode > \"$d/$1\"; shift 2; done", "sh", clipPanel.thumbDir];
                    imgs.forEach(function (e) { args.push(e.id, e.raw); });
                    thumbProc.command = args;
                    thumbProc.running = true;
                }
            }
        }
        property int thumbGen: 0
        Process {
            id: thumbProc
            onExited: clipPanel.thumbGen++
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: clipPanel.visible = false
            onWheel: function (w) { w.accepted = true; }
        }

        Rectangle {
            id: clipCard
            width: 520
            height: 460
            anchors.centerIn: parent
            radius: 14
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Column {
                id: clipTop
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 10

                Item {
                    width: parent.width
                    height: 20
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Text {
                            text: root.g(0xF0A38)
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 15
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "CLIPBOARD" + (clipPanel.entries.length ? "  ·  " + clipPanel.entries.length : "")
                            color: root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            font.letterSpacing: 1.5
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: clipPanel.entries.length > 0
                        width: wipeText.implicitWidth + 16
                        height: 22
                        radius: 6
                        color: wipeMouse.containsMouse ? root.cSurface2 : root.cSurface
                        border.color: wipeMouse.containsMouse ? root.cMuted : root.cOutline
                        border.width: 1
                        Text {
                            id: wipeText
                            anchors.centerIn: parent
                            text: "Clear all"
                            color: root.cFg
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                        MouseArea {
                            id: wipeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: clipPanel.wipe()
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 17
                    color: root.cSurface
                    border.color: clipSearch.activeFocus ? root.cMuted : root.cOutline
                    border.width: 1
                    Text {
                        id: clipSearchIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 13
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.g(0xF0349)
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 15
                    }
                    TextInput {
                        id: clipSearch
                        anchors.left: clipSearchIcon.right
                        anchors.leftMargin: 9
                        anchors.right: parent.right
                        anchors.rightMargin: 13
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 13
                        clip: true
                        selectionColor: root.cSurface2
                        onTextChanged: { clipPanel.query = text; clipPanel.sel = 0; clipView.positionViewAtBeginning(); }
                        Keys.onPressed: function (e) {
                            var n = clipPanel.shown.length;
                            if (e.key === Qt.Key_Escape) {
                                if (text !== "") text = ""; else clipPanel.visible = false;
                            } else if (e.key === Qt.Key_Down || (e.key === Qt.Key_Tab && !(e.modifiers & Qt.ShiftModifier))) {
                                clipPanel.sel = Math.min(n - 1, clipPanel.sel + 1);
                            } else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) {
                                clipPanel.sel = Math.max(0, clipPanel.sel - 1);
                            } else if (e.key === Qt.Key_PageDown) {
                                clipPanel.sel = Math.min(n - 1, clipPanel.sel + 8);
                            } else if (e.key === Qt.Key_PageUp) {
                                clipPanel.sel = Math.max(0, clipPanel.sel - 8);
                            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                clipPanel.pick(clipPanel.shown[clipPanel.sel]);
                            } else if (e.key === Qt.Key_Delete) {
                                clipPanel.remove(clipPanel.shown[clipPanel.sel]);
                            } else return;
                            clipView.positionViewAtIndex(clipPanel.sel, ListView.Contain);
                            e.accepted = true;
                        }
                        Text {
                            visible: clipSearch.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Search clipboard history"
                            color: root.cMuted
                            font: clipSearch.font
                        }
                    }
                }
            }

            ListView {
                id: clipView
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: clipTop.bottom
                anchors.bottom: clipFoot.top
                anchors.margins: 10
                clip: true
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds
                model: clipPanel.shown
                delegate: Rectangle {
                    id: clipRow
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === clipPanel.sel
                    width: clipView.width
                    height: modelData.image ? 64 : clipText.lineCount > 1 ? 52 : 36
                    radius: 8
                    color: cur ? root.cSurface2 : clipMouse.containsMouse ? root.cSurface : "transparent"
                    border.color: cur ? root.cMuted : "transparent"
                    border.width: 1
                    Image {
                        id: clipImg
                        visible: clipRow.modelData.image
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 84
                        height: 52
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        sourceSize.width: 168
                        source: clipRow.modelData.image
                                ? "file://" + clipPanel.thumbDir + "/" + clipRow.modelData.id + "?" + clipPanel.thumbGen : ""
                    }
                    Text {
                        id: clipText
                        anchors.left: clipRow.modelData.image ? clipImg.right : parent.left
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: clipRow.modelData.text
                        color: clipRow.cur ? root.cWhite : root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    MouseArea {
                        id: clipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        onEntered: clipPanel.sel = clipRow.index
                        onClicked: function (m) {
                            if (m.button === Qt.LeftButton) clipPanel.pick(clipRow.modelData);
                            else clipPanel.remove(clipRow.modelData);
                        }
                    }
                }
            }
            Text {
                visible: clipPanel.shown.length === 0
                anchors.centerIn: clipView
                text: clipPanel.loading ? "Loading…" : clipPanel.entries.length ? "No matches" : "Nothing copied yet"
                color: root.cMuted
                font.family: root.fontFamily
                font.pixelSize: 12
            }

            Text {
                id: clipFoot
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 12
                text: "Enter / click  copy   ·   Del / right-click  remove   ·   Esc  close"
                color: root.cMuted
                font.family: root.fontFamily
                font.pixelSize: 10
            }
        }
    }

    // ============================================================
    //  ON-SCREEN DISPLAY: volume / mute / mic / brightness changes
    //  (volume + mic are watched in PipeWire; brightness is reported by
    //   ~/.local/bin/osd-brightness, which the brightness keys run)
    // ============================================================
    property string osdKind: ""        // "volume" | "mic" | "brightness"
    property real osdValue: 0          // 0..1
    property bool osdMuted: false
    property bool osdReady: false      // ignore the values PipeWire reports at startup
    Timer { running: true; interval: 3000; onTriggered: root.osdReady = true }

    function showOsd(kind, value, muted) {
        if (!osdReady) return;
        // the media popup / quick settings have their own sliders; no OSD on top of them
        if (kind === "volume" && (mediaPopup.visible || flyout.visible)) return;
        osdKind = kind;
        osdValue = Math.max(0, Math.min(1, value));
        osdMuted = muted;
        osd.shown = true;
        osdHide.restart();
    }
    Timer { id: osdHide; interval: 1400; onTriggered: osd.shown = false }

    readonly property real sinkVol: sink && sink.audio ? sink.audio.volume : 0
    readonly property bool sinkMuted: sink && sink.audio ? sink.audio.muted : false
    onSinkVolChanged: showOsd("volume", sinkVol, sinkMuted)
    onSinkMutedChanged: showOsd("volume", sinkVol, sinkMuted)

    readonly property var micNode: Pipewire.defaultAudioSource
    readonly property bool micMuted: micNode && micNode.audio ? micNode.audio.muted : false
    onMicMutedChanged: showOsd("mic", micNode && micNode.audio ? micNode.audio.volume : 0, micMuted)

    // brightness: the key helper writes the new percentage to this file
    readonly property string osdBrightFile: Quickshell.env("XDG_RUNTIME_DIR") + "/osd-brightness"
    Process {
        running: true
        command: ["sh", "-c", "[ -e \"$1\" ] || echo -1 > \"$1\"", "sh", root.osdBrightFile]
        onExited: brightWatch.path = root.osdBrightFile
    }
    FileView {
        id: brightWatch
        watchChanges: true
        printErrors: false
        property bool primed: false
        onFileChanged: reload()
        onLoaded: {
            var v = parseInt(text());
            if (!primed) { primed = true; return; }
            if (v >= 0) {
                stats.brightness = v;
                root.showOsd("brightness", v / 100, false);
            }
        }
    }

    PanelWindow {
        id: osd
        property bool shown: false
        visible: shown || osdBody.opacity > 0
        color: "transparent"
        anchors.bottom: true
        margins.bottom: 90
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        aboveWindows: true
        WlrLayershell.namespace: "rice-osd"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}                 // clicks go straight through
        implicitWidth: 300
        implicitHeight: 52

        Rectangle {
            id: osdBody
            anchors.fill: parent
            radius: 14
            color: Qt.rgba(0.07, 0.07, 0.07, 0.94)
            border.color: "#999999"
            border.width: 1
            opacity: osd.shown ? 1 : 0
            scale: osd.shown ? 1 : 0.94
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Text {
                id: osdIcon
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 22
                horizontalAlignment: Text.AlignHCenter
                text: root.osdKind === "brightness" ? (root.osdValue < 0.34 ? root.g(0xF00DE) : root.osdValue < 0.67 ? root.g(0xF00DF) : root.g(0xF00E0))
                      : root.osdKind === "mic" ? (root.osdMuted ? root.g(0xF036D) : root.g(0xF036C))
                      : root.volIcon(root.osdValue, root.osdMuted)
                color: root.osdMuted ? root.cMuted : root.cWhite
                font.family: root.fontFamily
                font.pixelSize: 20
            }
            Rectangle {
                id: osdTrack
                anchors.left: osdIcon.right
                anchors.leftMargin: 14
                anchors.right: osdPct.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                height: 6
                radius: 3
                color: root.cSurface2
                visible: root.osdKind !== "mic"
                Rectangle {
                    width: parent.width * (root.osdMuted ? 0 : root.osdValue)
                    height: parent.height
                    radius: parent.radius
                    color: root.cWhite
                    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                anchors.left: osdIcon.right
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                visible: root.osdKind === "mic"
                text: root.osdMuted ? "Microphone muted" : "Microphone on"
                color: root.cWhite
                font.family: root.fontFamily
                font.pixelSize: 13
            }
            Text {
                id: osdPct
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                horizontalAlignment: Text.AlignRight
                visible: root.osdKind !== "mic"
                text: root.osdMuted ? "mute" : Math.round(root.osdValue * 100) + "%"
                color: root.cFg
                font.family: root.fontFamily
                font.pixelSize: 13
            }
        }
    }

    // ============================================================
    //  SOUNDBOARD (the mic button on the right of the bar): Rice Mic on/off,
    //  clips, share app audio, add clips. Opens under the button.
    // ============================================================
    PanelWindow {
        id: sbPopup
        visible: false
        color: "transparent"
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true
        WlrLayershell.namespace: "rice-soundboard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        readonly property string sbBin: Quickshell.env("HOME") + "/.local/bin/soundboard"
        readonly property string sbDir: Quickshell.env("HOME") + "/Music/Soundboard"
        property var sb: ({ on: false, sounds: [], apps: [], mic: "", volume: 100 })
        property bool sbReady: true
        property bool sbBusy: false
        property string sbStatus: ""
        property real cardRight: 0          // screen x of the mic button's right edge

        function toggle() {
            if (visible) { visible = false; return; }
            tooltip.hide();
            flyout.visible = false;
            btPopup.close("soundboard");
            mediaPopup.close();
            startMenu.close();
            calendar.visible = false;
            cardRight = micPill.mapToItem(bar.contentItem, micPill.width, 0).x + 8;
            sbStatus = "";
            visible = true;
            sbRefresh();
            sbKeys.forceActiveFocus();
        }
        function close() { visible = false; }
        function setVolume(v) {
            v = Math.max(0, Math.min(150, Math.round(v)));
            var o = Object.assign({}, sb);
            o.volume = v;
            sb = o;
            sbVolSave.restart();
        }
        Timer {     // write the volume once the slider / wheel settles
            id: sbVolSave
            interval: 250
            onTriggered: Quickshell.execDetached([sbPopup.sbBin, "volume", String(sbPopup.sb.volume)])
        }
        function sbRefresh() { if (!sbList.running) { sbList.buf = ""; sbList.running = true; } }
        function sbRun(args) {
            if (sbAct.running) return;
            sbBusy = true;
            sbAct.command = [sbBin].concat(args);
            sbAct.running = true;
        }
        Timer {
            interval: 1500
            repeat: true
            running: sbPopup.visible
            onTriggered: sbPopup.sbRefresh()
        }
        Process {
            id: sbList
            property string buf: ""
            command: [sbPopup.sbBin, "list", "--json"]
            stdout: SplitParser { onRead: function (line) { sbList.buf += line; } }
            onExited: function (code) {
                sbPopup.sbReady = code === 0;
                try { if (code === 0) sbPopup.sb = JSON.parse(sbList.buf); } catch (e) {}
            }
        }
        Process {
            id: sbAct
            stdout: SplitParser { onRead: function (line) { if (line.trim() !== "") sbPopup.sbStatus = line.trim(); } }
            stderr: SplitParser { onRead: function (line) { if (line.trim() !== "") sbPopup.sbStatus = line.trim().replace(/^soundboard: /, ""); } }
            onExited: { sbPopup.sbBusy = false; sbPopup.sbRefresh(); }
        }

        // a click anywhere outside the card closes it
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: sbPopup.close()
            onWheel: function (w) { w.accepted = true; }
        }
        Item {
            id: sbKeys
            anchors.fill: parent
            focus: sbPopup.visible
            Keys.onEscapePressed: sbPopup.close()
        }

        Rectangle {
            id: sbCard
            width: 330
            height: 516
            x: Math.max(8, Math.min(parent.width - width - 8, sbPopup.cardRight - width))
            y: 56          // bar: 6 margin + 42 height, then an 8px gap
            radius: 12
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Item {
                id: sbHeader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                height: 20
                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7
                    Text {
                        text: root.g(0xF00E6)
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "SOUNDBOARD"
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.5
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u2715"
                    color: sbCloseMouse.containsMouse ? root.cWhite : root.cMuted
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    MouseArea {
                        id: sbCloseMouse
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sbPopup.close()
                    }
                }
            }

            Item {
                id: sbBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: sbHeader.bottom
                anchors.bottom: parent.bottom
                anchors.margins: 12
                anchors.topMargin: 8

                Column {
                    id: sbCol
                    width: parent.width
                    spacing: 8

                    // Rice Mic on / off
                    Rectangle {
                        width: parent.width
                        height: 52
                        radius: 10
                        color: sbPopup.sb.on ? root.cSurface2 : root.cSurface
                        border.color: sbPopup.sb.on ? root.cWhite : root.cOutline
                        border.width: 1
                        Text {
                            id: sbMicIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: sbPopup.sb.on ? root.g(0xF036C) : root.g(0xF036D)
                            color: sbPopup.sb.on ? root.cWhite : root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 20
                        }
                        Column {
                            anchors.left: sbMicIcon.right
                            anchors.leftMargin: 10
                            anchors.right: sbSwitch.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text {
                                text: "RICE MIC  ·  " + (sbPopup.sb.on ? "ON" : "OFF")
                                color: root.cWhite
                                font.family: root.fontFamily
                                font.pixelSize: 11
                                font.bold: true
                                font.letterSpacing: 1.2
                            }
                            Text {
                                width: parent.width
                                text: !sbPopup.sbReady ? "Install the soundboard command first"
                                      : sbPopup.sb.on ? "Pick “Rice Mic” as the mic in Discord / Zoom / games"
                                      : "Off — your mic isn't captured"
                                color: root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }
                        Rectangle {   // switch
                            id: sbSwitch
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 38
                            height: 20
                            radius: 10
                            opacity: sbPopup.sbBusy ? 0.5 : 1
                            color: sbPopup.sb.on ? root.cWhite : root.cSurface2
                            border.color: sbPopup.sb.on ? root.cWhite : root.cMuted
                            border.width: 1
                            Rectangle {
                                width: 14
                                height: 14
                                radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                x: sbPopup.sb.on ? parent.width - width - 3 : 3
                                color: sbPopup.sb.on ? root.cBg : root.cFg2
                                Behavior on x { NumberAnimation { duration: 140 } }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: !sbPopup.sbBusy && sbPopup.sbReady
                            onClicked: sbPopup.sbRun([sbPopup.sb.on ? "off" : "on"])
                        }
                    }

                    // clips
                    Item {
                        width: parent.width
                        height: 18
                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "SOUNDS" + (sbPopup.sb.sounds.length ? "  ·  " + sbPopup.sb.sounds.length : "")
                            color: root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            font.letterSpacing: 1.5
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            Repeater {
                                model: [[root.g(0xF04DB), "stop"], [root.g(0xF0256), "folder"]]
                                delegate: Text {
                                    id: sbTool
                                    required property var modelData
                                    text: modelData[0]
                                    color: sbToolMouse.containsMouse ? root.cWhite : root.cMuted
                                    font.family: root.fontFamily
                                    font.pixelSize: 14
                                    MouseArea {
                                        id: sbToolMouse
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (sbTool.modelData[1] === "stop") Quickshell.execDetached([sbPopup.sbBin, "stop"]);
                                            else {
                                                sbPopup.close();
                                                root.launch("mkdir -p \"" + sbPopup.sbDir + "\" && dolphin \"" + sbPopup.sbDir + "\"");
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // clip volume
                    Item {
                        width: parent.width
                        height: 18
                        Text {
                            id: sbVolIcon
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.g(sbPopup.sb.volume === 0 ? 0xF075F : 0xF057E)
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 14
                        }
                        MediaSlider {
                            anchors.left: sbVolIcon.right
                            anchors.leftMargin: 8
                            anchors.right: sbVolText.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            value: (sbPopup.sb.volume === undefined ? 100 : sbPopup.sb.volume) / 150
                            onMoved: function (v) { sbPopup.setVolume(v * 150); }
                            onCommitted: function (v) { sbPopup.setVolume(v * 150); }
                            onWheeled: function (d) { sbPopup.setVolume((sbPopup.sb.volume === undefined ? 100 : sbPopup.sb.volume) + d * 5); }
                        }
                        Text {
                            id: sbVolText
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 34
                            horizontalAlignment: Text.AlignRight
                            text: (sbPopup.sb.volume === undefined ? 100 : sbPopup.sb.volume) + "%"
                            color: root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                    }
                    Flickable {
                        id: sbClips
                        width: parent.width
                        height: 136
                        clip: true
                        contentHeight: sbGrid.height
                        boundsBehavior: Flickable.StopAtBounds
                        Grid {
                            id: sbGrid
                            width: parent.width
                            columns: 2
                            spacing: 5
                            Repeater {
                                model: sbPopup.sb.sounds
                                delegate: Rectangle {
                                    id: sbClip
                                    required property var modelData
                                    required property int index
                                    width: (sbGrid.width - sbGrid.spacing) / 2
                                    height: 30
                                    radius: 7
                                    color: sbClipMouse.pressed ? root.cWhite : sbClipMouse.containsMouse ? root.cSurface2 : root.cSurface
                                    border.color: sbClipMouse.containsMouse ? root.cMuted : root.cOutline
                                    border.width: 1
                                    Text {     // hotkey number: Super+Alt+1..9
                                        id: sbClipNum
                                        visible: sbClip.index < 9
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(sbClip.index + 1)
                                        color: sbClipMouse.pressed ? root.cBg : root.cMuted
                                        font.family: root.fontFamily
                                        font.pixelSize: 10
                                        font.bold: true
                                    }
                                    Text {
                                        anchors.fill: parent
                                        anchors.leftMargin: sbClipNum.visible ? 22 : 9
                                        anchors.rightMargin: 9
                                        verticalAlignment: Text.AlignVCenter
                                        text: sbClip.modelData.name
                                        color: sbClipMouse.pressed ? root.cBg : root.cFg
                                        font.family: root.fontFamily
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                    MouseArea {
                                        id: sbClipMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            Quickshell.execDetached([sbPopup.sbBin, "play", sbClip.modelData.path]);
                                            sbPopup.sbStatus = (sbPopup.sb.on ? "▶ " : "▶ only you hear it (Rice Mic off): ") + sbClip.modelData.name;
                                        }
                                    }
                                }
                            }
                        }
                        Text {
                            visible: sbPopup.sb.sounds.length === 0
                            width: parent.width
                            topPadding: 26
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            text: "No sounds yet — add a clip below,\nor drop audio files in ~/Music/Soundboard"
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: root.cOutline }

                    // app audio sharing
                    Text {
                        text: "SHARE APP AUDIO"
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.5
                    }
                    ListView {
                        id: sbApps
                        width: parent.width
                        height: 84
                        clip: true
                        spacing: 3
                        boundsBehavior: Flickable.StopAtBounds
                        model: sbPopup.sb.apps
                        delegate: Rectangle {
                            id: sbApp
                            required property var modelData
                            width: sbApps.width
                            height: 26
                            radius: 6
                            color: modelData.shared ? root.cSurface2 : "transparent"
                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.right: sbShare.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: sbApp.modelData.app + (sbApp.modelData.title ? "  ·  " + sbApp.modelData.title : "")
                                color: sbApp.modelData.shared ? root.cWhite : root.cFg
                                font.family: root.fontFamily
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                id: sbShare
                                anchors.right: parent.right
                                anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                width: sbShareText.implicitWidth + 14
                                height: 20
                                radius: 10
                                opacity: sbPopup.sb.on ? 1 : 0.4
                                color: sbApp.modelData.shared ? root.cWhite : sbShareMouse.containsMouse ? root.cSurface2 : root.cSurface
                                border.color: sbApp.modelData.shared ? root.cWhite : root.cOutline
                                border.width: 1
                                Text {
                                    id: sbShareText
                                    anchors.centerIn: parent
                                    text: sbApp.modelData.shared ? "shared" : "share"
                                    color: sbApp.modelData.shared ? root.cBg : root.cFg
                                    font.family: root.fontFamily
                                    font.pixelSize: 10
                                    font.bold: sbApp.modelData.shared
                                }
                                MouseArea {
                                    id: sbShareMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (!sbPopup.sb.on) { sbPopup.sbStatus = "turn Rice Mic on first"; return; }
                                        sbPopup.sbRun([sbApp.modelData.shared ? "unshare" : "share", sbApp.modelData.app]);
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        visible: sbPopup.sb.apps.length === 0
                        text: "No apps are playing sound right now"
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        leftPadding: 4
                    }
                }

                // add a clip
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 6
                    Rectangle {
                        width: parent.width
                        height: 28
                        radius: 14
                        color: root.cSurface
                        border.color: sbAddInput.activeFocus ? root.cMuted : root.cOutline
                        border.width: 1
                        Text {
                            id: sbAddIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.g(0xF0415)
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 13
                        }
                        TextInput {
                            id: sbAddInput
                            anchors.left: sbAddIcon.right
                            anchors.leftMargin: 7
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: !sbPopup.sbBusy
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            clip: true
                            selectionColor: root.cSurface2
                            Keys.onEscapePressed: { text = ""; sbKeys.forceActiveFocus(); }
                            Keys.onReturnPressed: {
                                if (text.trim() === "") return;
                                sbPopup.sbStatus = "adding…";
                                sbPopup.sbRun(["add", text.trim()]);
                                text = "";
                            }
                            Text {
                                visible: sbAddInput.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Add a clip: link or file path, then Enter"
                                color: root.cMuted
                                font: sbAddInput.font
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        text: sbPopup.sbStatus !== "" ? sbPopup.sbStatus : "Super+Alt+1–9 plays a clip  ·  Super+Alt+0 stops"
                        color: sbPopup.sbStatus !== "" ? root.cFg : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        elide: Text.ElideRight
                        leftPadding: 4
                    }
                }
            }
        }
    }

    // ============================================================
    //  MEDIA POPUP (opened by the now-playing pill)
    //  art + track info, visualizer, seek, controls, volume, output device
    //  keys: ↑↓←→ pick output · Enter switch · Space play/pause · n/p track · Esc close
    // ============================================================
    PanelWindow {
        id: mediaPopup
        visible: false
        color: "transparent"
        anchors {
            top: true
            left: true
        }
        margins {
            top: 56        // bar: 6 margin + 42 height, then an 8px gap
            // the drawer opens to the right; near the screen edge the whole popup moves left
            left: Math.max(8, Math.min(mediaPopup.baseLeft, bar.width + 8 - mediaPopup.implicitWidth))
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true
        WlrLayershell.namespace: "rice-media"
        WlrLayershell.layer: WlrLayer.Overlay
        // keyboard stays with the panel the whole time it is open: switching it off (e.g. while the
        // pointer crossed the gap to the drawer) made Hyprland end the click-outside grab and close it
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        implicitWidth: cardW + drawerW + drawerGap
        implicitHeight: Math.max(mediaBg.height, libDrawer.visible ? libDrawer.height : 0)

        // ---- geometry: player card on the left, library drawer sliding out on its right ----
        readonly property int cardW: 300
        readonly property int drawerFull: 320
        property real baseLeft: 8                 // where the card sits when the drawer is closed
        property real drawerW: libOpen ? drawerFull : 0
        Behavior on drawerW { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        readonly property real drawerGap: 8 * drawerW / drawerFull

        // hover over the card or the drawer counts as "in use"
        property int hoverN: 0
        function hoverPart(on) {
            hoverN = Math.max(0, hoverN + (on ? 1 : -1));
            if (hoverN > 0) {
                hoverOff.stop();
                hovered = true;
                entered = true;
                justOpened = false;
                mediaLeave.stop();
                if (!typing) mediaKeys.forceActiveFocus();
            } else {
                hoverOff.restart();    // crossing the gap between card and drawer is not leaving
            }
        }
        Timer {
            id: hoverOff
            interval: 250
            onTriggered: {
                if (mediaPopup.hoverN > 0) return;
                mediaPopup.hovered = false;
                if (mediaPopup.entered) mediaLeave.restart();
            }
        }

        readonly property var p: root.player
        readonly property string artUrl: p !== null ? (p.trackArtUrl || "") : ""
        readonly property bool hasLength: p !== null && p.lengthSupported && p.length > 0

        // ---- music library (the `music` command in ~/.local/bin) ----
        readonly property string musicBin: Quickshell.env("HOME") + "/.local/bin/music"
        property bool musicReady: true
        property bool libOpen: false
        property var libTracks: []
        property string libQuery: ""
        readonly property var libShown: {
            var words = libQuery.toLowerCase().split(/\s+/).filter(function (w) { return w !== ""; });
            if (!words.length) return libTracks;
            return libTracks.filter(function (t) {
                var hay = (t.title + " " + t.artist + " " + t.album).toLowerCase();
                for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) < 0) return false;
                return true;
            });
        }
        property bool dlBusy: false
        property string dlStatus: ""
        readonly property bool typing: libSearch.activeFocus || dlInput.activeFocus

        function loadLibrary() {
            if (!libProc.running) { libProc.buf = ""; libProc.running = true; }
        }
        onLibOpenChanged: if (libOpen) loadLibrary()
        function playTrack(t) { Quickshell.execDetached([musicBin, "play", t.path]); }
        function queueTrack(t) {
            Quickshell.execDetached([musicBin, "add", t.path]);
            dlStatus = "queued: " + t.title;
        }
        function download(q) {
            dlBusy = true;
            dlStatus = "searching for “" + q + "”…";
            dlProc.command = [musicBin, "get", q];
            dlProc.running = true;
        }

        Process {
            id: libProc
            property string buf: ""
            command: [mediaPopup.musicBin, "list", "--json"]
            stdout: SplitParser { onRead: function (line) { libProc.buf += line; } }
            onExited: function (code) {
                mediaPopup.musicReady = code === 0;
                try { mediaPopup.libTracks = code === 0 ? JSON.parse(libProc.buf || "[]") : []; }
                catch (e) { mediaPopup.libTracks = []; }
            }
        }
        Process {
            id: dlProc
            stdout: SplitParser { onRead: function (line) { if (line.trim() !== "") mediaPopup.dlStatus = line.trim(); } }
            stderr: SplitParser { onRead: function (line) { if (line.trim() !== "") mediaPopup.dlStatus = line.trim(); } }
            onExited: function (code) {
                mediaPopup.dlBusy = false;
                if (code === 0 && mediaPopup.dlStatus.indexOf("saved") === 0)
                    mediaPopup.dlStatus = "✓ " + mediaPopup.dlStatus.replace(/^saved: /, "added ");
                mediaPopup.loadLibrary();
            }
        }

        function toggle() {
            tooltip.hide();
            flyout.visible = false;
            btPopup.close("media popup");
            startMenu.close();
            if (visible) { close(); return; }
            // the click on the pill that just closed it via the grab shouldn't reopen it
            if (Date.now() - grabClosedAt < 400) return;
            // left edge lines up with the media pill (bar has an 8px left margin)
            var x = mediaPill.mapToItem(bar.contentItem, 0, 0).x + 8;
            baseLeft = Math.max(8, Math.min(bar.width + 8 - cardW, x));
            visible = true;
        }
        function close() { visible = false; }

        // ---- output device selector: browse with wheel / arrows, apply with Enter / click ----
        property int devPending: -1
        readonly property int devCur: root.audioSinks.indexOf(root.sink)
        readonly property int devShown: devPending >= 0 && devPending < root.audioSinks.length ? devPending : devCur
        function cycleDev(d) {
            var n = root.audioSinks.length;
            if (n < 2) return;
            var i = devShown < 0 ? 0 : devShown;
            devPending = ((i + d) % n + n) % n;
        }
        function applyDev() {
            var node = root.audioSinks[devShown];
            if (node && devShown !== devCur) Pipewire.preferredDefaultAudioSink = node;
            devPending = -1;
        }

        // closes on a click outside it, when the pointer leaves the panel for a moment
        // (after having been on it), when the pill is clicked again, or with Esc
        property bool entered: false
        property bool hovered: false
        property bool justOpened: false
        readonly property bool busy: seekSlider.dragging || volSlider.dragging || typing
        onVisibleChanged: {
            entered = false;
            hovered = false;
            hoverN = 0;
            hoverOff.stop();
            mediaLeave.stop();
            devPending = -1;
            justOpened = visible;
            if (visible) { openGrace.restart(); mediaKeys.forceActiveFocus(); if (libOpen) loadLibrary(); }
            mediaGrab.active = visible;
        }
        // a click anywhere outside the panel (bar included) closes it
        property real grabClosedAt: 0
        // the grab only starts once the panel is actually mapped on screen, which can lag
        // a moment behind `visible`; keep asking until Hyprland confirms it is active
        Timer {
            interval: 100
            repeat: true
            running: mediaPopup.visible && !mediaGrab.active
            onTriggered: mediaGrab.active = true
        }
        HyprlandFocusGrab {
            id: mediaGrab
            windows: [mediaPopup]
            onCleared: {
                mediaPopup.grabClosedAt = Date.now();
                mediaPopup.close();
            }
        }
        Timer {
            id: mediaLeave
            interval: 700
            onTriggered: if (!mediaPopup.busy) mediaPopup.close(); else restart()
        }
        // if the pointer never comes over, give the keyboard back after a few seconds
        Timer {
            id: openGrace
            interval: 5000
            onTriggered: mediaPopup.justOpened = false
        }

        Item {
            id: mediaKeys
            anchors.fill: parent
            focus: true
            Keys.onPressed: function (e) {
                var p = mediaPopup.p;
                switch (e.key) {
                case Qt.Key_Escape: mediaPopup.close(); break;
                case Qt.Key_Up:
                case Qt.Key_Left: mediaPopup.cycleDev(-1); break;
                case Qt.Key_Down:
                case Qt.Key_Right:
                case Qt.Key_Tab: mediaPopup.cycleDev(1); break;
                case Qt.Key_Return:
                case Qt.Key_Enter: mediaPopup.applyDev(); break;
                case Qt.Key_Space: if (p && p.canTogglePlaying) p.togglePlaying(); break;
                case Qt.Key_N: if (p && p.canGoNext) p.next(); break;
                case Qt.Key_P: if (p && p.canGoPrevious) p.previous(); break;
                default: return;
                }
                e.accepted = true;
            }
        }

        Rectangle {
            id: mediaBg
            anchors.left: parent.left
            width: mediaPopup.cardW
            height: mediaCol.implicitHeight + 20
            radius: 12
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            HoverHandler { onHoveredChanged: mediaPopup.hoverPart(hovered) }

            // ---- blurred, desaturated album art behind everything ----
            Item {
                anchors.fill: parent
                anchors.margins: 1
                visible: backdropImg.status === Image.Ready
                Image {
                    id: backdropImg
                    anchors.fill: parent
                    source: mediaPopup.artUrl
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 160
                    sourceSize.height: 160
                    visible: false
                }
                Rectangle {
                    id: backdropMask
                    anchors.fill: parent
                    radius: 11
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    anchors.fill: parent
                    source: backdropImg
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 64
                    saturation: -1.0
                    brightness: -0.45
                    opacity: 0.55
                    maskEnabled: true
                    maskSource: backdropMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
            }

            Column {
                id: mediaCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 10
                spacing: 6

                // ---- header (only with several players): app icon + name, player switcher ----
                Item {
                    visible: Mpris.players.values.length > 1
                    width: parent.width
                    height: 16
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        Image {
                            id: appIcon
                            width: 14
                            height: 14
                            sourceSize.width: 14
                            sourceSize.height: 14
                            anchors.verticalCenter: parent.verticalCenter
                            source: mediaPopup.p !== null && mediaPopup.p.desktopEntry
                                    ? Quickshell.iconPath(mediaPopup.p.desktopEntry, true) : ""
                            visible: source != "" && status === Image.Ready
                            layer.enabled: true
                            layer.effect: MultiEffect { saturation: -1.0 }
                        }
                        Text {
                            visible: !appIcon.visible
                            text: root.g(0xF0387)
                            color: root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: mediaPopup.p !== null ? (mediaPopup.p.identity || "Player").toUpperCase() : "MEDIA"
                            color: root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            font.letterSpacing: 1.5
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    // one chip per player when more than one is open; click to switch
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        visible: Mpris.players.values.length > 1
                        Repeater {
                            model: Mpris.players
                            delegate: Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool cur: modelData === mediaPopup.p
                                width: chipText.implicitWidth + 12
                                height: 18
                                radius: 9
                                color: cur ? root.cWhite : chipMouse.containsMouse ? root.cSurface2 : root.cSurface
                                border.color: cur ? root.cWhite : root.cOutline
                                border.width: 1
                                Text {
                                    id: chipText
                                    anchors.centerIn: parent
                                    text: (chip.modelData.isPlaying ? "▶ " : "") + (chip.modelData.identity || "?")
                                    color: chip.cur ? root.cBg : root.cFg
                                    font.family: root.fontFamily
                                    font.pixelSize: 10
                                    font.bold: chip.cur
                                }
                                MouseArea {
                                    id: chipMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.mediaSel = chip.modelData
                                }
                            }
                        }
                    }
                }

                // ---- nothing playing ----
                Row {
                    visible: mediaPopup.p === null
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    topPadding: 6
                    bottomPadding: 6
                    Text {
                        text: root.g(0xF075A)
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 22
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Nothing playing"
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // ---- album art + track info ----
                Row {
                    visible: mediaPopup.p !== null
                    width: parent.width
                    spacing: 10

                    Item {
                        id: artBox
                        width: 62
                        height: 62
                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: root.cSurface
                            visible: artImg.status !== Image.Ready
                            Text {
                                anchors.centerIn: parent
                                text: root.g(0xF075A)
                                color: root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 26
                            }
                        }
                        Image {
                            id: artImg
                            anchors.fill: parent
                            source: mediaPopup.artUrl
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 124
                            sourceSize.height: 124
                            visible: false
                        }
                        Rectangle {
                            id: artMask
                            anchors.fill: parent
                            radius: 7
                            visible: false
                            layer.enabled: true
                        }
                        // black & white by default; colour fades in while hovered
                        MultiEffect {
                            anchors.fill: parent
                            source: artImg
                            visible: artImg.status === Image.Ready
                            maskEnabled: true
                            maskSource: artMask
                            maskThresholdMin: 0.5
                            maskSpreadAtMin: 1.0
                            saturation: artHover.hovered ? 0.0 : -1.0
                            Behavior on saturation { NumberAnimation { duration: 300 } }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: "transparent"
                            border.color: root.cOutline
                            border.width: 1
                        }
                        HoverHandler { id: artHover }
                    }

                    Column {
                        width: parent.width - artBox.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        Text {
                            width: parent.width
                            text: mediaPopup.p !== null ? (mediaPopup.p.trackTitle || mediaPopup.p.identity || "Unknown") : ""
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            font.bold: true
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: mediaPopup.p !== null ? (mediaPopup.p.trackArtist || "") : ""
                            color: root.cFg
                            font.family: root.fontFamily
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        // album · player app on one muted line
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: mediaPopup.p === null ? ""
                                  : [mediaPopup.p.trackAlbum || "", mediaPopup.p.identity || ""]
                                    .filter(function (x) { return x !== ""; }).join("  \u00b7  ")
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                }

                // ---- visualizer (needs cava; hidden otherwise) ----
                Item {
                    id: vis
                    visible: mediaPopup.p !== null && root.cavaBars.length > 0
                    width: parent.width
                    height: 16
                    readonly property int n: Math.max(1, root.cavaBars.length)
                    Row {
                        anchors.fill: parent
                        spacing: 2
                        Repeater {
                            model: root.cavaBars.length
                            delegate: Rectangle {
                                required property int index
                                readonly property real lvl: Math.max(0, Math.min(1, (root.cavaBars[index] || 0) / 100))
                                width: (vis.width - (vis.n - 1) * 2) / vis.n
                                height: Math.max(2, lvl * vis.height)
                                anchors.bottom: parent.bottom
                                radius: 1
                                color: Qt.rgba(1, 1, 1, 0.3 + 0.7 * lvl)
                                Behavior on height { NumberAnimation { duration: 60 } }
                            }
                        }
                    }
                }

                // ---- seek bar with times on either side ----
                Item {
                    visible: mediaPopup.p !== null
                    width: parent.width
                    height: 12
                    Text {
                        id: posText
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        text: !mediaPopup.hasLength ? "live"
                              : root.fmtTime(seekSlider.dragging ? seekSlider.dragValue * mediaPopup.p.length
                                                                 : mediaPopup.p.position)
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 10
                    }
                    MediaSlider {
                        id: seekSlider
                        anchors.left: posText.right
                        anchors.right: lenText.left
                        anchors.leftMargin: 4
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: mediaPopup.hasLength
                        interactive: mediaPopup.p !== null && mediaPopup.p.canSeek
                        value: mediaPopup.hasLength ? mediaPopup.p.position / mediaPopup.p.length : 0
                        onCommitted: function (v) {
                            if (mediaPopup.p && mediaPopup.hasLength) mediaPopup.p.position = v * mediaPopup.p.length;
                        }
                        onWheeled: function (d) {
                            if (mediaPopup.p && mediaPopup.p.canSeek)
                                mediaPopup.p.position = Math.max(0, mediaPopup.p.position + d * 5);
                        }
                    }
                    Text {
                        id: lenText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        horizontalAlignment: Text.AlignRight
                        text: mediaPopup.hasLength ? root.fmtTime(mediaPopup.p.length) : ""
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 10
                    }
                }

                // ---- transport controls ----
                Item {
                    visible: mediaPopup.p !== null
                    width: parent.width
                    height: 32
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        MediaBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            ok: mediaPopup.p !== null && mediaPopup.p.shuffleSupported
                            lit: ok && mediaPopup.p.shuffle
                            icon: lit ? root.g(0xF049D) : root.g(0xF049E)
                            onClicked: mediaPopup.p.shuffle = !mediaPopup.p.shuffle
                        }
                        MediaBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            ok: mediaPopup.p !== null && mediaPopup.p.canGoPrevious
                            icon: root.g(0xF04AE)
                            onClicked: mediaPopup.p.previous()
                        }
                        MediaBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            big: true
                            ok: mediaPopup.p !== null && mediaPopup.p.canTogglePlaying
                            icon: mediaPopup.p !== null && mediaPopup.p.isPlaying ? root.g(0xF03E4) : root.g(0xF040A)
                            onClicked: mediaPopup.p.togglePlaying()
                        }
                        MediaBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            ok: mediaPopup.p !== null && mediaPopup.p.canGoNext
                            icon: root.g(0xF04AD)
                            onClicked: mediaPopup.p.next()
                        }
                        MediaBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            readonly property int ls: ok ? mediaPopup.p.loopState : MprisLoopState.None
                            ok: mediaPopup.p !== null && mediaPopup.p.loopSupported
                            lit: ls !== MprisLoopState.None
                            icon: ls === MprisLoopState.Track ? root.g(0xF0458)
                                  : ls === MprisLoopState.Playlist ? root.g(0xF0456) : root.g(0xF0457)
                            // off -> playlist -> track -> off
                            onClicked: mediaPopup.p.loopState = ls === MprisLoopState.None ? MprisLoopState.Playlist
                                       : ls === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                // ---- system volume ----
                Item {
                    visible: root.sink !== null && root.sink.audio !== null
                    width: parent.width
                    height: 20
                    readonly property real vol: visible ? root.sink.audio.volume : 0
                    readonly property bool muted: visible && root.sink.audio.muted
                    MediaBtn {
                        id: muteBtn
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20
                        lit: parent.muted
                        icon: root.volIcon(parent.vol, parent.muted)
                        onClicked: root.sink.audio.muted = !root.sink.audio.muted
                    }
                    MediaSlider {
                        id: volSlider
                        anchors.left: muteBtn.right
                        anchors.leftMargin: 8
                        anchors.right: volPct.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        value: parent.muted ? 0 : Math.min(1, parent.vol)
                        onMoved: function (v) {
                            root.sink.audio.volume = v;
                            if (v > 0 && root.sink.audio.muted) root.sink.audio.muted = false;
                        }
                        onWheeled: function (d) {
                            root.sink.audio.volume = Math.max(0, Math.min(1, root.sink.audio.volume + d * 0.05));
                        }
                    }
                    Text {
                        id: volPct
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        horizontalAlignment: Text.AlignRight
                        text: parent.muted ? "mute" : Math.round(parent.vol * 100) + "%"
                        color: root.cFg
                        font.family: root.fontFamily
                        font.pixelSize: 11
                    }
                }

                // ---- output device: shows the one in use; wheel / arrows browse, Enter / click switches ----
                Rectangle {
                    id: devRow
                    visible: root.audioSinks.length > 0
                    width: parent.width
                    height: 24
                    radius: 6
                    readonly property var node: root.audioSinks[mediaPopup.devShown] || null
                    readonly property bool pending: mediaPopup.devShown !== mediaPopup.devCur
                    readonly property bool many: root.audioSinks.length > 1
                    color: devMouse.containsMouse ? root.cSurface2 : root.cSurface
                    border.color: pending ? root.cWhite : devMouse.containsMouse ? root.cMuted : root.cOutline
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // whole row: click applies, wheel browses
                    MouseArea {
                        id: devMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: devRow.pending ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: mediaPopup.applyDev()
                        onWheel: function (w) { mediaPopup.cycleDev(w.angleDelta.y > 0 ? -1 : 1); }
                    }

                    Text {
                        id: devLeft
                        visible: devRow.many
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18
                        horizontalAlignment: Text.AlignHCenter
                        text: root.g(0xF0141)
                        color: devLeftMouse.containsMouse ? root.cWhite : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 15
                        MouseArea {
                            id: devLeftMouse
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mediaPopup.cycleDev(-1)
                        }
                    }
                    Text {
                        id: devIcon
                        anchors.left: devRow.many ? devLeft.right : parent.left
                        anchors.leftMargin: devRow.many ? 4 : 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.sinkIcon(devRow.node)
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 14
                    }
                    Text {
                        anchors.left: devIcon.right
                        anchors.leftMargin: 8
                        anchors.right: devHint.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: devRow.node ? (devRow.node.description || devRow.node.nickname || devRow.node.name) : ""
                        color: devRow.pending ? root.cFg : root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        font.bold: !devRow.pending
                        elide: Text.ElideRight
                    }
                    Text {
                        id: devHint
                        anchors.right: devRow.many ? devRight.left : parent.right
                        anchors.rightMargin: devRow.many ? 4 : 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: devRow.pending ? root.g(0xF0311) + " switch"
                              : devRow.many ? (mediaPopup.devShown + 1) + "/" + root.audioSinks.length : "●"
                        color: devRow.pending ? root.cWhite : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: devRow.pending ? 11 : 10
                    }
                    Text {
                        id: devRight
                        visible: devRow.many
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18
                        horizontalAlignment: Text.AlignHCenter
                        text: root.g(0xF0142)
                        color: devRightMouse.containsMouse ? root.cWhite : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 15
                        MouseArea {
                            id: devRightMouse
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mediaPopup.cycleDev(1)
                        }
                    }
                }

                // ---- library / downloader drawer toggle (the drawer slides out on the right) ----
                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                Rectangle {
                    id: libToggle
                    width: parent.width
                    height: 26
                    radius: 7
                    color: mediaPopup.libOpen ? root.cSurface2 : libToggleMouse.containsMouse ? root.cSurface : "transparent"
                    border.color: mediaPopup.libOpen ? root.cMuted : libToggleMouse.containsMouse ? root.cOutline : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        Text {
                            text: mediaPopup.libOpen ? root.g(0xF0141) : root.g(0xF0142)   // ‹ / ›
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 15
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: root.g(0xF0333)
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "LIBRARY & DOWNLOAD" + (mediaPopup.libTracks.length ? "  ·  " + mediaPopup.libTracks.length : "")
                            color: libToggleMouse.containsMouse || mediaPopup.libOpen ? root.cWhite : root.cFg2
                            font.family: root.fontFamily
                            font.pixelSize: 10
                            font.letterSpacing: 1.2
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {   // download in progress
                        visible: mediaPopup.dlBusy
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.g(0xF01DA)
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 13
                        SequentialAnimation on opacity {
                            running: mediaPopup.dlBusy
                            loops: Animation.Infinite
                            NumberAnimation { from: 1; to: 0.3; duration: 600 }
                            NumberAnimation { from: 0.3; to: 1; duration: 600 }
                        }
                    }
                    MouseArea {
                        id: libToggleMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mediaPopup.libOpen = !mediaPopup.libOpen
                    }
                }
            }
        }

        // ============================================================
        //  LIBRARY DRAWER: slides out to the right of the player card
        // ============================================================
        Rectangle {
            id: libDrawer
            anchors.right: parent.right
            anchors.top: parent.top
            width: mediaPopup.drawerW
            height: Math.max(mediaBg.height, 420)
            visible: width > 1
            radius: 12
            color: root.cBg1
            border.color: "#999999"
            border.width: 1
            clip: true

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            HoverHandler { onHoveredChanged: mediaPopup.hoverPart(hovered) }

            // content keeps its full width and is revealed as the drawer opens
            Item {
                id: drawerBody
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: mediaPopup.drawerFull
                opacity: mediaPopup.drawerW / mediaPopup.drawerFull

                Column {
                    id: drawerTop
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    // header: title + count, open the terminal app, close
                    Item {
                        width: parent.width
                        height: 20
                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 7
                            Text {
                                text: root.g(0xF0333)
                                color: root.cWhite
                                font.family: root.fontFamily
                                font.pixelSize: 14
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "LIBRARY" + (mediaPopup.libTracks.length ? "  ·  " + mediaPopup.libTracks.length + " songs" : "")
                                color: root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.5
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            Text {   // open the terminal app
                                text: root.g(0xF018D)
                                color: drAppMouse.containsMouse ? root.cWhite : root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 14
                                anchors.verticalCenter: parent.verticalCenter
                                MouseArea {
                                    id: drAppMouse
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { mediaPopup.close(); root.launch("kitty --class music -e " + mediaPopup.musicBin); }
                                }
                            }
                            Text {   // push the drawer back in
                                text: root.g(0xF0141)
                                color: drCloseMouse.containsMouse ? root.cWhite : root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 16
                                anchors.verticalCenter: parent.verticalCenter
                                MouseArea {
                                    id: drCloseMouse
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: mediaPopup.libOpen = false
                                }
                            }
                        }
                    }

                    // search
                    Rectangle {
                        width: parent.width
                        height: 28
                        radius: 14
                        color: root.cSurface
                        border.color: libSearch.activeFocus ? root.cMuted : root.cOutline
                        border.width: 1
                        Text {
                            id: libSearchIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.g(0xF0349)
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 13
                        }
                        TextInput {
                            id: libSearch
                            anchors.left: libSearchIcon.right
                            anchors.leftMargin: 7
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            clip: true
                            selectionColor: root.cSurface2
                            onTextChanged: mediaPopup.libQuery = text
                            Keys.onEscapePressed: { text = ""; mediaKeys.forceActiveFocus(); }
                            Keys.onReturnPressed: if (mediaPopup.libShown.length) mediaPopup.playTrack(mediaPopup.libShown[0])
                            Text {
                                visible: libSearch.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Search your music"
                                color: root.cMuted
                                font: libSearch.font
                            }
                        }
                    }
                }

                // songs: fill the space between the search and the downloader
                ListView {
                    id: libList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: drawerTop.bottom
                    anchors.bottom: drawerBottom.top
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 6
                    anchors.bottomMargin: 6
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: mediaPopup.libShown
                    delegate: Rectangle {
                        id: libRow
                        required property var modelData
                        readonly property bool now: mediaPopup.p !== null && mediaPopup.p.identity === "Music"
                                                    && mediaPopup.p.trackTitle === modelData.title
                        width: libList.width
                        height: 34
                        radius: 6
                        color: libRowMouse.containsMouse ? root.cSurface2 : libRow.now ? root.cSurface : "transparent"
                        Text {
                            id: libRowIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            text: libRow.now ? root.g(0xF040A) : root.g(0xF0387)
                            color: libRow.now ? root.cWhite : root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 12
                        }
                        Column {
                            anchors.left: libRowIcon.right
                            anchors.leftMargin: 8
                            anchors.right: libRowDur.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                width: parent.width
                                text: libRow.modelData.title
                                color: root.cWhite
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                font.bold: libRow.now
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: libRow.modelData.artist + (libRow.modelData.album ? "  ·  " + libRow.modelData.album : "")
                                color: root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            id: libRowDur
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.fmtTime(libRow.modelData.duration)
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                        MouseArea {
                            id: libRowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function (m) {
                                if (m.button === Qt.RightButton) mediaPopup.queueTrack(libRow.modelData);
                                else mediaPopup.playTrack(libRow.modelData);
                            }
                        }
                    }
                }
                Text {
                    visible: mediaPopup.libShown.length === 0
                    anchors.centerIn: libList
                    width: libList.width - 20
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: !mediaPopup.musicReady ? "Install the music command first"
                          : mediaPopup.libTracks.length === 0 ? "No songs yet — download one below" : "No matches"
                    color: root.cMuted
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }

                // downloader at the bottom
                Column {
                    id: drawerBottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 12
                    spacing: 6

                    Text {
                        visible: mediaPopup.libShown.length > 0
                        text: "click to play  ·  right-click to queue"
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 9
                        leftPadding: 4
                    }
                    Rectangle { width: parent.width; height: 1; color: root.cOutline }
                    Text {
                        text: "DOWNLOAD"
                        color: root.cFg2
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.5
                        leftPadding: 2
                    }
                    Rectangle {
                        width: parent.width
                        height: 28
                        radius: 14
                        color: root.cSurface
                        border.color: dlInput.activeFocus ? root.cMuted : root.cOutline
                        border.width: 1
                        opacity: mediaPopup.dlBusy ? 0.6 : 1
                        Text {
                            id: dlIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.g(0xF01DA)
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 13
                        }
                        TextInput {
                            id: dlInput
                            anchors.left: dlIcon.right
                            anchors.leftMargin: 7
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: !mediaPopup.dlBusy
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            clip: true
                            selectionColor: root.cSurface2
                            Keys.onEscapePressed: { text = ""; mediaKeys.forceActiveFocus(); }
                            Keys.onReturnPressed: {
                                if (text.trim() === "") return;
                                mediaPopup.download(text.trim());
                                text = "";
                            }
                            Text {
                                visible: dlInput.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Song name or link, then Enter"
                                color: root.cMuted
                                font: dlInput.font
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        text: mediaPopup.dlStatus !== "" ? mediaPopup.dlStatus
                              : "YouTube, SoundCloud, Bandcamp… — tagged + cover added"
                        color: mediaPopup.dlBusy ? root.cFg : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                        elide: Text.ElideRight
                        leftPadding: 4
                    }
                }
            }
        }
    }

    // ============================================================
    //  HIDDEN ICONS FLYOUT (opened by the arrow next to notifications)
    // ============================================================
    PopupWindow {
        id: flyout
        visible: false
        color: "transparent"
        anchor.window: bar
        // as wide as the longest row, so no label is ever cut off
        implicitWidth: {
            var w = 160, cs = flyCol.children;
            for (var i = 0; i < cs.length; i++)
                if (cs[i].wide === true && cs[i].visible) w = Math.max(w, cs[i].implicitWidth);
            return w + 12;
        }
        // fixed height so the window never resizes while open (the panel below is drawn
        // at its real size; the transparent rest closes the flyout when clicked)
        implicitHeight: 520

        function toggle() {
            tooltip.hide();
            btPopup.close("arrow flyout");
            mediaPopup.close();
            startMenu.close();
            root.ctxItem = null;
            if (visible) { visible = false; return; }
            // right edge lines up with the arrow
            var p = arrowPill.mapToItem(bar.contentItem, arrowPill.width, arrowPill.height);
            anchor.rect.x = Math.max(4, Math.min(bar.width - implicitWidth - 4, p.x - implicitWidth));
            anchor.rect.y = p.y + 10;
            visible = true;
        }

        // a tray item's menu, shown under the arrow once the flyout is closed
        function trayMenu(it) {
            visible = false;
            if (it && it.hasMenu) {
                var p = arrowPill.mapToItem(bar.contentItem, 0, arrowPill.height + 8);
                it.display(bar, p.x, p.y);
            }
        }

        // closes when the pointer leaves the panel for a moment (after having been on it),
        // on a click in the empty area below it, or when the arrow is clicked again.
        // (no HyprlandFocusGrab: on this setup it treats clicks INSIDE popups as outside)
        property bool entered: false
        onVisibleChanged: if (!visible) { root.ctxItem = null; entered = false; flyLeave.stop(); }
        Timer { id: flyLeave; interval: 600; onTriggered: flyout.visible = false }

        MouseArea {
            anchors.fill: parent
            onClicked: flyout.visible = false
        }

        Rectangle {
            id: flyBg
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: flyCol.implicitHeight + 12
            radius: 10
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            // swallow clicks on the panel's own background
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            HoverHandler {
                onHoveredChanged: {
                    if (hovered) { flyout.entered = true; flyLeave.stop(); }
                    else if (flyout.entered) flyLeave.restart();
                }
            }

            Column {
                id: flyCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                spacing: 4

                // hidden tray icons (Steam, …): click to open, right-click for the app's menu
                Flow {
                    id: flyTray
                    width: parent.width
                    spacing: 4
                    visible: {
                        var its = SystemTray.items.values;
                        for (var i = 0; i < its.length; i++)
                            if (root.inFlyout(its[i])) return true;
                        return false;
                    }
                    bottomPadding: 2

                    Repeater {
                        model: SystemTray.items
                        delegate: Rectangle {
                            id: flyTrayItem
                            required property var modelData
                            visible: root.inFlyout(modelData)
                            width: 26
                            height: 22
                            radius: 6
                            readonly property bool picked: root.ctxItem === modelData
                            color: picked || flyTrayMouse.containsMouse ? root.cSurface2 : root.cSurface
                            border.color: picked ? root.cWhite : flyTrayMouse.containsMouse ? root.cMuted : root.cOutline
                            border.width: 1

                            Image {
                                anchors.centerIn: parent
                                source: flyTrayItem.modelData.icon
                                width: 15
                                height: 15
                                sourceSize.width: 15
                                sourceSize.height: 15
                                smooth: true
                                layer.enabled: true
                                layer.effect: MultiEffect { saturation: -1.0 }
                            }
                            MouseArea {
                                id: flyTrayMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                onClicked: function (mouse) {
                                    var it = flyTrayItem.modelData;
                                    if (mouse.button === Qt.RightButton) root.ctxItem = (root.ctxItem === it ? null : it);
                                    else if (it.onlyMenu) flyout.trayMenu(it);
                                    else if (mouse.button === Qt.MiddleButton) { flyout.visible = false; it.secondaryActivate(); }
                                    else { flyout.visible = false; it.activate(); }
                                }
                            }
                        }
                    }
                }

                // options for the right-clicked app
                Rectangle {
                    id: appOpts
                    visible: root.ctxItem !== null
                    width: parent.width
                    height: optsCol.implicitHeight + 10
                    radius: 7
                    color: root.cBg
                    border.color: root.cOutline
                    border.width: 1
                    Column {
                        id: optsCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 5
                        spacing: 4
                        Text {
                            width: parent.width
                            leftPadding: 3
                            text: root.ctxItem ? (root.ctxItem.title || root.ctxItem.id || "") : ""
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 11
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Row {
                            id: optsRow
                            width: parent.width
                            spacing: 4
                            readonly property bool hasMenu: root.ctxItem !== null && root.ctxItem.hasMenu
                            readonly property real tileW: (width - spacing * (hasMenu ? 2 : 1)) / (hasMenu ? 3 : 2)
                            Pill {
                                compact: true
                                width: optsRow.tileW
                                visible: optsRow.hasMenu
                                icon: root.g(0xF035C)   // menu
                                label: "Menu"
                                onClicked: { var it = root.ctxItem; root.ctxItem = null; flyout.trayMenu(it); }
                            }
                            Pill {
                                compact: true
                                width: optsRow.tileW
                                icon: root.g(0xF0156)   // close
                                label: "Quit"
                                onClicked: root.quitTrayApp(root.ctxItem, false)
                            }
                            Pill {
                                compact: true
                                width: optsRow.tileW
                                icon: root.g(0xF0425)   // power
                                iconColor: "#ff6b6b"
                                label: "Kill"
                                onClicked: root.quitTrayApp(root.ctxItem, true)
                            }
                        }
                    }
                }

                // performance mode + network: two small tiles side by side
                Row {
                    id: sysRow
                    width: parent.width
                    spacing: 4
                    readonly property int shown: (modePill.visible ? 1 : 0) + 1
                    readonly property real tileW: shown > 1 ? (width - spacing) / 2 : width

                    // Predator performance mode (via ASense): click next, right-click previous
                    Pill {
                        id: modePill
                        compact: true
                        width: sysRow.tileW
                        visible: stats.profile !== ""
                        icon: root.g(0xF04C5)   // speedometer
                        label: root.modeNames[stats.profile] || stats.profile
                        onClicked: { stats.profile = "…"; root.run([Quickshell.env("HOME") + "/.local/bin/predator-mode", "next"]); }
                        onRightClicked: { stats.profile = "…"; root.run([Quickshell.env("HOME") + "/.local/bin/predator-mode", "prev"]); }
                    }

                    // network: icon shows wifi strength / wired; name is shortened to fit the tile
                    Pill {
                        compact: true
                        width: sysRow.tileW
                        icon: {
                            if (stats.netType === "ethernet") return root.g(0xF0200);
                            if (stats.netType !== "wifi") return root.g(0xF092E);
                            var s = stats.netSignal;
                            return root.g(s >= 75 ? 0xF0928 : s >= 50 ? 0xF0925 : s >= 25 ? 0xF0922 : 0xF091F);
                        }
                        label: {
                            if (stats.netType === "none") return "Offline";
                            var n = stats.netType === "ethernet" ? "Wired" : stats.netName;
                            return n.length > 11 ? n.slice(0, 10) + "…" : n;
                        }
                        onClicked: { flyout.visible = false; root.launch("kitty -e nmtui"); }
                        onRightClicked: { flyout.visible = false; root.launch("nm-connection-editor"); }
                    }
                }

                // VPN: Proton's own icon (it no longer sits on the bar) + status;
                // while connected a second line shows location · exit IP · uptime
                Rectangle {
                    id: vpnCard
                    readonly property bool wide: true          // counted by the flyout's width calc
                    readonly property bool vpnOn: stats.vpnProvider !== ""
                    width: parent.width
                    implicitWidth: vpnCardRow.implicitWidth + 18
                    height: vpnOn && root.vpnDetails !== "" ? 38 : 22
                    radius: 6
                    color: vpnCardMouse.containsMouse ? root.cSurface2 : root.cSurface
                    border.color: vpnOn ? root.cFg2 : (vpnCardMouse.containsMouse ? root.cMuted : root.cOutline)
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        id: vpnCardRow
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        Item {
                            width: 13
                            height: 13
                            anchors.verticalCenter: parent.verticalCenter
                            Image {
                                visible: root.protonTray !== null
                                anchors.fill: parent
                                source: root.protonTray ? root.protonTray.icon : ""
                                sourceSize.width: 13
                                sourceSize.height: 13
                                smooth: true
                                opacity: vpnCard.vpnOn ? 1.0 : 0.5
                                layer.enabled: true
                                layer.effect: MultiEffect { saturation: -1.0 }
                            }
                            Text {   // fallback when the Proton app isn't running
                                visible: root.protonTray === null
                                anchors.centerIn: parent
                                text: vpnCard.vpnOn ? root.g(0xF099D) : root.g(0xF099C)   // shield-lock / shield-off
                                color: vpnCard.vpnOn ? root.cWhite : root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 13
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                text: !vpnCard.vpnOn ? (root.protonTray ? "Proton VPN  ·  off" : "VPN off")
                                    : stats.vpnProvider + (stats.vpnServer !== "" ? "  ·  " + stats.vpnServer : "")
                                color: vpnCard.vpnOn ? root.cWhite : root.cFg
                                font.family: root.fontFamily
                                font.pixelSize: 11
                                font.bold: vpnCard.vpnOn
                            }
                            Text {
                                visible: vpnCard.vpnOn && root.vpnDetails !== ""
                                text: root.vpnDetails
                                color: root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 10
                            }
                        }
                    }
                    MouseArea {
                        id: vpnCardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: function (mouse) {
                            if (mouse.button === Qt.RightButton) root.ctxItem = (root.ctxItem === root.protonTray ? null : root.protonTray);
                            else { flyout.visible = false; root.launch("protonvpn-app"); }
                        }
                    }
                }

                // volume + brightness: two small tiles side by side
                Row {
                    id: levelRow
                    width: parent.width
                    spacing: 4
                    readonly property int shown: (volPill.visible ? 1 : 0) + (briPill.visible ? 1 : 0)
                    readonly property real tileW: shown > 1 ? (width - spacing) / 2 : width

                    // volume: click mute, scroll to change
                    Pill {
                        id: volPill
                        compact: true
                        width: levelRow.tileW
                        visible: root.sink !== null && root.sink.audio !== null
                        readonly property real vol: root.sink && root.sink.audio ? root.sink.audio.volume : 0
                        readonly property bool muted: root.sink && root.sink.audio ? root.sink.audio.muted : false
                        icon: muted ? root.g(0xF075F) : vol >= 0.66 ? root.g(0xF057E) : vol >= 0.33 ? root.g(0xF0580) : root.g(0xF057F)
                        label: muted ? "Muted" : Math.round(vol * 100) + "%"
                        iconColor: muted ? root.cMuted : root.cWhite
                        onClicked: if (root.sink && root.sink.audio) root.sink.audio.muted = !root.sink.audio.muted
                        onScrolled: function (d) {
                            if (!root.sink || !root.sink.audio) return;
                            root.sink.audio.volume = Math.max(0, Math.min(1.0, root.sink.audio.volume + d * 0.05));
                        }
                    }

                    // brightness: scroll to change
                    Pill {
                        id: briPill
                        compact: true
                        width: levelRow.tileW
                        visible: stats.brightness >= 0
                        icon: root.g(0xF00E0)
                        label: stats.brightness + "%"
                        onScrolled: function (d) {
                            stats.brightness = Math.max(1, Math.min(100, stats.brightness + d * 5));
                            root.run(["brightnessctl", "-q", "set", (d > 0 ? "5%+" : "5%-")]);
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    //  TRAY APP OPTIONS (right-click an app in the flyout): its own menu / quit / force quit
    // ============================================================
    // the app whose options are shown inside the flyout (right-click its icon), or null
    property var ctxItem: null
    function quitTrayApp(it, force) {
        ctxItem = null;
        if (!it) return;
        Quickshell.execDetached([Quickshell.shellDir + "/scripts/tray-quit.sh",
                                 it.id || "", it.title || it.id || "", force ? "force" : "term"]);
    }

    // ============================================================
    //  BLUETOOTH POPUP (opened by the bluetooth pill)
    // ============================================================

    // paired devices (connected first), then discovered ones that have a real name
    readonly property var btPaired: Bluetooth.devices.values
        .filter(function (d) { return d.paired; })
        .sort(function (a, b) {
            if (a.connected !== b.connected) return a.connected ? -1 : 1;
            return a.name.localeCompare(b.name);
        })
    readonly property var btFound: Bluetooth.devices.values
        .filter(function (d) { return !d.paired && (d.deviceName !== "" || d.pairing); })
        .sort(function (a, b) { return a.name.localeCompare(b.name); })

    function btIcon(d) {
        var i = d ? (d.icon || "") : "";
        if (/headset/.test(i)) return g(0xF02CE);
        if (/headphone|audio/.test(i)) return g(0xF02CB);
        if (/keyboard/.test(i)) return g(0xF030C);
        if (/mouse|tablet/.test(i)) return g(0xF037D);
        if (/phone/.test(i)) return g(0xF011C);
        if (/computer|laptop/.test(i)) return g(0xF0322);
        if (/gaming|joystick/.test(i)) return g(0xF0297);
        if (/video|display|tv/.test(i)) return g(0xF0502);
        if (/printer/.test(i)) return g(0xF042A);
        return g(0xF00AF);
    }
    function btBusy(d) {
        return d !== null && (d.pairing || d.state === BluetoothDeviceState.Connecting
                              || d.state === BluetoothDeviceState.Disconnecting);
    }
    function btStatus(d) {
        if (!d) return "";
        if (d.pairing) return "Pairing…";
        if (d.state === BluetoothDeviceState.Connecting) return "Connecting…";
        if (d.state === BluetoothDeviceState.Disconnecting) return "Disconnecting…";
        if (d.connected) return "Connected" + (d.batteryAvailable ? "  ·  " + Math.round(d.battery * 100) + "%" : "");
        return d.paired ? "Paired · click to connect" : "Click to pair";
    }
    // click on a device row: disconnect / connect / pair-then-connect
    property string btPendingConnect: ""
    function btActivate(d) {
        if (!d || btBusy(d)) return;
        if (d.connected) d.disconnect();
        else if (d.paired) d.connect();
        else {
            // trust first (lets HID devices like gamepads open their input channel),
            // and pause scanning: many adapters drop the pairing while discovery runs
            btError = "";
            btPendingConnect = d.address;
            if (btAdapter && btAdapter.discovering) btAdapter.discovering = false;
            d.trusted = true;
            d.pair();
        }
    }
    property string btError: ""
    // once a freshly paired device is paired, trust it (auto-reconnect) and connect
    Instantiator {
        model: Bluetooth.devices
        delegate: Connections {
            required property var modelData
            target: modelData
            function onPairedChanged() {
                if (modelData.paired && modelData.address === root.btPendingConnect) {
                    root.btPendingConnect = "";
                    console.info("bt: paired " + modelData.name + ", connecting");
                    modelData.trusted = true;
                    modelData.connect();
                }
            }
            // pairing ended without the device becoming paired -> it failed
            function onPairingChanged() {
                if (!modelData.pairing && !modelData.paired && modelData.address === root.btPendingConnect) {
                    root.btPendingConnect = "";
                    root.btError = "Couldn't pair " + modelData.name + ". Put it in pairing mode and try again.";
                    console.warn("bt: pairing failed for " + modelData.name + " (" + modelData.address + ")");
                }
            }
        }
    }
    // power on/off; if rfkill has it blocked, unblock first
    function btSetPower(on) {
        if (!btAdapter) return;
        if (on && btAdapter.state === BluetoothAdapterState.Blocked) {
            run(["rfkill", "unblock", "bluetooth"]);
            btUnblockTimer.restart();
            return;
        }
        btAdapter.enabled = on;
    }
    Timer {
        id: btUnblockTimer
        interval: 800
        onTriggered: if (root.btAdapter) root.btAdapter.enabled = true
    }

    // ---- on/off switch ----
    component Toggle: Rectangle {
        id: tog
        property bool checked: false
        property bool busy: false
        signal toggled()
        width: 38
        height: 20
        radius: 10
        color: checked ? root.cWhite : root.cSurface2
        border.color: checked ? root.cWhite : (togMouse.containsMouse ? root.cMuted : root.cOutline)
        border.width: 1
        opacity: busy ? 0.55 : 1
        Behavior on color { ColorAnimation { duration: 140 } }
        Rectangle {
            width: 14
            height: 14
            radius: 7
            anchors.verticalCenter: parent.verticalCenter
            x: tog.checked ? tog.width - width - 3 : 3
            color: tog.checked ? root.cBg : root.cFg2
            Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            id: togMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (!tog.busy) tog.toggled()
        }
    }

    // ---- one device row ----
    component BtRow: Rectangle {
        id: btRow
        required property var modelData
        readonly property var dev: modelData
        readonly property bool active: dev !== null && dev.connected
        readonly property bool busy: root.btBusy(dev)
        readonly property bool hovered: rowMouse.containsMouse || forgetMouse.containsMouse

        width: parent ? parent.width : 0
        height: 42
        radius: 8
        color: active || hovered ? root.cSurface2 : root.cSurface
        border.color: active ? root.cFg2 : (hovered ? root.cMuted : root.cOutline)
        border.width: 1
        Behavior on color { ColorAnimation { duration: 120 } }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: btRow.busy ? Qt.BusyCursor : Qt.PointingHandCursor
            onClicked: root.btActivate(btRow.dev)
        }

        Text {
            id: rowIcon
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            horizontalAlignment: Text.AlignHCenter
            text: root.btIcon(btRow.dev)
            color: btRow.active ? root.cWhite : root.cFg2
            font.family: root.fontFamily
            font.pixelSize: 17
            // pulse while pairing / connecting
            SequentialAnimation on opacity {
                running: btRow.busy
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { to: 0.25; duration: 450 }
                NumberAnimation { to: 1.0; duration: 450 }
            }
        }

        Column {
            anchors.left: rowIcon.right
            anchors.leftMargin: 10
            anchors.right: forgetBtn.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                text: btRow.dev ? btRow.dev.name : ""
                color: btRow.active ? root.cWhite : root.cFg
                font.family: root.fontFamily
                font.pixelSize: 13
                font.bold: btRow.active
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.btStatus(btRow.dev)
                color: root.cMuted
                font.family: root.fontFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }

        // forget (paired devices only, shown on hover)
        Rectangle {
            id: forgetBtn
            readonly property bool shown: btRow.dev !== null && btRow.dev.paired && btRow.hovered && !btRow.busy
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: shown ? 24 : 0
            height: 24
            radius: 6
            opacity: shown ? 1 : 0
            color: forgetMouse.containsMouse ? root.cOutline : "transparent"
            Text {
                anchors.centerIn: parent
                text: root.g(0xF0A7A)   // trash-can-outline
                color: forgetMouse.containsMouse ? "#ff6b6b" : root.cFg2
                font.family: root.fontFamily
                font.pixelSize: 14
            }
            MouseArea {
                id: forgetMouse
                anchors.fill: parent
                enabled: forgetBtn.shown
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (btRow.dev) btRow.dev.forget()
            }
        }
    }

    // ---- section label ----
    component BtLabel: Text {
        color: root.cMuted
        font.family: root.fontFamily
        font.pixelSize: 10
        font.bold: true
        font.letterSpacing: 1.2
    }

    PopupWindow {
        id: btPopup
        visible: false
        color: "transparent"
        anchor.window: bar
        // the window keeps one fixed size so it never has to be re-created while open
        // (resizing a popup can make Hyprland drop it); clicking its empty part closes it
        implicitWidth: 310
        implicitHeight: 640

        readonly property var adapter: root.btAdapter
        readonly property bool powered: adapter !== null && adapter.enabled
        readonly property bool blocked: adapter !== null && adapter.state === BluetoothAdapterState.Blocked
        readonly property bool switching: adapter !== null && (adapter.state === BluetoothAdapterState.Enabling
                                                               || adapter.state === BluetoothAdapterState.Disabling)
        readonly property bool scanning: powered && adapter.discovering

        function toggle() {
            tooltip.hide();
            flyout.visible = false;
            mediaPopup.close();
            startMenu.close();
            if (visible) { close("bar pill"); return; }
            // right edge lines up with the bluetooth pill
            var p = btPill.mapToItem(bar.contentItem, btPill.width, btPill.height);
            anchor.rect.x = Math.max(4, Math.min(bar.width - implicitWidth - 4, p.x - implicitWidth));
            anchor.rect.y = p.y + 10;
            visible = true;
        }
        // look for devices only while the popup is open (saves battery)
        function scan(want) {
            if (adapter && adapter.enabled && adapter.discovering !== want) adapter.discovering = want;
        }
        onVisibleChanged: {
            if (!visible) { entered = false; btLeaveTimer.stop(); root.btError = ""; }
            scan(visible);
            console.info("bt-popup: visible = " + visible);
        }
        onPoweredChanged: scan(visible && powered)

        // closes when the pointer leaves the panel for a moment (after having been on it),
        // when the bluetooth pill is clicked again, or on a click in the empty area below.
        // (no HyprlandFocusGrab here: it was closing the popup on clicks inside it)
        function close(why) {
            if (!visible) return;
            console.info("bt-popup: closed by " + why);
            visible = false;
        }
        property bool entered: false
        Timer {
            id: btLeaveTimer
            interval: 600
            onTriggered: btPopup.close("pointer left the panel")
        }

        // empty (transparent) area below the panel: click closes the popup
        MouseArea {
            anchors.fill: parent
            onClicked: btPopup.close("click below the panel")
        }

        Rectangle {
            id: btBg
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: btCol.implicitHeight + 24
            radius: 10
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            // swallow clicks on the panel's own background so they don't reach the closer above
            MouseArea { anchors.fill: parent }

            HoverHandler {
                onHoveredChanged: {
                    if (hovered) { btPopup.entered = true; btLeaveTimer.stop(); }
                    else if (btPopup.entered) btLeaveTimer.restart();
                }
            }

            Column {
                id: btCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 10

                // ---- header: icon, title, status, power switch ----
                Item {
                    width: parent.width
                    height: 34

                    Rectangle {
                        id: btHdrIcon
                        width: 34
                        height: 34
                        radius: 8
                        color: btPopup.powered ? root.cWhite : root.cSurface
                        border.color: btPopup.powered ? root.cWhite : root.cOutline
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 140 } }
                        Text {
                            anchors.centerIn: parent
                            text: !btPopup.powered ? root.g(0xF00B2) : root.btConnected > 0 ? root.g(0xF00B1) : root.g(0xF00AF)
                            color: btPopup.powered ? root.cBg : root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 18
                        }
                    }
                    Column {
                        anchors.left: btHdrIcon.right
                        anchors.leftMargin: 10
                        anchors.right: btSwitch.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        Text {
                            text: "Bluetooth"
                            color: root.cWhite
                            font.family: root.fontFamily
                            font.pixelSize: 14
                            font.bold: true
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: btPopup.blocked ? "Blocked (rfkill)"
                                : btPopup.switching ? (btPopup.powered ? "Turning off…" : "Turning on…")
                                : !btPopup.powered ? "Off"
                                : root.btConnected > 0 ? root.btConnected + " connected"
                                : (btPopup.adapter.name || "On")
                            color: root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                    }
                    Toggle {
                        id: btSwitch
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: btPopup.powered
                        busy: btPopup.switching
                        onToggled: root.btSetPower(!btPopup.powered)
                    }
                }

                Rectangle { width: parent.width; height: 1; color: root.cOutline }

                Text {
                    visible: btPopup.powered && root.btError !== ""
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.btError
                    color: "#ff6b6b"
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }

                // ---- off ----
                Text {
                    visible: !btPopup.powered
                    width: parent.width
                    topPadding: 4
                    bottomPadding: 6
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: btPopup.blocked ? "Bluetooth is blocked. Flip the switch to unblock it."
                                          : "Bluetooth is off."
                    color: root.cMuted
                    font.family: root.fontFamily
                    font.pixelSize: 12
                }

                // ---- my devices ----
                BtLabel { visible: btPopup.powered && root.btPaired.length > 0; text: "MY DEVICES" }
                Flickable {
                    visible: btPopup.powered && root.btPaired.length > 0
                    width: parent.width
                    height: Math.min(contentHeight, 200)
                    contentHeight: pairedCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: pairedCol
                        width: parent.width
                        spacing: 5
                        // connected first, then the rest; rows are never rebuilt, only shown/hidden
                        Repeater {
                            model: Bluetooth.devices
                            delegate: BtRow { visible: modelData.paired && modelData.connected }
                        }
                        Repeater {
                            model: Bluetooth.devices
                            delegate: BtRow { visible: modelData.paired && !modelData.connected }
                        }
                    }
                }

                // ---- available (discovery) ----
                Item {
                    visible: btPopup.powered
                    width: parent.width
                    height: 18
                    BtLabel {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "AVAILABLE"
                    }
                    Rectangle {
                        id: scanBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: scanRow.implicitWidth + 14
                        height: 20
                        radius: 6
                        color: btPopup.scanning ? root.cSurface2 : (scanMouse.containsMouse ? root.cSurface2 : root.cSurface)
                        border.color: scanMouse.containsMouse ? root.cMuted : root.cOutline
                        border.width: 1
                        Row {
                            id: scanRow
                            anchors.centerIn: parent
                            spacing: 5
                            Text {
                                text: btPopup.scanning ? "Scanning" : "Scan"
                                color: btPopup.scanning ? root.cWhite : root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: root.g(0xF0450)   // refresh
                                color: btPopup.scanning ? root.cWhite : root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                anchors.verticalCenter: parent.verticalCenter
                                RotationAnimation on rotation {
                                    running: btPopup.scanning
                                    loops: Animation.Infinite
                                    alwaysRunToEnd: true
                                    from: 0
                                    to: 360
                                    duration: 1200
                                }
                            }
                        }
                        MouseArea {
                            id: scanMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: btPopup.scan(!btPopup.scanning)
                        }
                    }
                }
                Flickable {
                    visible: btPopup.powered && root.btFound.length > 0
                    width: parent.width
                    height: Math.min(contentHeight, 230)
                    contentHeight: foundCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: foundCol
                        width: parent.width
                        spacing: 5
                        Repeater {
                            model: Bluetooth.devices
                            delegate: BtRow { visible: !modelData.paired && (modelData.deviceName !== "" || modelData.pairing) }
                        }
                    }
                }
                Text {
                    visible: btPopup.powered && root.btFound.length === 0
                    width: parent.width
                    topPadding: 2
                    bottomPadding: 4
                    horizontalAlignment: Text.AlignHCenter
                    text: btPopup.scanning ? "Looking for devices…" : "No new devices · press Scan"
                    color: root.cMuted
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }
            }
        }
    }

    // ============================================================
    //  NOTIFICATION POPUP (toast under the bar)
    // ============================================================
    property var toastNotif: null

    function showToast(n) {
        toastNotif = n;
        toast.visible = true;
        var t = (n && n.expireTimeout > 0) ? n.expireTimeout * 1000 : 4000;
        if (t < 100) t = 4000;      // some clients send seconds, some ms
        toastTimer.interval = Math.min(t, 10000);
        toastTimer.restart();
    }

    // re-show the toast when a notification is replaced in place (e.g. mode OSD)
    Instantiator {
        model: notifServer.trackedNotifications
        delegate: Connections {
            required property var modelData
            target: modelData
            function onSummaryChanged() { root.showToast(modelData); }
            function onBodyChanged() { root.showToast(modelData); }
        }
    }

    Timer {
        id: toastTimer
        onTriggered: toast.visible = false
    }

    PanelWindow {
        id: toast
        visible: false

        anchors.top: true
        margins.top: 56
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: 380
        implicitHeight: toastCol.implicitHeight + 20
        color: "transparent"
        focusable: false

        WlrLayershell.namespace: "rice-toast"
        WlrLayershell.layer: WlrLayer.Overlay

        Rectangle {
            anchors.fill: parent
            radius: 10
            color: root.cBg1
            border.color: "#999999"
            border.width: 1

            Column {
                id: toastCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 14
                spacing: 3

                Text {
                    width: parent.width
                    text: root.toastNotif ? (root.toastNotif.appName || "") : ""
                    visible: text !== ""
                    color: root.cMuted
                    font.family: root.fontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.toastNotif ? (root.toastNotif.summary || "") : ""
                    color: root.cWhite
                    font.family: root.fontFamily
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.toastNotif ? (root.toastNotif.body || "") : ""
                    visible: text !== ""
                    color: root.cFg2
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: toast.visible = false
            }
        }
    }

    // ============================================================
    //  NOTIFICATION CENTER
    // ============================================================
    PanelWindow {
        id: notificationCenter
        visible: false

        anchors {
            top: true
            right: true
            bottom: true
        }
        margins {
            top: 50
            right: 12
            bottom: 12
        }

        implicitWidth: 340
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        aboveWindows: true

        WlrLayershell.namespace: "rice-notifications"
        WlrLayershell.layer: WlrLayer.Overlay

        Rectangle {
            anchors.fill: parent
            radius: 10
            color: root.cBg1
            border.color: root.cOutline
            border.width: 1
            clip: true

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Notifications"
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "clear"
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 11

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.clearNotifications()
                        }
                    }
                }

                ListView {
                    width: parent.width
                    height: parent.height - 30
                    clip: true
                    spacing: 6
                    model: notifServer.trackedNotifications

                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: notifColumn.implicitHeight + 16
                        radius: 6
                        color: root.cSurface
                        border.color: root.cSurface2
                        border.width: 1

                        Column {
                            id: notifColumn
                            anchors.left: parent.left
                            anchors.right: dismissBtn.left
                            anchors.top: parent.top
                            anchors.leftMargin: 10
                            anchors.rightMargin: 6
                            anchors.topMargin: 8
                            spacing: 3

                            Text {
                                width: parent.width
                                text: (modelData.summary || modelData.appName || "Notification")
                                color: root.cFg
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: modelData.body || ""
                                color: root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                                visible: text !== ""
                            }
                        }

                        Rectangle {
                            id: dismissBtn
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.rightMargin: 6
                            anchors.topMargin: 6
                            width: 16
                            height: 16
                            radius: 3
                            color: "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: "\uF00D"
                                color: root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 9
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: modelData.dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    //  LAUNCHER
    // ============================================================
    PanelWindow {
        id: launcher
        visible: false

        anchors {
            left: true
            right: true
            top: true
            bottom: true
        }

        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        aboveWindows: true

        WlrLayershell.namespace: "rice-launcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        property string query: ""
        property var results: []
        property var usage: ({})          // launch-frequency map (frecency)
        property string calcExpr: ""       // expression currently being evaluated
        property string calcResult: ""     // last computed result ("" = pending)
        property string mode: "search"     // "search" | "all" | "power"
        readonly property int visibleRows: 7
        readonly property int appColumns: 3
        readonly property int gridCols: (mode === "power" || (results.length > 0 && results[0].type === "Command")) ? 1 : appColumns

        onVisibleChanged: {
            if (visible) {
                mode = "search";
                launcherInput.text = "";
                calcExpr = "";
                calcResult = "";
                launcherInput.forceActiveFocus();
                refreshResults();
            }
        }

        function setMode(m) {
            mode = m;
            launcherInput.text = "";       // onTextChanged refreshes the results
            refreshResults();
            launcherInput.forceActiveFocus();
        }

        function select(i) {
            if (results.length === 0) return;
            resultsList.currentIndex = Math.max(0, Math.min(i, results.length - 1));
            resultsList.positionViewAtIndex(resultsList.currentIndex, GridView.Contain);
        }

        // "/" commands shown while typing a slash in the search box
        function commandRows(q) {
            var cmds = [
                { cmd: "/all", title: "All apps", subtitle: "/all \u2014 browse every installed app", glyph: "\uF00A", type: "Command" },
                { cmd: "/power", title: "Power", subtitle: "/power \u2014 lock, suspend, log out, reboot, shut down", glyph: root.g(0xF0425), type: "Command" }
            ];
            q = q.toLowerCase();
            return cmds.filter(function (c) { return c.cmd.indexOf(q) === 0; });
        }

        function powerRows(q) {
            var rows = [
                { title: "Lock", subtitle: "Lock the screen", glyph: root.g(0xF033E), type: "Power", run: "loginctl lock-session" },
                { title: "Suspend", subtitle: "Sleep", glyph: root.g(0xF04B2), type: "Power", run: "systemctl suspend" },
                { title: "Log out", subtitle: "End the Hyprland session", glyph: root.g(0xF0343), type: "Power", run: "uwsm stop" },
                { title: "Reboot", subtitle: "Restart the computer", glyph: root.g(0xF0709), type: "Power", run: "systemctl reboot" },
                { title: "Shut down", subtitle: "Power off", glyph: root.g(0xF0425), type: "Power", run: "systemctl poweroff" }
            ];
            q = q.toLowerCase();
            return rows.filter(function (r) { return r.title.toLowerCase().indexOf(q) !== -1; });
        }

        // ---- fuzzy matching, ported from Ryoku's fuzzy.js ----
        function haystacks(e) {
            var parts = [];
            if (e.name) parts.push(String(e.name));
            if (e.genericName) parts.push(String(e.genericName));
            if (e.keywords) for (var i = 0; i < e.keywords.length; i++) parts.push(String(e.keywords[i]));
            return parts;
        }

        function subsequence(needle, hay) {
            var j = 0;
            for (var i = 0; i < hay.length && j < needle.length; i++)
                if (hay[i] === needle[j]) j++;
            return j === needle.length;
        }

        function fuzzyScore(e, q) {
            var name = (e.name || "").toLowerCase();
            if (name.indexOf(q) === 0) return 0;
            var fields = haystacks(e);
            var best = 99;
            for (var i = 0; i < fields.length; i++) {
                var f = fields[i].toLowerCase();
                if (f.indexOf(q) !== -1) { best = Math.min(best, 1); continue; }
                if (subsequence(q, f)) best = Math.min(best, 2);
            }
            return best;
        }

        function fuzzyRank(q) {
            var apps = DesktopEntries.applications.values;
            var visible = [];
            for (var i = 0; i < apps.length; i++)
                if (apps[i] && !apps[i].noDisplay) visible.push(apps[i]);
            q = q.trim().toLowerCase();
            var byUsageThenName = function (a, b) {
                var ua = usage[a.id] || 0, ub = usage[b.id] || 0;
                if (ua !== ub) return ub - ua;
                return (a.name || "").toLowerCase().localeCompare((b.name || "").toLowerCase());
            };
            if (q.length === 0) return visible.slice().sort(byUsageThenName);
            var scored = [];
            for (var k = 0; k < visible.length; k++) {
                var s = fuzzyScore(visible[k], q);
                if (s < 99) scored.push({ e: visible[k], s: s });
            }
            scored.sort(function (a, b) {
                if (a.s !== b.s) return a.s - b.s;
                var ua = usage[a.e.id] || 0, ub = usage[b.e.id] || 0;
                if (ua !== ub) return ub - ua;
                return (a.e.name || "").toLowerCase().localeCompare((b.e.name || "").toLowerCase());
            });
            return scored.map(function (x) { return x.e; });
        }

        function categoryLabel(raw) {
            var order = [
                ["TerminalEmulator", "Terminal"], ["WebBrowser", "Browser"],
                ["InstantMessaging", "Chat"], ["Audio", "Media"], ["AudioVideo", "Media"],
                ["Video", "Media"], ["Game", "Game"], ["Development", "Dev"],
                ["Graphics", "Graphics"], ["Office", "Office"], ["Settings", "System"],
                ["System", "System"], ["Utility", "Tool"], ["Network", "Net"]
            ];
            var cats = String(raw || "").split(/[;,]/);
            for (var i = 0; i < order.length; i++)
                if (cats.indexOf(order[i][0]) !== -1) return order[i][1];
            return "App";
        }

        // calc applies on an explicit "=" prefix, or a leading digit with math
        function calcExpression(q) {
            if (q.length === 0) return "";
            if (q[0] === "=") return q.slice(1).trim();
            if (/^[0-9]/.test(q) && /[+\-*/^%()]/.test(q)) return q.trim();
            return "";
        }

        function appRow(e) {
            var sub = (e.genericName && e.genericName.length > 0) ? e.genericName : categoryLabel(e.categories);
            return { title: e.name, subtitle: sub, icon: e.icon, type: categoryLabel(e.categories), entry: e };
        }

        function refreshResults() {
            var q = query.trim();
            var list = [];

            if (mode === "power") {
                list = powerRows(q);
            } else if (mode === "search" && q.charAt(0) === "/") {
                list = commandRows(q);
            } else {
                var expr = mode === "search" ? calcExpression(q) : "";
                appendApps(list, q, expr);
            }

            results = list;
            resultsList.currentIndex = list.length > 0 ? 0 : -1;
            resultsList.positionViewAtBeginning();
        }

        function appendApps(list, q, expr) {
            if (expr.length > 0) {
                if (expr === calcExpr && calcResult.length > 0) {
                    list.push({ title: calcResult, subtitle: expr, icon: "", type: "Calc", entry: null });
                } else {
                    if (expr !== calcExpr) {
                        calcExpr = expr;
                        calcResult = "";
                        calcDebounce.restart();
                    }
                    list.push({ title: "\u2026", subtitle: expr, icon: "", type: "Calc", entry: null });
                }
            }

            var ranked = fuzzyRank(q);
            var limit = mode === "all" ? ranked.length : 5 * appColumns;   // 5 rows of the grid
            for (var i = 0; i < ranked.length && list.length < limit; i++)
                list.push(appRow(ranked[i]));
        }

        function activate(row) {
            if (!row) return;
            if (row.type === "Command") {
                setMode(row.cmd.slice(1));
                return;
            }
            if (row.type === "Power") {
                launcher.visible = false;
                root.launch(row.run);
                return;
            }
            if (row.entry) {
                usage[row.entry.id] = (usage[row.entry.id] || 0) + 1;
                if (row.entry.runInTerminal)      // e.g. btop: needs a terminal to live in
                    Quickshell.execDetached(["kitty", "-e"].concat(row.entry.command));
                else
                    row.entry.execute();
            } else if (row.type === "Calc" && row.title !== "\u2026") {
                Quickshell.clipboardText = row.title;
            }
            launcher.visible = false;
        }

        // calculator (qalc, async, debounced) — same engine as Ryoku
        Timer {
            id: calcDebounce
            interval: 80
            repeat: false
            onTriggered: {
                calcProc.expr = launcher.calcExpr;
                calcProc.out = "";
                calcProc.running = true;
            }
        }

        Process {
            id: calcProc
            property string expr: ""
            property string out: ""
            command: ["qalc", "-t", expr]
            stdout: SplitParser {
                onRead: function (data) { calcProc.out += data; }
            }
            onExited: function (code, status) {
                if (code === 0)
                    launcher.calcResult = String(calcProc.out).trim().replace(/^[=\u2248]\s*/, "").trim();
                else
                    launcher.calcResult = "";
                launcher.refreshResults();
            }
        }

        // dim backdrop
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.45)

            MouseArea {
                anchors.fill: parent
                onClicked: launcher.visible = false
            }
        }

        // centered card
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            // fixed top so the usual search view (~340px) sits in the middle of the
            // screen; longer lists (All apps) grow downward instead of jumping around
            anchors.topMargin: Math.max(40, Math.round((parent.height - 340) / 2))
            width: Math.min(760, parent.width - 80)
            height: cardColumn.implicitHeight + 24
            radius: 10
            color: root.cBg1
            border.color: root.cOutline
            border.width: 1
            clip: true

            // background art (ryoku wallpaper), clipped to the card's rounded corners
            ClippingRectangle {
                anchors.fill: parent
                radius: 10
                color: "transparent"
                Image {
                    anchors.fill: parent
                    source: Quickshell.shellDir + "/assets/launcher-bg.jpg"
                    fillMode: Image.PreserveAspectCrop
                    verticalAlignment: Image.AlignVCenter
                    asynchronous: false     // decode up front so it's there on the first open
                    smooth: true
                }
            }
            // dark tint so the search box and results stay readable
            Rectangle {
                anchors.fill: parent
                radius: 10
                color: Qt.rgba(0.04, 0.04, 0.04, 0.68)
            }
            // outline drawn above the art
            Rectangle {
                anchors.fill: parent
                radius: 10
                color: "transparent"
                border.color: root.cOutline
                border.width: 1
                z: 5
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onClicked: function(mouse) { mouse.accepted = true; }
            }

            Column {
                id: cardColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 10

                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    color: root.cSurface
                    border.color: launcherInput.activeFocus ? root.cWhite : root.cOutline
                    border.width: 1

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "\uF4EA"   // nf-cod-search
                        color: launcherInput.activeFocus ? root.cWhite : root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 14
                    }

                    TextInput {
                        id: launcherInput
                        anchors.fill: parent
                        anchors.leftMargin: 34
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.cWhite
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        text: launcher.query
                        selectByMouse: true

                        onTextChanged: {
                            launcher.query = text;
                            launcher.refreshResults();
                        }

                        Keys.onPressed: function(event) {
                            var n = launcher.visibleRows;
                            if (event.key === Qt.Key_Escape) {
                                if (launcher.mode !== "search") launcher.setMode("search");
                                else launcher.visible = false;
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Backspace && text === "" && launcher.mode !== "search") {
                                launcher.setMode("search");
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                if (resultsList.currentIndex >= 0 && launcher.results.length > 0)
                                    launcher.activate(launcher.results[resultsList.currentIndex]);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down) {
                                launcher.select(resultsList.currentIndex + launcher.gridCols);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up) {
                                launcher.select(resultsList.currentIndex - launcher.gridCols);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                launcher.select(resultsList.currentIndex + (event.key === Qt.Key_Tab ? 1 : -1));
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_Right || event.key === Qt.Key_Left) && text === "" && launcher.gridCols > 1) {
                                // with an empty search box, left/right move across the grid
                                launcher.select(resultsList.currentIndex + (event.key === Qt.Key_Right ? 1 : -1));
                                event.accepted = true;
                            } else if (event.key === Qt.Key_PageDown) {
                                launcher.select(resultsList.currentIndex + n * launcher.gridCols);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_PageUp) {
                                launcher.select(resultsList.currentIndex - n * launcher.gridCols);
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_Home || event.key === Qt.Key_End) && launcher.mode !== "search") {
                                launcher.select(event.key === Qt.Key_Home ? 0 : launcher.results.length - 1);
                                event.accepted = true;
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 34
                        text: launcher.mode === "all" ? "Filter all apps"
                            : launcher.mode === "power" ? "Power options"
                            : "Search apps, / for commands, = to calculate"
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 14
                        visible: launcher.query === ""
                    }
                }

                // mode buttons under the search box
                Item {
                    width: parent.width
                    height: 26

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Repeater {
                            model: [
                                { id: "all", label: "All apps", glyph: "\uF00A" },
                                { id: "power", label: "Power", glyph: root.g(0xF0425) }
                            ]
                            delegate: Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool active: launcher.mode === modelData.id
                                width: chipRow.implicitWidth + 18
                                height: 26
                                radius: 7
                                color: active ? root.cWhite : (chipMouse.containsMouse ? root.cSurface2 : root.cSurface)
                                border.color: active ? root.cWhite : (chipMouse.containsMouse ? root.cMuted : root.cOutline)
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 6
                                    Text {
                                        text: chip.modelData.glyph
                                        color: chip.active ? root.cBg : root.cWhite
                                        font.family: root.fontFamily
                                        font.pixelSize: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: chip.modelData.label
                                        color: chip.active ? root.cBg : root.cFg
                                        font.family: root.fontFamily
                                        font.pixelSize: 12
                                        font.bold: chip.active
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    id: chipMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: launcher.setMode(chip.active ? "search" : chip.modelData.id)
                                }
                            }
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: launcher.mode === "all" ? launcher.results.length + " apps \u00B7 \u2191\u2193 scroll \u00B7 esc back"
                            : launcher.mode === "power" ? "\u21B5 confirm \u00B7 esc back"
                            : "\u2191\u2193\u2190\u2192 select \u00B7 \u21B5 open"
                        color: root.cMuted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                    }
                }

                GridView {
                    id: resultsList
                    width: parent.width
                    cellWidth: Math.floor(width / launcher.gridCols)
                    cellHeight: 46
                    height: Math.min(Math.ceil(count / launcher.gridCols), launcher.visibleRows) * cellHeight
                    clip: true
                    model: launcher.results
                    currentIndex: -1
                    boundsBehavior: Flickable.StopAtBounds

                    // scrollbar when the list is longer than the view
                    Rectangle {
                        visible: resultsList.contentHeight > resultsList.height
                        anchors.right: parent.right
                        width: 3
                        radius: 2
                        color: root.cMuted
                        y: resultsList.visibleArea.yPosition * resultsList.height
                        height: Math.max(20, resultsList.visibleArea.heightRatio * resultsList.height)
                        z: 10
                    }

                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === resultsList.currentIndex
                        readonly property bool isCalc: modelData.type === "Calc"
                        readonly property bool hasGlyph: !!modelData.glyph
                        readonly property bool wide: launcher.gridCols === 1
                        width: resultsList.cellWidth
                        height: resultsList.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: wide ? 0 : 2
                            radius: 6
                            color: selected ? root.cSurface2 : "transparent"
                        }

                        Image {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 24
                            height: 24
                            source: (isCalc || hasGlyph) ? "" : Quickshell.iconPath(modelData.icon, true)
                            asynchronous: true
                            visible: source !== ""
                        }

                        // calc glyph (no icon path)
                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 24
                            height: 24
                            radius: 6
                            color: "transparent"
                            border.color: root.cOutline
                            border.width: 1
                            visible: isCalc || hasGlyph
                            Text {
                                anchors.centerIn: parent
                                text: hasGlyph ? modelData.glyph : "\uF1EC"   // row glyph, or nf-fa-calculator
                                color: root.cFg2
                                font.family: root.fontFamily
                                font.pixelSize: 12
                            }
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 44
                            anchors.right: typeBadge.visible ? typeBadge.left : parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: modelData.title || ""
                                color: selected ? root.cWhite : root.cFg
                                font.family: root.fontFamily
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: modelData.subtitle || ""
                                color: root.cMuted
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                                visible: text !== ""
                            }
                        }

                        // type badge
                        Text {
                            id: typeBadge
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: wide           // no room for the badge in grid cells
                            text: modelData.type || ""
                            color: selected ? root.cFg2 : root.cMuted
                            font.family: root.fontFamily
                            font.pixelSize: 9
                            font.bold: selected
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onEntered: resultsList.currentIndex = index
                            onClicked: launcher.activate(modelData)
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    //  GLOBAL SHORTCUTS (bound in Hyprland via `global` dispatcher)
    // ============================================================
    GlobalShortcut {
        appid: "quickshell"
        name: "launcher"
        description: "Toggle launcher"
        onPressed: launcher.visible = !launcher.visible
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "notifications"
        description: "Toggle notification center"
        onPressed: notificationCenter.visible = !notificationCenter.visible
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "clipboard"
        description: "Clipboard history"
        onPressed: clipPanel.toggle()
    }
}
