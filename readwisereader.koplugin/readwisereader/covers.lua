-- Reader covers are KOReader custom covers, separate from the article HTML.
-- Covers:sync makes one attempt and reports how it went; the caller decides
-- what to remember, so this module keeps no state between calls.
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")

local Covers = {
    -- Covers above WARN_BYTES are installed but logged; above MAX_BYTES the
    -- download is stopped. Covers are shown at 600x800, so neither is needed.
    WARN_BYTES = 1024 * 1024,
    MAX_BYTES = 2 * 1024 * 1024,
    -- A smaller image makes a worse cover than KOReader's generated one, and a
    -- larger one is decoded at full size before scaling, which can exhaust memory.
    MIN_SIDE = 200,
    MAX_PIXELS = 4 * 1000 * 1000,
    -- Seconds: for each network wait, and for the whole download.
    BLOCK_TIMEOUT = 5,
    TOTAL_TIMEOUT = 15,
}

-- Covers:sync results:
--   "installed"  the cover was downloaded and set
--   "exists"     the article already has a custom cover, possibly chosen by hand
--   "permanent"  retrying cannot help: HTTP error, unsupported or rejected image
--   "temporary"  the server or this device may recover: 408, 429, 5xx, local write failure
--   "offline"    no HTTP response at all: network error or timeout

function Covers.isFetchable(url)
    return type(url) == "string" and url:match("^https?://") ~= nil
end

-- URLs and Content-Type headers may not describe the actual image format.
local function imageSuffix(data)
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return "gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
end

-- Unsigned integer of `count` bytes at `pos`, or nil past the end of data.
local function uint(data, pos, count, little_endian)
    if #data < pos + count - 1 then return nil end
    local value = 0
    for k = 0, count - 1 do
        value = value * 256 + data:byte(little_endian and pos + count - 1 - k or pos + k)
    end
    return value
end

local function jpegSize(data)
    local pos = 3 -- after the start-of-image marker
    while pos + 3 <= #data do
        if data:byte(pos) ~= 0xFF then return nil end
        local marker = data:byte(pos + 1)
        if marker == 0xFF then
            pos = pos + 1 -- fill byte
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
            pos = pos + 2 -- markers without a length
        elseif marker == 0xD9 or marker == 0xDA then
            return nil -- end of image or image data before any frame header
        elseif marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            -- start of frame: length, precision, height, width
            return uint(data, pos + 7, 2), uint(data, pos + 5, 2)
        else
            local length = uint(data, pos + 2, 2)
            if not length then return nil end
            pos = pos + 2 + length
        end
    end
end

-- Width and height from the image header, without decoding the image.
local function imageSize(data, suffix)
    if suffix == "png" then
        if data:sub(13, 16) ~= "IHDR" then return nil end
        return uint(data, 17, 4), uint(data, 21, 4)
    elseif suffix == "gif" then
        return uint(data, 7, 2, true), uint(data, 9, 2, true)
    elseif suffix == "jpg" then
        return jpegSize(data)
    end
    local chunk = data:sub(13, 16)
    if chunk == "VP8X" then
        local width, height = uint(data, 25, 3, true), uint(data, 28, 3, true)
        return width and width + 1, height and height + 1
    elseif chunk == "VP8 " then
        if data:sub(24, 26) ~= "\157\1\42" then return nil end
        local width, height = uint(data, 27, 2, true), uint(data, 29, 2, true)
        return width and width % 16384, height and height % 16384
    elseif chunk == "VP8L" then
        local bits = data:byte(21) == 0x2F and uint(data, 22, 4, true)
        if not bits then return nil end
        return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
    end
end

-- Returns the image bytes, or nil, a result and a reason.
local function download(url)
    local size, too_large = 0, false
    socketutil:set_timeout(Covers.BLOCK_TIMEOUT, Covers.TOTAL_TIMEOUT)
    -- LuaSocket restarts its own timeout for every chunk; this sink enforces the
    -- total timeout as data arrives.
    local sink, chunks = socketutil.table_sink({})
    local ok, result, code = pcall(http.request, {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader Readwise Plugin)",
            -- Formats KOReader renders. image/* lets some CDNs choose AVIF.
            ["Accept"] = "image/webp,image/png,image/jpeg,image/gif",
        },
        sink = function(chunk, err)
            if chunk then
                size = size + #chunk
                if size > Covers.MAX_BYTES then
                    too_large = true
                    return nil, "cover exceeds size limit"
                end
            end
            return sink(chunk, err)
        end,
    })
    socketutil:reset_timeout()

    if too_large then return nil, "permanent", "larger than 2 MB" end
    if not ok or not result then return nil, "offline", tostring(ok and code or result) end
    if code == 408 or code == 429 or (type(code) == "number" and code >= 500) then
        return nil, "temporary", "HTTP " .. code
    end
    if code ~= 200 then return nil, "permanent", "HTTP " .. tostring(code) end
    if size == 0 then return nil, "permanent", "empty response" end
    if size > Covers.WARN_BYTES then
        logger.warn("ReadwiseReader: large cover,", size, "bytes:", url)
    end
    return table.concat(chunks)
end

-- Returns the file suffix of a usable image, or nil and a reason.
local function check(data)
    local suffix = imageSuffix(data)
    if not suffix then return nil, "not a PNG, JPEG, GIF or WebP image" end
    local width, height = imageSize(data, suffix)
    if not width or not height then return nil, "unreadable image size" end
    if math.min(width, height) < Covers.MIN_SIDE then
        return nil, string.format("image too small (%dx%d)", width, height)
    end
    if width * height > Covers.MAX_PIXELS then
        return nil, string.format("image too large (%dx%d)", width, height)
    end
    -- Reject corrupt images before making them the document's custom cover.
    local image = RenderImage:renderImageData(data, #data, false, 600, 800)
    if not image then return nil, "image could not be decoded" end
    image:free()
    return suffix
end

-- Best effort: never prevent an article from syncing because its cover failed.
-- Existing custom covers are left alone, including manually chosen ones.
function Covers:sync(filepath, url)
    if not Covers.isFetchable(url) then return "permanent", "no image URL" end
    local temporary
    local ok, result, reason = pcall(function()
        if DocSettings:findCustomCoverFile(filepath) then return "exists" end
        local data, status, why = download(url)
        if not data then return status, why end
        local suffix
        suffix, why = check(data)
        if not suffix then return "permanent", why end

        -- Use KOReader's writable settings directory: /tmp is unavailable on
        -- some devices. Sync runs sequentially, so only one cover uses this file.
        temporary = DataStorage:getSettingsDir() .. "/readwisereader-cover.tmp." .. suffix
        local file = io.open(temporary, "wb")
        if not file then return "temporary", "cannot create temporary file" end
        local written = file:write(data)
        local closed = file:close()
        if not written or not closed then return "temporary", "cannot write temporary file" end
        if not DocSettings:flushCustomCover(filepath, temporary) then
            return "temporary", "cannot save cover"
        end
        -- KOReader's copy helper may miss a write failure on full storage.
        -- Remove only the cover we just created, so a retry starts clean.
        local installed = DocSettings:findCustomCoverFile(filepath)
        if not installed or lfs.attributes(installed, "size") ~= #data then
            if installed then os.remove(installed) end
            return "temporary", "incomplete cover copy"
        end
        -- The file browser is refreshed once at the end of the sync.
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", filepath))
        return "installed"
    end)
    if temporary then os.remove(temporary) end
    if not ok then
        result, reason = "temporary", tostring(result)
    end
    if result ~= "installed" and result ~= "exists" then
        logger.warn("ReadwiseReader: cover not set (" .. result .. "):", reason, url)
    end
    return result, reason
end

return Covers
