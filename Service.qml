import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Reads snapshot state on a timer and exposes it as properties. Every action it
// can take is either read-only or handed to a visible terminal — nothing
// privileged happens silently behind the bar.
Item {
  id: root

  property var settings: ({})

  property var status: Model.emptyStatus()
  property var healthInfo: ({ level: "ok", headline: "Reading snapshots…", issues: [] })
  property bool refreshing: false
  property bool everLoaded: false
  property string lastError: ""
  property string actionStatus: ""

  readonly property string level: healthInfo.level
  readonly property string headline: healthInfo.headline
  readonly property var issues: healthInfo.issues
  readonly property var configs: status.configs
  readonly property int totalSnapshots: Model.totalSnapshots(status)
  readonly property bool snapperMissing: everLoaded && !status.ok
  readonly property bool busy: statusProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)
  readonly property int snapshotsPerConfig: intSetting("snapshotsPerConfig", 5, 1, 50)
  readonly property bool showCount: setting("showCount", true) === true
  readonly property var navItems: Model.navItems(status, snapshotsPerConfig)

  readonly property string currentUser: status.user || Quickshell.env("USER")
  // Blank until the first read lands, so the bar does not flash a zero.
  readonly property string barCountText: everLoaded && status.ok ? String(totalSnapshots) : ""

  // A plugin cannot lean on OMARCHY_PATH the way a bundled one does, so resolve
  // the helper next to this QML file instead.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/bin/omarchy-snapshots-status"

  property string _statusOutput: ""

  signal actionLaunched(string label)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    refreshing = true
    statusProcess.command = ["bash", helperPath]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    status = parsed
    healthInfo = Model.health(parsed)
    everLoaded = true
    lastError = parsed.ok ? "" : (parsed.error || "")
  }

  function configByName(name) {
    for (var i = 0; i < configs.length; i++) {
      if (configs[i].name === name) return configs[i]
    }
    return null
  }

  function unreadableConfigs() {
    return configs.filter(function(c) { return !c.readable })
  }

  // ------------------------------------------------------------- actions

  // Snapshot creation and restore both need root, and restore rewrites what the
  // machine boots into. Both go to a real terminal so the sudo prompt, the
  // output, and any refusal are all visible — a bar popup is the wrong place to
  // hide either one.
  function runInTerminal(command, label) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", command])
    actionStatus = label
    actionStatusTimer.restart()
    actionLaunched(label)
    settleTimer.restart()
  }

  function createSnapshot() {
    runInTerminal("omarchy-snapshot create", "Creating snapshot in a terminal…")
  }

  function restore() {
    runInTerminal("omarchy-snapshot restore", "Opened the restore tool…")
  }

  // snapper's own mechanism for letting a user read a config: add them to
  // ALLOW_USERS and let SYNC_ACL put an ACL on the .snapshots directory. Once
  // it is set, this widget needs no privilege at all to read that config.
  function grantReadAccess(configName) {
    var user = status.user || Quickshell.env("USER")
    if (!configName || !user) return
    runInTerminal("sudo snapper -c " + configName + " set-config ALLOW_USERS=" + user + " SYNC_ACL=yes",
                  "Granting read access to " + configName + "…")
  }

  function grantCommandFor(configName) {
    var user = status.user || Quickshell.env("USER")
    return "sudo snapper -c " + configName + " set-config ALLOW_USERS=" + user + " SYNC_ACL=yes"
  }

  // Deleting needs no privilege for a config this user is allowed to work with,
  // so the common case runs in place and reports failures in the panel. Anything
  // else falls back to the same visible terminal as create and restore.
  function canModify(configName) {
    return Model.allowsUser(configByName(configName), currentUser)
  }

  function deleteSnapshot(configName, number) {
    if (!configName || !(number > 0) || deleteProcess.running) return
    if (!canModify(configName)) {
      runInTerminal("sudo snapper -c " + configName + " delete " + number,
                    "Deleting snapshot " + number + " in a terminal…")
      return
    }
    actionStatus = "Deleting snapshot " + number + "…"
    deleteProcess.command = ["snapper", "-c", configName, "delete", String(number)]
    deleteProcess.running = true
  }

  function browse(row) {
    if (!row || !row.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", row.path])
    actionStatus = "Opened snapshot " + row.number
    actionStatusTimer.restart()
  }

  function copyPath(row) {
    if (!row || !row.path) return
    Quickshell.execDetached(["wl-copy", "--", row.path])
    actionStatus = "Copied " + row.path
    actionStatusTimer.restart()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A snapshot created or restored from the terminal lands seconds after the
  // command is handed over, so re-read a few times rather than waiting out the
  // whole refresh interval.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 4000
    repeat: true
    running: false
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 5) running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: deleteProcess
    running: false
    command: []
    stdout: StdioCollector { id: deleteStdout; waitForEnd: true }
    stderr: StdioCollector { id: deleteStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.actionStatus = "Snapshot deleted"
      } else {
        // snapper refuses to delete the active or default snapshot, and says so
        // clearly enough to show verbatim.
        var why = String(deleteStderr.text || deleteStdout.text || "").replace(/\s+/g, " ").trim()
        root.actionStatus = why || "Could not delete that snapshot"
      }
      actionStatusTimer.restart()
      root.refresh()
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var out = String(statusStdout.text || root._statusOutput || "")
      if (out.trim() !== "") {
        root.applyStatus(out)
        return
      }
      // The helper reports its own failures as JSON, so an empty stdout means it
      // could not run at all.
      root.everLoaded = true
      root.lastError = String(statusStderr.text || "").trim() || ("Could not run " + root.helperPath)
      root.healthInfo = { level: "critical", headline: root.lastError, issues: [{ level: "critical", text: root.lastError }] }
    }
  }
}
