import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// arch.iudc — Pacman package manager for the Omarchy bar.
// Notifier icon (pacman+AUR update states) plus a popup panel with updates,
// search, installed packages, package details, a live transaction console,
// and cache cleaning. Icons are Nerd Fonts glyphs.
Panel {
  id: root
  moduleName: "arch.iudc"
  ipcTarget: "arch.iudc"
  manageIpc: false

  // --- config ---------------------------------------------------------------
  readonly property int refreshIntervalSec: root.setting("refreshIntervalSec", 1800)
  readonly property bool includeAur: root.setting("includeAur", true)
  readonly property int cacheKeepVersions: root.setting("cacheKeepVersions", 2)

  // --- plugin dir -------------------------------------------------------------
  readonly property string pluginDir: root.bar && root.bar.omarchyConfigDir
    ? root.bar.omarchyConfigDir + "/plugins/arch.iudc"
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/arch.iudc"

  // --- state -------------------------------------------------------------------
  property var updates: []
  property var searchResults: []
  property var nativePkgs: []
  property var foreignPkgs: []
  property var cacheInfo: []
  property string tab: "updates"
  property string selectedPkg: ""
  property string selectedState: "remote"
  property var infoPairs: []
  property var infoMap: ({})
  property var consoleLines: []
  property string txLabel: ""
  property bool checking: false
  property bool searching: false
  property bool loadingInfo: false
  property bool loadingInstalled: false
  property bool txRunning: false
  property int txExitCode: -1
  property bool haveChecked: false
  property bool txViewActive: false
  property string prevTab: "updates"

  // --- derived ------------------------------------------------------------------
  readonly property int repoCount: {
    var n = 0
    for (var i = 0; i < root.updates.length; i++) if (root.updates[i].source === "repo") n++
    return n
  }
  readonly property int aurCount: root.updates.length - root.repoCount
  readonly property int totalUpdates: root.updates.length
  readonly property int installedCount: root.nativePkgs.length + root.foreignPkgs.length

  // Notifier colors: red = repo updates, amber = only AUR, green = clean.
  readonly property color okColor: "#43a047"
  readonly property color aurColor: "#e3a117"
  readonly property color dimColor: root.bar ? Qt.darker(root.bar.foreground, 1.45) : Color.foreground
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color accentC: root.bar && root.bar.accent !== undefined ? root.bar.accent : Color.accent
  readonly property color urgentC: root.bar ? root.bar.urgent : Color.urgent

  readonly property string iconText: "\ueefe"
  readonly property color iconColor: root.haveChecked && root.totalUpdates > 0 ? root.urgentC : root.fg
  readonly property string statusPhrase: {
    if (root.checking) return "Checking for updates\u2026"
    if (!root.haveChecked) return "Not checked yet"
    if (root.totalUpdates === 0) return "System up to date"
    var parts = []
    if (root.repoCount > 0) parts.push(root.repoCount + " repo update" + (root.repoCount === 1 ? "" : "s"))
    if (root.aurCount > 0) parts.push(root.aurCount + " AUR update" + (root.aurCount === 1 ? "" : "s"))
    return parts.join(" \u00b7 ")
  }

  function appendConsole(line) {
    var l = Model.clean(line)
    if (l === "") return
    root.consoleLines.push(l)
    if (root.consoleLines.length > 500) root.consoleLines.splice(0, root.consoleLines.length - 500)
    root.consoleLinesChanged()
  }

  function startTx(label, mode, arg) {
    if (root.txRunning) return
    if (!root.txViewActive) root.prevTab = root.tab
    root.tab = "updates"
    root.txLabel = label
    root.consoleLines = [">>> " + label]
    root.txRunning = true
    root.txExitCode = -1
    root.txViewActive = true
    Qt.callLater(function() { flick.contentY = 0 })
    runProc.command = [root.pluginDir + "/iudc-run.sh", mode].concat(arg !== undefined && arg !== "" ? [arg] : [])
    runProc.running = true
  }

  function syncDbs() { root.startTx("Syncing databases (pacman -Sy)", "sync") }

  function upgradeAll() {
    root.startTx("Full system upgrade" + (root.includeAur ? " + AUR" : ""), "upgrade", root.includeAur ? "aur" : "")
  }

  function installPkg(name, source) {
    if (!name) return
    if (source === "aur") root.startTx("Installing AUR package " + name, "install-aur", name)
    else root.startTx("Installing " + name, "install-repo", name)
  }

  function reinstallPkg(name) {
    if (!name) return
    root.startTx("Reinstalling " + name, "install-repo", name)
  }

  function removePkg(name) {
    if (!name) return
    root.startTx("Removing " + name, "remove", name)
  }

  function cleanPaccache() {
    root.startTx("Pruning pacman cache (keep " + root.cacheKeepVersions + ")", "clean-paccache", String(root.cacheKeepVersions))
  }

  function cleanAurCache() {
    root.startTx("Clearing AUR build cache (~/.cache/yay)", "clean-aurcache")
  }

  function refresh() {
    if (root.checking) return
    root.checking = true
    checkProc.command = [root.pluginDir + "/iudc-check.sh", root.includeAur ? "all" : "repo"]
    checkProc.running = true
  }

  function loadInstalled() {
    if (root.loadingInstalled) return
    root.loadingInstalled = true
    installedProc.command = [root.pluginDir + "/iudc-installed.sh"]
    installedProc.running = true
  }

  function doSearch() {
    var q = searchField.text.trim()
    if (q === "") return
    root.searching = true
    root.searchResults = []
    searchProc.command = ["bash", "-c", root.pluginDir + "/iudc-search.sh " + Util.shellQuote(q)]
    searchProc.running = true
  }

  function showDetail(name, state) {
    if (!name) return
    root.selectedPkg = name
    root.selectedState = state || "remote"
    root.loadingInfo = true
    root.infoPairs = []
    root.infoMap = {}
    infoProc.command = ["bash", "-c",
      root.pluginDir + "/iudc-info.sh " + Util.shellQuote(name) + " " + Util.shellQuote(root.selectedState)]
    infoProc.running = true
  }

  function clearDetail() {
    root.selectedPkg = ""
    root.infoPairs = []
    root.infoMap = {}
  }

  function isInstalled(name) {
    for (var i = 0; i < root.nativePkgs.length; i++) if (root.nativePkgs[i].name === name) return "installed"
    for (var j = 0; j < root.foreignPkgs.length; j++) if (root.foreignPkgs[j].name === name) return "installed"
    return "remote"
  }

  function detailIsAur() {
    for (var i = 0; i < root.searchResults.length; i++)
      if (root.searchResults[i].name === root.selectedPkg) return root.searchResults[i].aur ? "aur" : "repo"
    for (var j = 0; j < root.foreignPkgs.length; j++)
      if (root.foreignPkgs[j].name === root.selectedPkg) return "aur"
    for (var k = 0; k < root.updates.length; k++)
      if (root.updates[k].name === root.selectedPkg) return root.updates[k].source
    return "repo"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (root.opened) { root.refresh(); root.loadInstalled() }

  // --- IPC ----------------------------------------------------------------------
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function upgrade(): void { root.upgradeAll() }
  }

  // --- processes ------------------------------------------------------------------
  Process {
    id: checkProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updates = Model.parseCheck(text)
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.checking = false
      root.haveChecked = true
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.parseSearch(text)
        root.searchResults = res.repo.concat(res.aur).slice(0, 60)
        root.searching = false
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function() { root.searching = false }
  }

  Process {
    id: infoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseInfo(text)
        root.infoPairs = parsed.pairs
        root.infoMap = parsed.map
        root.loadingInfo = false
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function() { root.loadingInfo = false }
  }

  Process {
    id: installedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.parseInstalled(text)
        root.nativePkgs = res.native
        root.foreignPkgs = res.foreign
        root.cacheInfo = res.cacheInfo
        root.loadingInstalled = false
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function() { root.loadingInstalled = false }
  }

  Process {
    id: runProc
    stdout: SplitParser {
      onRead: function(data) { root.appendConsole(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { root.appendConsole(data) }
    }
    onExited: function(exitCode) {
      root.txRunning = false
      root.txExitCode = exitCode
      root.appendConsole(exitCode === 0 ? ">>> Finished OK" : ">>> Failed (exit " + exitCode + ")")
      root.refresh()
      root.loadInstalled()
      if (exitCode === 0) {
        var rs = root.searchResults.slice()
        for (var i = 0; i < rs.length; i++)
          rs[i].installed = root.isInstalled(rs[i].name) === "installed"
        root.searchResults = rs
      }
    }
  }

  Timer {
    interval: Math.max(300, root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // --- bar button --------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    useActiveColor: false
    foreground: root.iconColor
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.statusPhrase

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }

    Rectangle {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: 1
      anchors.rightMargin: 1
      visible: root.totalUpdates > 0
      width: 13
      height: 13
      radius: 7
      color: root.repoCount > 0 ? root.urgentC : root.accentC
      Text {
        anchors.centerIn: parent
        text: root.totalUpdates > 99 ? "99+" : root.totalUpdates
        color: root.bar ? root.bar.background : Color.background
        font.pixelSize: 7
        font.bold: true
      }
    }
  }

  // --- popup ---------------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(Math.min(listColumn.implicitHeight, Style.space(680)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (root.txViewActive && !root.txRunning) root.txViewActive = false
        else root.close()
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "1") root.tab = "updates"
        else if (t === "2") root.tab = "search"
        else if (t === "3") root.tab = "installed"
        else if (t === "4") root.tab = "cache"
        else if ((t === "u" || t === "U") && !root.txRunning) root.upgradeAll()
      }
    }

    Flickable {
      id: flick
      anchors.fill: parent
      clip: true
      contentHeight: listColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: listColumn
        width: parent.width
        spacing: Style.space(12)

        // ---------- Header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight, headerActions.implicitHeight)

          Text {
            id: headerIcon
            text: root.iconText
            color: root.iconColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: headerLabels
            spacing: Style.space(2)
            anchors.left: headerIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: "Pacman"
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: root.statusPhrase
              visible: text !== ""
              color: root.dimColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              iconText: "\uf021"
              tooltipText: "Check for updates (r)"
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              iconSpinning: root.checking
              enabled: !root.checking
              onClicked: root.refresh()
            }
            Button {
              iconText: "\uf1c0"
              tooltipText: "Sync package databases"
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              enabled: !root.txRunning
              onClicked: root.syncDbs()
            }
            Button {
              iconText: "\uf120"
              tooltipText: "Open omarchy-update in a floating terminal"
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
              }
            }
          }
        }

        // ---------- Tabs ----------
        RowLayout {
          visible: !root.txViewActive
          width: parent.width
          spacing: Style.space(6)

          IudcTab { label: "Updates (" + root.totalUpdates + ")"; key: "updates" }
          IudcTab { label: "Search"; key: "search" }
          IudcTab { label: "Installed"; key: "installed" }
          IudcTab { label: "Cache"; key: "cache" }
        }

        PanelSeparator {
          visible: !root.txViewActive
          foreground: root.fg
        }

        // ---------- UPDATES ----------
        Column {
          visible: root.tab === "updates" && !root.txViewActive
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: root.checking
                ? "Checking for updates\u2026"
                : (root.totalUpdates > 0 ? root.statusPhrase : "Everything is up to date")
              color: root.totalUpdates > 0 ? root.fg : root.dimColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            Button {
              text: root.totalUpdates > 0 ? "Upgrade all" : "Refresh"
              tooltipText: root.totalUpdates > 0
                ? "pacman -Syu --noconfirm" + (root.includeAur ? " then yay -Sua --noconfirm" : "")
                : "Check again"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.txRunning && !root.checking
              onClicked: root.totalUpdates > 0 ? root.upgradeAll() : root.refresh()
            }
          }

          Repeater {
            model: root.updates
            delegate: UpdateRow {}
          }

          Text {
            visible: !root.checking && root.totalUpdates === 0
            text: "\uf058  No pending updates"
            color: root.okColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- SEARCH ----------
        Column {
          visible: root.tab === "search" && !root.txViewActive
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "Search repositories and AUR\u2026"
              foreground: root.fg
              accent: root.accentC
              font.family: root.bar.fontFamily
              verticalPadding: Style.space(5)
              onAccepted: root.doSearch()
            }

            Button {
              iconText: root.searching ? "\uf021" : "\uf002"
              tooltipText: "Search"
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              iconSpinning: root.searching
              enabled: !root.searching
              onClicked: root.doSearch()
            }
          }

          Text {
            visible: root.searchResults.length > 0
            text: root.searchResults.length + " result(s)"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.searchResults.length === 0 && !root.searching && searchField.text.trim() !== ""
            text: "No results"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.searchResults
            delegate: SearchRow {}
          }
        }

        // ---------- INSTALLED ----------
        Column {
          visible: root.tab === "installed" && !root.txViewActive
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: root.loadingInstalled
              ? "Loading\u2026"
              : root.installedCount + " packages (" + root.nativePkgs.length + " native \u00b7 " + root.foreignPkgs.length + " foreign/AUR)"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: installedFilter
            width: parent.width
            placeholderText: "Filter installed packages\u2026"
            foreground: root.fg
            accent: root.accentC
            font.family: root.bar.fontFamily
            verticalPadding: Style.space(5)
          }

          Repeater {
            model: {
              var all = root.nativePkgs.concat(root.foreignPkgs)
              var f = installedFilter.text.trim()
              if (f !== "") all = all.filter(function(p) { return p.name.indexOf(f) >= 0 })
              return all.slice(0, 200)
            }
            delegate: InstalledRow {}
          }

          Text {
            visible: root.installedCount > 200 && installedFilter.text.trim() === ""
            text: "+ more (use the filter)"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- CACHE ----------
        Column {
          visible: root.tab === "cache" && !root.txViewActive
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "Cache maintenance"
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.cacheInfo.length > 0 ? root.cacheInfo.join("\n") : "Cache info unavailable"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              iconText: "\uf187"
              text: "Prune pacman cache"
              tooltipText: "pkexec paccache -rk " + root.cacheKeepVersions
              fontSize: Style.font.bodySmall
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.txRunning
              onClicked: root.cleanPaccache()
            }

            Button {
              iconText: "\uf1f8"
              text: "Clear AUR build cache"
              tooltipText: "~/.cache/yay"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.txRunning
              onClicked: root.cleanAurCache()
            }
          }
        }

        // ---------- DETAIL ----------
        Column {
          visible: root.selectedPkg !== "" && !root.txViewActive
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.fg }

          Item {
            width: parent.width
            implicitHeight: Math.max(detailTitleRow.implicitHeight, detailActions.implicitHeight)

            Row {
              id: detailTitleRow
              spacing: Style.space(6)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: "\uf105"
                color: root.accentC
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.selectedPkg
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
              Rectangle {
                visible: root.selectedState === "installed"
                radius: Style.cornerRadius
                implicitHeight: stateTag.implicitHeight + Style.space(3)
                implicitWidth: stateTag.implicitWidth + Style.space(8)
                color: Style.hoverFillFor(root.fg, root.accentC)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  id: stateTag
                  anchors.centerIn: parent
                  text: "installed"
                  color: root.dimColor
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption * 0.85
                }
              }
            }

            Row {
              id: detailActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                visible: root.selectedState === "installed"
                iconText: "\uf021"
                tooltipText: "Reinstall"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                enabled: !root.txRunning
                onClicked: root.reinstallPkg(root.selectedPkg)
              }
              Button {
                visible: root.selectedState === "remote"
                iconText: "\uf019"
                tooltipText: "Install"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                enabled: !root.txRunning
                onClicked: root.installPkg(root.selectedPkg, root.detailIsAur())
              }
              Button {
                iconText: "\uf1f8"
                tooltipText: "Remove (pacman -Rns)"
                foreground: root.urgentC
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                enabled: root.selectedState === "installed" && !root.txRunning
                onClicked: root.removePkg(root.selectedPkg)
              }
              Button {
                iconText: "\uf00d"
                tooltipText: "Close details"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                onClicked: root.clearDetail()
              }
            }
          }

          Text {
            visible: root.loadingInfo
            text: "Loading package info\u2026"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.infoPairs.filter(function(p) {
              return ["Description", "Version", "Repository", "Install Reason",
                      "Depends On", "Required By", "Licenses"].indexOf(p.key) >= 0
            })
            delegate: RowLayout {
              required property var modelData
              width: parent ? parent.width : 0
              spacing: Style.space(8)

              Text {
                text: modelData.key
                color: root.dimColor
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.preferredWidth: Style.space(96)
              }
              Text {
                text: modelData.value === "" ? "-" : modelData.value
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
                Layout.fillWidth: true
              }
            }
          }
        }

        // ---------- Last transaction pill ----------
        Row {
          visible: !root.txViewActive && root.txLabel !== "" && root.consoleLines.length > 0
          width: parent.width

          Button {
            iconText: root.txExitCode === 0 ? "\uf058" : (root.txExitCode < 0 ? "\uf021" : "\uf071")
            text: "Last operation: " + root.txLabel + " \u2014 click to review"
            tooltipText: "Reopen transaction output"
            fontSize: Style.font.caption
            foreground: root.txExitCode === 0 ? root.okColor : (root.txExitCode < 0 ? root.dimColor : root.urgentC)
            accent: root.accentC
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.txViewActive = true
          }
        }

        // ---------- TRANSACTION VIEW ----------
        // Full-panel view for the running operation (install / upgrade /
        // remove / cache). Every action opens this view with its live output,
        // modal transaction-dialog style.
        Column {
          visible: root.txViewActive
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: Math.max(txHeader.implicitHeight, txActions.implicitHeight)

            Row {
              id: txHeader
              spacing: Style.space(6)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                width: 9
                height: 9
                radius: 4.5
                anchors.verticalCenter: parent.verticalCenter
                color: root.txRunning ? root.okColor
                  : (root.txExitCode === 0 ? root.okColor : (root.txExitCode < 0 ? root.dimColor : root.urgentC))
              }
              Text {
                text: root.txLabel !== "" ? root.txLabel : "Transaction"
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                width: Math.min(implicitWidth, Style.space(330))
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.txRunning ? "running\u2026"
                  : (root.txExitCode === 0 ? "Finished OK" : (root.txExitCode < 0 ? "" : "Failed (exit " + root.txExitCode + ")"))
                color: root.txRunning ? root.okColor
                  : (root.txExitCode === 0 ? root.okColor : root.urgentC)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: txActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                iconText: "\uf060"
                tooltipText: "Back"
                text: "Back"
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                bordered: true
                enabled: !root.txRunning
                onClicked: {
                  root.txViewActive = false
                  root.tab = root.prevTab
                }
              }
              Button {
                iconText: "\uf00d"
                tooltipText: "Discard output and close view"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                enabled: !root.txRunning
                onClicked: {
                  root.consoleLines = []
                  root.txLabel = ""
                  root.txExitCode = -1
                  root.txViewActive = false
                  root.tab = root.prevTab
                }
              }
            }
          }

          Text {
            visible: root.txRunning && root.consoleLines.length === 0
            text: "Waiting for output\u2026"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            height: Style.space(430)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.fg, root.accentC)
            clip: true

            Flickable {
              id: consoleScroll
              property bool follow: true
              anchors.fill: parent
              anchors.margins: Style.space(6)
              contentWidth: width
              contentHeight: consoleText.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              onDragStarted: follow = false
              onContentHeightChanged: if (follow) scrollToBottom()

              function scrollToBottom() {
                contentY = Math.max(0, contentHeight - height)
              }

              Text {
                id: consoleText
                width: consoleScroll.width
                text: root.consoleLines.join("\n")
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              }

              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
          }

          Text {
            text: root.txRunning
              ? "The panel stays here until it finishes \u00b7 output streams live"
              : "Esc or Back to return \u00b7 output kept until you discard it"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Footer hints ----------
        Text {
          visible: root.consoleLines.length === 0 && !root.txViewActive
          text: "Esc close \u00b7 r refresh \u00b7 u upgrade \u00b7 1-4 tabs \u00b7 click a package for details"
          color: root.dimColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------- inline components ----------

  component IudcTab: Button {
    id: tb
    required property string label
    required property string key
    text: tb.label
    selected: root.tab === tb.key
    fontSize: Style.font.bodySmall
    foreground: root.fg
    accent: root.accentC
    fontFamily: root.bar.fontFamily
    bordered: true
    Layout.fillWidth: true
    onClicked: root.tab = tb.key
  }

  // One pending-update row: source glyph + name + old -> new + tag.
  component UpdateRow: MouseArea {
    id: urow
    required property var modelData
    required property int index
    width: parent ? parent.width : 0
    implicitHeight: urowBody.implicitHeight + Style.space(6)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.showDetail(urow.modelData.name,
      urow.modelData.source === "aur" ? "installed" : root.isInstalled(urow.modelData.name))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: urow.containsMouse ? Style.hoverFillFor(root.fg, root.accentC) : "transparent"
    }

    RowLayout {
      id: urowBody
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: urow.modelData.source === "aur" ? "\uf089a" : "\uf03d3"
        color: urow.modelData.source === "aur" ? root.aurColor : root.accentC
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        text: urow.modelData.name
        color: root.fg
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        Layout.preferredWidth: Style.space(150)
      }
      Text {
        text: urow.modelData.old + " \u2192 " + urow.modelData.new
        color: root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        text: urow.modelData.source === "aur" ? "AUR" : "repo"
        color: urow.modelData.source === "aur" ? root.aurColor : root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption * 0.85
      }
    }
  }

  // One search-result row: name/version/repo + description + action.
  component SearchRow: MouseArea {
    id: srow
    required property var modelData
    required property int index
    width: parent ? parent.width : 0
    implicitHeight: srowCol.implicitHeight + Style.space(6)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.showDetail(srow.modelData.name,
      srow.modelData.installed ? "installed" : "remote")

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: srow.containsMouse ? Style.hoverFillFor(root.fg, root.accentC) : "transparent"
    }

    Column {
      id: srowCol
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: srowAction.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(1)

      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: srow.modelData.name
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        Text {
          visible: srow.modelData.version !== ""
          text: srow.modelData.version
          color: root.dimColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: srow.modelData.repo
          color: srow.modelData.aur ? root.aurColor : root.dimColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption * 0.9
        }
      }
      Text {
        visible: srow.modelData.description !== ""
        width: parent.width
        text: srow.modelData.description
        color: root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }

    PanelActionButton {
      id: srowAction
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: srow.modelData.installed ? "\uf1f8" : "\uf019"
      tooltipText: srow.modelData.installed ? "Remove" : "Install"
      foreground: srow.modelData.installed ? root.urgentC : root.fg
      hoverColor: srow.modelData.installed ? root.urgentC : root.fg
      fontFamily: root.bar.fontFamily
      enabled: !root.txRunning
      onClicked: {
        if (srow.modelData.installed) root.removePkg(srow.modelData.name)
        else root.installPkg(srow.modelData.name, srow.modelData.aur ? "aur" : "repo")
      }
    }
  }

  // One installed-package row: name + version + AUR marker.
  component InstalledRow: MouseArea {
    id: irow
    required property var modelData
    required property int index
    width: parent ? parent.width : 0
    implicitHeight: irowBody.implicitHeight + Style.space(4)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.showDetail(irow.modelData.name, "installed")

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: irow.containsMouse ? Style.hoverFillFor(root.fg, root.accentC) : "transparent"
    }

    RowLayout {
      id: irowBody
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: irow.modelData.name
        color: root.fg
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        text: irow.modelData.version
        color: root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: irow.modelData.aur
        text: "AUR"
        color: root.aurColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption * 0.85
      }
    }
  }
}
