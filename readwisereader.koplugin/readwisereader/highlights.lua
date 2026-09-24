-- Highlight export rules, independent of KOReader widgets and file parsing.
-- history is the persisted document/passage map. save_history checkpoints each
-- successful create/update through the caller's settings storage.
local logger = require("logger")

local HighlightExporter = {}
HighlightExporter.__index = HighlightExporter

function HighlightExporter:new(options)
    return setmetatable({
        api = assert(options.api),
        history = assert(options.history),
        save_history = assert(options.save_history),
    }, self)
end

function HighlightExporter:createReaderHighlights(document_id, booknotes)
    local saved = self.history[document_id] or {}
    self.history[document_id] = saved

    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            local passage = clipping.text
            if type(passage) ~= "string" or not passage:find("%S") then
                return false, "Reader requires a non-empty text highlight."
            end
            local notes = clipping.note or ""
            local previous = saved[passage]
            local result, err, code
            if previous and previous.notes ~= notes then
                -- Editing a note must not create a second highlight. An empty
                -- string explicitly removes a previously exported note.
                result, err, code = self.api:requestReader("PATCH", "/update/" .. previous.id .. "/",
                    { notes = notes })
                if not result then
                    return false, string.format("Could not update highlight note (%s).", tostring(code or err))
                end
            elseif not previous then
                result, err, code = self.api:requestReader("POST", "/save/", {
                    parent_id = document_id,
                    content = passage,
                    notes = notes,
                    saved_using = "koreader",
                })
                if not result then
                    if code == 400 then
                        return false, "Reader rejected the highlight; its text may not match the original article."
                    end
                    return false, string.format("Could not create Reader highlight (%s).", tostring(code or err))
                end
                if type(result) ~= "table" or type(result.id) ~= "string" or result.id == "" then
                    return false, "Reader did not return a highlight ID."
                end
            end
            if result then
                saved[passage] = { id = previous and previous.id or result.id, notes = notes }
                -- Save each success immediately: a later failure must not cause
                -- already exported passages to be sent again on the next sync.
                self.save_history()
            end
        end
    end
    return true
end

-- metadata is resolved by the caller from the local document identity.
function HighlightExporter:exportBook(booknotes, metadata)
    local document_id = metadata.document_id
    if document_id and document_id ~= "" then
        return self:createReaderHighlights(document_id, booknotes)
    end

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
