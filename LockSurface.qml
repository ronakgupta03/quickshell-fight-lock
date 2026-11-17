// Self-contained lock screen UI with fighting-game animations, shared by
// WlSessionLockSurface (real lock) and PanelWindow (safe preview).
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

Item {
    id: surface

    property var lock
    property bool preview: false
    property date now: new Date()
    property string armed: ""
    property int prevLen: 0

    readonly property string home: Quickshell.env("HOME")
    readonly property bool fightMode: surface.lock ? surface.lock.fightEnabled : true

    readonly property color colPrimary: "#7dcfff"
    readonly property color colOnPrimary: "#00344a"
    readonly property color colError: "#ffb4ab"
    readonly property color colOnError: "#690005"
    readonly property color colSurface: "#1b2023"
    readonly property color colSurfaceLowest: "#0a0f12"
    readonly property color colOutline: "#40484c"
    readonly property string uiFont: "Inter Variable"

    function alpha(col, a) {
        const q = Qt.lighter(col, 1.0)
        return Qt.rgba(q.r, q.g, q.b, a)
    }

    function submitAttempt() {
        if (!input.text || (surface.lock && (surface.lock.busy || surface.lock.finishing)))
            return
        if (surface.fightMode)
            fightStage.triggerWindup()
        surface.lock.submit(input.text)
    }

    Component.onCompleted: {
        exitOffset.y = 0
        prevLen = 0
        fightStage.resetRound()
        input.forceActiveFocus()
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: surface.now = new Date()
    }

    Timer {
        id: disarm
        interval: 3000
        onTriggered: surface.armed = ""
    }

    Connections {
        target: surface.lock
        function onFailed() {
            input.text = ""
            surface.prevLen = 0
            if (surface.fightMode)
                fightStage.triggerCounter()
            shake.restart()
            input.forceActiveFocus()
        }
        function onSucceeded() {
            if (surface.fightMode) {
                fightStage.triggerFinisher()
                cardExitAnim.restart()
            }
        }
    }

    function power(action) {
        if (surface.preview)
            return
        if (action !== "suspend" && armed !== action) {
            armed = action
            disarm.restart()
            return
        }
        armed = ""
        Quickshell.execDetached(["systemctl", action])
    }

    // ------------------------------------------------------------ backdrop --
    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    // Fallback atmospheric gradient when no wallpaper file is found.
    Rectangle {
        anchors.fill: parent
        visible: !(surface.fightMode && fightStage.impactActive) && wallpaper.status !== Image.Ready
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#141821" }
            GradientStop { position: 0.6; color: "#1c222e" }
            GradientStop { position: 1.0; color: "#0b0e14" }
        }
    }

    Image {
        id: wallpaper
        anchors.fill: parent
        source: "file://" + surface.home + "/.cache/rice/wallpaper"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: wallpaper
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        brightness: -0.2
        saturation: 0.1
        visible: wallpaper.status === Image.Ready && !(surface.fightMode && fightStage.impactActive)
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        visible: !(surface.fightMode && fightStage.impactActive)
    }

    // --------------------------------------------------------- fight stage --
    FightStage {
        id: fightStage
        anchors.fill: parent
        active: surface.visible
        fightEnabled: surface.fightMode

        onComboHit: comboPop.restart()
    }

    MouseArea {
        anchors.fill: parent
        onClicked: input.forceActiveFocus()
    }

    // ---------------------------------------------------------- combo badge --
    Item {
        id: comboBadge
        visible: surface.fightMode && fightStage.comboCount >= 2 && !fightStage.blackoutActive
        anchors.left: parent.left
        anchors.leftMargin: Math.round(parent.width * 0.08)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Math.round(parent.height * 0.08)
        width: 220
        height: 80
        opacity: fightStage.impactActive ? 0.95 : 0.9

        transform: Scale {
            id: comboScale
            origin.x: 0
            origin.y: 40
            xScale: 1.0
            yScale: 1.0
        }

        SequentialAnimation {
            id: comboPop
            NumberAnimation { target: comboScale; properties: "xScale,yScale"; from: 1.32; to: 1.0; duration: 140; easing.type: Easing.OutBack }
        }

        Column {
            spacing: 2
            Row {
                spacing: 8
                Text {
                    text: fightStage.comboCount
                    color: surface.colPrimary
                    font.family: surface.uiFont
                    font.pixelSize: 46
                    font.weight: Font.Black
                    font.features: { "tnum": 1 }
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.7)
                }
                Text {
                    anchors.baseline: parent.children[0].baseline
                    text: "HIT"
                    color: "white"
                    font.family: surface.uiFont
                    font.pixelSize: 20
                    font.weight: Font.ExtraBold
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.7)
                }
            }
            Text {
                text: fightStage.comboCount >= 8 ? "HYPER COMBO!" : fightStage.comboCount >= 4 ? "SUPER COMBO!" : "COMBO"
                color: fightStage.comboCount >= 8 ? "#ffe042" : "white"
                opacity: 0.9
                font.family: surface.uiFont
                font.pixelSize: 13
                font.weight: Font.Bold
                font.letterSpacing: 2.2
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.7)
            }
        }
    }

    // ------------------------------------------------------------- content --
    ColumnLayout {
        id: mainColumn
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: surface.fightMode ? parent.top : undefined
        anchors.topMargin: surface.fightMode ? Math.round(parent.height * 0.045) : 0
        anchors.verticalCenter: surface.fightMode ? undefined : parent.verticalCenter
        width: 440
        spacing: surface.fightMode ? 10 : 16

        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: 10
            visible: !(surface.fightMode && fightStage.impactActive)

            Text {
                id: bigTime
                text: Qt.formatTime(surface.now, "h:mm")
                color: "white"
                font.family: surface.uiFont
                font.pixelSize: surface.fightMode ? 84 : 120
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
            }

            Text {
                anchors.baseline: bigTime.baseline
                text: Qt.formatTime(surface.now, "AP")
                color: "white"
                opacity: 0.75
                font.family: surface.uiFont
                font.pixelSize: surface.fightMode ? 22 : 28
                font.weight: Font.DemiBold
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: Qt.formatDate(surface.now, "dddd, d MMMM")
            color: "white"
            opacity: 0.8
            font.family: surface.uiFont
            font.pixelSize: surface.fightMode ? 18 : 22
            visible: !(surface.fightMode && fightStage.impactActive)
        }

        Item { Layout.preferredHeight: surface.fightMode ? 6 : 26 }

        Rectangle {
            id: loginCard
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: surface.fightMode ? 410 : 380
            implicitHeight: cardCol.implicitHeight + (surface.fightMode ? 28 : 0)
            radius: 14
            color: surface.fightMode ? surface.alpha(surface.colSurface, 0.85) : "transparent"
            border.width: surface.fightMode ? 1 : 0
            border.color: surface.fightMode
                ? (surface.lock && surface.lock.error ? surface.colError : surface.alpha(surface.colPrimary, 0.75))
                : "transparent"

            transform: [
                Translate { id: shakeOffset },
                Translate {
                    x: surface.fightMode ? fightStage.uiShakeX : 0
                    y: surface.fightMode ? fightStage.uiShakeY : 0
                },
                Translate { id: exitOffset }
            ]

            Rectangle {
                visible: surface.fightMode
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: 1
                anchors.bottomMargin: 1
                width: 5
                radius: 4
                color: surface.lock && surface.lock.error ? surface.colError : surface.colPrimary
            }

            SequentialAnimation {
                id: shake
                NumberAnimation { target: shakeOffset; property: "x"; to: -14; duration: 50 }
                NumberAnimation { target: shakeOffset; property: "x"; to: 14; duration: 70 }
                NumberAnimation { target: shakeOffset; property: "x"; to: -9; duration: 60 }
                NumberAnimation { target: shakeOffset; property: "x"; to: 9; duration: 60 }
                NumberAnimation { target: shakeOffset; property: "x"; to: 0; duration: 50 }
            }

            SequentialAnimation {
                id: cardExitAnim
                NumberAnimation {
                    target: exitOffset
                    property: "y"
                    from: 0
                    to: Math.round(surface.height * 0.02)
                    duration: 80
                    easing.type: Easing.OutSine
                }
                NumberAnimation {
                    target: exitOffset
                    property: "y"
                    to: -Math.round(surface.height * 1.15)
                    duration: 350
                    easing.type: Easing.InCubic
                }
            }

            ColumnLayout {
                id: cardCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: surface.fightMode ? 22 : 0
                anchors.rightMargin: surface.fightMode ? 18 : 0
                spacing: surface.fightMode ? 10 : 14

                RowLayout {
                    Layout.alignment: surface.fightMode ? Qt.AlignLeft : Qt.AlignHCenter
                    spacing: 12

                    ClippingRectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: surface.fightMode ? 48 : 96
                        implicitHeight: surface.fightMode ? 48 : 96
                        radius: surface.fightMode ? 24 : 48
                        color: surface.alpha(surface.colSurface, 0.85)
                        border.width: 2
                        border.color: surface.colPrimary

                        Image {
                            id: face
                            anchors.fill: parent
                            source: "file://" + surface.home + "/.face"
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: face.status !== Image.Ready
                            text: "󰀄"
                            font.pixelSize: surface.fightMode ? 22 : 40
                            color: "white"
                        }
                    }

                    Column {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 2

                        Text {
                            visible: surface.fightMode
                            text: "PLAYER 1"
                            color: surface.colPrimary
                            font.family: surface.uiFont
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            font.letterSpacing: 1.8
                        }

                        Text {
                            text: (Quickshell.env("USER") || "").toUpperCase()
                            color: "white"
                            font.family: surface.uiFont
                            font.pixelSize: 22
                            font.weight: Font.Bold
                        }
                    }
                }

                Rectangle {
                    id: field
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: surface.fightMode
                    implicitWidth: 360
                    implicitHeight: surface.fightMode ? 50 : 56
                    radius: surface.fightMode ? 12 : 28
                    color: surface.alpha(surface.colSurfaceLowest, 0.9)
                    border.width: 2
                    border.color: surface.lock && surface.lock.error ? surface.colError
                                : input.activeFocus ? surface.colPrimary : surface.alpha(surface.colOutline, 0.8)
                    Behavior on border.color {
                        ColorAnimation { duration: 150 }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 6
                        spacing: 12

                        Text {
                            text: "󰌾"
                            font.pixelSize: 16
                            color: "white"
                            opacity: 0.8
                        }

                        TextInput {
                            id: input
                            Layout.fillWidth: true
                            echoMode: TextInput.Password
                            passwordCharacter: "●"
                            color: "white"
                            font.family: surface.uiFont
                            font.pixelSize: 18
                            clip: true
                            focus: true
                            enabled: !(surface.lock && (surface.lock.busy || surface.lock.finishing))
                            Component.onCompleted: forceActiveFocus()
                            onTextChanged: {
                                if (text && surface.lock)
                                    surface.lock.error = ""
                                const len = text.length
                                if (surface.fightMode) {
                                    if (len > surface.prevLen) {
                                        fightStage.triggerHit()
                                    } else if (len === 0 && surface.prevLen > 0) {
                                        fightStage.triggerReset()
                                    } else if (len < surface.prevLen) {
                                        fightStage.triggerBlock()
                                    }
                                }
                                surface.prevLen = len
                            }
                            Keys.onReturnPressed: surface.submitAttempt()
                            Keys.onEnterPressed: surface.submitAttempt()
                            Keys.onEscapePressed: {
                                if (text)
                                    text = ""
                                else if (surface.preview)
                                    surface.lock.endPreview()
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !input.text
                                text: surface.fightMode ? "Enter password to fight..." : "Password"
                                color: "white"
                                opacity: 0.45
                                font: input.font
                            }
                        }

                        Rectangle {
                            implicitWidth: 38
                            implicitHeight: 38
                            radius: surface.fightMode ? 10 : 19
                            color: surface.colPrimary

                            Text {
                                id: submitIcon
                                anchors.centerIn: parent
                                text: surface.lock && (surface.lock.busy || surface.lock.finishing) ? "◌" : "→"
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: surface.colOnPrimary

                                NumberAnimation on rotation {
                                    running: surface.lock && (surface.lock.busy || surface.lock.finishing)
                                    from: 0
                                    to: 360
                                    duration: 900
                                    loops: Animation.Infinite
                                    onRunningChanged: if (!running) submitIcon.rotation = 0
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: surface.submitAttempt()
                            }
                        }
                    }
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 20
            visible: !(surface.fightMode && fightStage.impactActive)
            text: surface.lock ? surface.lock.error : ""
            color: surface.colError
            font.family: surface.uiFont
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            visible: surface.preview && !(surface.fightMode && fightStage.impactActive)
            text: surface.fightMode
                ? "Preview - nothing is locked. Type to fight, Enter to finish, or Esc to close."
                : "Preview - nothing is locked. Try your password, or Esc to close."
            color: "white"
            opacity: 0.75
            font.family: surface.uiFont
            font.pixelSize: 13
        }
    }

    // -------------------------------------------------------- bottom controls --
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: surface.fightMode ? 24 : 50
        spacing: 26
        opacity: surface.preview ? 0.4 : 1
        visible: !(surface.fightMode && fightStage.impactActive)

        Repeater {
            model: [
                { action: "suspend", icon: "󰤄", label: "Suspend" },
                { action: "reboot", icon: "󰜉", label: "Restart" },
                { action: "poweroff", icon: "󰐥", label: "Power off" }
            ]

            Column {
                required property var modelData
                readonly property bool isArmed: surface.armed === modelData.action
                spacing: 6

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: surface.fightMode ? 44 : 56
                    height: surface.fightMode ? 44 : 56
                    radius: surface.fightMode ? 22 : 28
                    color: isArmed ? surface.colError
                         : powerArea.containsMouse ? surface.alpha(surface.colPrimary, 0.35) : surface.alpha(surface.colSurface, 0.7)

                    Text {
                        anchors.centerIn: parent
                        text: modelData.icon
                        font.pixelSize: surface.fightMode ? 18 : 22
                        color: isArmed ? surface.colOnError : "white"
                    }

                    MouseArea {
                        id: powerArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: surface.preview ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: surface.power(modelData.action)
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: isArmed ? "Click again" : modelData.label
                    color: "white"
                    opacity: 0.8
                    font.family: surface.uiFont
                    font.pixelSize: 11
                }
            }
        }
    }
}
