import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets


Rectangle {
  id: root

  // Plugin API (injected by PluginService)
  property var pluginApi: null

  // Required properties for bar widgets
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""

  implicitWidth: row.implicitWidth + Style.marginS * 2
  implicitHeight: Style.barHeight

  color: Style.capsuleColor
  radius: Style.radiusL

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: Style.marginS

    NIcon {
      icon: "lamp"
      color: Color.mPrimary
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: {
        root.color = Qt.lighter(Style.capsulecolor, 1.1)
    }

    onExited: {
        root.color = Style.capsuleColor
    }

    onClicked: {
        if (pluginApi) {
          pluginApi.openPanel(root.screen, root)
        }
    }
  }
}
