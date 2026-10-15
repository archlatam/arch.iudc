import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// arch.iudc — Pacman package manager for the Omarchy bar.
// Notifier icon (update states) plus a popup panel with updates, search,
// installed packages, package details, and cache cleaning. Privileged
// actions open in the system's default terminal. Icons are Nerd Fonts glyphs.
Panel {
  id: root
  moduleName: "arch.iudc"
  ipcTarget: "arch.iudc"
  manageIpc: false

  // --- config ---------------------------------------------------------------
  readonly property int refreshIntervalSec: root.setting("refreshIntervalSec", 1800)
  readonly property int cacheKeepVersions: root.setting("cacheKeepVersions", 2)

  // --- plugin dir -------------------------------------------------------------
  readonly property string pluginDir: root.bar && root.bar.omarchyConfigDir
    ? root.bar.omarchyConfigDir + "/plugins/arch.iudc"
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/arch.iudc"

  // --- state -------------------------------------------------------------------
  property var updates: []
  property var searchResults: []
  property var nativePkgs: []
  property var cacheInfo: []
  property string tab: "updates"
  property string selectedPkg: ""
  property string selectedState: "remote"
  property var infoPairs: []
  property var infoMap: ({})
  property bool checking: false
  property bool searching: false
  property bool loadingInfo: false
  property bool loadingInstalled: false
  property bool haveChecked: false
  property int searchRunId: 0
  property string lastCompletedQuery: ""
  property var repoList: []
  property bool repoListLoaded: false

  // --- derived ------------------------------------------------------------------
  readonly property int totalUpdates: root.updates.length
  readonly property int installedCount: root.nativePkgs.length

  // Notifier colors: red = updates pending, green = clean.
  readonly property color okColor: "#43a047"
  readonly property color dimColor: root.bar ? Qt.darker(root.bar.foreground, 1.45) : ShellColor.foreground
  readonly property color fg: root.bar ? root.bar.foreground : ShellColor.foreground
  readonly property color accentC: root.bar && root.bar.accent !== undefined ? root.bar.accent : ShellColor.accent
  readonly property color urgentC: root.bar ? root.bar.urgent : ShellColor.urgent

  readonly property string iconText: "\uDB80\uDFD6"
  readonly property color iconColor: root.haveChecked && root.totalUpdates > 0 ? root.urgentC : root.fg
  readonly property string statusPhrase: {
    if (root.checking) return "Checking for updates\u2026"
    if (!root.haveChecked) return "Not checked yet"
    if (root.totalUpdates === 0) return "System up to date"
    return root.totalUpdates + " package update" + (root.totalUpdates === 1 ? "" : "s")
  }

  // Privileged actions never run inside the panel: they open in the system's
  // default terminal, where sudo asks for the root password interactively.
  function runInTerminal(mode, arg) {
    var cmd = "sudo " + Util.shellQuote(root.pluginDir + "/iudc-run") + " " + mode
    if (arg !== undefined && arg !== "") cmd += " " + Util.shellQuote(arg)
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(cmd))
  }

  function syncDbs() { root.runInTerminal("sync") }

  function upgradeAll() {
    // Hand the upgrade to Omarchy's official updater in a floating terminal:
    // it prompts for sudo, snapshots and runs the system migrations.
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
  }

  function installPkg(name) {
    if (!name) return
    root.runInTerminal("install-repo", name)
  }

  function removePkg(name) {
    if (!name) return
    root.runInTerminal("remove", name)
  }

  function cleanPaccache() {
    root.runInTerminal("clean-paccache", String(root.cacheKeepVersions))
  }

  function refresh() {
    if (root.checking) return
    root.checking = true
    checkProc.command = [root.pluginDir + "/iudc-check"]
    checkProc.running = true
  }

  function loadInstalled() {
    if (root.loadingInstalled) return
    root.loadingInstalled = true
    installedProc.command = [root.pluginDir + "/iudc-installed"]
    installedProc.running = true
  }

  function loadRepoList() {
    if (root.repoListLoaded || repolistProc.running) return
    repolistProc.command = [root.pluginDir + "/iudc-repolist"]
    repolistProc.running = true
  }

  function doSearch() {
    var q = searchField.text.trim()
    if (q === "") return
    if (!root.searching && q === root.lastCompletedQuery) return
    root.searchRunId++
    searchProc.runId = root.searchRunId
    if (searchProc.running) searchProc.running = false
    root.searching = true
    root.searchResults = []
    searchProc.lastQuery = q
    searchProc.command = [root.pluginDir + "/iudc-search", q]
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
      root.pluginDir + "/iudc-info " + Util.shellQuote(name) + " " + Util.shellQuote(root.selectedState)]
    infoProc.running = true
  }

  function clearDetail() {
    root.selectedPkg = ""
    root.infoPairs = []
    root.infoMap = {}
  }

  function isInstalled(name) {
    for (var i = 0; i < root.nativePkgs.length; i++) if (root.nativePkgs[i].name === name) return "installed"
    return "remote"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (root.opened) { root.refresh(); root.loadInstalled() }
  onTabChanged: {
    if (root.tab === "search") root.loadRepoList()
    else if (root.tab === "installed") root.loadInstalled()
    else if (root.tab === "updates") root.refresh()
  }

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
  // All data streams are collected through BoundedCollector (hard ceiling) so
  // hostile repository/package output can never force unbounded buffering.
  Process {
    id: checkProc
    stdout: BoundedCollector { id: checkOut }
    stderr: BoundedCollector { id: checkErr }
    onStarted: { checkOut.reset(); checkErr.reset() }
    onExited: function(exitCode) {
      checkOut.done = true
      root.updates = Model.parseCheck(checkOut.text)
      root.checking = false
      root.haveChecked = true
    }
  }

  Process {
    id: searchProc
    property int runId: 0
    property string lastQuery: ""
    stdout: BoundedCollector {
      id: searchOut
      onFinished: {
        if (searchProc.runId !== root.searchRunId) return
        root.searchResults = Model.rankSearch(Model.parseSearch(searchOut.text), searchProc.lastQuery)
        root.lastCompletedQuery = searchProc.lastQuery
        root.searching = false
      }
    }
    stderr: BoundedCollector { id: searchErr }
    onStarted: { searchOut.reset(); searchErr.reset() }
    onExited: function() {
      if (searchProc.runId !== root.searchRunId) return
      searchOut.done = true
      searchOut.finished()
    }
  }

  Process {
    id: repolistProc
    stdout: BoundedCollector {
      id: repolistOut
      onFinished: {
        root.repoList = Model.parseRepoList(repolistOut.text)
        root.repoListLoaded = true
      }
    }
    stderr: BoundedCollector { id: repolistErr }
    onStarted: { repolistOut.reset(); repolistErr.reset() }
    onExited: function() {
      repolistOut.done = true
      repolistOut.finished()
    }
  }

  Process {
    id: infoProc
    stdout: BoundedCollector { id: infoOut }
    stderr: BoundedCollector { id: infoErr }
    onStarted: { infoOut.reset(); infoErr.reset() }
    onExited: function() {
      infoOut.done = true
      var parsed = Model.parseInfo(infoOut.text)
      root.infoPairs = parsed.pairs
      root.infoMap = parsed.map
      root.loadingInfo = false
    }
  }

  Process {
    id: installedProc
    stdout: BoundedCollector { id: installedOut }
    stderr: BoundedCollector { id: installedErr }
    onStarted: { installedOut.reset(); installedErr.reset() }
    onExited: function() {
      installedOut.done = true
      var res = Model.parseInstalled(installedOut.text)
      root.nativePkgs = res.native
      root.cacheInfo = res.cacheInfo
      root.loadingInstalled = false
      var rs = root.searchResults.slice()
      for (var i = 0; i < rs.length; i++)
        rs[i].installed = root.isInstalled(rs[i].name) === "installed"
      root.searchResults = rs
    }
  }

  Timer {
    interval: Math.max(300, root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: searchDebounce
    interval: 250
    onTriggered: root.doSearch()
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
      color: root.urgentC
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.totalUpdates > 99 ? "99+" : root.totalUpdates
        color: root.bar ? root.bar.background : ShellColor.background
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

      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "1") root.tab = "updates"
        else if (t === "2") root.tab = "search"
        else if (t === "3") root.tab = "installed"
        else if (t === "4") root.tab = "cache"
        else if (t === "u" || t === "U") root.upgradeAll()
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
            textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              text: "Package Manager"
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
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
              tooltipText: "Sync package databases (opens a terminal)"
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
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
          width: parent.width
          spacing: Style.space(6)

          IudcTab { label: "Updates (" + root.totalUpdates + ")"; key: "updates" }
          IudcTab { label: "Search"; key: "search" }
          IudcTab { label: "Installed"; key: "installed" }
          IudcTab { label: "Cache"; key: "cache" }
        }

        PanelSeparator {
          foreground: root.fg
        }

        // ---------- UPDATES ----------
        Column {
          visible: root.tab === "updates"
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
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
                ? "Runs omarchy update in a terminal"
                : "Check again"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.checking
              onClicked: root.totalUpdates > 0 ? root.upgradeAll() : root.refresh()
            }
          }

          Repeater {
            model: root.updates
            delegate: UpdateRow {}
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.checking && root.totalUpdates === 0
            text: "\uf058  No pending updates"
            color: root.okColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- SEARCH ----------
        Column {
          visible: root.tab === "search"
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "Search repositories\u2026"
              foreground: root.fg
              accent: root.accentC
              font.family: root.bar.fontFamily
              verticalPadding: Style.space(5)
              onAccepted: root.doSearch()
              onTextChanged: {
                var t = searchField.text.trim()
                if (t !== "") {
                  searchDebounce.restart()
                } else {
                  searchDebounce.stop()
                  root.searchRunId++
                  if (searchProc.running) searchProc.running = false
                  root.searchResults = []
                  root.lastCompletedQuery = ""
                  root.searching = false
                }
              }
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
            textFormat: Text.PlainText
            visible: searchField.text.trim() === "" && root.repoList.length > 0
            text: root.repoList.length + " official packages (a\u2013z)"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: searchField.text.trim() === "" && root.repoList.length === 0
            text: repolistProc.running ? "Loading\u2026" : "No official packages"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: root.searchResults.length > 0 && searchField.text.trim() !== ""
            text: root.searchResults.length + " result(s)"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: root.searchResults.length === 0 && !root.searching && searchField.text.trim() !== ""
            text: "No results"
            color: root.dimColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Virtualized: only rows near the viewport are instantiated, so the
          // full index (~13k) or an unrestricted result set never blocks the
          // UI thread. Short lists grow to fit; long ones scroll in place.
          ListView {
            id: searchList
            width: parent.width
            height: Math.min(contentHeight, Style.space(420))
            interactive: contentHeight > height
            clip: true
            spacing: Style.space(8)
            boundsBehavior: Flickable.StopAtBounds
            model: searchField.text.trim() === "" ? root.repoList : root.searchResults
            delegate: SearchRow {}
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }
        }

        // ---------- INSTALLED ----------
        Column {
          visible: root.tab === "installed"
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: root.loadingInstalled
              ? "Loading\u2026"
              : root.installedCount + " packages"
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

          ListView {
            width: parent.width
            height: Math.min(contentHeight, Style.space(420))
            interactive: contentHeight > height
            clip: true
            spacing: Style.space(8)
            boundsBehavior: Flickable.StopAtBounds
            model: {
              var all = root.nativePkgs
              var f = installedFilter.text.trim()
              if (f !== "") all = all.filter(function(p) { return p.name.indexOf(f) >= 0 })
              return all
            }
            delegate: InstalledRow {}
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }
        }

        // ---------- CACHE ----------
        Column {
          visible: root.tab === "cache"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: "Cache maintenance"
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
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
              tooltipText: "paccache -rk " + root.cacheKeepVersions + " (opens a terminal)"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              accent: root.accentC
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.cleanPaccache()
            }
          }
        }

        // ---------- DETAIL ----------
        Column {
          visible: root.selectedPkg !== ""
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
                textFormat: Text.PlainText
                text: "\uf105"
                color: root.accentC
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
                tooltipText: "Reinstall (opens a terminal)"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                onClicked: root.installPkg(root.selectedPkg)
              }
              Button {
                visible: root.selectedState === "remote"
                iconText: "\uf019"
                tooltipText: "Install (opens a terminal)"
                foreground: root.fg
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                onClicked: root.installPkg(root.selectedPkg)
              }
              Button {
                iconText: "\uf1f8"
                tooltipText: "Remove (pacman -Rns, opens a terminal)"
                foreground: root.urgentC
                accent: root.accentC
                fontFamily: root.bar.fontFamily
                enabled: root.selectedState === "installed"
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
            textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: modelData.key
                color: root.dimColor
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.preferredWidth: Style.space(96)
              }
              Text {
                textFormat: Text.PlainText
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

        // ---------- Footer hints ----------
        Text {
          textFormat: Text.PlainText
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

  // One pending-update row: glyph + name + old -> new.
  component UpdateRow: MouseArea {
    id: urow
    required property var modelData
    required property int index
    width: parent ? parent.width : 0
    implicitHeight: urowBody.implicitHeight + Style.space(6)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.showDetail(urow.modelData.name, root.isInstalled(urow.modelData.name))

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
        textFormat: Text.PlainText
        text: "\uf03d3"
        color: root.accentC
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        text: urow.modelData.name
        color: root.fg
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        Layout.preferredWidth: Style.space(150)
      }
      Text {
        textFormat: Text.PlainText
        text: urow.modelData.old + " \u2192 " + urow.modelData.new
        color: root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
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
          textFormat: Text.PlainText
          text: srow.modelData.name
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        Text {
          textFormat: Text.PlainText
          visible: srow.modelData.version !== ""
          text: srow.modelData.version
          color: root.dimColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText
          text: srow.modelData.repo
          color: root.dimColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption * 0.9
        }
      }
      Text {
        textFormat: Text.PlainText
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
      onClicked: {
        if (srow.modelData.installed) root.removePkg(srow.modelData.name)
        else root.installPkg(srow.modelData.name)
      }
    }
  }

  // One installed-package row: name + version.
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
        textFormat: Text.PlainText
        text: irow.modelData.name
        color: root.fg
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        textFormat: Text.PlainText
        text: irow.modelData.version
        color: root.dimColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Line accumulator with a hard ceiling so hostile command output can never
  // balloon shell memory; past maxChars the remainder is dropped and marked.
  // `done` marks process exit — chunks arriving afterwards re-emit finished()
  // so consumers always see the complete (possibly truncated) text.
  // reset() must run before each launch (onStarted) because Quickshell reuses
  // the same parser instance across runs of one Process.
  component BoundedCollector: SplitParser {
    id: bcol
    property int maxChars: 8 * 1024 * 1024
    property bool done: false
    property string text: ""
    property bool truncated: false
    signal finished()
    function reset() {
      text = ""
      truncated = false
      done = false
    }
    onRead: function(data) {
      if (!bcol.truncated && bcol.text.length < bcol.maxChars) {
        var room = bcol.maxChars - bcol.text.length
        var piece = data.length > room ? data.slice(0, room) : data
        bcol.text += piece + "\n"
        if (piece.length < data.length || bcol.text.length >= bcol.maxChars)
          bcol.truncated = true
      }
      if (bcol.done) bcol.finished()
    }
  }
}
