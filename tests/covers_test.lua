-- Run from the repo root: luajit tests/covers_test.lua
-- Network and KOReader are external boundaries; temporary cover files are real.
local function eq(actual, expected)
    assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end
local png = "\137PNG\r\n\26\nfixture"
local jpeg = "\255\216\255fixture"
local gif = "GIF89afixture"
local webp = "RIFFxxxxWEBPfixture"
local calls, reply, installed, existing, timeout, freed, events, temporary, saved_path
local function noop() end
package.preload.datastorage = function() return {
    getSettingsDir = function() return os.getenv("TMPDIR") or "/tmp" end,
} end
package.preload.logger = function() return { warn = noop, dbg = noop } end
package.preload.docsettings = function() return {
    findCustomCoverFile = function()
        if existing then return existing end
        if saved_path then
            local f = io.open(saved_path, "rb")
            if f then f:close(); return saved_path end
        end
    end,
    flushCustomCover = function(_, path, file)
        local f = assert(io.open(file, "rb"))
        installed = { path = path, bytes = f:read("*a"), suffix = file:match("%.([^.]*)$") }
        f:close()
        temporary = file
        if reply.save_ok == false then return false end
        saved_path = os.tmpname()
        f = assert(io.open(saved_path, "wb"))
        f:write(reply.partial_copy and installed.bytes:sub(1, 8) or installed.bytes)
        f:close()
        return true
    end,
} end
package.preload["socket.http"] = function() return { request = function(request)
    calls = calls + 1
    eq(request.url, "https://example.com/cover?size=large")
    eq(request.headers.Authorization, nil)
    if reply.throw then error("offline") end
    for _, chunk in ipairs(reply.chunks or { reply.body or png }) do
        local ok = request.sink(chunk)
        if not ok then return nil, "sink rejected body" end
    end
    request.sink(nil)
    return 1, reply.code or 200, { ["content-type"] = reply.mime or "application/octet-stream" }
end } end
package.preload.socketutil = function() return {
    set_timeout = function() timeout = timeout + 1 end,
    reset_timeout = function() timeout = timeout - 1 end,
} end
package.preload["ui/renderimage"] = function() return {
    renderImageData = function(_, data, size, frames, width, height)
        eq(size, #data)
        eq(frames, false)
        assert(width and height, "validation should bound rendered dimensions")
        if data ~= png and data ~= jpeg and data ~= gif and data ~= webp then return nil end
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
    calls, timeout, freed = 0, 0, 0
    reply, events = {}, {}
    installed, existing, temporary, saved_path = nil, nil, nil, nil
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err)) end
    eq(timeout, 0)
    if temporary then eq(io.open(temporary, "rb"), nil) end
    if saved_path then os.remove(saved_path) end
    passed = passed + 1
    print("ok - " .. name)
end
local function sync(url, enabled, limit)
    return Covers:sync("/reader/article.html", url or "https://example.com/cover?size=large", enabled ~= false, limit or 10)
end

test("Reader image becomes a custom cover and invalidates cached metadata", function()
    assert(sync())
    eq(installed.path, "/reader/article.html")
    eq(installed.bytes, png)
    eq(installed.suffix, "png")
    eq(freed, 1)
    eq(events[1].name, "InvalidateMetadataCache")
    eq(events[1].path, "/reader/article.html")
    eq(events[2].name, "BookMetadataChanged")
end)
test("image bytes determine the extension even with misleading headers", function()
    reply = { body = jpeg, mime = "image/png" }
    assert(sync())
    eq(installed.suffix, "jpg")
end)
test("GIF and WebP covers use extensions KOReader can open", function()
    for _, fixture in ipairs({ { data = gif, suffix = "gif" }, { data = webp, suffix = "webp" } }) do
        if saved_path then os.remove(saved_path) end
        reply = { body = fixture.data }
        assert(sync())
        eq(installed.suffix, fixture.suffix)
    end
end)
test("manual and previously downloaded custom covers are preserved", function()
    existing = "/reader/article.sdr/cover.jpg"
    eq(sync(), false)
    eq(calls, 0)
    eq(installed, nil)
end)
test("disabled image downloads and missing or invalid URLs do not fetch", function()
    eq(sync(nil, false), false)
    for _, url in ipairs({ "", "file:///secret", "data:image/png;base64,abc", {}, false }) do
        eq(Covers:sync("/reader/article.html", url, true, 10), false)
    end
    eq(Covers:sync("/reader/article.html", nil, true, 10), false)
    eq(calls, 0)
end)
test("empty, HTTP error and corrupt image responses leave the cover unset", function()
    for _, fixture in ipairs({ { body = "" }, { code = 404 }, { body = "<html>error</html>" }, { body = "\137PNG\r\n\26\ncorrupt" } }) do
        reply = fixture
        eq(sync(), false)
        eq(installed, nil)
    end
    eq(#events, 0)
end)
test("oversized bodies are stopped while receiving rather than saved", function()
    reply = { chunks = { png, string.rep("x", 1024 * 1024) } }
    eq(sync(nil, true, 1), false)
    eq(installed, nil)
    eq(freed, 0)
end)
test("transport exceptions reset timeouts and allow a later retry", function()
    reply = { throw = true }
    eq(sync(), false)
    eq(timeout, 0)
    reply = {}
    assert(sync())
end)
test("failed installation cleans temporary files and does not invalidate caches", function()
    reply = { save_ok = false }
    eq(sync(), false)
    eq(#events, 0)
end)
test("partial sidecar copies are removed so the next sync can retry", function()
    reply = { partial_copy = true }
    eq(sync(), false)
    eq(io.open(saved_path, "rb"), nil)
    eq(#events, 0)
    reply = {}
    assert(sync())
    eq(calls, 2)
end)
test("a downloaded cover persists and is not fetched again", function()
    assert(sync())
    local f = assert(io.open(saved_path, "rb"))
    eq(f:read("*a"), png)
    f:close()
    eq(sync(), false)
    eq(calls, 1)
end)

-- Load the actual plugin with lightweight KOReader UI boundaries.
local object = {}
function object:extend(value) return setmetatable(value or {}, { __index = self }) end
function object:new(value) return self:extend(value) end
local empty_modules = {
    "ui/bidi", "dispatcher", "ffi/util", "apps/filemanager/filemanager",
    "ui/widget/inputdialog", "luasettings", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
    "readcollection", "clip", "ui/network/manager", "readhistory", "device",
    "apps/filemanager/filemanagerutil", "libs/libkoreader-lfs", "ltn12", "mime", "socket",
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
local function readerFor(document, filepath)
    return Reader:new{
        download_images = true, max_image_size_mb = 10,
        findLocalDocumentByReadwiseId = function() return filepath end,
        shouldSkipDocument = function() return false end,
        validateSettings = function() return true end,
        api = { resetRateLimit = noop },
        cleanupArchivedDocuments = function() return 0 end,
        reconcileLocalDocuments = function() return 0 end,
        getDocumentList = function() return { document } end,
        updateAvailableTags = noop, showProgress = noop, hideProgress = noop,
        saveSettings = noop, initCollectionTracking = noop, saveCollections = noop,
        storeAuthorMetadata = noop, storeSourceUrlMetadata = noop,
        setDocumentMetadata = noop, updateDocumentCollections = noop,
    }
end
local document = { id = "doc-1", title = "Article", image_url = "https://example.com/cover?size=large", html_content = "Article body" }
test("sync fills an existing article's missing cover without rewriting its HTML", function()
    local file = os.tmpname()
    local f = assert(io.open(file, "wb")); f:write("existing annotations depend on this HTML"); f:close()
    local reader = readerFor(document, file)
    reader:synchronize()
    eq(installed and installed.path, file)
    f = assert(io.open(file, "rb")); eq(f:read("*a"), "existing annotations depend on this HTML"); f:close()
    os.remove(file)
    assert(messages[#messages]:find("Covers downloaded: 1", 1, true), messages[#messages])
end)
test("new article downloads save HTML and a Reader cover", function()
    local dir = os.tmpname()
    os.remove(dir)
    -- Use a unique filename prefix rather than creating a directory.
    local reader = readerFor(document)
    reader.directory = dir
    reader.processHtmlContent = function(_, content) return content end
    eq(reader:downloadDocument(document), "downloaded")
    local path = dir .. "[rw-id_doc-1] Article.html"
    eq(installed and installed.path, path)
    local f = assert(io.open(path, "rb")); eq(f:read("*a"), "Article body"); f:close()
    os.remove(path)
end)
test("cover errors do not fail an article download", function()
    local dir = os.tmpname()
    os.remove(dir)
    local reader = readerFor(document)
    reader.directory = dir
    reader.processHtmlContent = function(_, content) return content end
    reply = { throw = true }
    eq(reader:downloadDocument(document), "downloaded")
    eq(installed, nil)
    os.remove(dir .. "[rw-id_doc-1] Article.html")
end)
print(string.format("%d cover tests passed", passed))
