-- Highlight export rules, independent of KOReader widgets and file parsing.
-- history is the persisted document/passage map. save_history checkpoints each
-- successful create/update through the caller's settings storage.
local logger = require("logger")

local HighlightExporter = {}
HighlightExporter.__index = HighlightExporter

-- Fields of the /save/ request whose values this plugin chooses itself.
local REQUEST_FIELDS = { "notes", "saved_using" }

-- Reader answers 400 when it cannot attach a passage to its copy of the article,
-- and may answer 404 once the article is deleted. Retrying cannot fix either. A
-- 400 that only names a field this plugin chooses, such as
-- {"notes": ["This field may not be blank."]}, is a bug in the request instead:
-- falling back would hide it and skip Reader for that passage for good.
local function rejectsPassage(code, body)
    if code == 404 then
        return true
    elseif code ~= 400 then
        return false
    end
    body = body or ""
    local function names(field)
        return body:find('"' .. field .. '"%s*:') ~= nil
    end
    if names("content") or names("parent_id") then
        return true
    end
    for _, field in ipairs(REQUEST_FIELDS) do
        if names(field) then
            return false
        end
    end
    return true
end

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

-- The Readwise highlights API, for everything that is not a Reader article and
-- for passages Reader rejects. metadata holds the stored author and source URL.
local function exportViaHighlightsApi(api, booknotes, metadata)
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

    local result, err = api:createReadwiseHighlights(highlights)

    if not result then
        logger.warn("HighlightExporter: error creating highlights", err)
        return false, err
    end
    return true
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
        if not notes:find("%S") then
            -- Reader trims notes, so a whitespace-only note is blank too
            notes = ""
        end
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
                -- create rejects a blank note with 400; only PATCH accepts "" (to clear)
                notes = notes ~= "" and notes or nil,
                saved_using = "koreader",
            })
            if result then
                if type(result) ~= "table" or type(result.id) ~= "string" or result.id == "" then
                    failure = "Reader did not return a highlight ID."
                    break
                end
                record(passage, { id = result.id, notes = notes })
            elseif rejectsPassage(code, body) then
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
        local ok, err = exportViaHighlightsApi(self.api,
            { title = booknotes.title, author = booknotes.author, fallback }, metadata)
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
    return exportViaHighlightsApi(self.api, booknotes, metadata)
end

return HighlightExporter
