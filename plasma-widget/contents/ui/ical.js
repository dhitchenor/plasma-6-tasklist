.pragma library

// Edits are applied to the original lines of the resource rather than
// regenerating it, so properties this widget doesn't understand (DUE,
// PRIORITY, CATEGORIES, X-* from other clients...) survive a round-trip.

function unfold(text) {
    return text.replace(/\r?\n[ \t]/g, "").split(/\r?\n/)
}

function utf8Length(ch) {
    var c = ch.charCodeAt(0)
    if (c < 0x80) return 1
    if (c < 0x800) return 2
    if (c >= 0xD800 && c <= 0xDBFF) return 4
    return 3
}

// RFC 5545 limits lines to 75 octets, not characters.
function fold(line) {
    var out = []
    var current = ""
    var bytes = 0
    var limit = 75
    for (var i = 0; i < line.length; i++) {
        var ch = line[i]
        var code = line.charCodeAt(i)
        if (code >= 0xD800 && code <= 0xDBFF && i + 1 < line.length) {
            ch += line[++i]
        }
        var len = utf8Length(ch)
        if (bytes + len > limit) {
            out.push(current)
            current = " "
            bytes = 1
        }
        current += ch
        bytes += len
    }
    out.push(current)
    return out.join("\r\n")
}

function serialize(lines) {
    var out = []
    for (var i = 0; i < lines.length; i++) {
        if (lines[i] !== "") out.push(fold(lines[i]))
    }
    return out.join("\r\n") + "\r\n"
}

// The name/value separator is the first colon outside a quoted parameter
// value, e.g. ATTENDEE;CN="Smith: John":mailto:... has two colons before it.
function splitLine(line) {
    var inQuotes = false
    for (var i = 0; i < line.length; i++) {
        var ch = line[i]
        if (ch === '"') inQuotes = !inQuotes
        else if (ch === ":" && !inQuotes) {
            var head = line.substring(0, i)
            var semi = head.indexOf(";")
            return {
                name: (semi === -1 ? head : head.substring(0, semi)).toUpperCase(),
                value: line.substring(i + 1)
            }
        }
    }
    return { name: line.toUpperCase(), value: "" }
}

function unescapeText(v) {
    return v.replace(/\\([\\;,nN])/g, function(m, c) {
        return (c === "n" || c === "N") ? "\n" : c
    })
}

function escapeText(v) {
    return v.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n")
}

function formatDateTime(date) {
    function pad(n) { return (n < 10 ? "0" : "") + n }
    return date.getUTCFullYear() + pad(date.getUTCMonth() + 1) + pad(date.getUTCDate()) + "T"
        + pad(date.getUTCHours()) + pad(date.getUTCMinutes()) + pad(date.getUTCSeconds()) + "Z"
}

// Floating and TZID-qualified times are read as local time; for sorting and
// "Today/Yesterday" grouping that is close enough.
function parseDateTime(value) {
    var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(value)
    if (!m) return null
    var y = +m[1], mo = +m[2] - 1, d = +m[3]
    var h = +(m[4] || 0), mi = +(m[5] || 0), s = +(m[6] || 0)
    return m[7] ? new Date(Date.UTC(y, mo, d, h, mi, s)) : new Date(y, mo, d, h, mi, s)
}

// Recurring tasks store overrides as extra VTODOs carrying RECURRENCE-ID;
// the one without it is the master.
function findTodo(lines) {
    var start = -1
    var candidate = null
    for (var i = 0; i < lines.length; i++) {
        var upper = lines[i].toUpperCase()
        if (upper === "BEGIN:VTODO") {
            start = i
        } else if (upper === "END:VTODO" && start !== -1) {
            var block = { start: start, end: i }
            if (!hasProp(lines, block, "RECURRENCE-ID")) return block
            if (!candidate) candidate = block
            start = -1
        }
    }
    return candidate
}

function findPropIndex(lines, block, name) {
    var depth = 0
    for (var i = block.start + 1; i < block.end; i++) {
        var p = splitLine(lines[i])
        if (p.name === "BEGIN") depth++
        else if (p.name === "END") depth--
        else if (depth === 0 && p.name === name) return i
    }
    return -1
}

function hasProp(lines, block, name) {
    return findPropIndex(lines, block, name) !== -1
}

function getProp(lines, block, name) {
    var i = findPropIndex(lines, block, name)
    return i === -1 ? null : splitLine(lines[i]).value
}

function setProp(lines, block, name, value) {
    var i = findPropIndex(lines, block, name)
    if (i !== -1) {
        lines[i] = name + ":" + value
    } else {
        lines.splice(block.end, 0, name + ":" + value)
        block.end++
    }
}

function removeProp(lines, block, name) {
    var i
    while ((i = findPropIndex(lines, block, name)) !== -1) {
        lines.splice(i, 1)
        block.end--
    }
}

// Returns null when the resource has no VTODO (e.g. an event in a mixed
// calendar), so callers can remember it without showing it.
function parseTodo(text) {
    var lines = unfold(text)
    var block = findTodo(lines)
    if (!block) return null

    var status = (getProp(lines, block, "STATUS") || "").toUpperCase()
    var created = parseDateTime(getProp(lines, block, "CREATED") || "")
        || parseDateTime(getProp(lines, block, "DTSTAMP") || "")
        || new Date()

    var due = parseDateTime(getProp(lines, block, "DUE") || "")
    // RFC 5545 §3.8.1.9: 1 is highest, 9 lowest, 0 or absent means undefined
    var priority = parseInt(getProp(lines, block, "PRIORITY") || "0", 10)

    return {
        uid: getProp(lines, block, "UID"),
        title: unescapeText(getProp(lines, block, "SUMMARY") || ""),
        completed: status === "COMPLETED" || (status === "" && hasProp(lines, block, "COMPLETED")),
        createdAt: created.toISOString(),
        due: due ? due.toISOString() : null,
        priority: priority >= 1 && priority <= 9 ? priority : 0
    }
}

function touch(lines, block, now) {
    setProp(lines, block, "DTSTAMP", formatDateTime(now))
    setProp(lines, block, "LAST-MODIFIED", formatDateTime(now))
    var seq = parseInt(getProp(lines, block, "SEQUENCE") || "0", 10)
    setProp(lines, block, "SEQUENCE", String((isNaN(seq) ? 0 : seq) + 1))
}

function setCompleted(text, completed) {
    var lines = unfold(text)
    var block = findTodo(lines)
    if (!block) return text
    var now = new Date()

    if (completed) {
        setProp(lines, block, "STATUS", "COMPLETED")
        setProp(lines, block, "COMPLETED", formatDateTime(now))
        setProp(lines, block, "PERCENT-COMPLETE", "100")
    } else {
        setProp(lines, block, "STATUS", "NEEDS-ACTION")
        removeProp(lines, block, "COMPLETED")
        removeProp(lines, block, "PERCENT-COMPLETE")
    }
    touch(lines, block, now)
    return serialize(lines)
}

function createTodo(uid, title, completed, createdAt) {
    var now = new Date()
    var created = createdAt ? new Date(createdAt) : now
    var lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//plasma-6-tasklist//EN",
        "BEGIN:VTODO",
        "UID:" + uid,
        "DTSTAMP:" + formatDateTime(now),
        "CREATED:" + formatDateTime(created),
        "LAST-MODIFIED:" + formatDateTime(now),
        "SUMMARY:" + escapeText(title),
        "STATUS:" + (completed ? "COMPLETED" : "NEEDS-ACTION")
    ]
    if (completed) {
        lines.push("COMPLETED:" + formatDateTime(now))
        lines.push("PERCENT-COMPLETE:100")
    }
    lines.push("END:VTODO", "END:VCALENDAR")
    return serialize(lines)
}

// Restricted to [0-9a-f-] so the UID can double as the resource file name
// without any percent-encoding ambiguity between client and server.
function generateUid() {
    var hex = ""
    for (var i = 0; i < 32; i++) hex += Math.floor(Math.random() * 16).toString(16)
    return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-"
        + hex.substr(16, 4) + "-" + hex.substr(20, 12)
}
