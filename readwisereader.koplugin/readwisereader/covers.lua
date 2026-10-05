-- Reader covers are KOReader custom covers, separate from the article HTML.
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local logger = require("logger")
local socketutil = require("socketutil")

local Covers = {}

-- URLs and Content-Type headers may not describe the actual image format.
local function imageSuffix(data)
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return "gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
end

-- Best effort: never prevent an article from syncing because its cover failed.
-- Existing custom covers are left alone, including manually chosen ones.
function Covers:sync(filepath, url, enabled, max_size_mb)
    if not enabled or type(url) ~= "string" or not url:match("^https?://") then return false end
    local temporary
    local ok, saved = pcall(function()
        if DocSettings:findCustomCoverFile(filepath) then return false end
        local chunks, size = {}, 0
        local limit = max_size_mb * 1024 * 1024
        local request = {
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader Readwise Plugin)",
                ["Accept"] = "image/*",
            },
            sink = function(chunk)
                if chunk then
                    size = size + #chunk
                    if size > limit then return nil, "cover exceeds size limit" end
                    chunks[#chunks + 1] = chunk
                end
                return 1
            end,
        }
        socketutil:set_timeout(8, 45)
        local transport_ok, result, code = pcall(http.request, request)
        socketutil:reset_timeout()
        if not transport_ok or not result or code ~= 200 or size == 0 or size > limit then return false end
        local data = table.concat(chunks)
        local suffix = imageSuffix(data)
        if not suffix then return false end
        -- Reject corrupt images before making them the document's custom cover.
        local image = RenderImage:renderImageData(data, #data, false, 600, 800)
        if not image then return false end
        image:free()

        -- Use KOReader's writable settings directory: /tmp is unavailable on
        -- some devices. Sync runs sequentially, so only one cover uses this file.
        temporary = DataStorage:getSettingsDir() .. "/readwisereader-cover.tmp." .. suffix
        local file = io.open(temporary, "wb")
        if not file then return false end
        local written = file:write(data)
        local closed = file:close()
        if not written or not closed then return false end
        if not DocSettings:flushCustomCover(filepath, temporary) then return false end
        -- KOReader's copy helper may miss a write failure on full storage.
        -- Remove only the cover we just created, allowing a later sync to retry.
        local installed = DocSettings:findCustomCoverFile(filepath)
        local cover = installed and io.open(installed, "rb")
        local installed_data
        if cover then
            installed_data = cover:read(#data + 1)
            cover:close()
        end
        if installed_data ~= data then
            if installed then os.remove(installed) end
            return false
        end
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", filepath))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
        return true
    end)
    if temporary then os.remove(temporary) end
    if not ok then logger.warn("ReadwiseReader: cover download failed:", saved) end
    return ok and saved or false
end

return Covers
