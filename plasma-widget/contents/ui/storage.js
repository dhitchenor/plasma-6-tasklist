.pragma library
.import QtQuick.LocalStorage 2.0 as LS
.import "ical.js" as ICal
.import "caldav.js" as CalDAV

// The SQLite database is a cache of the CalDAV collection. Local edits are
// applied to it immediately and flagged in `pending` ('new', 'modified',
// 'deleted'); sync() pushes those, then pulls whatever changed on the server.
// Conflicts resolve server-wins: a failed If-Match drops the local edit and
// the server copy is refetched.
//
// Every row belongs to a `list`: the collection URL for synced lists, or
// "local:<applet id>" for a widget instance with no server configured. Widget
// instances showing different lists therefore never disturb each other.
//
// This file is a .pragma library, so its state (including the per-list sync
// locks) is shared by every widget instance in the same plasmashell.

// LocalStorage databases are shared by the whole plasmashell and keyed only by
// name, so this must not reuse the upstream widget's "ToDoDB".
const DB_NAME = "dhitchenor.plasma.tasklist"
const DB_VERSION = "1.0"
const DB_DESCRIPTION = "Tasklist widget cache"
const DB_SIZE = 5000000
const LEGACY_DB_NAME = "ToDoDB"

const FETCH_CONCURRENCY = 4

// QML's XMLHttpRequest has no timeout, so a request that never completes
// would hold the lock forever; after this long the lock is considered stale.
const SYNC_STALE_MS = 120000

var db = null
var locks = {}

function getDatabase() {
    if (db === null) {
        db = LS.LocalStorage.openDatabaseSync(DB_NAME, DB_VERSION, DB_DESCRIPTION, DB_SIZE)
        db.transaction(function(tx) {
            tx.executeSql('CREATE TABLE IF NOT EXISTS tasks('
                + 'list TEXT NOT NULL, uid TEXT NOT NULL, href TEXT, href_key TEXT, etag TEXT, ics TEXT, '
                + 'kind TEXT, title TEXT, completed INTEGER, created_at TEXT, pending TEXT, '
                + 'due TEXT, priority INTEGER, '
                + 'PRIMARY KEY (list, uid))')
            tx.executeSql('CREATE INDEX IF NOT EXISTS tasks_href_key ON tasks(list, href_key)')
            tx.executeSql('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)')
            addDueAndPriority(tx)
        })
    }
    return db
}

// Databases created before due dates and priorities were read lack the two
// columns. The raw iCalendar text of every task is already cached, so the
// values are filled in from it rather than waiting for a refetch.
function addDueAndPriority(tx) {
    var columns = tx.executeSql('PRAGMA table_info(tasks)')
    for (var i = 0; i < columns.rows.length; i++) {
        if (columns.rows.item(i).name === 'due') return
    }
    tx.executeSql('ALTER TABLE tasks ADD COLUMN due TEXT')
    tx.executeSql('ALTER TABLE tasks ADD COLUMN priority INTEGER')
    var rs = tx.executeSql("SELECT list, uid, ics FROM tasks WHERE kind = 'todo' AND ics IS NOT NULL")
    for (var r = 0; r < rs.rows.length; r++) {
        var row = rs.rows.item(r)
        var todo = ICal.parseTodo(row.ics)
        if (!todo) continue
        tx.executeSql('UPDATE tasks SET due = ?, priority = ? WHERE list = ? AND uid = ?',
            [todo.due, todo.priority, row.list, row.uid])
    }
}

function initDatabase(localList) {
    getDatabase()
    importLegacyTodos(localList)
}

// One-time import of the upstream widget's local tasks into the first widget
// instance that starts. The upstream table is copied, never dropped: if the
// upstream widget is still installed, it still owns that data.
// Opening a database creates it when missing; an empty ToDoDB file is the
// price of not having an existence check in the LocalStorage API.
function importLegacyTodos(localList) {
    var done = false
    db.readTransaction(function(tx) {
        done = tx.executeSql("SELECT 1 FROM meta WHERE key = 'legacyImported'").rows.length > 0
    })
    if (done) return

    var legacy = []
    try {
        var old = LS.LocalStorage.openDatabaseSync(LEGACY_DB_NAME, "", "", 1000000)
        old.readTransaction(function(tx) {
            var exists = tx.executeSql("SELECT name FROM sqlite_master WHERE type='table' AND name='todos'")
            if (exists.rows.length === 0) return
            var rs = tx.executeSql('SELECT title, completed, created_at FROM todos')
            for (var i = 0; i < rs.rows.length; i++) legacy.push(rs.rows.item(i))
        })
    } catch (e) {
        console.warn("tasklist: could not read legacy tasks:", e)
    }

    db.transaction(function(tx) {
        for (var i = 0; i < legacy.length; i++) {
            var row = legacy[i]
            var uid = ICal.generateUid()
            tx.executeSql('INSERT INTO tasks (list, uid, ics, kind, title, completed, created_at, pending) '
                + "VALUES (?, ?, ?, 'todo', ?, ?, ?, 'new')",
                [localList, uid, ICal.createTodo(uid, row.title, row.completed === 1, row.created_at),
                 row.title, row.completed ? 1 : 0, row.created_at])
        }
        tx.executeSql("INSERT OR REPLACE INTO meta (key, value) VALUES ('legacyImported', '1')")
    })
}

// Tasks an instance created before it had a server move to its first list,
// becoming uploads.
function adoptLocalTasks(localList, list) {
    execute('UPDATE tasks SET list = ? WHERE list = ?', [list, localList])
}

function getAllTodos(list) {
    var todos = []
    getDatabase().readTransaction(function(tx) {
        var rs = tx.executeSql("SELECT uid, title, completed, created_at, due, priority FROM tasks "
            + "WHERE list = ? AND kind = 'todo' AND (pending IS NULL OR pending != 'deleted') "
            + "ORDER BY completed ASC, created_at DESC", [list])
        for (var i = 0; i < rs.rows.length; i++) {
            var row = rs.rows.item(i)
            todos.push({
                list: list,
                id: row.uid,
                title: row.title,
                completed: row.completed === 1,
                created_at: row.created_at,
                due: row.due,
                priority: row.priority || 0
            })
        }
    })
    return todos
}

function addTodo(list, title) {
    var uid = ICal.generateUid()
    var createdAt = new Date().toISOString()
    var ics = ICal.createTodo(uid, title, false, createdAt)
    getDatabase().transaction(function(tx) {
        tx.executeSql('INSERT INTO tasks (list, uid, ics, kind, title, completed, created_at, pending) '
            + "VALUES (?, ?, ?, 'todo', ?, 0, ?, 'new')", [list, uid, ics, title, createdAt])
    })
    return uid
}

function toggleTodo(list, uid) {
    getDatabase().transaction(function(tx) {
        var rs = tx.executeSql('SELECT ics, completed, pending FROM tasks WHERE list = ? AND uid = ?', [list, uid])
        if (rs.rows.length === 0) return
        var row = rs.rows.item(0)
        var completed = row.completed !== 1
        var ics = ICal.setCompleted(row.ics, completed)
        tx.executeSql('UPDATE tasks SET ics = ?, completed = ?, pending = ? WHERE list = ? AND uid = ?',
            [ics, completed ? 1 : 0, row.pending === 'new' ? 'new' : 'modified', list, uid])
    })
}

function deleteTodo(list, uid) {
    getDatabase().transaction(function(tx) {
        var rs = tx.executeSql('SELECT href, pending FROM tasks WHERE list = ? AND uid = ?', [list, uid])
        if (rs.rows.length === 0) return
        var row = rs.rows.item(0)
        // A 'new' task with an href may already have been PUT (the upload can
        // be in flight), so it needs a real DELETE rather than just vanishing
        // locally, or the next pull would bring it back.
        if (row.pending === 'new' && !row.href) {
            tx.executeSql('DELETE FROM tasks WHERE list = ? AND uid = ?', [list, uid])
        } else {
            tx.executeSql("UPDATE tasks SET pending = 'deleted' WHERE list = ? AND uid = ?", [list, uid])
        }
    })
}

function execute(sql, params) {
    getDatabase().transaction(function(tx) { tx.executeSql(sql, params || []) })
}

// Starts a sync of cfg.listUrl and returns true, or returns false without
// calling back when that list is already syncing (possibly from another widget
// instance). callback(error) receives "" on success.
function sync(cfg, callback) {
    var now = Date.now()
    var lock = locks[cfg.listUrl]
    if (lock && now - lock.startedAt < SYNC_STALE_MS) return false

    lock = { startedAt: now }
    locks[cfg.listUrl] = lock

    function finish(error) {
        if (locks[cfg.listUrl] === lock) delete locks[cfg.listUrl]
        callback(error || "")
    }

    pushPending(cfg, function(error) {
        if (error) finish(error)
        else pull(cfg, finish)
    })
    return true
}

function pushPending(cfg, done) {
    var rows = []
    getDatabase().readTransaction(function(tx) {
        var rs = tx.executeSql('SELECT uid, href, etag, ics, pending FROM tasks WHERE list = ? AND pending IS NOT NULL',
            [cfg.listUrl])
        for (var i = 0; i < rs.rows.length; i++) rows.push(rs.rows.item(i))
    })

    var index = 0
    function next(error) {
        if (error) { done(error); return }
        if (index >= rows.length) { done(null); return }
        var row = rows[index++]
        if (row.pending === 'new') pushNew(cfg, row, next)
        else if (row.pending === 'modified') pushModified(cfg, row, next)
        else if (row.pending === 'deleted') pushDeleted(cfg, row, next)
        else next(null)
    }
    next(null)
}

function pushNew(cfg, row, next) {
    var href = row.href
    if (!href) {
        href = CalDAV.collectionPath(cfg.listUrl) + row.uid + ".ics"
        // Recorded before the PUT so a lost response followed by a retry
        // ends in 412 (already exists) rather than a duplicate.
        execute('UPDATE tasks SET href = ?, href_key = ? WHERE list = ? AND uid = ?',
            [href, CalDAV.normalizeHref(href), cfg.listUrl, row.uid])
    }
    CalDAV.putResource(cfg, href, row.ics, { ifNoneMatch: true }, function(status, etag, error) {
        if (status === 412) {
            execute("UPDATE tasks SET etag = NULL, pending = NULL WHERE list = ? AND uid = ? AND pending = 'new'",
                [cfg.listUrl, row.uid])
            next(null)
        } else if (error) {
            next(error)
        } else {
            // The task may have been edited while the PUT was in flight.
            execute("UPDATE tasks SET etag = ?, pending = CASE WHEN ics = ? THEN NULL ELSE 'modified' END "
                + "WHERE list = ? AND uid = ? AND pending = 'new'", [etag, row.ics, cfg.listUrl, row.uid])
            next(null)
        }
    })
}

function pushModified(cfg, row, next) {
    CalDAV.putResource(cfg, row.href, row.ics, { ifMatch: row.etag }, function(status, etag, error) {
        if (status === 412) {
            execute('UPDATE tasks SET etag = NULL, pending = NULL WHERE list = ? AND uid = ?', [cfg.listUrl, row.uid])
            next(null)
        } else if (status === 404) {
            execute('DELETE FROM tasks WHERE list = ? AND uid = ?', [cfg.listUrl, row.uid])
            next(null)
        } else if (error) {
            next(error)
        } else {
            execute("UPDATE tasks SET etag = ?, pending = CASE WHEN ics = ? THEN NULL ELSE pending END "
                + "WHERE list = ? AND uid = ?", [etag, row.ics, cfg.listUrl, row.uid])
            next(null)
        }
    })
}

function pushDeleted(cfg, row, next) {
    if (!row.href) {
        execute('DELETE FROM tasks WHERE list = ? AND uid = ?', [cfg.listUrl, row.uid])
        next(null)
        return
    }
    CalDAV.deleteResource(cfg, row.href, row.etag, function(status, error) {
        if (status === 412) {
            execute('UPDATE tasks SET etag = NULL, pending = NULL WHERE list = ? AND uid = ?', [cfg.listUrl, row.uid])
            next(null)
        } else if (status === 404 || !error) {
            execute('DELETE FROM tasks WHERE list = ? AND uid = ?', [cfg.listUrl, row.uid])
            next(null)
        } else {
            next(error)
        }
    })
}

function pull(cfg, done) {
    CalDAV.listResources(cfg, function(error, resources) {
        if (error) { done(error); return }

        var local = {}
        getDatabase().readTransaction(function(tx) {
            var rs = tx.executeSql('SELECT uid, href_key, etag, pending FROM tasks WHERE list = ? AND href_key IS NOT NULL',
                [cfg.listUrl])
            for (var i = 0; i < rs.rows.length; i++) {
                var row = rs.rows.item(i)
                local[row.href_key] = row
            }
        })

        var onServer = {}
        var toFetch = []
        for (var i = 0; i < resources.length; i++) {
            var key = CalDAV.normalizeHref(resources[i].href)
            onServer[key] = true
            var existing = local[key]
            if (existing && existing.pending) continue
            if (existing && existing.etag && existing.etag === resources[i].etag) continue
            toFetch.push(resources[i])
        }

        getDatabase().transaction(function(tx) {
            for (var key in local) {
                if (!onServer[key] && !local[key].pending) {
                    tx.executeSql('DELETE FROM tasks WHERE list = ? AND uid = ? AND pending IS NULL',
                        [cfg.listUrl, local[key].uid])
                }
            }
        })

        fetchAll(cfg, toFetch, done)
    })
}

function fetchAll(cfg, resources, done) {
    var index = 0
    var active = 0
    var firstError = null

    function launch() {
        while (active < FETCH_CONCURRENCY && index < resources.length) {
            var resource = resources[index++]
            active++
            fetchOne(cfg, resource, function(error) {
                active--
                if (error && !firstError) firstError = error
                launch()
            })
        }
        if (active === 0 && index >= resources.length) done(firstError)
    }
    launch()
}

function fetchOne(cfg, resource, callback) {
    CalDAV.getResource(cfg, resource.href, function(error, text, etag) {
        if (error) { callback(error); return }
        storeFetched(cfg.listUrl, resource.href, etag || resource.etag, text)
        callback(null)
    })
}

function storeFetched(list, href, etag, text) {
    var key = CalDAV.normalizeHref(href)
    var todo = ICal.parseTodo(text)

    getDatabase().transaction(function(tx) {
        var sameHref = tx.executeSql('SELECT uid, pending FROM tasks WHERE list = ? AND href_key = ?', [list, key])
        for (var i = 0; i < sameHref.rows.length; i++) {
            var r = sameHref.rows.item(i)
            // Edited locally while this GET was in flight: keep the edit,
            // its If-Match will sort out the conflict on the next push.
            if (r.pending) return
            tx.executeSql('DELETE FROM tasks WHERE list = ? AND uid = ?', [list, r.uid])
        }

        // Events and other non-task resources are cached too (unrendered),
        // so a mixed calendar doesn't refetch them on every sync.
        var uid = (todo && todo.uid) ? todo.uid : "href:" + key
        var clash = tx.executeSql('SELECT pending FROM tasks WHERE list = ? AND uid = ?', [list, uid])
        if (clash.rows.length && clash.rows.item(0).pending) return

        tx.executeSql('INSERT OR REPLACE INTO tasks '
            + '(list, uid, href, href_key, etag, ics, kind, title, completed, created_at, pending, due, priority) '
            + 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)',
            [list, uid, href, key, etag, todo ? text : null, todo ? 'todo' : 'other',
             todo ? todo.title : null, todo && todo.completed ? 1 : 0, todo ? todo.createdAt : null,
             todo ? todo.due : null, todo ? todo.priority : 0])
    })
}
