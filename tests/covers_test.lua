-- Run from the repo root: luajit tests/covers_test.lua
-- Network and KOReader are external boundaries; temporary cover files are real.
local function eq(actual, expected)
    assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end
local function be(n, bytes)
    local out = {}
    for i = bytes - 1, 0, -1 do out[#out + 1] = string.char(math.floor(n / 256 ^ i) % 256) end
    return table.concat(out)
end
local function le(n, bytes)
    local out = {}
    for i = 0, bytes - 1 do out[#out + 1] = string.char(math.floor(n / 256 ^ i) % 256) end
    return table.concat(out)
end
-- Image headers with real dimensions; the rest of each fixture is filler.
local function png(w, h) return "\137PNG\r\n\26\n" .. be(13, 4) .. "IHDR" .. be(w, 4) .. be(h, 4) .. "fixture" end
local function gif(w, h) return "GIF89a" .. le(w, 2) .. le(h, 2) .. "fixture" end
local function jpeg(w, h)
    -- an APP0 segment to skip, then a baseline frame header
    return "\255\216\255\224" .. be(16, 2) .. string.rep("\0", 14)
        .. "\255\192" .. be(17, 2) .. "\8" .. be(h, 2) .. be(w, 2) .. "fixture"
end
local function webp(chunk, w, h)
    local body
    if chunk == "VP8X" then
        body = "\0\0\0\0" .. le(w - 1, 3) .. le(h - 1, 3)
    elseif chunk == "VP8 " then
        body = "\0\0\0\157\1\42" .. le(w, 2) .. le(h, 2)
    else
        body = "\47" .. le((w - 1) + (h - 1) * 16384, 4)
    end
    return "RIFF" .. le(12 + #body, 4) .. "WEBP" .. chunk .. le(#body, 4) .. body .. "fixture"
end
local cover = png(600, 800)

local calls, urls, request, reply, installed, existing, covers, timeout, timeouts, sinks
local rendered, freed, events, temporary, warnings
local function noop() end
package.preload.datastorage = function() return {
    getSettingsDir = function() return os.getenv("TMPDIR") or "/tmp" end,
} end
package.preload.logger = function() return {
    warn = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        warnings[#warnings + 1] = table.concat(parts, " ")
    end,
    dbg = noop, err = noop, info = noop,
} end
package.preload.docsettings = function() return {
    findCustomCoverFile = function(_, path)
        if existing then return existing end
        local saved = covers[path]
        local f = saved and io.open(saved, "rb")
        if f then f:close(); return saved end
    end,
    flushCustomCover = function(_, path, file)
        local f = assert(io.open(file, "rb"))
        installed = { path = path, bytes = f:read("*a"), suffix = file:match("%.([^.]*)$") }
        f:close()
        temporary = file
        if reply.save_ok == false then return false end
        local saved = os.tmpname()
        f = assert(io.open(saved, "wb"))
        f:write(reply.partial_copy and installed.bytes:sub(1, 8) or installed.bytes)
        f:close()
        covers[path] = saved
        return true
    end,
} end
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path, name)
        local f = io.open(path, "rb")
        if not f then return nil end
        local size = f:seek("end")
        f:close()
        return name == "size" and size or { size = size }
    end,
} end
package.preload["socket.http"] = function() return { request = function(req)
    calls = calls + 1
    request = req
    urls[#urls + 1] = req.url
    if reply.throw then error("offline") end
    if reply.network_error then return nil, reply.network_error end
    for _, chunk in ipairs(reply.chunks or { reply.body or cover }) do
        local ok, err = req.sink(chunk)
        if not ok then return nil, err end
    end
    req.sink(nil)
    return 1, reply.code or 200, { ["content-type"] = reply.mime or "application/octet-stream" }
end } end
package.preload.socketutil = function() return {
    set_timeout = function(_, block, total)
        timeout = timeout + 1
        timeouts = { block, total }
    end,
    reset_timeout = function() timeout = timeout - 1 end,
    table_sink = function(t)
        sinks = sinks + 1
        return function(chunk)
            if chunk then t[#t + 1] = chunk end
            return 1
        end, t
    end,
} end
package.preload["ui/renderimage"] = function() return {
    renderImageData = function(_, data, size, frames, width, height)
        rendered = rendered + 1
        eq(size, #data)
        eq(frames, false)
        assert(width and height, "validation should bound rendered dimensions")
        if data:find("corrupt", 1, true) then return nil end
        return { free = function() freed = freed + 1 end }
    end,
} end
package.preload["ui/event"] = function() return {
    new = function(_, name, path) return { name = name, path = path } end,
} end
package.preload["ui/uimanager"] = function() return {
    broadcastEvent = function(_, event) events[#events + 1] = event end,
} end
local Covers = dofile("readwisereader.koplugin/readwisereader/covers.lua")
local passed = 0
local function test(name, run)
    calls, timeout, sinks, rendered, freed = 0, 0, 0, 0, 0
    reply, events, warnings, urls, covers = {}, {}, {}, {}, {}
    installed, existing, temporary, request, timeouts = nil, nil, nil, nil, nil
    local ok, err = pcall(run)
    for _, saved in pairs(covers) do os.remove(saved) end
    if not ok then error(name .. ": " .. tostring(err)) end
    eq(timeout, 0)
    if temporary then eq(io.open(temporary, "rb"), nil) end
    passed = passed + 1
    print("ok - " .. name)
end
local URL = "https://example.com/cover?size=large"
local function sync(url)
    return Covers:sync("/reader/article.html", url or URL)
end
local function removeCover(path)
    os.remove(covers[path])
    covers[path] = nil
end

test("a Reader image becomes a custom cover and invalidates only that file's metadata", function()
    eq(sync(), "installed")
    eq(installed.path, "/reader/article.html")
    eq(installed.bytes, cover)
    eq(installed.suffix, "png")
    eq(freed, 1)
    eq(#events, 1)
    eq(events[1].name, "InvalidateMetadataCache")
    eq(events[1].path, "/reader/article.html")
    eq(#warnings, 0)
end)
test("image bytes, not headers, determine the format, and each format's size is read", function()
    local fixtures = {
        { data = jpeg(600, 800), suffix = "jpg" },
        { data = gif(600, 800), suffix = "gif" },
        { data = webp("VP8X", 600, 800), suffix = "webp" },
        { data = webp("VP8 ", 600, 800), suffix = "webp" },
        { data = webp("VP8L", 600, 800), suffix = "webp" },
    }
    for _, fixture in ipairs(fixtures) do
        if covers["/reader/article.html"] then removeCover("/reader/article.html") end
        reply = { body = fixture.data, mime = "image/png" }
        eq(sync(), "installed")
        eq(installed.suffix, fixture.suffix)
    end
end)
test("requests ask for formats KOReader renders and use KOReader's timeout sink", function()
    sync()
    eq(request.url, URL)
    eq(request.headers.Accept, "image/webp,image/png,image/jpeg,image/gif")
    eq(request.headers.Authorization, nil)
    eq(timeouts[1], 5)
    eq(timeouts[2], 15)
    eq(sinks, 1)
end)
test("existing custom covers, including manual ones, are kept without a request", function()
    existing = "/reader/article.sdr/cover.jpg"
    eq(sync(), "exists")
    eq(calls, 0)
    eq(installed, nil)
end)
test("missing or non-HTTP URLs are permanent and make no request", function()
    for _, url in ipairs({ "", "file:///secret", "data:image/png;base64,abc", {}, false }) do
        eq(Covers:sync("/reader/article.html", url), "permanent")
    end
    eq(Covers:sync("/reader/article.html", nil), "permanent")
    eq(calls, 0)
end)
test("HTTP errors are permanent, except ones the server may recover from", function()
    for _, code in ipairs({ 301, 403, 404, 410 }) do
        reply = { code = code }
        eq(sync(), "permanent")
    end
    for _, code in ipairs({ 408, 429, 500, 503 }) do
        reply = { code = code }
        eq(sync(), "temporary")
    end
    eq(installed, nil)
end)
test("no response is offline: exceptions, network errors and the total timeout", function()
    for _, fixture in ipairs({ { throw = true }, { network_error = "timeout" }, { network_error = "sink timeout" } }) do
        reply = fixture
        eq(sync(), "offline")
    end
    eq(installed, nil)
end)
test("empty, non-image, unreadable and corrupt responses are permanent", function()
    local bodies = { "", "<html>error</html>", "\137PNG\r\n\26\n", "\255\216\255\217", png(600, 800) .. "corrupt" }
    for _, body in ipairs(bodies) do
        reply = { body = body }
        eq(sync(), "permanent")
    end
    eq(installed, nil)
    eq(#events, 0)
end)
test("images too small or with too many pixels are refused before decoding", function()
    for _, body in ipairs({ png(199, 800), jpeg(800, 150), gif(32, 32), png(2001, 2000), webp("VP8X", 4000, 3000) }) do
        reply = { body = body }
        eq(sync(), "permanent")
    end
    eq(rendered, 0)
    for _, body in ipairs({ png(200, 200), png(2000, 2000) }) do
        if covers["/reader/article.html"] then removeCover("/reader/article.html") end
        reply = { body = body }
        eq(sync(), "installed")
    end
end)
test("covers over 2 MB are stopped while receiving; over 1 MB they are installed and logged", function()
    reply = { chunks = { cover, string.rep("x", 2 * 1024 * 1024) } }
    eq(sync(), "permanent")
    eq(installed, nil)
    eq(rendered, 0)
    reply = { body = cover .. string.rep("x", 1536 * 1024) }
    eq(sync(), "installed")
    assert(warnings[#warnings]:find("large cover", 1, true), warnings[#warnings])
end)
test("failed or incomplete installs are temporary, cleaned up, and invalidate nothing", function()
    reply = { save_ok = false }
    eq(sync(), "temporary")
    reply = { partial_copy = true }
    eq(sync(), "temporary")
    eq(io.open(covers["/reader/article.html"], "rb"), nil)
    eq(#events, 0)
    reply = {}
    eq(sync(), "installed")
end)
test("every failure is logged with its reason and URL", function()
    reply = { code = 404 }
    sync()
    eq(#warnings, 1)
    assert(warnings[1]:find("HTTP 404", 1, true) and warnings[1]:find(URL, 1, true), warnings[1])
end)

-- Load the actual plugin with lightweight KOReader UI boundaries.
local object = {}
function object:extend(value) return setmetatable(value or {}, { __index = self }) end
function object:new(value) return self:extend(value) end
local empty_modules = {
    "ui/bidi", "dispatcher", "ffi/util", "apps/filemanager/filemanager",
    "ui/widget/inputdialog", "luasettings", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
    "readcollection", "clip", "ui/network/manager", "readhistory", "device",
    "apps/filemanager/filemanagerutil", "ltn12", "mime", "socket",
    "json", "rapidjson",
}
for _, name in ipairs(empty_modules) do package.preload[name] = function() return {} end end
package.preload["ui/widget/container/widgetcontainer"] = function() return object end
package.preload["ui/widget/infomessage"] = function() return object end
package.preload.gettext = function() return function(s) return s end end
package.preload.util = function() return { getSafeFilename = function(title) return title end } end
local ui = require("ui/uimanager")
local messages = {}
ui.show = function(_, info) messages[#messages + 1] = info.text end
ui.close = noop
package.path = "readwisereader.koplugin/?.lua;" .. package.path
local Reader = dofile("readwisereader.koplugin/main.lua")

local function doc(n)
    return { id = "doc-" .. n, title = "Article " .. n, image_url = "https://example.com/cover-" .. n,
        html_content = "Article body" }
end
local function pathOf(n) return "/reader/doc-" .. n .. ".html" end
-- local_paths: Readwise id -> file, the articles already on the device.
local function readerFor(documents, local_paths, fields)
    local reader = Reader:new{
        download_covers = true, covers_failed = {},
        localDocumentPaths = function() return local_paths end,
        documentExists = function(_, id) return local_paths[id] ~= nil end,
        shouldSkipDocument = function() return false end,
        validateSettings = function() return true end,
        api = { resetRateLimit = noop },
        cleanupArchivedDocuments = function() return 0 end,
        reconcileLocalDocuments = function() return 0 end,
        getDocumentList = function() return documents end,
        updateAvailableTags = noop, showProgress = noop, hideProgress = noop,
        saveSettings = noop, initCollectionTracking = noop, saveCollections = noop,
        storeAuthorMetadata = noop, storeSourceUrlMetadata = noop,
        setDocumentMetadata = noop, updateDocumentCollections = noop,
        processHtmlContent = function(_, content) return content end,
    }
    for key, value in pairs(fields or {}) do reader[key] = value end
    return reader
end
local function lastMessage() return messages[#messages] end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

test("with covers off, sync downloads and stores nothing", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) }, { download_covers = false })
    reader:synchronize()
    eq(calls, 0)
    eq(reader.covers_pending, nil)
end)
test("the first sync with covers on adds covers to earlier articles without rewriting them", function()
    local file = os.tmpname()
    local f = assert(io.open(file, "wb")); f:write("existing annotations depend on this HTML"); f:close()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = file })
    reader:synchronize()
    eq(installed and installed.path, file)
    f = assert(io.open(file, "rb")); eq(f:read("*a"), "existing annotations depend on this HTML"); f:close()
    os.remove(file)
    assert(lastMessage():find("Covers added: 1", 1, true), lastMessage())
    eq(next(reader.covers_pending), nil)
end)
test("earlier articles are queued once, so a removed cover is not downloaded again", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) })
    reader:synchronize()
    eq(calls, 1)
    removeCover(pathOf(1))
    reader:synchronize()
    eq(calls, 1)
    assert(lastMessage():find("No new articles found", 1, true), lastMessage())
end)
test("articles that already have a cover or have no image are not queued", function()
    covers[pathOf(1)] = os.tmpname()
    local no_image = doc(2)
    no_image.image_url = nil
    local reader = readerFor({ doc(1), no_image }, { ["doc-1"] = pathOf(1), ["doc-2"] = pathOf(2) })
    reader:synchronize()
    eq(calls, 0)
    eq(next(reader.covers_pending), nil)
end)
test("an open article is skipped and keeps its place for a later sync", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) }, { ui = { document = { file = pathOf(1) } } })
    reader:synchronize()
    eq(calls, 0)
    eq(reader.covers_pending["doc-1"], true)
    reader.ui = {}
    reader:synchronize()
    eq(calls, 1)
end)
test("the time budget stops covers of earlier articles; the rest wait", function()
    local real_time, now = os.time, 0
    os.time = function() now = now + 20; return now end -- luacheck: ignore
    local reader = readerFor({ doc(1), doc(2), doc(3) },
        { ["doc-1"] = pathOf(1), ["doc-2"] = pathOf(2), ["doc-3"] = pathOf(3) })
    local ok, err = pcall(reader.synchronize, reader)
    os.time = real_time -- luacheck: ignore
    assert(ok, err)
    eq(calls, 1)
    eq(reader.covers_pending["doc-2"], true)
    eq(reader.covers_pending["doc-3"], true)
end)
test("temporary failures wait for the manual retry instead of being retried", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) })
    reply = { code = 503 }
    reader:synchronize()
    eq(reader.covers_failed["doc-1"], true)
    eq(next(reader.covers_pending), nil)
    assert(lastMessage():find("Covers failed: 1", 1, true), lastMessage())
    reader:synchronize()
    eq(calls, 1)
    eq(reader:retryFailedCovers(), 1)
    eq(next(reader.covers_failed), nil)
    reply = {}
    reader:synchronize()
    eq(calls, 2)
    eq(installed and installed.path, pathOf(1))
end)
test("permanent failures are not recorded or retried", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) })
    reply = { code = 404 }
    reader:synchronize()
    eq(next(reader.covers_failed), nil)
    eq(next(reader.covers_pending), nil)
    reader:synchronize()
    eq(calls, 1)
end)
test("three network errors in a row stop cover downloads for the sync", function()
    local documents, local_paths = {}, {}
    for n = 1, 5 do
        documents[n] = doc(n)
        local_paths["doc-" .. n] = pathOf(n)
    end
    local reader = readerFor(documents, local_paths)
    reply = { throw = true }
    reader:synchronize()
    eq(calls, 3)
    eq(count(reader.covers_failed), 3)
    eq(reader.covers_pending["doc-4"], true)
    eq(reader.covers_pending["doc-5"], true)
end)
test("a pending article missing from this sync's list waits without blocking 'no changes'", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1), ["doc-9"] = pathOf(9) }, {
        covers_pending = { ["doc-9"] = true },
    })
    reader:synchronize()
    eq(calls, 0)
    eq(reader.covers_pending["doc-9"], true)
    assert(lastMessage():find("No new articles found", 1, true), lastMessage())
end)
test("articles no longer on the device are dropped from both lists", function()
    local reader = readerFor({ doc(1) }, { ["doc-1"] = pathOf(1) }, {
        covers_pending = { gone = true, ["doc-1"] = true },
        covers_failed = { ["also-gone"] = true },
    })
    reader:startCoverSync({ doc(1) }, { ["doc-1"] = pathOf(1) })
    eq(reader.covers_pending.gone, nil)
    eq(reader.covers_pending["doc-1"], true)
    eq(next(reader.covers_failed), nil)
end)
local function downloadNew(fields, run)
    local dir = os.tmpname()
    os.remove(dir)
    -- Use a unique filename prefix rather than creating a directory.
    local reader = readerFor({}, {}, fields)
    reader.directory = dir
    reader.covers_pending = {}
    local result = reader:downloadDocument(doc(1), run)
    local path = dir .. "[rw-id_doc-1] Article 1.html"
    local f = assert(io.open(path, "rb")); eq(f:read("*a"), "Article body"); f:close()
    os.remove(path)
    return result, path, reader
end
test("new article downloads save HTML and get their cover once", function()
    local run = { added = 0, failed = 0, network_errors = 0 }
    local result, path, reader = downloadNew(nil, run)
    eq(result, "downloaded")
    eq(installed and installed.path, path)
    eq(run.added, 1)
    eq(next(reader.covers_failed), nil)
end)
test("cover errors do not fail an article download", function()
    reply = { throw = true }
    local result, _, reader = downloadNew(nil, { added = 0, failed = 0, network_errors = 0 })
    eq(result, "downloaded")
    eq(installed, nil)
    eq(reader.covers_failed["doc-1"], true)
end)
test("after three network errors, new articles' covers wait in the pending list", function()
    local result, _, reader = downloadNew(nil, { added = 0, failed = 0, network_errors = 3 })
    eq(result, "downloaded")
    eq(calls, 0)
    eq(reader.covers_pending["doc-1"], true)
end)
test("with covers off, new article downloads make no cover request", function()
    eq(downloadNew({ download_covers = false }, nil), "downloaded")
    eq(calls, 0)
end)
test("downloadDocument skips articles already on the device without fetching a cover", function()
    local reader = readerFor({}, { ["doc-1"] = pathOf(1) })
    eq(reader:downloadDocument(doc(1), { added = 0, failed = 0, network_errors = 0 }), "skipped")
    eq(calls, 0)
end)
test("settings keep an empty pending list but no empty failed list", function()
    local saved
    local reader = readerFor({}, {}, {
        covers_pending = {}, covers_failed = {},
        readwise_settings = { saveSetting = function(_, _, value) saved = value end, flush = noop },
    })
    reader.saveSettings = nil -- use the real one
    reader:saveSettings()
    eq(type(saved.covers_pending), "table")
    eq(saved.covers_failed, nil)
    eq(saved.download_covers, true)
    reader.covers_failed = { ["doc-1"] = true }
    reader:saveSettings()
    eq(saved.covers_failed["doc-1"], true)
end)
print(string.format("%d cover tests passed", passed))
