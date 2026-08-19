// Parsing, formatting, and health policy for the snapshots panel. The status
// script is a pure reporter; every judgement about whether a machine is actually
// recoverable is made here, in one place, on plain data.

// A timeline config takes a snapshot every hour. Warn only well past that, so a
// laptop that spent the morning suspended settles on its own instead of showing
// a scare it will clear within the hour.
var STALE_WARN_SEC = 6 * 3600

function emptyStatus() {
  return {
    ok: false,
    error: "",
    now: 0,
    user: "",
    configs: [],
    units: {},
    limine: { confPresent: false, bootReadable: false, restoreMethod: "", limitUsagePercent: 0 }
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return emptyStatus()
    var status = emptyStatus()
    status.ok = parsed.ok === true
    status.error = String(parsed.error || "")
    status.now = Number(parsed.now || 0)
    status.user = String(parsed.user || "")
    status.configs = Array.isArray(parsed.configs) ? parsed.configs : []
    status.units = parsed.units && typeof parsed.units === "object" ? parsed.units : {}
    if (parsed.limine && typeof parsed.limine === "object") status.limine = parsed.limine
    return status
  } catch (e) {
    var broken = emptyStatus()
    broken.error = "Could not parse snapshot status"
    return broken
  }
}

function unit(status, name) {
  var u = status && status.units ? status.units[name] : null
  return u ? u : { unit: name, present: false, active: "inactive", enabled: "disabled", result: "", nextElapseUsec: 0 }
}

function unitRunning(status, name) {
  return unit(status, name).active === "active"
}

// ------------------------------------------------------------------ health

// Returns { level, headline, issues }. `level` drives the bar icon colour, so it
// stays quiet unless something is genuinely broken: "ok" means snapshots are
// landing and a rollback is reachable.
function health(status) {
  var issues = []

  if (!status.ok) {
    var reason = status.error || "Snapshots unavailable"
    return {
      level: "critical",
      headline: reason,
      issues: [{ level: "critical", text: reason }]
    }
  }

  var configs = status.configs || []
  var readable = configs.filter(function(c) { return c.readable })
  var unreadable = configs.filter(function(c) { return !c.readable })

  // The boot menu is the only place a snapper rollback gets chosen on Omarchy.
  // Snapshots that exist but cannot be booted into are not a recovery plan.
  var sync = unit(status, "limine-snapper-sync.service")
  if (sync.present && sync.active !== "active") {
    issues.push({ level: "critical", text: "limine-snapper-sync is not running — new snapshots will not reach the boot menu" })
  }

  var timeline = unit(status, "snapper-timeline.timer")
  var wantsTimeline = readable.some(function(c) { return c.config && c.config.timelineCreate })
  if (wantsTimeline && timeline.present && timeline.active !== "active") {
    issues.push({ level: "critical", text: "snapper-timeline.timer is not running — no new timeline snapshots" })
  }

  var cleanup = unit(status, "snapper-cleanup.timer")
  var wantsCleanup = readable.some(function(c) { return c.config && c.config.timelineCleanup })
  if (wantsCleanup && cleanup.present && cleanup.active !== "active") {
    issues.push({ level: "warn", text: "snapper-cleanup.timer is not running — old snapshots will pile up" })
  }

  // A timeline config whose newest snapshot is hours old means the timer is
  // firing into something that fails, which the unit state alone will not show.
  readable.forEach(function(c) {
    if (!c.config || !c.config.timelineCreate) return
    var newest = newestSnapshot(c)
    if (!newest) {
      issues.push({ level: "warn", text: c.name + " has no snapshots yet" })
      return
    }
    var age = status.now - newest.epoch
    if (age > STALE_WARN_SEC) {
      issues.push({ level: "warn", text: c.name + " has taken nothing since " + relativeAge(age) })
    }
  })

  // limine-snapper-sync stops adding boot entries once the filesystem crosses
  // its own usage ceiling, so disk pressure is a recovery problem, not just a
  // housekeeping one.
  var ceiling = Number(status.limine.limitUsagePercent || 0)
  if (ceiling > 0) {
    configs.forEach(function(c) {
      var used = Number(c.usedPercent || 0)
      if (used >= ceiling) {
        issues.push({ level: "warn", text: c.subvolume + " is " + used + "% full — past the " + ceiling + "% boot-entry ceiling" })
      }
    })
  }

  // A config without this user in its ALLOW_USERS is the stock Omarchy state,
  // not a fault: snapper only grants read access when asked. Report it as
  // information the panel can act on, and keep it out of the bar's colour — a
  // widget that ships permanently yellow teaches people to ignore it. Losing
  // sight of *every* config is different, and does warrant a warning.
  unreadable.forEach(function(c) {
    issues.push({
      level: readable.length === 0 ? "warn" : "info",
      text: c.name + " (" + c.subvolume + ") needs read access — " + (c.error || "no permissions"),
      config: c.name
    })
  })

  var level = "ok"
  if (issues.some(function(i) { return i.level === "critical" })) level = "critical"
  else if (issues.some(function(i) { return i.level === "warn" })) level = "warn"

  return { level: level, headline: headlineFor(status, level, issues), issues: issues }
}

function headlineFor(status, level, issues) {
  // Lead with the worst thing, not the first thing: info-level notes are
  // appended last but must never outrank a failure in the headline.
  if (level !== "ok") {
    var worst = issues.filter(function(i) { return i.level === level })
    if (worst.length > 0) return worst[0].text
    return issues.length > 0 ? issues[0].text : "Needs attention"
  }

  var total = totalSnapshots(status)
  var newest = newestAcrossConfigs(status)
  if (total === 0) return "No snapshots yet"
  var when = newest ? relativeAge(status.now - newest.epoch) : "unknown"
  return total + (total === 1 ? " snapshot" : " snapshots") + " · newest " + when
}

// ------------------------------------------------------------- aggregation

function newestSnapshot(config) {
  var snaps = config && config.snapshots ? config.snapshots : []
  if (snaps.length === 0) return null
  var best = null
  for (var i = 0; i < snaps.length; i++) {
    if (!best || Number(snaps[i].epoch) > Number(best.epoch)) best = snaps[i]
  }
  return best
}

function newestAcrossConfigs(status) {
  var best = null
  ;(status.configs || []).forEach(function(c) {
    var n = newestSnapshot(c)
    if (n && (!best || Number(n.epoch) > Number(best.epoch))) best = n
  })
  return best
}

function totalSnapshots(status) {
  return (status.configs || []).reduce(function(sum, c) { return sum + Number(c.count || 0) }, 0)
}

// One flat list of everything the cursor can land on, built in the same order
// the panel draws it: each config's snapshots (newest first) or, when a config
// cannot be read, the single row that offers to fix that; then the two actions.
// Every entry carries its own navIndex, so the view never has to recompute
// offsets while grouping rows back under their config headers.
function navItems(status, perConfigLimit) {
  var items = []

  ;(status.configs || []).forEach(function(c) {
    if (!c.readable) {
      items.push({ kind: "grant", config: c.name, subvolume: c.subvolume, error: c.error || "" })
      return
    }
    var snaps = (c.snapshots || []).slice().sort(function(a, b) { return Number(b.epoch) - Number(a.epoch) })
    var limit = perConfigLimit > 0 ? Math.min(perConfigLimit, snaps.length) : snaps.length
    for (var i = 0; i < limit; i++) {
      items.push({
        kind: "snapshot",
        config: c.name,
        subvolume: c.subvolume,
        number: snaps[i].number,
        epoch: Number(snaps[i].epoch),
        type: snaps[i].type,
        description: snaps[i].description,
        cleanup: snaps[i].cleanup,
        usedSpace: snaps[i].usedSpace,
        path: snapshotPath(c, snaps[i])
      })
    }
  })

  items.push({ kind: "create", config: "" })
  items.push({ kind: "restore", config: "" })

  for (var n = 0; n < items.length; n++) items[n].navIndex = n
  return items
}

// The rows belonging to one config, in draw order, with their navIndex intact.
function itemsForConfig(items, configName) {
  return (items || []).filter(function(i) {
    return i.config === configName && (i.kind === "snapshot" || i.kind === "grant")
  })
}

function itemOfKind(items, kind) {
  var found = (items || []).filter(function(i) { return i.kind === kind })
  return found.length > 0 ? found[0] : null
}

// How many snapshots a config has beyond the ones the panel is showing.
function hiddenCount(config, perConfigLimit) {
  if (!config || !config.readable) return 0
  return Math.max(0, Number(config.count || 0) - Math.max(0, perConfigLimit))
}

// Where snapper mounts a snapshot's read-only tree. With SYNC_ACL on the config
// this is browsable without privilege, which is what makes "recover one file"
// possible from the panel at all.
function snapshotPath(config, snapshot) {
  var base = String(config.subvolume || "")
  if (base === "/") return "/.snapshots/" + snapshot.number + "/snapshot"
  return base + "/.snapshots/" + snapshot.number + "/snapshot"
}

// snapper lets the users in a config's ALLOW_USERS create and delete its
// snapshots, not just read them — verified by asking snapper to delete a
// snapshot number that does not exist: an allowed user is told the snapshot was
// not found, everyone else is told "No permissions." So the same list that
// makes a config readable also decides whether deleting needs sudo.
function allowsUser(config, user) {
  if (!config || !config.config || !user) return false
  var allowed = String(config.config.allowUsers || "").split(/[\s,]+/)
  for (var i = 0; i < allowed.length; i++) {
    if (allowed[i] === user) return true
  }
  return false
}

function configMeta(config, now) {
  // An unreadable config gets its own explanatory row right below this one, so
  // saying "not readable" here only says it twice.
  if (!config.readable) return ""
  var parts = []
  parts.push(config.count + (config.count === 1 ? " snapshot" : " snapshots"))
  var newest = newestSnapshot(config)
  if (newest) parts.push("newest " + relativeAge(now - newest.epoch))
  return parts.join(" · ")
}

function configPolicy(config) {
  if (!config.readable || !config.config) return ""
  var c = config.config
  if (!c.timelineCreate) return "manual snapshots only · keeps " + c.numberLimit
  return "hourly · keeps " + c.hourly + "h / " + c.daily + "d"
}

// -------------------------------------------------------------- formatting

function relativeAge(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return "just now"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h ago"
  var d = Math.floor(h / 24)
  if (d < 30) return d + "d ago"
  var mo = Math.floor(d / 30)
  return mo + "mo ago"
}

// "2026-08-19 16:00:01" -> "Wed 19 Aug, 16:00". Built from the epoch the status
// script resolved, never by parsing the string in JS: the space-separated form
// is not something every JS engine reads the same way.
function clockText(epoch) {
  var e = Number(epoch || 0)
  if (e <= 0) return ""
  var d = new Date(e * 1000)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var hh = ("0" + d.getHours()).slice(-2)
  var mm = ("0" + d.getMinutes()).slice(-2)
  return days[d.getDay()] + " " + d.getDate() + " " + months[d.getMonth()] + ", " + hh + ":" + mm
}

function formatBytes(bytes) {
  var n = Number(bytes || 0)
  if (!isFinite(n) || n <= 0) return ""
  var units = ["B", "K", "M", "G", "T"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)) + units[i]
}

function usageText(config) {
  var pct = Number(config.usedPercent || 0)
  var avail = formatBytes(config.fsAvail)
  if (pct <= 0) return ""
  return pct + "% used" + (avail ? " · " + avail + " free" : "")
}

// The label under a snapshot row: what made it, and what will clean it up.
function snapshotDetail(row) {
  var parts = []
  if (row.description) parts.push(row.description)
  else parts.push(row.type)
  if (row.cleanup) parts.push(row.cleanup)
  var size = formatBytes(row.usedSpace)
  if (size) parts.push(size)
  return parts.join(" · ")
}
