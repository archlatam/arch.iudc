// arch.iudc — output parsers for pacman command output.
.pragma library

// iudc-check output -> [{name,old,new}]
function parseCheck(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].split("\t")
    if (p.length >= 3 && p[0] !== "")
      out.push({ name: p[0], old: p[1], new: p[2] })
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
    description: (descLines || []).join(" ").trim()
  }
}

// iudc-search output -> [{repo,name,version,installed,description}]
function parseSearch(text) {
  var out = []
  var cur = null
  var desc = []
  var flush = function() {
    if (!cur) return
    cur.description = desc.join(" ").trim()
    out.push(cur)
    cur = null
    desc = []
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    if (line.charAt(0) === " " || line.charAt(0) === "\t") {
      if (cur) desc.push(line.trim())
      continue
    }
    var entry = _searchEntry(line)
    if (!entry) continue
    flush()
    cur = entry
  }
  flush()
  return out
}

// Ranked search results: relevance (exact name > name prefix > name contains >
// description only), alphabetical.
function rankSearch(entries, query) {
  var q = String(query || "").toLowerCase()
  var score = function(e) {
    var n = e.name.toLowerCase()
    if (n === q) return 0
    if (n.indexOf(q) === 0) return 1
    if (n.indexOf(q) >= 0) return 2
    return 3
  }
  var cmp = function(a, b) {
    var sa = score(a)
    var sb = score(b)
    if (sa !== sb) return sa - sb
    // Byte-wise compare: much cheaper than localeCompare on big result sets
    // and equivalent for package names (ASCII).
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  }
  return entries.sort(cmp)
}

// iudc-repolist output -> [{repo,name,version,installed,description}] sorted by name
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
      description: ""
    })
  }
  // Byte-wise sort: localeCompare costs several times more across ~13k rows.
  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// iudc-installed output -> {native:[], cacheInfo:[]}
function parseInstalled(text) {
  var res = { native: [], cacheInfo: [] }
  var section = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "---IUDC-NATIVE---" || line === "---IUDC-CACHE---") {
      section = line
      continue
    }
    if (line === "") continue
    if (section === "---IUDC-NATIVE---") {
      var sp = line.lastIndexOf(" ")
      if (sp > 0)
        res.native.push({ name: line.substring(0, sp), version: line.substring(sp + 1) })
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
