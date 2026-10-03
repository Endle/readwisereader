-- Highlight export rules, independent of KOReader widgets and file parsing.
-- history is the persisted document/passage map. save_history persists it
-- through the caller's settings storage, once per exported book.
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

-- A Reader highlight is identified by its document and text, so repeated
-- highlights of the same text become one passage carrying all of their notes.
-- Returns the passages in book order and how many clippings had no text.
local function bookPassages(booknotes)
    local passages, by_text, skipped = {}, {}, 0
    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            local text, note = clipping.text, clipping.note
            if type(text) ~= "string" or not text:find("%S") then
                skipped = skipped + 1
            else
                local passage = by_text[text]
                if not passage then
                    passage = { text = text, clipping = clipping, notes = {}, seen = {} }
                    by_text[text] = passage
                    passages[#passages + 1] = passage
                end
                -- Reader trims notes, so a whitespace-only note is blank too
                if type(note) == "string" and note:find("%S") and not passage.seen[note] then
                    passage.seen[note] = true
                    passage.notes[#passage.notes + 1] = note
                end
            end
        end
    end
    for _, passage in ipairs(passages) do
        passage.notes = table.concat(passage.notes, "\n\n")
    end
    return passages, skipped
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
-- Highlights deleted in Reader are recorded as { deleted = true, notes } and
-- left alone.
function HighlightExporter:exportReaderBook(document_id, booknotes, metadata)
    local saved = self.history[document_id] or {}
    self.history[document_id] = saved
    local fallback = {}
    local failure, changed

    local function fallBack(passage)
        fallback[#fallback + 1] = {
            text = passage.text,
            note = passage.notes ~= "" and passage.notes or nil,
            page = passage.clipping.page,
            time = passage.clipping.time,
        }
    end

    local function record(passage, entry)
        saved[passage] = entry
        changed = true
    end

    local passages, skipped = bookPassages(booknotes)
    if skipped > 0 then
        -- e.g. image selections; Reader has no passage to attach them to
        logger.warn("HighlightExporter: skipping", skipped, "highlight(s) without text in", document_id)
    end

    for _, entry in ipairs(passages) do
        local passage, notes = entry.text, entry.notes
        local previous = saved[passage]
        if previous and (previous.deleted or previous.notes == notes) then
            -- Already exported with this note, or deleted in Reader
            logger.dbg("HighlightExporter: passage unchanged in", document_id)
        elseif previous and previous.id then
            -- Editing a note must not create a second highlight. An empty
            -- string explicitly removes a previously exported note.
            local result, err, code = self.api:requestReader("PATCH", "/update/" .. previous.id .. "/",
                { notes = notes })
            if result then
                record(passage, { id = previous.id, notes = notes })
            elseif code == 404 then
                -- Deleted in Reader since it was exported. Respect that rather
                -- than recreating it, and stop retrying the update.
                logger.warn("HighlightExporter: highlight", previous.id, "no longer exists in", document_id)
                record(passage, { deleted = true, notes = notes })
            else
                failure = string.format("Could not update highlight note (%s).", tostring(code or err))
                break
            end
        elseif previous then
            -- Rejected by Reader earlier. The highlights API matches the existing
            -- highlight by text, title, author and source URL, so this updates its note.
            fallBack(entry)
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
                fallBack(entry)
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
        if ok then
            for _, clipping in ipairs(fallback) do
                record(clipping.text, { fallback = true, notes = clipping.note or "" })
            end
        else
            local fallback_failure = string.format(
                "Reader rejected %d highlight(s) and the Readwise highlights API failed (%s).",
                #fallback, tostring(err))
            failure = failure and (failure .. "\n" .. fallback_failure) or fallback_failure
        end
    end

    -- Saved even when the book failed, so the next sync does not send the
    -- passages that did succeed again.
    if changed then
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
