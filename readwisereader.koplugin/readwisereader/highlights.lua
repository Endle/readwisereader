-- Highlight export rules, independent of KOReader widgets and file parsing.
-- history is the persisted document/passage map. save_history checkpoints each
-- successful create/update through the caller's settings storage.
local logger = require("logger")

local HighlightExporter = {}
HighlightExporter.__index = HighlightExporter

-- Reader answers 400 when a passage does not match its copy of the article, and
-- may answer 404 once the article is deleted. Retrying cannot fix either.
local REJECTED_BY_READER = { [400] = true, [404] = true }

function HighlightExporter:new(options)
    return setmetatable({
        api = assert(options.api),
        history = assert(options.history),
        save_history = assert(options.save_history),
    }, self)
end

local function bookClippings(booknotes)
    local clippings = {}
    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            clippings[#clippings + 1] = clipping
        end
    end
    return clippings
end

-- Reader records are { id, notes }. Passages Reader rejected are recorded as
-- { fallback = true, notes } and only ever go through the highlights API again.
function HighlightExporter:exportReaderBook(document_id, booknotes, metadata)
    local saved = self.history[document_id] or {}
    self.history[document_id] = saved
    local fallback, queued = {}, {}
    local failure

    local function record(passage, entry)
        saved[passage] = entry
        -- Save each success immediately: a later failure must not cause
        -- already exported passages to be sent again on the next sync.
        self.save_history()
    end

    for _, clipping in ipairs(bookClippings(booknotes)) do
        local passage = clipping.text
        local notes = clipping.note or ""
        local has_text = type(passage) == "string" and passage:find("%S") ~= nil
        local previous = has_text and saved[passage]
        if not has_text then
            -- e.g. an image selection; Reader has no passage to attach it to
            logger.warn("HighlightExporter: skipping highlight without text in", document_id)
        elseif queued[passage] or (previous and previous.notes == notes) then
            -- Already exported with this note, or a duplicate of a queued passage
            logger.dbg("HighlightExporter: passage unchanged in", document_id)
        elseif previous and previous.id then
            -- Editing a note must not create a second highlight. An empty
            -- string explicitly removes a previously exported note.
            local result, err, code = self.api:requestReader("PATCH", "/update/" .. previous.id .. "/",
                { notes = notes })
            if not result then
                failure = string.format("Could not update highlight note (%s).", tostring(code or err))
                break
            end
            record(passage, { id = previous.id, notes = notes })
        elseif previous then
            -- Rejected by Reader earlier. The highlights API matches the existing
            -- highlight by text, title, author and source URL, so this updates its note.
            fallback[#fallback + 1] = clipping
            queued[passage] = true
        else
            local result, err, code, body = self.api:requestReader("POST", "/save/", {
                parent_id = document_id,
                content = passage,
                notes = notes,
                saved_using = "koreader",
            })
            if result then
                if type(result) ~= "table" or type(result.id) ~= "string" or result.id == "" then
                    failure = "Reader did not return a highlight ID."
                    break
                end
                record(passage, { id = result.id, notes = notes })
            elseif REJECTED_BY_READER[code] then
                logger.warn("HighlightExporter: Reader rejected passage in", document_id, "with", code,
                    "response:", body, "passage:", passage)
                fallback[#fallback + 1] = clipping
                queued[passage] = true
            else
                failure = string.format("Could not create Reader highlight (%s).", tostring(code or err))
                break
            end
        end
    end

    -- Send rejected passages even when a later one failed, so they are not
    -- offered to Reader again on the next sync.
    if #fallback > 0 then
        -- Without a document_id, exportBook sends them through the highlights API.
        local ok, err = self:exportBook({ title = booknotes.title, author = booknotes.author, fallback },
            { author = metadata.author, source_url = metadata.source_url })
        if not ok then
            local fallback_failure = string.format(
                "Reader rejected %d highlight(s) and the Readwise highlights API failed (%s).",
                #fallback, tostring(err))
            return false, failure and (failure .. "\n" .. fallback_failure) or fallback_failure
        end
        for _, clipping in ipairs(fallback) do
            saved[clipping.text] = { fallback = true, notes = clipping.note or "" }
        end
        self.save_history()
    end

    if failure then
        return false, failure
    end
    return true
end

-- metadata is resolved by the caller from the local document identity.
function HighlightExporter:exportBook(booknotes, metadata)
    local document_id = metadata.document_id
    if document_id and document_id ~= "" then
        return self:exportReaderBook(document_id, booknotes, metadata)
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
