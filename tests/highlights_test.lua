-- Run from the repo root: luajit tests/highlights_test.lua
-- KOReader/HTTP are stubbed; these exercise the actual plugin methods.
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

local function eq(actual, expected)
    assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local function contains(actual, expected)
    assert(actual and actual:find(expected, 1, true), tostring(actual))
end

local function noop() end
local object = {}
function object:extend(value) return setmetatable(value or {}, { __index = self }) end
function object:new(value) return self:extend(value) end

-- Fixture codec: preserve payloads through the HTTP boundary without requiring
-- KOReader's JSON libraries. Invalid response fixtures still raise decode errors.
local encoded = {}
local json = { util = { null = function() end } }
function json.encode(value)
    local token = "json:" .. tostring(#encoded + 1)
    encoded[#encoded + 1] = copy(value)
    return token
end
function json.decode(token)
    local index = tonumber(token:match("^json:(%d+)$"))
    assert(index and encoded[index], "invalid JSON fixture")
    return copy(encoded[index])
end

local stored, flushes, messages, sleeps, http_calls, replies, timeouts
local settings = {}
function settings:readSetting(key) return copy(stored[key]) end
function settings:saveSetting(key, value) stored[key] = copy(value) end
function settings:flush() flushes = flushes + 1 end

local modules = {
    logger = { dbg = noop, warn = noop, err = noop },
    datastorage = { getSettingsDir = function() return "/settings" end },
    dispatcher = { registerAction = noop },
    luasettings = { open = function() return settings end },
    ["ui/widget/container/widgetcontainer"] = object,
    ["ui/widget/infomessage"] = object,
    ["ui/uimanager"] = {
        show = function(_, msg) messages[#messages + 1] = msg.text end,
        close = noop,
    },
    clip = object,
    device = { isKindle = function() return false end },
    util = {
        splitFilePathName = function(path) return path:match("^(.-)([^/]+)$") end,
    },
    gettext = function(s) return s end,
    json = json,
    rapidjson = { encode = json.encode, decode = json.decode, null = function() end },
    socketutil = {
        set_timeout = function() timeouts = timeouts + 1 end,
        reset_timeout = function() timeouts = timeouts - 1 end,
    },
    socket = {
        skip = function(n, ...) return select(n + 1, ...) end,
        sleep = function(n) sleeps[#sleeps + 1] = n end,
    },
    ltn12 = {
        source = { string = function(body)
            return function()
                local chunk = body
                body = nil
                return chunk
            end
        end },
        sink = { table = function(sink)
            return function(chunk)
                if chunk then sink[#sink + 1] = chunk end
                return 1
            end
        end },
    },
    ["socket.http"] = { request = function(request)
        local body = request.source and request.source()
        http_calls[#http_calls + 1] = {
            url = request.url, method = request.method,
            body = body and json.decode(body), headers = copy(request.headers),
        }
        local reply = table.remove(replies, 1)
        assert(reply, "unexpected HTTP request")
        if reply.network_error then return nil, reply.network_error end
        local data = reply.raw or (reply.body and json.encode(reply.body)) or ""
        -- Exercise response assembly across multiple chunks.
        local middle = math.floor(#data / 2)
        request.sink(data:sub(1, middle))
        request.sink(data:sub(middle + 1))
        return 1, reply.code, reply.headers or {}, "HTTP " .. reply.code
    end },
}
local unused = {
    "ui/bidi", "docsettings", "ui/event", "ffi/util", "apps/filemanager/filemanager",
    "ui/widget/inputdialog", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
    "readcollection", "ui/network/manager", "readhistory", "apps/filemanager/filemanagerutil",
    "libs/libkoreader-lfs", "mime",
}
for _, name in ipairs(unused) do modules[name] = {} end
for name, module in pairs(modules) do
    package.preload[name] = function() return module end
end
-- KOReader temporarily prepends the plugin directory while loading main.lua.
local package_path = package.path
package.path = "readwisereader.koplugin/?.lua;" .. package.path
local Reader = dofile("readwisereader.koplugin/main.lua")
package.path = package_path

local function newReader()
    local reader = Reader:new{
        ui = { menu = { registerToMainMenu = noop } },
        showProgress = noop, hideProgress = noop,
    }
    reader:init()
    return reader
end

local function book(passages, id)
    local notes = { title = "Article", file = "/reader/[rw-id_" .. (id or "doc-1") .. "] Article.html" }
    for _, passage in ipairs(passages) do
        notes[#notes + 1] = {{ text = passage, note = "My note", page = 4, time = 12345 }}
    end
    return notes
end

local passed = 0
local function test(name, run)
    stored = { readwisereader = { access_token = "test-token" } }
    flushes, timeouts = 0, 0
    messages, sleeps, http_calls, replies = {}, {}, {}, {}
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err)) end
    eq(timeouts, 0)
    passed = passed + 1
    print("ok - " .. name)
end

test("Reader payload preserves text and accepts 201", function()
    local reader = newReader()
    local text = "A ‘quote’ & punctuation.\nA second paragraph."
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(book({text})))
    eq(#http_calls, 1)
    local request = http_calls[1]
    eq(request.url, "https://readwise.io/api/v3/save/")
    eq(request.method, "POST")
    eq(request.headers.Authorization, "Token test-token")
    eq(request.body.parent_id, "doc-1")
    eq(request.body.content, text)
    eq(request.body.notes, "My note")
    eq(request.body.saved_using, "koreader")
    eq(request.body.url, nil)
    eq(request.body.location, nil)
    eq(flushes, 1)
    eq(stored.readwisereader.reader_highlights["doc-1"][text].id, "highlight-1")
end)

test("highlights without a note omit notes when created", function()
    local reader = newReader()
    local notes = book({"Passage"})
    notes[1][1].note = nil
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(notes))
    eq(http_calls[1].body.notes, nil)
    eq(stored.readwisereader.reader_highlights["doc-1"].Passage.notes, "")
end)

test("whitespace-only notes count as blank", function()
    -- Reader trims notes, so " " would be rejected as blank (400) like "".
    local reader = newReader()
    local notes = book({"Passage"})
    notes[1][1].note = " \n"
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(notes))
    eq(http_calls[1].body.notes, nil)
    eq(stored.readwisereader.reader_highlights["doc-1"].Passage.notes, "")
    notes[1][1].note = nil
    assert(newReader():createHighlights(notes))
    eq(#http_calls, 1)
end)

test("successful exports survive restart and skip repeated syncs", function()
    local reader = newReader()
    replies = {{ code = 200, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(book({"Passage"})))
    local restarted = newReader()
    assert(restarted:createHighlights(book({"Passage"})))
    eq(#http_calls, 1)
    eq(flushes, 1)
end)

test("notes changed after export are not sent", function()
    local reader = newReader()
    local notes = book({"Passage"})
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(notes))
    notes[1][1].note = "Edited note"
    assert(newReader():createHighlights(notes))
    notes[1][1].note = nil
    assert(newReader():createHighlights(notes))
    eq(#http_calls, 1)
    eq(flushes, 1)
    eq(stored.readwisereader.reader_highlights["doc-1"].Passage.notes, "My note")
end)

test("partial failure preserves progress and retries only unsent passages", function()
    local reader = newReader()
    replies = {
        { code = 201, body = { id = "highlight-1" } },
        { code = 201, body = { id = "highlight-2" } },
        { code = 500 },
    }
    local notes = book({"First", "Second", "Third", "Fourth"})
    local ok, err = reader:createHighlights(notes)
    eq(ok, false)
    contains(err, "500")
    eq(#http_calls, 3)
    -- History is saved once per book, including when the book fails.
    eq(flushes, 1)
    eq(stored.readwisereader.reader_highlights["doc-1"].Second.id, "highlight-2")
    eq(stored.readwisereader.reader_highlights["doc-1"].Third, nil)
    replies = {
        { code = 201, body = { id = "highlight-3" } },
        { code = 201, body = { id = "highlight-4" } },
    }
    assert(newReader():createHighlights(notes))
    eq(#http_calls, 5)
    eq(http_calls[4].body.content, "Third")
end)

local function captureLog(level)
    local lines = {}
    require("logger")[level] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    return lines
end

test("rejected passages fall back to the highlights API once", function()
    local errors, warnings = captureLog("err"), captureLog("warn")
    local logger = require("logger")
    local reader = newReader()
    reader.document_authors = { ["doc-1"] = "Stored Author" }
    reader.document_source_urls = { ["doc-1"] = "https://example.com/article" }
    local notes = book({"First", "Second", "Third"})
    replies = {
        { code = 201, body = { id = "highlight-1" } },
        { code = 400, raw = "content not found" },
        { code = 201, body = { id = "highlight-3" } },
        { code = 200, body = {} },
    }
    local ok = reader:createHighlights(notes)
    logger.err, logger.warn = noop, noop
    assert(ok)
    eq(http_calls[4].url, "https://readwise.io/api/v2/highlights")
    eq(#http_calls[4].body.highlights, 1)
    local highlight = http_calls[4].body.highlights[1]
    eq(highlight.text, "Second")
    eq(highlight.note, "My note")
    eq(highlight.author, "Stored Author")
    eq(highlight.source_url, "https://example.com/article")
    contains(errors[#errors], "content not found")
    contains(warnings[#warnings], "rejected")
    contains(warnings[#warnings], "page 4")
    -- Highlight text is private; it is only logged at debug level.
    for _, line in ipairs(warnings) do assert(not line:find("Second", 1, true), line) end
    eq(stored.readwisereader.reader_highlights["doc-1"].Second.fallback, true)
    eq(flushes, 1)
    -- Later syncs send the passage nowhere, even after a note edit.
    assert(newReader():createHighlights(notes))
    notes[2][1].note = "Edited note"
    assert(newReader():createHighlights(notes))
    eq(#http_calls, 4)
end)

test("validation errors on plugin-chosen fields fail instead of falling back", function()
    -- e.g. the blank-notes 400: falling back would hide the bug and skip Reader
    -- for that passage forever.
    local reader = newReader()
    replies = {{ code = 400, raw = '{"notes": ["This field may not be blank."]}' }}
    local ok, err = reader:createHighlights(book({"Passage"}))
    eq(ok, false)
    contains(err, "400")
    eq(#http_calls, 1)
    eq(stored.readwisereader.reader_highlights, nil)
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(newReader():createHighlights(book({"Passage"})))
    eq(http_calls[2].url, "https://readwise.io/api/v3/save/")
end)

test("400s about the passage or its parent still fall back", function()
    for _, body in ipairs({
        '{"content": ["Not found in the document."]}',
        '{"parent_id": ["Invalid parent."], "notes": ["Ensure this field has no more than 8191 characters."]}',
    }) do
        local reader = newReader()
        replies = {
            { code = 400, raw = body },
            { code = 200, body = {} },
        }
        assert(reader:createHighlights(book({"Passage"})))
        eq(http_calls[#http_calls].url, "https://readwise.io/api/v2/highlights")
    end
end)

test("deleted parent documents fall back instead of blocking sync", function()
    local reader = newReader()
    replies = {
        { code = 404 },
        { code = 200, body = {} },
    }
    assert(reader:createHighlights(book({"Passage"})))
    eq(http_calls[2].url, "https://readwise.io/api/v2/highlights")
end)

test("rejected passages are sent even when a later passage fails", function()
    local reader = newReader()
    local notes = book({"First", "Second"})
    replies = {
        { code = 400 },
        { code = 500 },
        { code = 200, body = {} },
    }
    local ok, err = reader:createHighlights(notes)
    eq(ok, false)
    contains(err, "500")
    eq(http_calls[3].body.highlights[1].text, "First")
    eq(stored.readwisereader.reader_highlights["doc-1"].First.fallback, true)
end)

test("a failed fallback is not recorded", function()
    local reader = newReader()
    replies = {
        { code = 400 },
        { code = 500 },
    }
    local ok, err = reader:createHighlights(book({"Passage"}))
    eq(ok, false)
    contains(err, "highlights API failed")
    eq(flushes, 0)
    replies = {
        { code = 400 },
        { code = 200, body = {} },
    }
    assert(newReader():createHighlights(book({"Passage"})))
    eq(http_calls[3].body.content, "Passage")
end)

test("identical passages are scoped to their document", function()
    local reader = newReader()
    replies = {
        { code = 201, body = { id = "highlight-1" } },
        { code = 201, body = { id = "highlight-2" } },
    }
    assert(reader:createHighlights(book({"Same", "Same"})))
    assert(reader:createHighlights(book({"Same"}, "doc-2")))
    eq(#http_calls, 2)
    eq(http_calls[2].body.parent_id, "doc-2")
end)

test("repeated passages share one highlight with every note", function()
    local reader = newReader()
    local notes = book({"Same", "Other", "Same", "Same"})
    notes[1][1].note = "First"
    notes[3][1].note = nil
    notes[4][1].note = "Second"
    replies = {
        { code = 201, body = { id = "highlight-1" } },
        { code = 201, body = { id = "highlight-2" } },
    }
    assert(reader:createHighlights(notes))
    eq(#http_calls, 2)
    eq(http_calls[1].body.content, "Same")
    eq(http_calls[1].body.notes, "First\n\nSecond")
    -- Without merging, only the first copy's note would ever reach Reader.
    assert(newReader():createHighlights(notes))
    eq(#http_calls, 2)
end)

test("non-Reader books and clippings without files keep legacy export", function()
    local reader = newReader()
    for _, file in ipairs({"/books/book.epub", false}) do
        local notes = book({"Passage"})
        notes.file = file or nil
        notes.author = "An Author"
        replies = {{ code = 200, body = {} }}
        assert(reader:createHighlights(notes))
        local request = http_calls[#http_calls]
        eq(request.url, "https://readwise.io/api/v2/highlights")
        eq(request.method, "POST")
        eq(request.body.highlights[1].text, "Passage")
        eq(request.body.highlights[1].author, "An Author")
        eq(request.body.highlights[1].note, "My note")
        eq(request.headers.Authorization, "Token test-token")
    end
    eq(#http_calls, 2)
end)

test("books without stored metadata fall back to the parsed author", function()
    local reader = newReader()
    for _, file in ipairs({"/books/book.epub", false}) do
        local notes = book({"Passage"})
        notes.file = file or nil
        notes.author = "An Author\nAnother Author"
        replies = {{ code = 200, body = {} }}
        assert(reader:createHighlights(notes))
        local highlight = http_calls[#http_calls].body.highlights[1]
        eq(highlight.author, "An Author, Another Author")
        eq(highlight.source_url, nil)
    end
    eq(#http_calls, 2)
end)

test("highlights API failures are returned to the caller and logged", function()
    local errors = captureLog("err")
    local reader = newReader()
    for _, reply in ipairs({{ code = 500, raw = "server exploded" }, { code = 200 }}) do
        replies = {reply}
        local notes = book({"Passage"})
        notes.file = "/books/book.epub"
        local ok, err = reader:createHighlights(notes)
        eq(ok, false)
        assert(err)
    end
    require("logger").err = noop
    eq(http_calls[1].url, "https://readwise.io/api/v2/highlights")
    contains(errors[1], "server exploded")
end)

test("429 retries rebuild the consumed request body", function()
    local reader = newReader()
    replies = {
        { code = 429, headers = { ["retry-after"] = "2" } },
        { code = 201, body = { id = "highlight-1" } },
    }
    assert(reader:createHighlights(book({"Passage"})))
    eq(#http_calls, 2)
    eq(http_calls[2].body.content, "Passage")
    eq(sleeps[1], 2)
    eq(flushes, 1)
end)

test("rate-limit retries are bounded and do not mark success", function()
    local reader = newReader()
    for _ = 1, 3 do replies[#replies + 1] = { code = 429, headers = { ["retry-after"] = "1" } } end
    local ok, err = reader:createHighlights(book({"Passage"}))
    eq(ok, false)
    contains(err, "429")
    eq(#http_calls, 3)
    eq(flushes, 0)
end)

test("ambiguous create failures are not automatically retried", function()
    local reader = newReader()
    replies = {{ network_error = "wantread" }}
    eq(reader:createHighlights(book({"Passage"})), false)
    eq(#http_calls, 1)
    eq(flushes, 0)
end)

test("malformed responses and missing IDs are not recorded as success", function()
    local reader = newReader()
    for _, reply in ipairs({
        { code = 201, raw = "not-json" },
        { code = 201, body = {} },
        { code = 201 },
        { code = 401 },
    }) do
        replies = {reply}
        eq(reader:createHighlights(book({"Passage"})), false)
        eq(flushes, 0)
    end
end)

test("empty/image-only highlights are skipped without blocking the book", function()
    local reader = newReader()
    assert(reader:createHighlights(book({"  \n"})))
    local notes = book({"Image", "Passage"})
    notes[1][1].text = nil
    replies = {{ code = 201, body = { id = "highlight-1" } }}
    assert(reader:createHighlights(notes))
    eq(#http_calls, 1)
    eq(http_calls[1].body.content, "Passage")
end)

test("book export errors reach the caller, including partial success", function()
    local reader = newReader()
    reader.parseAllBooks = function() return { good = book({"Good"}), bad = book({"Bad"}, "doc-2") } end
    reader.createHighlights = function(_, notes)
        if notes[1][1].text == "Good" then return true end
        return false, "Text mismatch"
    end
    local count, err = reader:exportHighlights()
    eq(count, 1)
    contains(err, "Text mismatch")
end)

test("failure to save open annotations stops parsing", function()
    local reader = newReader()
    reader.ui.document = {}
    reader.ui.saveSettings = function() error("disk full") end
    reader.parser.parseHistory = function() error("must not parse stale annotations") end
    local _, err = reader:exportHighlights()
    contains(err, "disk full")
end)

test("failed export keeps local files and sync cursor but still downloads", function()
    for _, failure in ipairs({"parse", "export"}) do
        for _, server_documents in ipairs({ {}, {{ id = "new-doc", title = "New" }} }) do
            local reader = newReader()
            reader.export_highlights_at_sync = true
            reader.archive_finished = true
            reader.last_sync_time = "previous-sync"
            reader.validateSettings = function() return true end
            reader.parseAllBooks = function()
                if failure == "parse" then error("parse failed") end
                return { article = book({"Passage"}) }
            end
            reader.createHighlights = function() return false, "export failed" end
            local function forbidden() error("must not delete local files after failed export") end
            reader.cleanupArchivedDocuments = forbidden
            reader.processFinishedDocuments = forbidden
            reader.reconcileLocalDocuments = forbidden
            reader.getDocumentList = function() return server_documents end
            reader.updateAvailableTags = noop
            reader.documentExists = function() return false end
            reader.initCollectionTracking = noop
            reader.saveCollections = noop
            local downloads = 0
            reader.downloadDocument = function() downloads = downloads + 1; return "downloaded" end
            reader:synchronize()
            eq(downloads, #server_documents)
            eq(reader.last_sync_time, "previous-sync")
            local shown = table.concat(messages, "\n")
            contains(shown, "no local articles will be removed")
            contains(shown, failure .. " failed")
        end
    end
end)

test("sync still cleans up when export succeeds or is disabled", function()
    for _, enabled in ipairs({true, false}) do
        local reader = newReader()
        reader.export_highlights_at_sync = enabled
        reader.validateSettings = function() return true end
        reader.exportHighlights = function()
            assert(enabled, "export must respect the toggle")
            return 1, nil
        end
        local cleanup, archive = false, false
        reader.cleanupArchivedDocuments = function() cleanup = true; return 0 end
        reader.processFinishedDocuments = function() archive = true; return 0, 0 end
        -- Stop after cleanup, before the unrelated download/UI pipeline.
        reader.getDocumentList = function() return nil end
        reader:synchronize()
        assert(cleanup and archive)
    end
end)

test("API requests read the current token after settings change", function()
    local reader = newReader()
    replies = {
        { code = 200, body = { results = {} } },
        { code = 200, body = { results = {} } },
        { code = 200, body = {} },
    }
    assert(reader:callAPI("GET", "/list/"))
    reader.access_token = "replacement-token"
    assert(reader:callAPI("GET", "/list/"))
    assert(reader.api:createReadwiseHighlights({}))
    eq(http_calls[1].headers.Authorization, "Token test-token")
    eq(http_calls[2].headers.Authorization, "Token replacement-token")
    eq(http_calls[3].headers.Authorization, "Token replacement-token")
end)


test("transport retries safe reads and strips nested JSON nulls", function()
    local reader = newReader()
    replies = {
        { network_error = "wantread" },
        { code = 200, body = { results = {{ id = "doc-1", author = json.util.null }} } },
        { code = 204 },
    }
    local result = reader:callAPI("GET", "/list/")
    eq(result.results[1].id, "doc-1")
    eq(result.results[1].author, nil)
    eq(#http_calls, 2)
    eq(sleeps[1], 2)
    eq(reader:callAPI("PATCH", "/update/doc-1/", { location = "archive" }), true)
end)


test("large error bodies are returned whole but logged truncated", function()
    local errors = captureLog("err")
    local reader = newReader()
    local page = "<html>" .. string.rep("x", 5000) .. "</html>"
    replies = {{ code = 400, raw = page }}
    local _, _, code, body = reader.api:requestReader("POST", "/save/", {})
    require("logger").err = noop
    eq(code, 400)
    eq(body, page)
    assert(#errors[1] < 600, #errors[1])
end)

test("only the plugin presents interactive API errors", function()
    local reader = newReader()
    replies = {
        { code = 401 },
        { code = 401 },
        { code = 401 },
        { network_error = "offline" },
    }
    local result, err, code = reader.api:requestReader("GET", "/list/")
    eq(result, nil)
    eq(err, "http_error")
    eq(code, 401)
    eq(#messages, 0)
    reader:callAPI("GET", "/list/", nil, true)
    eq(#messages, 0)
    reader:callAPI("GET", "/list/")
    contains(messages[1], "401")
    reader:callAPI("GET", "/list/")
    contains(messages[2], "Network error")
end)


test("rate-limit sessions reset independently for each client", function()
    local reader, another = newReader(), newReader()
    local progress = {}
    reader.showProgress = function(_, message) progress[#progress + 1] = message end
    reader.hideProgress = function() progress[#progress + 1] = "hidden" end
    replies = {
        { code = 429, headers = { ["retry-after"] = "2" } },
        { code = 200, body = {} },
    }
    assert(reader.api:requestReader("GET", "/list/"))
    contains(progress[1], "2 seconds")
    eq(progress[2], "hidden")
    eq(reader.api.needs_rate_limiting, true)
    eq(another.api.needs_rate_limiting, false)
    reader.api:resetRateLimit()
    eq(reader.api.api_call_count, 0)
    eq(reader.api.sync_start_time, nil)
    eq(reader.api.needs_rate_limiting, false)
end)

print(string.format("%d tests passed", passed))
