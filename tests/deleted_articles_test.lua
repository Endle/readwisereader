-- Run from the repo root: luajit tests/deleted_articles_test.lua
-- KOReader and the Reader API are stubbed; article files in temporary folders are real.
-- Every sync runs on a new plugin instance, so the record must survive saved settings.
local function eq(actual, expected)
    assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local function contains(actual, expected)
    assert(actual and actual:find(expected, 1, true), tostring(actual))
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

local function noop() end
local object = {}
function object:extend(value) return setmetatable(value or {}, { __index = self }) end
function object:new(value) return self:extend(value) end

local stored, messages, statuses, picker, confirm
local settings = {}
function settings:readSetting(key) return copy(stored[key]) end
function settings:saveSetting(key, value) stored[key] = copy(value) end
function settings:flush() end

local modules = {
    logger = { dbg = noop, warn = noop, err = noop },
    datastorage = { getSettingsDir = function() return "/settings" end },
    dispatcher = { registerAction = noop },
    luasettings = { open = function() return settings end },
    docsettings = {
        hasSidecarFile = function(_, path) return statuses[path] ~= nil end,
        open = function(_, path)
            return { readSetting = function() return { status = statuses[path] } end }
        end,
    },
    ["apps/filemanager/filemanager"] = {
        deleteFile = function(_, path) return os.remove(path) end,
    },
    ["libs/libkoreader-lfs"] = {
        dir = function(folder)
            local pipe = assert(io.popen("ls -1 '" .. folder .. "'"))
            local names = {}
            for name in pipe:lines() do names[#names + 1] = name end
            pipe:close()
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        attributes = function() return "file" end,
    },
    ["ui/widget/container/widgetcontainer"] = object,
    ["ui/widget/infomessage"] = object,
    ["ui/uimanager"] = {
        show = function(_, widget) messages[#messages + 1] = widget.text end,
        close = noop,
    },
    ["ui/downloadmgr"] = {
        new = function(_, value)
            picker = value
            return { chooseDir = noop }
        end,
    },
    ["ui/widget/confirmbox"] = {
        new = function(_, value)
            confirm = value
            return value
        end,
    },
    clip = object,
    device = { isKindle = function() return false end },
    util = {
        splitFilePathName = function(path) return path:match("^(.-)([^/]+)$") end,
        getSafeFilename = function(title) return title end,
    },
    gettext = function(s) return s end,
}
local unused = {
    "ui/bidi", "ui/event", "ffi/util", "ui/widget/inputdialog",
    "ui/widget/multiconfirmbox", "readcollection", "ui/network/manager", "readhistory",
    "apps/filemanager/filemanagerutil", "socket.http", "ltn12", "mime", "socket",
    "socketutil", "json", "rapidjson", "ui/renderimage",
}
for _, name in ipairs(unused) do modules[name] = {} end
for name, module in pairs(modules) do
    package.preload[name] = function() return module end
end
package.path = "readwisereader.koplugin/?.lua;" .. package.path
local Reader = dofile("readwisereader.koplugin/main.lua")

local function article(id)
    return { id = id, title = "Article " .. id, html_content = "Body of " .. id,
        reading_progress = 0, location = "new" }
end

-- The server: `listed` is the Inbox, the only list with articles, in order.
local listed, archived
local function serverAPI(_, method, endpoint)
    if method == "PATCH" then
        local id = endpoint:match("^/update/(.-)/$")
        for index, doc in ipairs(listed) do
            if doc.id == id then
                archived[#archived + 1] = table.remove(listed, index)
                break
            end
        end
        return {}
    end
    if endpoint:find("location=new", 1, true) then return { results = listed } end
    if endpoint:find("location=archive", 1, true) then return { results = archived } end
    return { results = {} }
end

local function newReader()
    local reader = Reader:new{
        ui = { menu = { registerToMainMenu = noop } },
        showProgress = noop, hideProgress = noop,
        -- These only decorate the article; the file itself is written for real.
        processHtmlContent = function(_, content) return content end,
        setDocumentMetadata = noop, updateDocumentCollections = noop,
        initCollectionTracking = noop, saveCollections = noop, removeFromAllCollections = noop,
    }
    reader:init()
    reader.callAPI = serverAPI
    reader.validateSettings = function() return true end
    return reader
end

local function sync()
    newReader():synchronize()
    return messages[#messages]
end

local function makeFolder()
    local folder = os.tmpname()
    os.remove(folder)
    -- os.execute returns 0 or true, depending on how LuaJIT was built.
    local status = os.execute("mkdir '" .. folder .. "'")
    assert(status == 0 or status == true)
    return folder .. "/"
end

local folder, other_folder

local function pathOf(id, in_folder)
    return (in_folder or folder) .. "[rw-id_" .. id .. "] Article " .. id .. ".html"
end

local function onDevice(id, in_folder)
    local file = io.open(pathOf(id, in_folder), "rb")
    if file then file:close() end
    return file ~= nil
end

local function deleteOnDevice(id)
    assert(os.remove(pathOf(id)))
end

local function advancedSyncItem(text)
    local menu = {}
    newReader():addToMainMenu(menu)
    for _, item in ipairs(menu.readwisereader.sub_item_table) do
        if item.text == "Advanced sync" then
            for _, sub_item in ipairs(item.sub_item_table) do
                if sub_item.text == text then return sub_item end
            end
        end
    end
    error("no Advanced sync item: " .. text)
end

local passed = 0
local function test(name, run)
    folder, other_folder = makeFolder(), makeFolder()
    stored = { readwisereader = { access_token = "test-token", directory = folder } }
    messages, statuses, listed, archived, picker, confirm = {}, {}, {}, {}, nil, nil
    local ok, err = pcall(run)
    os.execute("rm -rf '" .. folder .. "' '" .. other_folder .. "'")
    if not ok then error(name .. ": " .. tostring(err)) end
    passed = passed + 1
    print("ok - " .. name)
end

test("a fresh article downloads once and stays on the device", function()
    listed = { article("a") }
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
    contains(sync(), "No new articles found")
    assert(onDevice("a"))
end)

test("an article deleted on the device is not downloaded again", function()
    listed = { article("a"), article("b") }
    sync()
    deleteOnDevice("a")
    local message = sync()
    assert(not onDevice("a"))
    assert(onDevice("b"))
    -- The usual case after a delete: nothing else changed, so this is the short message.
    contains(message, "No new articles found")
    contains(message, "Skipped 1 existing articles.")
    contains(message, "Not downloaded (deleted on this device): 1")
    assert(not onDevice("a"))
end)

test("the full summary keeps its lines and adds the deleted count", function()
    listed = { article("a"), article("b") }
    sync()
    deleteOnDevice("a")
    listed[#listed + 1] = article("c")
    local message = sync()
    assert(onDevice("c"))
    contains(message, "Sync complete:")
    contains(message, "Downloaded: 1")
    contains(message, "Skipped (already exists): 1")
    contains(message, "Not downloaded (deleted on this device): 1")
end)

test("nothing is reported when no article was deleted", function()
    listed = { article("a") }
    assert(not sync():find("deleted on this device", 1, true))
    assert(not sync():find("deleted on this device", 1, true))
end)

test("after an upgrade, articles on disk are recorded and missing ones are fresh", function()
    -- Settings written by an earlier version have no record.
    local file = assert(io.open(pathOf("a"), "wb"))
    file:write("Body of a")
    file:close()
    listed = { article("a"), article("b") }
    eq(stored.readwisereader.downloaded_documents, nil)
    contains(sync(), "Downloaded: 1")
    assert(onDevice("b"))
    deleteOnDevice("a")
    contains(sync(), "Not downloaded (deleted on this device): 1")
    assert(not onDevice("a"))
end)

test("a failed save is not recorded, so the article is tried again", function()
    local doc = article("a")
    doc.title = "no/such/folder"
    listed = { doc }
    contains(sync(), "Failed: 1")
    eq(stored.readwisereader.downloaded_documents.a, nil)
    doc.title = "Article a"
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

test("deleted articles do not use up the per-sync limit", function()
    stored.readwisereader.max_articles_to_download = 2
    listed = { article("a"), article("b"), article("c"), article("d") }
    sync()
    assert(onDevice("a") and onDevice("b"))
    assert(not onDevice("c") and not onDevice("d"))
    deleteOnDevice("a")
    deleteOnDevice("b")
    contains(sync(), "Not downloaded (deleted on this device): 2")
    assert(onDevice("c") and onDevice("d"))
    assert(not onDevice("a") and not onDevice("b"))
end)

test("a finished article archived by the plugin can download again", function()
    listed = { article("a") }
    sync()
    statuses[pathOf("a")] = "complete"
    contains(sync(), "Archived in Readwise: 1")
    assert(not onDevice("a"))
    statuses = {}
    listed, archived = archived, {}
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

test("an article archived in Reader and removed by cleanup can download again", function()
    listed = { article("a") }
    sync()
    listed, archived = {}, listed
    contains(sync(), "Cleaned up archived: 1")
    assert(not onDevice("a"))
    listed, archived = archived, {}
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

test("an article reconciled away by the plugin can download again", function()
    local doc = article("a")
    listed = { doc }
    sync()
    listed = {}
    contains(sync(), "Removed (no longer on server): 1")
    assert(not onDevice("a"))
    listed = { doc }
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

-- Unticking a tag or location in "Include in sync" removes its articles. Those were
-- removed by the plugin, so they come back when it is ticked again.
test("an article removed for an excluded tag comes back when the tag is included", function()
    local doc = article("a")
    doc.tags = { t1 = { name = "news" } }
    listed = { doc }
    sync()
    newReader():toggleTagExclusion("news")
    assert(not onDevice("a"))
    -- Two syncs, because an excluded article is only skipped early every other sync.
    for _ = 1, 2 do
        assert(not sync():find("deleted on this device", 1, true))
    end
    assert(not onDevice("a"))
    newReader():toggleTagExclusion("news")
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

test("an article removed for an excluded location comes back when it is included", function()
    listed = { article("a") }
    sync()
    newReader():toggleLocationExclusion("new")
    confirm.ok_callback()
    assert(not onDevice("a"))
    assert(not sync():find("deleted on this device", 1, true))
    newReader():toggleLocationExclusion("new")
    contains(sync(), "Downloaded: 1")
    assert(onDevice("a"))
end)

test("Re-download deleted articles brings them back at the next sync", function()
    listed = { article("a"), article("b") }
    sync()
    deleteOnDevice("a")
    sync()
    assert(not onDevice("a"))
    advancedSyncItem("Re-download deleted articles").callback()
    contains(messages[#messages], "will be downloaded at the next sync")
    assert(not onDevice("a"))
    local message = sync()
    contains(message, "Downloaded: 1")
    contains(message, "Skipped (already exists): 1")
    assert(onDevice("a") and onDevice("b"))
    -- Articles on disk are recorded again, so deleting one still sticks.
    deleteOnDevice("b")
    contains(sync(), "Not downloaded (deleted on this device): 1")
    assert(not onDevice("b"))
end)

test("changing the download folder downloads the articles there", function()
    listed = { article("a"), article("b") }
    sync()
    deleteOnDevice("a")
    newReader():setDownloadDirectory()
    picker.onConfirm(other_folder)
    eq(stored.readwisereader.directory, other_folder)
    local message = sync()
    contains(message, "Downloaded: 2")
    assert(not message:find("deleted on this device", 1, true))
    assert(onDevice("a", other_folder) and onDevice("b", other_folder))
end)

test("a temporarily empty folder downloads nothing and recovers", function()
    -- Such as an SD card that is not mounted.
    listed = { article("a") }
    sync()
    local aside = other_folder .. "aside.html"
    assert(os.rename(pathOf("a"), aside))
    contains(sync(), "Not downloaded (deleted on this device): 1")
    assert(not onDevice("a"))
    assert(os.rename(aside, pathOf("a")))
    local message = sync()
    contains(message, "Skipped 1 existing articles.")
    assert(not message:find("deleted on this device", 1, true))
end)

print(string.format("%d deleted article tests passed", passed))
