-- Highlight export rules, independent of KOReader widgets and file parsing.
local logger = require("logger")

local HighlightExporter = {}
HighlightExporter.__index = HighlightExporter

function HighlightExporter:new(options)
    return setmetatable({
        api = assert(options.api),
    }, self)
end

-- metadata is resolved by the caller from the local document identity.
function HighlightExporter:exportBook(booknotes, metadata)
    local highlights = {}
    local correct_author = metadata.author
    local source_url = metadata.source_url

    -- Fallback to booknotes.author if no stored metadata, but clean it up
    if not correct_author and booknotes.author and booknotes.author ~= "" then
        -- Check if the author looks like a filename (contains file extensions)
        if not booknotes.author:match("%.%w+$") and not booknotes.author:match("[/\\]") then
            correct_author = booknotes.author:gsub("\n", ", ")
        end
    end

    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            local highlight = {
                text = clipping.text,
                title = booknotes.title,
                author = correct_author,
                source_url = source_url,
                source_type = "koreader",
                category = "articles",
                note = clipping.note,
                location = clipping.page,
                location_type = "order",
                highlighted_at = os.date("!%Y-%m-%dT%TZ", clipping.time),
            }
            table.insert(highlights, highlight)
        end
    end

    local result, err = self.api:createReadwiseHighlights(highlights)

    if not result then
        logger.warn("HighlightExporter: error creating highlights", err)
        return false, err
    end
    return true
end

return HighlightExporter
