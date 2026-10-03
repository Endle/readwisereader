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

test("highlights export through the Readwise highlights API", function()
    local reader = newReader()
    reader.document_authors = { ["doc-1"] = "Stored Author" }
    reader.document_source_urls = { ["doc-1"] = "https://example.com/article" }
    replies = {{ code = 200, body = {} }}
    assert(reader:createHighlights(book({"Passage"})))
    local request = http_calls[1]
    eq(request.url, "https://readwise.io/api/v2/highlights")
    eq(request.method, "POST")
    eq(request.headers.Authorization, "Token test-token")
    local highlight = request.body.highlights[1]
    eq(highlight.text, "Passage")
    eq(highlight.title, "Article")
    eq(highlight.author, "Stored Author")
    eq(highlight.source_url, "https://example.com/article")
    eq(highlight.note, "My note")
    eq(highlight.location, 4)
    eq(highlight.category, "articles")
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

test("highlights API failures are returned to the caller", function()
    local reader = newReader()
    for _, reply in ipairs({{ code = 500 }, { code = 200 }}) do
        replies = {reply}
        local ok, err = reader:createHighlights(book({"Passage"}))
        eq(ok, false)
        assert(err)
    end
end)

test("429 retries rebuild the consumed request body", function()
    local reader = newReader()
    replies = {
        { code = 429, headers = { ["retry-after"] = "2" } },
        { code = 200, body = { id = "doc-1" } },
    }
    assert(reader:callAPI("PATCH", "/update/doc-1/", { location = "archive" }))
    eq(#http_calls, 2)
    eq(http_calls[2].body.location, "archive")
    eq(sleeps[1], 2)
end)

test("rate-limit retries are bounded", function()
    local reader = newReader()
    for _ = 1, 3 do replies[#replies + 1] = { code = 429, headers = { ["retry-after"] = "1" } } end
    local result, err, code = reader.api:requestReader("GET", "/list/")
    eq(result, nil)
    eq(err, "http_error")
    eq(code, 429)
    eq(#http_calls, 3)
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

test("Reader requests accept 201 Created", function()
    local reader = newReader()
    replies = {{ code = 201, body = { id = "created-1" } }}
    local result = reader:callAPI("POST", "/save/", { url = "https://example.com" })
    eq(result.id, "created-1")
end)

test("ambiguous POST failures are not automatically retried", function()
    local reader = newReader()
    replies = {{ network_error = "wantread" }}
    local result, err = reader:callAPI("POST", "/save/", { url = "https://example.com" }, true)
    eq(result, nil)
    eq(err, "network_error")
    eq(#http_calls, 1)
end)

print(string.format("%d tests passed", passed))
