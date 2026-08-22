// arch.iudc — output parsers for pacman/yay commands.
.pragma library

// Strip ANSI escape sequences and normalize \r progress overwrites.
function clean(s) {
  var t = String(s || "")
  t = t.replace(/\x1B\[[0-9;?]*[a-zA-Z]/g, "")
  t = t.replace(/\x1B\][^\x07]*(\x07|\x1B\\)/g, "")
  // Progress bars reuse one line with \r — keep only the last frame.
  if (t.indexOf("\r") >= 0) {
    var lines = t.split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("\r") >= 0)
        lines[i] = lines[i].split("\r").pop()
    }
    t = lines.join("\n")
  }
  return t.replace(/\n{3,}/g, "\n\n").replace(/[ \t]+$/gm, "").trim()
}

// iudc-check.sh output -> [{source,name,old,new}]
function parseCheck(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].split("\t")
    if (p.length >= 4 && (p[0] === "repo" || p[0] === "aur") && p[1] !== "")
      out.push({ source: p[0], name: p[1], old: p[2], new: p[3] })
  }
  return out
}

function _searchEntry(header, descLines) {
  var slash = header.indexOf("/")
  if (slash <= 0) return null
  var rest = header.substring(slash + 1).trim()
  var sp = rest.search(/\s/)
  var name = sp < 0 ? rest : rest.substring(0, sp)
  var tail = sp < 0 ? "" : rest.substring(sp + 1)
  if (name === "") return null
  return {
    repo: header.substring(0, slash),
    name: name,
    version: tail.split(" ")[0] || "",
    meta: tail.trim(),
    installed: /\[installed/i.test(tail),
    aur: header.indexOf("aur/") === 0,
    description: (descLines || []).join(" ").trim()
  }
}

// iudc-search.sh output -> {repo:[], aur:[]}
function parseSearch(text) {
  var res = { repo: [], aur: [] }
  var section = ""
  var cur = null
  var desc = []
  var flush = function() {
    if (!cur) return
    cur.description = desc.join(" ").trim()
    ;(cur.aur ? res.aur : res.repo).push(cur)
    cur = null
    desc = []
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "---IUDC-REPO---" || line === "---IUDC-AUR---") {
      flush()
      section = line
      continue
    }
    if (line === "") continue
    if (line.charAt(0) === " " || line.charAt(0) === "\t") {
      if (cur) desc.push(line.trim())
      continue
    }
    var entry = _searchEntry(line.replace(/^(core|extra|multilib|aur|chaotic-aur)\//, function(m){ return m }))
    if (!entry) continue
    flush()
    cur = entry
  }
  flush()
  return res
}

// Ranked merge for search results: official repos first, then relevance
// (exact name > name prefix > name contains > description only), alphabetical.
function rankSearch(repoArr, aurArr, query) {
  var q = String(query || "").toLowerCase()
  var score = function(e) {
    var n = e.name.toLowerCase()
    if (n === q) return 0
    if (n.indexOf(q) === 0) return 1
    if (n.indexOf(q) >= 0) return 2
    return 3
  }
  var cmp = function(a, b) {
    if (a.aur !== b.aur) return a.aur ? 1 : -1
    var sa = score(a)
    var sb = score(b)
    if (sa !== sb) return sa - sb
    return a.name.localeCompare(b.name)
  }
  return repoArr.concat(aurArr).sort(cmp)
}

// iudc-repolist.sh output -> [{repo,name,version,installed,aur,description}] sorted by name
function parseRepoList(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var sp1 = line.indexOf(" ")
    if (sp1 <= 0) continue
    var sp2 = line.indexOf(" ", sp1 + 1)
    if (sp2 < 0) continue
    var sp3 = line.indexOf(" ", sp2 + 1)
    out.push({
      repo: line.substring(0, sp1),
      name: line.substring(sp1 + 1, sp2),
      version: sp3 < 0 ? line.substring(sp2 + 1) : line.substring(sp2 + 1, sp3),
      installed: sp3 >= 0 && /\[\s*installed/i.test(line.substring(sp3)),
      aur: false,
      description: ""
    })
  }
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return out
}

// iudc-installed.sh output -> {native:[], foreign:[], cacheInfo:[]}
function parseInstalled(text) {
  var res = { native: [], foreign: [], cacheInfo: [] }
  var section = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "---IUDC-NATIVE---" || line === "---IUDC-FOREIGN---" || line === "---IUDC-CACHE---") {
      section = line
      continue
    }
    if (line === "") continue
    if (section === "---IUDC-NATIVE---" || section === "---IUDC-FOREIGN---") {
      var sp = line.lastIndexOf(" ")
      if (sp > 0)
        (section === "---IUDC-NATIVE---" ? res.native : res.foreign)
          .push({ name: line.substring(0, sp), version: line.substring(sp + 1), aur: section === "---IUDC-FOREIGN---" })
    } else if (section === "---IUDC-CACHE---") {
      res.cacheInfo.push(line.trim())
    }
  }
  return res
}

// pacman -Qi/-Si output -> ordered [{key,value}] plus map
function parseInfo(text) {
  var pairs = []
  var map = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "" || line.charAt(0) === " ") {
      // Continuation of a multi-line value (e.g. Depends On).
      if (pairs.length && line.trim() !== "")
        pairs[pairs.length - 1].value += " " + line.trim()
      continue
    }
    var c = line.indexOf(":")
    if (c <= 0) continue
    var k = line.substring(0, c).trim()
    var v = line.substring(c + 1).trim()
    if (v === "") v = pairs.length && k === pairs[pairs.length - 1].key ? pairs[pairs.length - 1].value : ""
    if (map[k] === undefined) {
      map[k] = v
      pairs.push({ key: k, value: v })
    } else if (k === "Depends On" || k === "Required By") {
      map[k] += " " + v
      pairs[pairs.length - 1].value += " " + v
    }
  }
  return { pairs: pairs, map: map }
}
