import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets
import qs.Services.UI

FloatingWindow {
  id: root

  property var pluginApi: null
  readonly property var mainInstance: pluginApi?.mainInstance

  title: taildropWindow.mode === "send" 
    ? (pluginApi?.tr("title.send") || "Send Files via Taildrop")
    : (pluginApi?.tr("title.receive") || "Receive Files via Taildrop")

  minimumSize: Qt.size(500 * Style.uiScaleRatio, 600 * Style.uiScaleRatio)
  implicitWidth: Math.round(500 * Style.uiScaleRatio)
  implicitHeight: Math.round(600 * Style.uiScaleRatio)
  color: Color.mSurface

  visible: false

  // Open window when component is created
  Component.onCompleted: {
    visible = true
  }

  // Close panel when window closes
  onVisibleChanged: {
    if (!visible && pluginApi) {
      pluginApi.withCurrentScreen(screen => {
        pluginApi.closePanel(screen);
      });
    }
  }

  // Keyboard shortcuts
  Shortcut {
    sequence: "Escape"
    onActivated: root.visible = false
  }

  Item {
    id: taildropWindow
    anchors.fill: parent

    NFilePicker {
      id: filePicker
      selectionMode: "files"
      title: pluginApi?.tr("select-files") || "Select Files to Send"
      initialPath: Quickshell.env("HOME")
      onAccepted: paths => {
        if (paths.length > 0) {
          taildropWindow.pendingFiles = paths
        }
      }
    }

    property var sortedPeerList: {
      if (!mainInstance?.peerList) return []
      var peers = mainInstance.peerList.slice()
      
      // Only show online peers that are not tagged
      peers = peers.filter(function(peer) {
        return peer.Online === true && (!peer.Tags || peer.Tags.length === 0)
      })
      
      peers.sort(function(a, b) {
        var nameA = (a.HostName || a.DNSName || "").toLowerCase()
        var nameB = (b.HostName || b.DNSName || "").toLowerCase()
        return nameA.localeCompare(nameB)
      })
      return peers
    }

    function filterIPv4(ips) {
      return mainInstance?.filterIPv4(ips) || []
    }

    function getOSIcon(os) {
      if (!os) return "device-desktop"
      switch (os.toLowerCase()) {
        case "linux":
          return "brand-debian"
        case "macos":
          return "brand-apple"
        case "ios":
          return "device-mobile"
        case "android":
          return "device-mobile"
        case "windows":
          return "brand-windows"
        default:
          return "device-desktop"
      }
    }

    property var selectedPeer: null
    property string selectedPeerHostname: ""
    property var pendingFiles: []
    property bool isTransferring: false
    property string transferStatus: ""
    property string mode: "send" // "send" or "receive"
    property var receivedFiles: []
    property bool isLoadingReceived: false
    property bool isReceiving: false
    readonly property string taildropDir: mainInstance?.receiveDirectory || (Quickshell.env("HOME") + "/Downloads/Taildrop")

    Component.onCompleted: {
      // Reset to send mode when window is created
      mode = "send"
    }

    Process {
      id: fileTransferProcess
      stdout: StdioCollector {}
      stderr: StdioCollector {}

      onExited: function(exitCode, exitStatus) {
        taildropWindow.isTransferring = false
        if (exitCode === 0) {
          var hostname = taildropWindow.selectedPeer?.HostName || "device"
          var message = (pluginApi?.tr("transfer-success.message") || "Files successfully sent to %1").replace("%1", hostname)
          ToastService.showNotice(
            pluginApi?.tr("transfer-success.title") || "Files Sent",
            message,
            "check"
          )
          taildropWindow.pendingFiles = []
          taildropWindow.transferStatus = ""
        } else {
          var stderr = String(fileTransferProcess.stderr.text || "").trim()
          ToastService.showError(
            pluginApi?.tr("transfer-error.title") || "Transfer Failed",
            stderr || (pluginApi?.tr("transfer-error.message") || "Failed to send files"),
            "alert-circle"
          )
          taildropWindow.transferStatus = ""
        }
      }
    }

    readonly property string pluginDir: {
      // Get the directory where this Panel.qml file is located
      var qmlFile = Qt.resolvedUrl("Panel.qml").toString()
      if (qmlFile.startsWith("file://")) {
        qmlFile = qmlFile.substring(7)
      }
      return qmlFile.substring(0, qmlFile.lastIndexOf('/'))
    }

    Timer {
      id: scanTimer
      interval: 2000
      repeat: true
      triggeredOnStart: false
      property int scanCount: 0
      property int maxScans: 10  // Scan for up to 20 seconds (2s * 10)
      
      onTriggered: {
        taildropWindow.scanReceivedFiles()
        scanCount++
        if (scanCount >= maxScans) {
          stop()
          scanCount = 0
        }
      }
    }

    Process {
      id: scanDirProcess
      stdout: StdioCollector {}
      stderr: StdioCollector {}

      onExited: function(exitCode, exitStatus) {
        if (exitCode === 0) {
          var output = String(scanDirProcess.stdout.text || "").trim()
          if (output) {
            var lines = output.split('\n')
            var files = []
            for (var i = 0; i < lines.length; i++) {
              var line = lines[i].trim()
              if (line && line !== taildropWindow.taildropDir) {
                files.push(line)
              }
            }
            taildropWindow.receivedFiles = files
          } else {
            taildropWindow.receivedFiles = []
          }
        } else {
          taildropWindow.receivedFiles = []
        }
      }
    }

    function sendFiles() {
      if (!selectedPeer || pendingFiles.length === 0) return
      
      isTransferring = true
      transferStatus = pluginApi?.tr("transferring") || "Sending files..."
      
      var target = filterIPv4(selectedPeer.TailscaleIPs)[0] || selectedPeer.HostName
      var args = ["file", "cp"]
      
      for (var i = 0; i < pendingFiles.length; i++) {
        args.push(pendingFiles[i])
      }
      
      args.push(target + ":")
      
      fileTransferProcess.command = ["tailscale"].concat(args)
      fileTransferProcess.running = true
    }

    Process {
      id: receiveProcess
      stdout: StdioCollector {}
      stderr: StdioCollector {}

      onExited: function(exitCode, exitStatus) {
        taildropWindow.isReceiving = false
        if (exitCode === 0) {
          ToastService.showNotice(
            pluginApi?.tr("receive-success.title") || "Files Downloaded",
            pluginApi?.tr("receive-success.message") || "Files successfully downloaded to Taildrop folder",
            "check"
          )
          // Scan immediately after successful download
          taildropWindow.scanReceivedFiles()
        } else if (exitCode === 126 || exitCode === 127) {
          // User cancelled authentication or command not found
          ToastService.showNotice(
            pluginApi?.tr("receive-cancelled.title") || "Download Cancelled",
            pluginApi?.tr("receive-cancelled.message") || "Authentication cancelled or no pending files",
            "info-circle"
          )
        } else {
          var stderr = String(receiveProcess.stderr.text || "").trim()
          ToastService.showError(
            pluginApi?.tr("receive-error.title") || "Download Failed",
            stderr || (pluginApi?.tr("receive-error.message") || "Failed to download files"),
            "alert-circle"
          )
        }
      }
    }

    function loadReceivedFiles() {
      // First ensure the directory exists
      Quickshell.execDetached(["mkdir", "-p", taildropWindow.taildropDir])
      
      // Set receiving state
      taildropWindow.isReceiving = true
      
      // Show notification that authentication is needed
      ToastService.showNotice(
        pluginApi?.tr("receive-started.title") || "Downloading Files",
        pluginApi?.tr("receive-started.message") || "Please authenticate to download pending Taildrop files",
        "download"
      )
      
      // Run pkexec directly using Process instead of execDetached so we can track completion
      receiveProcess.command = [
        "pkexec",
        "sh", "-c",
        "tailscale file get '" + taildropWindow.taildropDir + "' && chown -R $SUDO_UID:$SUDO_GID '" + taildropWindow.taildropDir + "'"
      ]
      receiveProcess.running = true
    }

    function scanReceivedFiles() {
      // Scan the Taildrop directory for files
      scanDirProcess.command = ["find", taildropWindow.taildropDir, "-type", "f"]
      scanDirProcess.running = true
    }

    function openReceivedFile(filePath) {
      Quickshell.execDetached(["xdg-open", filePath])
    }

    function openTaildropFolder() {
      Quickshell.execDetached(["xdg-open", taildropWindow.taildropDir])
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginL

      // Header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NIcon {
          icon: taildropWindow.mode === "send" ? "send" : "inbox"
          pointSize: Style.fontSizeL
          color: Color.mPrimary
        }

        NText {
          text: taildropWindow.mode === "send" 
            ? (pluginApi?.tr("title.send") || "Send Files via Taildrop")
            : (pluginApi?.tr("title.receive") || "Receive Files via Taildrop")
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
          Layout.fillWidth: true
        }

        NIconButton {
          icon: "x"
          onClicked: root.visible = false
        }
      }

      // Mode switcher
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NButton {
          text: pluginApi?.tr("mode.send") || "Send"
          icon: "send"
          Layout.fillWidth: true
          backgroundColor: taildropWindow.mode === "send" ? Color.mPrimary : "transparent"
          textColor: taildropWindow.mode === "send" ? Color.mOnPrimary : Color.mOnSurface
          onClicked: taildropWindow.mode = "send"
        }

        NButton {
          text: pluginApi?.tr("mode.receive") || "Receive"
          icon: "inbox"
          Layout.fillWidth: true
          backgroundColor: taildropWindow.mode === "receive" ? Color.mPrimary : "transparent"
          textColor: taildropWindow.mode === "receive" ? Color.mOnPrimary : Color.mOnSurface
          onClicked: {
            taildropWindow.mode = "receive"
            taildropWindow.scanReceivedFiles()
          }
        }
      }

      // Device selection (Send mode only)
      NBox {
        Layout.fillWidth: true
        Layout.preferredHeight: 200
        visible: taildropWindow.mode === "send"

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginS

          NText {
            text: pluginApi?.tr("select-device") || "Select a device:"
            pointSize: Style.fontSizeM
            font.weight: Style.fontWeightMedium
            color: Color.mOnSurface
          }

          Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: deviceColumn.height
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
              id: deviceColumn
              width: parent.width
              spacing: Style.marginS

              Repeater {
                model: taildropWindow.sortedPeerList

                delegate: ItemDelegate {
                  id: deviceDelegate
                  Layout.fillWidth: true
                  height: 48
                  topPadding: Style.marginS
                  bottomPadding: Style.marginS
                  leftPadding: Style.marginM
                  rightPadding: Style.marginM

                  readonly property var peerData: modelData
                  readonly property string peerHostname: peerData.HostName || peerData.DNSName || "Unknown"
                  readonly property bool isSelected: taildropWindow.selectedPeerHostname === peerHostname

                  background: Rectangle {
                    anchors.fill: parent
                    color: deviceDelegate.isSelected 
                      ? Qt.alpha(Color.mPrimary, 0.2)
                      : (deviceDelegate.hovered ? Qt.alpha(Color.mPrimary, 0.1) : "transparent")
                    radius: Style.radiusM
                    border.width: deviceDelegate.isSelected ? 2 : (deviceDelegate.hovered ? 1 : 0)
                    border.color: deviceDelegate.isSelected ? Color.mPrimary : Qt.alpha(Color.mPrimary, 0.3)
                  }

                  contentItem: RowLayout {
                    spacing: Style.marginM

                    NIcon {
                      icon: taildropWindow.getOSIcon(deviceDelegate.peerData.OS)
                      pointSize: Style.fontSizeM
                      color: deviceDelegate.isSelected ? Color.mPrimary : Color.mOnSurface
                    }

                    NText {
                      text: deviceDelegate.peerHostname
                      color: deviceDelegate.isSelected ? Color.mPrimary : Color.mOnSurface
                      font.weight: deviceDelegate.isSelected ? Style.fontWeightBold : Style.fontWeightMedium
                      Layout.fillWidth: true
                    }

                    NIcon {
                      icon: "check"
                      pointSize: Style.fontSizeS
                      color: Color.mPrimary
                      visible: deviceDelegate.isSelected
                    }
                  }

                  onClicked: {
                    taildropWindow.selectedPeer = deviceDelegate.peerData
                    taildropWindow.selectedPeerHostname = deviceDelegate.peerHostname
                  }
                }
              }

              NText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Style.marginL
                text: pluginApi?.tr("no-devices") || "No online devices available"
                visible: taildropWindow.sortedPeerList.length === 0
                pointSize: Style.fontSizeM
                color: Color.mOnSurfaceVariant
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }

      // Drop zone (Send mode only)
      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: taildropWindow.mode === "send"
        color: dropArea.containsDrag ? Qt.alpha(Color.mPrimary, 0.1) : Qt.alpha(Color.mSurfaceVariant, 0.5)
        radius: Style.radiusM
        border.width: 2
        border.color: dropArea.containsDrag ? Color.mPrimary : Qt.alpha(Color.mOutline, 0.3)

        DropArea {
          id: dropArea
          anchors.fill: parent

          onDropped: function(drop) {
            if (drop.hasUrls) {
              var files = []
              for (var i = 0; i < drop.urls.length; i++) {
                var url = drop.urls[i].toString()
                if (url.startsWith("file://")) {
                  files.push(url.substring(7))
                }
              }
              taildropWindow.pendingFiles = files
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          enabled: !taildropWindow.isTransferring
          onClicked: {
            filePicker.openFilePicker()
          }
        }

        ColumnLayout {
          anchors.centerIn: parent
          spacing: Style.marginM
          width: parent.width - Style.marginL * 2

          NIcon {
            icon: taildropWindow.pendingFiles.length > 0 ? "files" : "upload"
            pointSize: Style.fontSizeXL * 2
            color: dropArea.containsDrag ? Color.mPrimary : Color.mOnSurfaceVariant
            Layout.alignment: Qt.AlignHCenter
          }

          NText {
            text: {
              if (taildropWindow.isTransferring) {
                return taildropWindow.transferStatus
              } else if (taildropWindow.pendingFiles.length > 0) {
                return (pluginApi?.tr("files-ready") || "%1 file(s) ready to send").replace("%1", taildropWindow.pendingFiles.length)
              } else if (dropArea.containsDrag) {
                return pluginApi?.tr("drop-here") || "Drop files here"
              } else {
                return pluginApi?.tr("drop-zone") || "Click to browse or drag files here"
              }
            }
            pointSize: Style.fontSizeL
            font.weight: Style.fontWeightMedium
            color: dropArea.containsDrag ? Color.mPrimary : Color.mOnSurface
            Layout.alignment: Qt.AlignHCenter
          }

          NText {
            text: taildropWindow.pendingFiles.length > 0 
              ? taildropWindow.pendingFiles.join("\n")
              : (pluginApi?.tr("drop-hint") || "Multiple file selection supported")
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            visible: !taildropWindow.isTransferring
            elide: Text.ElideMiddle
            maximumLineCount: 5
          }

          NButton {
            text: pluginApi?.tr("clear-files") || "Clear Files"
            icon: "x"
            visible: taildropWindow.pendingFiles.length > 0 && !taildropWindow.isTransferring
            onClicked: taildropWindow.pendingFiles = []
            Layout.alignment: Qt.AlignHCenter
          }
        }
      }

      // Received files list (Receive mode only)
      NBox {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: taildropWindow.mode === "receive"

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginM

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NText {
              text: pluginApi?.tr("received-files") || "Received Files"
              pointSize: Style.fontSizeM
              font.weight: Style.fontWeightMedium
              color: Color.mOnSurface
              Layout.fillWidth: true
            }

            NIconButton {
              icon: "folder-open"
              onClicked: taildropWindow.openTaildropFolder()
            }

            NIconButton {
              icon: taildropWindow.isReceiving ? "loader" : "download"
              enabled: !taildropWindow.isReceiving
              onClicked: taildropWindow.loadReceivedFiles()
              ToolTip.visible: hovered
              ToolTip.text: taildropWindow.isReceiving 
                ? (pluginApi?.tr("downloading-files-tooltip") || "Downloading files...")
                : (pluginApi?.tr("download-files-tooltip") || "Download pending files from Tailscale (requires authentication)")
              
              // Rotating animation for loader icon
              RotationAnimator on rotation {
                running: taildropWindow.isReceiving
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 1000
              }
            }

            NIconButton {
              icon: "refresh"
              enabled: !taildropWindow.isReceiving
              onClicked: taildropWindow.scanReceivedFiles()
              ToolTip.visible: hovered
              ToolTip.text: pluginApi?.tr("refresh-list-tooltip") || "Refresh local file list"
            }
          }

          NText {
            Layout.fillWidth: true
            text: (pluginApi?.tr("receive-hint") || "Files are saved to: %1").replace("%1", taildropWindow.taildropDir)
            pointSize: Style.fontSizeXS
            color: Color.mOnSurfaceVariant
            wrapMode: Text.Wrap
          }

          Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: receivedFilesColumn.height
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
              id: receivedFilesColumn
              width: parent.width
              spacing: Style.marginS

              Repeater {
                model: taildropWindow.receivedFiles

                delegate: ItemDelegate {
                  Layout.fillWidth: true
                  height: 48
                  topPadding: Style.marginS
                  bottomPadding: Style.marginS
                  leftPadding: Style.marginM
                  rightPadding: Style.marginM

                  readonly property string fileName: {
                    var filePath = modelData
                    var parts = filePath.split('/')
                    return parts[parts.length - 1]
                  }

                  background: Rectangle {
                    anchors.fill: parent
                    color: parent.hovered ? Qt.alpha(Color.mPrimary, 0.1) : "transparent"
                    radius: Style.radiusM
                    border.width: parent.hovered ? 1 : 0
                    border.color: Qt.alpha(Color.mPrimary, 0.3)
                  }

                  contentItem: RowLayout {
                    spacing: Style.marginM

                    NIcon {
                      icon: "file"
                      pointSize: Style.fontSizeM
                      color: Color.mPrimary
                    }

                    NText {
                      text: parent.parent.fileName
                      color: Color.mOnSurface
                      font.weight: Style.fontWeightMedium
                      elide: Text.ElideMiddle
                      Layout.fillWidth: true
                    }

                    NIcon {
                      icon: "external-link"
                      pointSize: Style.fontSizeS
                      color: Color.mOnSurfaceVariant
                    }
                  }

                  onClicked: taildropWindow.openReceivedFile(modelData)
                }
              }

              NText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Style.marginL
                text: taildropWindow.isLoadingReceived 
                  ? (pluginApi?.tr("loading") || "Loading...")
                  : (pluginApi?.tr("no-received-files") || "No files received yet")
                visible: taildropWindow.receivedFiles.length === 0
                pointSize: Style.fontSizeM
                color: Color.mOnSurfaceVariant
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }

      // Action buttons (Send mode only)
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM
        visible: taildropWindow.mode === "send"

        NButton {
          text: pluginApi?.tr("cancel") || "Cancel"
          Layout.fillWidth: true
          enabled: !taildropWindow.isTransferring
          onClicked: {
            taildropWindow.pendingFiles = []
            taildropWindow.selectedPeer = null
            taildropWindow.selectedPeerHostname = ""
            taildropWindow.transferStatus = ""
          }
        }

        NButton {
          text: pluginApi?.tr("send") || "Send Files"
          icon: "send"
          backgroundColor: Color.mPrimary
          textColor: Color.mOnPrimary
          Layout.fillWidth: true
          enabled: taildropWindow.selectedPeer !== null && taildropWindow.pendingFiles.length > 0 && !taildropWindow.isTransferring
          onClicked: taildropWindow.sendFiles()
        }
      }
    }
  }
}
