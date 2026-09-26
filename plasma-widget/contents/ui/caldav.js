.pragma library

// QML's XMLHttpRequest only allows GET/PUT/HEAD/POST/DELETE/OPTIONS/PROPFIND/
// PATCH, so REPORT (calendar-query, sync-collection) is unavailable. Listing
// is done with a Depth: 1 PROPFIND for hrefs + etags, and only resources whose
// etag changed are fetched individually.
//
// It does follow redirects itself, keeping method, headers and body (only a
// 303 becomes a GET), which is what makes /.well-known/caldav usable.

var NS_DAV = "DAV:"
var NS_CALDAV = "urn:ietf:params:xml:ns:caldav"
var NS_APPLE = "http://apple.com/ns/ical/"

// Qt.btoa() encodes Latin-1, so non-ASCII passwords must be turned into UTF-8
// bytes first or they'd be sent mangled.
function basicAuth(username, password) {
    var utf8 = encodeURIComponent(username + ":" + password).replace(/%([0-9A-F]{2})/g,
        function(m, hex) { return String.fromCharCode(parseInt(hex, 16)) })
    return "Basic " + Qt.btoa(utf8)
}

function origin(url) {
    var m = /^(https?:\/\/[^\/?#]+)/i.exec(url)
    return m ? m[1] : ""
}

function collectionPath(listUrl) {
    var path = listUrl.substring(origin(listUrl).length) || "/"
    return path.charAt(path.length - 1) === "/" ? path : path + "/"
}

function resolve(baseUrl, href) {
    return /^https?:\/\//i.test(href) ? href : origin(baseUrl) + href
}

// Servers differ in which characters they percent-encode in hrefs (Nextcloud
// encodes "@" in user names, Radicale doesn't), so hrefs are only ever
// compared in decoded form.
function normalizeHref(href) {
    var path = /^https?:\/\//i.test(href) ? href.substring(origin(href).length) : href
    try {
        return decodeURIComponent(path)
    } catch (e) {
        return path
    }
}

function normalizeServerUrl(input) {
    var url = (input || "").trim()
    if (url === "") return ""
    return /^https?:\/\//i.test(url) ? url : "https://" + url
}

function request(cfg, method, url, headers, body, callback) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) callback(xhr)
    }
    try {
        xhr.open(method, url)
        if (cfg.username) xhr.setRequestHeader("Authorization", basicAuth(cfg.username, cfg.password || ""))
        for (var name in headers) xhr.setRequestHeader(name, headers[name])
        xhr.send(body || "")
    } catch (e) {
        callback({ status: 0, statusText: String(e), getResponseHeader: function() { return null } })
    }
}

function describeFailure(method, xhr) {
    if (xhr.status === 0) return "Could not reach server" + (xhr.statusText ? ": " + xhr.statusText : "")
    if (xhr.status === 401) return "Authentication failed (check username and app password)"
    return method + " failed: HTTP " + xhr.status + (xhr.statusText ? " " + xhr.statusText : "")
}

function isSuccess(status) {
    return status >= 200 && status < 300
}

function childElements(node, ns, localName) {
    var out = []
    var children = node.childNodes
    for (var i = 0; i < children.length; i++) {
        var c = children[i]
        if (c.nodeType === 1 && c.nodeName === localName && c.namespaceUri === ns) out.push(c)
    }
    return out
}

function firstChild(node, ns, localName) {
    return node ? (childElements(node, ns, localName)[0] || null) : null
}

function textOf(node) {
    if (!node) return ""
    var s = ""
    var children = node.childNodes
    for (var i = 0; i < children.length; i++) {
        var c = children[i]
        if (c.nodeType === 3 || c.nodeType === 4) s += c.nodeValue
    }
    return s.trim()
}

function attribute(node, name) {
    var attrs = node.attributes
    for (var i = 0; attrs && i < attrs.length; i++) {
        if (attrs[i].nodeName === name) return attrs[i].nodeValue
    }
    return null
}

// props: inner XML of <d:prop>, using the d/c/a prefixes declared here.
// callback(error, responses, status) where each response is
// { href, props: [<d:prop> elements from its 2xx propstats] }.
function propfind(cfg, url, depth, props, callback) {
    var body = '<?xml version="1.0" encoding="utf-8"?>'
        + '<d:propfind xmlns:d="DAV:" xmlns:c="' + NS_CALDAV + '" xmlns:a="' + NS_APPLE + '">'
        + '<d:prop>' + props + '</d:prop></d:propfind>'

    request(cfg, "PROPFIND", url, { "Depth": String(depth), "Content-Type": "application/xml; charset=utf-8" }, body,
        function(xhr) {
            if (xhr.status !== 207) {
                callback(describeFailure("PROPFIND", xhr), null, xhr.status)
                return
            }
            var doc = xhr.responseXML
            if (!doc || !doc.documentElement) {
                callback("Server returned an unreadable response", null, xhr.status)
                return
            }
            var out = []
            var responses = childElements(doc.documentElement, NS_DAV, "response")
            for (var i = 0; i < responses.length; i++) {
                var href = firstChild(responses[i], NS_DAV, "href")
                if (!href) continue
                var props = []
                var propstats = childElements(responses[i], NS_DAV, "propstat")
                for (var j = 0; j < propstats.length; j++) {
                    var status = firstChild(propstats[j], NS_DAV, "status")
                    if (status && !/\s2\d\d\s/.test(" " + textOf(status) + " ")) continue
                    var prop = firstChild(propstats[j], NS_DAV, "prop")
                    if (prop) props.push(prop)
                }
                out.push({ href: textOf(href), props: props })
            }
            callback(null, out, xhr.status)
        })
}

function findProp(response, ns, localName) {
    for (var i = 0; i < response.props.length; i++) {
        var el = firstChild(response.props[i], ns, localName)
        if (el) return el
    }
    return null
}

// callback(error, resources) where resources is [{ href, etag }], collection
// itself excluded.
function listResources(cfg, callback) {
    propfind(cfg, cfg.listUrl, 1, '<d:getetag/><d:resourcetype/>', function(error, responses) {
        if (error) { callback(error, null); return }
        var self = normalizeHref(collectionPath(cfg.listUrl))
        var resources = []
        for (var i = 0; i < responses.length; i++) {
            var normalized = normalizeHref(responses[i].href)
            if (normalized === self || normalized + "/" === self) continue
            if (firstChild(findProp(responses[i], NS_DAV, "resourcetype"), NS_DAV, "collection")) continue
            var etag = findProp(responses[i], NS_DAV, "getetag")
            resources.push({ href: responses[i].href, etag: etag ? textOf(etag) : null })
        }
        callback(null, resources)
    })
}

// callback(error, text, etag)
function getResource(cfg, href, callback) {
    request(cfg, "GET", resolve(cfg.listUrl, href), {}, null, function(xhr) {
        if (xhr.status !== 200) callback(describeFailure("GET", xhr), null, null)
        else callback(null, xhr.responseText, xhr.getResponseHeader("ETag"))
    })
}

// options: { ifMatch: etag } to update, { ifNoneMatch: true } to create.
// callback(status, etag, error). The etag is often absent: servers omit it
// when they rewrote the body, and the next listing then triggers a refetch.
function putResource(cfg, href, body, options, callback) {
    var headers = { "Content-Type": "text/calendar; charset=utf-8" }
    if (options.ifMatch) headers["If-Match"] = options.ifMatch
    if (options.ifNoneMatch) headers["If-None-Match"] = "*"
    request(cfg, "PUT", resolve(cfg.listUrl, href), headers, body, function(xhr) {
        callback(xhr.status, xhr.getResponseHeader("ETag"),
            isSuccess(xhr.status) ? null : describeFailure("PUT", xhr))
    })
}

// callback(status, error)
function deleteResource(cfg, href, ifMatch, callback) {
    var headers = {}
    if (ifMatch) headers["If-Match"] = ifMatch
    request(cfg, "DELETE", resolve(cfg.listUrl, href), headers, null, function(xhr) {
        callback(xhr.status, isSuccess(xhr.status) ? null : describeFailure("DELETE", xhr))
    })
}

// Account discovery (RFC 6764 / RFC 4791): find the principal, its calendar
// home, then the collections in it that accept VTODO.
//
// cfg: { serverUrl, username, password }. serverUrl may be a bare host, a DAV
// root or a principal URL. callback(error, lists) with lists as
// [{ url, name, color }], sorted by name.
function discoverTaskLists(cfg, callback) {
    var start = normalizeServerUrl(cfg.serverUrl)
    if (start === "") { callback("Enter a server address", null); return }
    var host = origin(start)

    // Tried in order until one yields a principal. Well-known redirects are
    // often left unconfigured on self-hosted servers, hence the fallbacks for
    // the common layouts: Nextcloud/ownCloud, Baïkal, Radicale at the root.
    var candidates = []
    var seen = {}
    var list = [start, host + "/.well-known/caldav", host + "/remote.php/dav/", host + "/dav.php/", host + "/"]
    for (var i = 0; i < list.length; i++) {
        if (!seen[list[i]]) { seen[list[i]] = true; candidates.push(list[i]) }
    }

    var authFailed = false
    var reachedServer = false
    var index = 0

    function tryNext() {
        if (index >= candidates.length) {
            callback(authFailed ? "Authentication failed (check username and app password)"
                : reachedServer ? "No CalDAV service found at this address"
                : "Could not reach server", null)
            return
        }
        var url = candidates[index++]
        propfind(cfg, url, 0, '<d:current-user-principal/>', function(error, responses, status) {
            if (status === 401) authFailed = true
            if (status !== 0) reachedServer = true
            var principal = null
            for (var r = 0; !error && r < responses.length && !principal; r++) {
                var el = findProp(responses[r], NS_DAV, "current-user-principal")
                var href = firstChild(el, NS_DAV, "href")
                if (href && textOf(href)) principal = resolve(url, textOf(href))
            }
            if (principal) findHomes(principal)
            else tryNext()
        })
    }

    function findHomes(principalUrl) {
        propfind(cfg, principalUrl, 0, '<c:calendar-home-set/>', function(error, responses) {
            if (error) { callback(error, null); return }
            var homes = []
            for (var r = 0; r < responses.length; r++) {
                var set = findProp(responses[r], NS_CALDAV, "calendar-home-set")
                var hrefs = set ? childElements(set, NS_DAV, "href") : []
                for (var h = 0; h < hrefs.length; h++) homes.push(resolve(principalUrl, textOf(hrefs[h])))
            }
            if (homes.length === 0) callback("This account has no calendar home", null)
            else listHomes(homes, 0, [])
        })
    }

    function listHomes(homes, h, found) {
        if (h >= homes.length) {
            found.sort(function(a, b) { return a.name.localeCompare(b.name) })
            callback(null, found)
            return
        }
        var props = '<d:displayname/><d:resourcetype/><c:supported-calendar-component-set/><a:calendar-color/>'
        propfind(cfg, homes[h], 1, props, function(error, responses) {
            if (error) { callback(error, null); return }
            for (var r = 0; r < responses.length; r++) {
                var entry = toTaskList(homes[h], responses[r])
                var dup = false
                for (var f = 0; f < found.length; f++) {
                    if (normalizeHref(found[f].url) === normalizeHref(entry ? entry.url : "")) dup = true
                }
                if (entry && !dup) found.push(entry)
            }
            listHomes(homes, h + 1, found)
        })
    }

    tryNext()
}

function toTaskList(homeUrl, response) {
    var type = findProp(response, NS_DAV, "resourcetype")
    if (!firstChild(type, NS_CALDAV, "calendar")) return null

    // RFC 4791 §5.2.3: an absent component set means any component is
    // accepted, so only an explicit set without VTODO excludes a collection
    // (e.g. Nextcloud's event-only calendars and birthday calendar).
    var set = findProp(response, NS_CALDAV, "supported-calendar-component-set")
    if (set) {
        var comps = childElements(set, NS_CALDAV, "comp")
        var hasTodo = false
        for (var i = 0; i < comps.length; i++) {
            if ((attribute(comps[i], "name") || "").toUpperCase() === "VTODO") hasTodo = true
        }
        if (!hasTodo) return null
    }

    var url = resolve(homeUrl, response.href)
    if (url.charAt(url.length - 1) !== "/") url += "/"
    var name = textOf(findProp(response, NS_DAV, "displayname"))
    if (!name) {
        var segments = normalizeHref(url).split("/").filter(function(s) { return s !== "" })
        name = segments.length ? segments[segments.length - 1] : url
    }
    // Apple-style colours may carry an alpha byte (#RRGGBBAA); QML reads
    // 8-digit hex as #AARRGGBB, so keep only the RGB part.
    var color = textOf(findProp(response, NS_APPLE, "calendar-color"))
    var m = /^#([0-9a-f]{6})/i.exec(color)
    return { url: url, name: name, color: m ? "#" + m[1] : "" }
}
