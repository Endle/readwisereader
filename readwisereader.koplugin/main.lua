-- ===============================================================================
-- KOREADER READWISE READER PLUGIN
-- ===============================================================================
-- This plugin synchronizes articles from Readwise Reader to KOReader
-- 
-- MAIN FEATURES:
-- - Downloads articles from Readwise Reader "later" and "shortlist" locations
-- - Converts articles to HTML format with embedded images
-- - Offers filtering by article tags, location and type
-- - Archives finished articles back to Readwise
-- - Handles incremental sync with cleanup of archived content
-- ===============================================================================

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local filemanagerutil = require("apps/filemanager/filemanagerutil")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template

-- constants
local API_ENDPOINT = "https://readwise.io/api/v3"
local article_id_prefix = "[rw-id_"
local article_id_postfix = "] "

local ReadwiseReader = WidgetContainer:extend{
    name = "readwisereader",
    is_doc_only = false,
    is_stub = false,
}

function ReadwiseReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("readwisereader_download", { 
        category = "none", 
        event = "SynchronizeReadwiseReader", 
        title = _("Readwise Reader sync"), 
        general = true,
    })
end

function ReadwiseReader:init()
    self:onDispatcherRegisterActions()

    self.readwise_settings = LuaSettings:open(DataStorage:getSettingsDir().."/readwisereader.lua")
    
    local settings = self.readwise_settings:readSetting("readwisereader") or {}
    self.access_token = settings.access_token
    self.directory = settings.directory
    self.archive_finished = settings.archive_finished
    self.last_sync_time = settings.last_sync_time
    
    self.available_tags = settings.available_tags or {}
    self.excluded_tags = settings.excluded_tags or {}
    self.document_tags = settings.document_tags or {}
    self.document_categories = settings.document_categories or {}
    
    self.available_locations = settings.available_locations or {}
    self.excluded_locations = settings.excluded_locations or {}
    self.document_locations = settings.document_locations or {}
    
    self.ui.menu:registerToMainMenu(self)
end

function ReadwiseReader:addToMainMenu(menu_items)
    menu_items.readwisereader = {
        text = _("Readwise Reader"),
        sub_item_table = {
            {
                text = _("Sync articles"),
                callback = function()
                    self.ui:handleEvent(Event:new("SynchronizeReadwiseReader"))
                end,
            },
            {
                text = _("Go to download folder"),
                callback = function()
                    if self.ui.document then
                        self.ui:onClose()
                    end
                    if FileManager.instance then
                        FileManager.instance:reinit(self.directory)
                    else
                        FileManager:showFiles(self.directory)
                    end
                end,
                enabled_func = function()
                    return self.directory and self.directory ~= ""
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Configure Readwise Reader"),
                        keep_menu_open = true,
                        callback = function()
                            self:editSettings()
                        end,
                    },
                    {
                        text_func = function()
                            local path
                            if not self.directory or self.directory == "" then
                                path = _("Not set")
                            else
                                path = filemanagerutil.abbreviate(self.directory)
                            end
                            return T(_("Download folder: %1"), BD.dirpath(path))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setDownloadDirectory(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Archive finished articles"),
                        checked_func = function() 
                            return self.archive_finished 
                        end,
                        callback = function()
                            self.archive_finished = not self.archive_finished
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Exclude from sync"),
                        sub_item_table_func = function()
                            return self:getExclusionMenuItems()
                        end,
                    },
                }
            },
        },
    }
end

function ReadwiseReader:getExclusionMenuItems()
    local menu_items = {}
    
    table.insert(menu_items, {
        text = _("Exclude documents of these types or tags:"),
    })
    
    if #self.available_locations > 0 then
        table.insert(menu_items, {
            text = _("--- Locations ---"),
            enabled = false,
        })
        
        for _, location in ipairs(self.available_locations) do
            local display_location = location:sub(1,1):upper() .. location:sub(2)
            
            table.insert(menu_items, {
                text = display_location,
                checked_func = function()
                    return self:isLocationExcluded(location)
                end,
                callback = function()
                    self:toggleLocationExclusion(location)
                end,
            })
        end
    end
    
    local category_tags = {}
    local regular_tags = {}
    
    for _, tag in ipairs(self.available_tags) do
        local is_category = self:isDocumentCategory(tag)
        if is_category then
            table.insert(category_tags, tag)
        else
            table.insert(regular_tags, tag)
        end
    end
    
    if #category_tags > 0 then
        table.insert(menu_items, {
            text = _("--- Types ---"),
            enabled = false,
        })
        
        for _, tag in ipairs(category_tags) do
            local display_tag = tag:sub(1,1):upper() .. tag:sub(2)
            
            table.insert(menu_items, {
                text = display_tag,
                checked_func = function()
                    return self:isTagExcluded(tag)
                end,
                callback = function()
                    self:toggleTagExclusion(tag)
                end,
            })
        end
    end
    
    if #regular_tags > 0 then
        table.insert(menu_items, {
            text = _("--- Tags ---"),
            enabled = false,
        })
        
        for _, tag in ipairs(regular_tags) do
            local display_tag = tag:sub(1,1):upper() .. tag:sub(2)
            
            table.insert(menu_items, {
                text = display_tag,
                checked_func = function()
                    return self:isTagExcluded(tag)
                end,
                callback = function()
                    self:toggleTagExclusion(tag)
                end,
            })
        end
    end
    
    if #self.available_tags == 0 and #self.available_locations == 0 then
        table.insert(menu_items, {
            text = _("No tags or locations found"),
            enabled = false,
        })
        table.insert(menu_items, {
            text = _("Sync articles first to discover options"),
            enabled = false,
        })
    end
    
    return menu_items
end

function ReadwiseReader:isLocationExcluded(location)
    for _, excluded_location in ipairs(self.excluded_locations) do
        if excluded_location == location then
            return true
        end
    end
    return false
end

function ReadwiseReader:toggleLocationExclusion(location)
    local found_index = nil
    for i, excluded_location in ipairs(self.excluded_locations) do
        if excluded_location == location then
            found_index = i
            break
        end
    end
    
    if found_index then
        table.remove(self.excluded_locations, found_index)
        logger.dbg("ReadwiseReader:toggleLocationExclusion: removed location from exclusion:", location)
    else
        table.insert(self.excluded_locations, location)
        logger.dbg("ReadwiseReader:toggleLocationExclusion: added location to exclusion:", location)
        self:deleteArticlesWithLocation(location)
    end
    
    self:saveSettings()
end

function ReadwiseReader:deleteArticlesWithLocation(location)
    local deleted_count = 0
    
    for entry in lfs.dir(self.directory) do
        if entry ~= "." and entry ~= ".." then
            local filepath = self.directory .. entry
            
            if lfs.attributes(filepath, "mode") == "file" and entry:find(article_id_prefix, 1, true) then
                local doc_id = self:getDocumentIdFromPath(filepath)
                if doc_id then
                    if self:documentHasLocation(doc_id, location) then
                        logger.dbg("ReadwiseReader:deleteArticlesWithLocation: deleting", filepath, "with location", location)
                        FileManager:deleteFile(filepath, true)
                        deleted_count = deleted_count + 1
                    end
                end
            end
        end
    end
    
    if deleted_count > 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Deleted %1 articles from location '%2'"), deleted_count, location)
        })
        
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end
end

function ReadwiseReader:documentHasLocation(doc_id, location)
    if self.document_locations and self.document_locations[doc_id] then
        return self.document_locations[doc_id] == location
    end
    return false
end

function ReadwiseReader:isTagExcluded(tag)
    for _, excluded_tag in ipairs(self.excluded_tags) do
        if excluded_tag == tag then
            return true
        end
    end
    return false
end

function ReadwiseReader:toggleTagExclusion(tag)
    local found_index = nil
    for i, excluded_tag in ipairs(self.excluded_tags) do
        if excluded_tag == tag then
            found_index = i
            break
        end
    end
    
    if found_index then
        table.remove(self.excluded_tags, found_index)
        logger.dbg("ReadwiseReader:toggleTagExclusion: removed tag from exclusion:", tag)
    else
        table.insert(self.excluded_tags, tag)
        logger.dbg("ReadwiseReader:toggleTagExclusion: added tag to exclusion:", tag)
        self:deleteArticlesWithTag(tag)
    end
    
    self:saveSettings()
end

function ReadwiseReader:deleteArticlesWithTag(tag)
    local deleted_count = 0
    
    for entry in lfs.dir(self.directory) do
        if entry ~= "." and entry ~= ".." then
            local filepath = self.directory .. entry
            
            if lfs.attributes(filepath, "mode") == "file" and entry:find(article_id_prefix, 1, true) then
                local doc_id = self:getDocumentIdFromPath(filepath)
                if doc_id then
                    if self:documentHasTag(doc_id, tag) then
                        logger.dbg("ReadwiseReader:deleteArticlesWithTag: deleting", filepath, "with tag", tag)
                        FileManager:deleteFile(filepath, true)
                        deleted_count = deleted_count + 1
                    end
                end
            end
        end
    end
    
    if deleted_count > 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Deleted %1 articles with tag '%2'"), deleted_count, tag)
        })
        
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end
end

function ReadwiseReader:documentHasTag(doc_id, tag)
    if self.document_tags and self.document_tags[doc_id] then
        for _, doc_tag in ipairs(self.document_tags[doc_id]) do
            if doc_tag == tag then
                return true
            end
        end
    end
    return false
end

function ReadwiseReader:isDocumentCategory(tag)
    if self.document_categories and self.document_categories[tag] then
        return true
    end
    return false
end

function ReadwiseReader:updateDocumentCategories(documents)
    self.document_categories = {}
    
    for _, doc in ipairs(documents) do
        if doc.category and type(doc.category) == "string" and doc.category ~= "" then
            self.document_categories[doc.category] = true
            logger.dbg("ReadwiseReader:updateDocumentCategories: found category:", doc.category)
        end
    end
    
    local category_list = {}
    for category, _ in pairs(self.document_categories) do
        table.insert(category_list, category)
    end
    table.sort(category_list)
    
    if #category_list > 0 then
        logger.dbg("ReadwiseReader:updateDocumentCategories: discovered categories:", table.concat(category_list, ", "))
    else
        logger.dbg("ReadwiseReader:updateDocumentCategories: no categories found in documents")
    end
end

function ReadwiseReader:updateAvailableTags(documents)
    local new_tags = {}
    local tag_set = {}
    local new_locations = {}
    local location_set = {}
    
    self.document_tags = {}
    self.document_locations = {}
    
    logger.dbg("ReadwiseReader:updateAvailableTags: processing", #documents, "documents")
    
    self:updateDocumentCategories(documents)
    
    for _, doc in ipairs(documents) do
        logger.dbg("ReadwiseReader:updateAvailableTags: processing document", doc.id)
        
        self.document_tags[doc.id] = {}
        
        if doc.location then
            self.document_locations[doc.id] = doc.location
            
            if not location_set[doc.location] then
                location_set[doc.location] = true
                table.insert(new_locations, doc.location)
            end
        end
        
        if doc.category then
            local category_tag = doc.category
            logger.dbg("ReadwiseReader:updateAvailableTags: found category tag:", category_tag)
            
            table.insert(self.document_tags[doc.id], category_tag)
            
            if not tag_set[category_tag] then
                tag_set[category_tag] = true
                table.insert(new_tags, category_tag)
            end
        end
        
        if doc.tags and type(doc.tags) == "table" then
            logger.dbg("ReadwiseReader:updateAvailableTags: found tags object for document", doc.id)
            
            for tag_name, tag_data in pairs(doc.tags) do
                if type(tag_name) == "string" and tag_name ~= "" then
                    logger.dbg("ReadwiseReader:updateAvailableTags: found tag:", tag_name)
                    
                    table.insert(self.document_tags[doc.id], tag_name)
                    
                    if not tag_set[tag_name] then
                        tag_set[tag_name] = true
                        table.insert(new_tags, tag_name)
                    end
                end
            end
        else
            logger.dbg("ReadwiseReader:updateAvailableTags: no tags found for document", doc.id)
        end
        
        logger.dbg("ReadwiseReader:updateAvailableTags: document", doc.id, "has", #self.document_tags[doc.id], "tags:", table.concat(self.document_tags[doc.id], ", "))
    end
    
    table.sort(new_tags, function(a, b)
        local a_is_category = self:isDocumentCategory(a)
        local b_is_category = self:isDocumentCategory(b)
        
        if a_is_category and not b_is_category then
            return true
        elseif not a_is_category and b_is_category then
            return false
        else
            return a < b
        end
    end)
    
    table.sort(new_locations)
    
    self.available_tags = new_tags
    self.available_locations = new_locations
    
    logger.dbg("ReadwiseReader:updateAvailableTags: total available tags:", #self.available_tags)
    logger.dbg("ReadwiseReader:updateAvailableTags: total available locations:", #self.available_locations)
    if #self.available_tags > 0 then
        logger.dbg("ReadwiseReader:updateAvailableTags: tags found:", table.concat(self.available_tags, ", "))
    else
        logger.warn("ReadwiseReader:updateAvailableTags: no tags found in any documents")
    end
    if #self.available_locations > 0 then
        logger.dbg("ReadwiseReader:updateAvailableTags: locations found:", table.concat(self.available_locations, ", "))
    end
end

function ReadwiseReader:shouldSkipDocument(document)
    if self.document_locations and self.document_locations[document.id] then
        local doc_location = self.document_locations[document.id]
        for _, excluded_location in ipairs(self.excluded_locations) do
            if doc_location == excluded_location then
                logger.dbg("ReadwiseReader:shouldSkipDocument: skipping document", document.id, "due to excluded location:", excluded_location)
                return true
            end
        end
    end
    
    if not self.document_tags or not self.document_tags[document.id] then
        return false
    end
    
    for _, doc_tag in ipairs(self.document_tags[document.id]) do
        for _, excluded_tag in ipairs(self.excluded_tags) do
            if doc_tag == excluded_tag then
                logger.dbg("ReadwiseReader:shouldSkipDocument: skipping document", document.id, "due to excluded tag:", excluded_tag)
                return true
            end
        end
    end
    
    return false
end

function ReadwiseReader:validateSettings()
    local function isEmpty(s)
        return s == nil or s == ""
    end

    local token_empty = isEmpty(self.access_token)
    local directory_empty = isEmpty(self.directory)
    
    if token_empty or directory_empty then
        UIManager:show(MultiConfirmBox:new{
            text = _("Please configure your Readwise Reader access token and download folder."),
            choice1_text_func = function()
                if token_empty then
                    return _("Token (★)")
                else
                    return _("Token")
                end
            end,
            choice1_callback = function() 
                self:editSettings() 
            end,
            choice2_text_func = function()
                if directory_empty then
                    return _("Folder (★)")
                else
                    return _("Folder")
                end
            end,
            choice2_callback = function() 
                self:setDownloadDirectory() 
            end,
        })
        return false
    end

    local dir_mode = lfs.attributes(self.directory, "mode")
    if dir_mode ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = _("The download folder is not valid.\nPlease configure it in the settings.")
        })
        return false
    end

    if string.sub(self.directory, -1) ~= "/" then
        self.directory = self.directory .. "/"
        self:saveSettings()
    end

    return true
end

function ReadwiseReader:editSettings()
    self.settings_dialog = InputDialog:new {
        title = _("Readwise Reader settings"),
        input = self.access_token or "",
        input_hint = _("Access Token"),
        description = _("Enter your Readwise Reader access token.\nYou can get it from: https://readwise.io/access_token"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.settings_dialog)
                    end
                },
                {
                    text = _("Save"),
                    callback = function()
                        self.access_token = self.settings_dialog:getInputText()
                        self:saveSettings()
                        UIManager:close(self.settings_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

function ReadwiseReader:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.directory = path
            self:saveSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir()
end

function ReadwiseReader:callAPI(method, endpoint, body, quiet)
    quiet = quiet or false
    local headers = {
        ["Authorization"] = "Token " .. self.access_token,
        ["Content-Type"] = "application/json",
    }
    
    local sink = {}
    local request = {
        url = API_ENDPOINT .. endpoint,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    
    if body then
        local json_body = JSON.encode(body)
        request.source = ltn12.source.string(json_body)
        request.headers["Content-Length"] = tostring(#json_body)
    end
    
    logger.dbg("ReadwiseReader:callAPI:", method, endpoint)
    
    socketutil:set_timeout(10, 60)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    
    if resp_headers == nil then
        logger.err("ReadwiseReader:callAPI: network error", status or code)
        if not quiet then
            UIManager:show(InfoMessage:new{ text = _("Network error connecting to Readwise Reader.") })
        end
        return nil, "network_error"
    end
    
    if code == 200 or code == 204 then
        local content = table.concat(sink)
        if content ~= "" then
            local ok, result = pcall(JSON.decode, content)
            if ok and result then
                return result
            else
                logger.err("ReadwiseReader:callAPI: invalid JSON response")
                return nil, "json_error"
            end
        else
            return true
        end
    else
        logger.err("ReadwiseReader:callAPI: HTTP error", code, status)
        if not quiet then
            UIManager:show(InfoMessage:new{ 
                text = T(_("Error connecting to Readwise Reader: %1"), code) 
            })
        end
        return nil, "http_error", code
    end
end

function ReadwiseReader:getDocumentList()
    local documents = {}
    local next_cursor = nil
    
    local locations = {"later", "shortlist"}
    
    for _, location in ipairs(locations) do
        logger.dbg("ReadwiseReader:getDocumentList: fetching documents from location:", location)
        next_cursor = nil
        
        repeat
            local endpoint = "/list/?location=" .. location .. "&withHtmlContent=true&withTags=true"
            if next_cursor and type(next_cursor) == "string" and next_cursor ~= "" then
                endpoint = endpoint .. "&pageCursor=" .. next_cursor
            end
            
            local result, err = self:callAPI("GET", endpoint)
            
            if not result then
                logger.err("ReadwiseReader:getDocumentList: error getting document list for location", location, ":", err)
                return nil
            end
            
            if result.results then
                for _, doc in ipairs(result.results) do
                    if (doc.category == "article" or doc.category == "pdf") and doc.reading_progress < 1 then
                        table.insert(documents, doc)
                    end
                end
            end
            
            if result.nextPageCursor and type(result.nextPageCursor) == "string" and result.nextPageCursor ~= "" then
                next_cursor = result.nextPageCursor
            else
                next_cursor = nil
            end
            
            logger.dbg("ReadwiseReader:getDocumentList: processed page for location", location, ", next_cursor:", next_cursor)
        until not next_cursor
    end
    
    logger.dbg("ReadwiseReader:getDocumentList: total documents retrieved:", #documents)
    return documents
end

function ReadwiseReader:getArchivedDocuments(since_date)
    local documents = {}
    local next_cursor = nil
    
    repeat
        local endpoint = "/list/?location=archive"
        if since_date then
            endpoint = endpoint .. "&updatedAfter=" .. since_date
        end
        if next_cursor and type(next_cursor) == "string" and next_cursor ~= "" then
            endpoint = endpoint .. "&pageCursor=" .. next_cursor
        end
        
        local result, err = self:callAPI("GET", endpoint)
        
        if not result then
            logger.err("ReadwiseReader:getArchivedDocuments: error getting archived document list:", err)
            return nil
        end
        
        if result.results then
            for _, doc in ipairs(result.results) do
                if doc.category == "article" or doc.category == "pdf" then
                    table.insert(documents, doc)
                end
            end
        end
        
        if result.nextPageCursor and type(result.nextPageCursor) == "string" and result.nextPageCursor ~= "" then
            next_cursor = result.nextPageCursor
        else
            next_cursor = nil
        end
        
        logger.dbg("ReadwiseReader:getArchivedDocuments: processed page, next_cursor:", next_cursor)
    until not next_cursor
    
    return documents
end

function ReadwiseReader:findLocalDocumentByReadwiseId(readwise_id)
    local filename_pattern = article_id_prefix .. readwise_id .. article_id_postfix
    
    for entry in lfs.dir(self.directory) do
        if entry ~= "." and entry ~= ".." then
            if entry:find(filename_pattern, 1, true) then
                return self.directory .. entry
            end
        end
    end
    
    return nil
end

function ReadwiseReader:cleanupArchivedDocuments()
    if not self.last_sync_time then
        logger.dbg("ReadwiseReader:cleanupArchivedDocuments: no previous sync time, skipping cleanup")
        return 0
    end
    
    self:showProgress(_("Checking for archived articles…"))
    
    local archived_docs = self:getArchivedDocuments(self.last_sync_time)
    
    if not archived_docs then
        logger.err("ReadwiseReader:cleanupArchivedDocuments: failed to get archived documents")
        return 0
    end
    
    local deleted_count = 0
    
    for _, doc in ipairs(archived_docs) do
        local local_filepath = self:findLocalDocumentByReadwiseId(doc.id)
        
        if local_filepath then
            logger.dbg("ReadwiseReader:cleanupArchivedDocuments: deleting locally archived document", doc.id, local_filepath)
            FileManager:deleteFile(local_filepath, true)
            deleted_count = deleted_count + 1
        end
    end
    
    logger.dbg("ReadwiseReader:cleanupArchivedDocuments: deleted", deleted_count, "locally archived documents")
    return deleted_count
end

function ReadwiseReader:documentExists(doc_id)
    local filename_pattern = article_id_prefix .. doc_id .. article_id_postfix
    
    for entry in lfs.dir(self.directory) do
        if entry:find(filename_pattern, 1, true) then
            return true
        end
    end
    
    return false
end

function ReadwiseReader:downloadDocument(document)
    if self:shouldSkipDocument(document) then
        logger.dbg("ReadwiseReader:downloadDocument: skipping", document.id, "- has excluded tags or location")
        return "skipped"
    end
    
    if self:documentExists(document.id) then
        logger.dbg("ReadwiseReader:downloadDocument: skipping", document.id, "- already exists")
        return "skipped"
    end
    
    self:showProgress(T(_("Processing: %1"), document.title or "Untitled"))
    
    local content = document.html_content
    
    if not content or content == "" or type(content) ~= "string" then
        logger.warn("ReadwiseReader:downloadDocument: no HTML content available for", document.id)
        local basic_content = string.format([[
<h1>%s</h1>
<p><strong>Author:</strong> %s</p>
<p><strong>Source:</strong> <a href="%s">%s</a></p>
<p><strong>Summary:</strong> %s</p>
<p><strong>Note:</strong> Full content was not available via API. Please visit the source URL above.</p>
]],
            document.title or "Untitled",
            document.author or "Unknown",
            document.source_url or "",
            document.source_url or "",
            document.summary or "No summary available"
        )
        content = basic_content
    end
    
    local title = util.getSafeFilename(document.title or "Untitled", self.directory, 200, 0)
    local filename = article_id_prefix .. document.id .. article_id_postfix .. title .. ".html"
    local filepath = self.directory .. filename
    
    local processed_content = self:processHtmlContent(content, document)
    
    local file, err = io.open(filepath, "w")
    if not file then
        logger.err("ReadwiseReader:downloadDocument: failed to open file for writing:", err)
        return "failed"
    end
    
    local success = file:write(processed_content)
    file:close()
    
    if success then
        logger.dbg("ReadwiseReader:downloadDocument: saved", document.id, "to", filepath)
        return "downloaded"
    else
        logger.err("ReadwiseReader:downloadDocument: failed to write file")
        os.remove(filepath)
        return "failed"
    end
end

function ReadwiseReader:processHtmlContent(content, document)
    local decoded_content = content:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    
    -- Enhanced image processing - extract larger images from responsive picture elements
    decoded_content = self:extractLargerImages(decoded_content)
    
    local html = string.format([[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>%s</title>
    <style>
        body { 
            font-family: Georgia, serif; 
            line-height: 1.6; 
            margin: 20px; 
            max-width: 800px;
        }
        img { 
            max-width: 100%%; 
            height: auto; 
            min-width: 300px;
            margin: 10px 0;
        }
        blockquote { 
            border-left: 3px solid #ccc; 
            margin-left: 0; 
            padding-left: 20px; 
        }
        .image-placeholder {
            background-color: #f0f0f0;
            border: 2px dashed #ccc;
            padding: 20px;
            text-align: center;
            margin: 10px 0;
            color: #666;
            min-height: 100px;
        }
        figcaption {
            font-style: italic;
            color: #666;
            font-size: 0.9em;
            margin-top: 5px;
        }
    </style>
</head>
<body>
    <h1>%s</h1>
    <p><em>%s</em></p>
    <p>Source: <a href="%s">%s</a></p>
    <hr>
    %s
</body>
</html>
]], 
    document.title or "Untitled",
    document.title or "Untitled", 
    document.author or "Unknown author",
    document.source_url or "",
    document.source_url or "",
    decoded_content)
    
    -- Enhanced image processing with size limits
    local processed_html = html:gsub('(<img[^>]+src=")([^"]+)(")', function(prefix, url, suffix)
        if url:match("^data:") then
            return prefix .. url .. suffix
        elseif url:match("^https?://") then
            local encoded = self:fetchAndEncodeImage(url)
            if encoded then
                return prefix .. encoded .. suffix
            else
                local alt_text = html:match('alt="([^"]*)"') or "Image"
                return string.format('<div class="image-placeholder">📷 Image: %s<br><small>Source: %s</small></div>', alt_text, url)
            end
        end
        return prefix .. url .. suffix
    end)
    
    return processed_html
end

-- Enhanced responsive image extraction
function ReadwiseReader:extractLargerImages(content)
    local processed = content:gsub('<figure[^>]*>%s*<picture[^>]*>(.-)</picture>(.-)</figure>', function(picture_content, caption)
        local largest_url = nil
        local largest_width = 0
        
        for srcset in picture_content:gmatch('srcset="([^"]+)"') do
            for url_part in srcset:gmatch('([^,]+)') do
                local url, width_str = url_part:match('([^%s]+)%s+(%d+)w')
                if not url then
                    url = url_part:match('([^%s]+)')
                end
                
                if url then
                    local width = tonumber(width_str)
                    if not width then
                        width = tonumber(url:match('[?&]width=(%d+)')) or 0
                    end
                    
                    -- Prefer larger images, but cap at 1200px for e-readers
                    if width > largest_width and width <= 1200 then
                        largest_width = width
                        largest_url = url
                    end
                end
            end
        end
        
        if not largest_url then
            largest_url = picture_content:match('<img[^>]+src="([^"]+)"')
        end
        
        if largest_url then
            local alt_text = picture_content:match('alt="([^"]*)"') or ""
            local img_html = string.format('<img src="%s" alt="%s" />', largest_url, alt_text)
            if caption and caption:match('%S') then
                return string.format('<figure>%s%s</figure>', img_html, caption)
            else
                return img_html
            end
        end
        
        return ""
    end)
    
    processed = processed:gsub('<picture[^>]*>(.-)</picture>', function(picture_content)
        local largest_url = nil
        local largest_width = 0
        
        for srcset in picture_content:gmatch('srcset="([^"]+)"') do
            for url_part in srcset:gmatch('([^,]+)') do
                local url, width_str = url_part:match('([^%s]+)%s+(%d+)w')
                if not url then
                    url = url_part:match('([^%s]+)')
                end
                
                if url then
                    local width = tonumber(width_str) or tonumber(url:match('[?&]width=(%d+)')) or 0
                    if width > largest_width and width <= 1200 then
                        largest_width = width
                        largest_url = url
                    end
                end
            end
        end
        
        if not largest_url then
            largest_url = picture_content:match('<img[^>]+src="([^"]+)"')
        end
        
        if largest_url then
            local alt_text = picture_content:match('alt="([^"]*)"') or ""
            return string.format('<img src="%s" alt="%s" />', largest_url, alt_text)
        end
        
        return ""
    end)
    
    return processed
end

-- Enhanced image fetching with size limits
function ReadwiseReader:fetchAndEncodeImage(url)
    logger.dbg("ReadwiseReader:fetchAndEncodeImage: attempting to fetch", url)
    
    local response = {}
    local request = {
        url = url,
        sink = ltn12.sink.table(response),
        method = "GET",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader Readwise Plugin)",
            ["Accept"] = "image/*,*/*;q=0.8"
        }
    }
    
    -- Longer timeouts for better success rate
    socketutil:set_timeout(8, 45)
    local code, headers = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    
    logger.dbg("ReadwiseReader:fetchAndEncodeImage: response code", code, "for URL", url)
    
    if code ~= 200 then
        logger.warn("ReadwiseReader:fetchAndEncodeImage: failed to fetch", url, "code:", code)
        return nil
    end
    
    local image_data = table.concat(response)
    if #image_data == 0 then
        logger.warn("ReadwiseReader:fetchAndEncodeImage: empty response for", url)
        return nil
    end
    
    -- Size limit: 1.5MB for better performance
    local max_size = 1.5 * 1024 * 1024
    if #image_data > max_size then
        logger.warn("ReadwiseReader:fetchAndEncodeImage: image too large", #image_data, "bytes, skipping", url)
        return nil
    end
    
    local encoded = mime.b64(image_data)
    local mime_type = headers and headers["content-type"] or "image/jpeg"
    
    logger.dbg("ReadwiseReader:fetchAndEncodeImage: successfully encoded image", #image_data, "bytes, mime type:", mime_type)
    
    return string.format("data:%s;base64,%s", mime_type, encoded)
end

function ReadwiseReader:showProgress(text)
    self.progress_message = InfoMessage:new{text = text, timeout = 1}
    UIManager:show(self.progress_message)
    UIManager:forceRePaint()
end

function ReadwiseReader:hideProgress()
    if self.progress_message then 
        UIManager:close(self.progress_message) 
    end
    self.progress_message = nil
end

function ReadwiseReader:archiveDocument(document_id)
    logger.dbg("ReadwiseReader:archiveDocument: archiving", document_id)
    
    local endpoint = "/update/" .. document_id
    local body = {
        location = "archive"
    }
    
    local result, err = self:callAPI("PATCH", endpoint, body, true)
    
    if result then
        logger.dbg("ReadwiseReader:archiveDocument: successfully archived", document_id)
        return true
    else
        logger.err("ReadwiseReader:archiveDocument: failed to archive", document_id, err)
        return false
    end
end

function ReadwiseReader:getDocumentIdFromPath(filepath)
    local _, filename = util.splitFilePathName(filepath)
    local prefix_len = article_id_prefix:len()
    
    if filename:sub(1, prefix_len) ~= article_id_prefix then
        return nil
    end
    
    local endpos = filename:find(article_id_postfix, prefix_len + 1, true)
    if not endpos then
        return nil
    end
    
    local id = filename:sub(prefix_len + 1, endpos - 1)
    logger.dbg("ReadwiseReader:getDocumentIdFromPath: extracted id", id, "from", filename)
    return id
end

function ReadwiseReader:processFinishedDocuments()
    if not self.archive_finished then
        return 0, 0
    end
    
    local archived_count = 0
    local deleted_count = 0
    
    for entry in lfs.dir(self.directory) do
        if entry ~= "." and entry ~= ".." then
            local filepath = self.directory .. entry
            
            if lfs.attributes(filepath, "mode") == "file" and DocSettings:hasSidecarFile(filepath) then
                local doc_settings = DocSettings:open(filepath)
                local summary = doc_settings:readSetting("summary")
                local status = summary and summary.status
                
                if status == "complete" then
                    local doc_id = self:getDocumentIdFromPath(filepath)
                    
                    if doc_id and self:archiveDocument(doc_id) then
                        archived_count = archived_count + 1
                        FileManager:deleteFile(filepath, true)
                        deleted_count = deleted_count + 1
                    end
                end
            end
        end
    end
    
    return archived_count, deleted_count
end

function ReadwiseReader:synchronize()
    local info = InfoMessage:new{ text = _("Connecting to Readwise Reader…") }
    UIManager:show(info)
    
    if not self:validateSettings() then
        UIManager:close(info)
        return
    end
    
    UIManager:close(info)
    
    local sync_start_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
    
    local cleaned_count = self:cleanupArchivedDocuments()
    self:hideProgress()
    
    self:showProgress(_("Processing finished articles…"))
    local archived_count, deleted_count = self:processFinishedDocuments()
    self:hideProgress()
    
    self:showProgress(_("Getting document list…"))
    local documents = self:getDocumentList()
    self:hideProgress()
    
    if not documents then
        UIManager:show(InfoMessage:new{ text = _("Failed to get document list from Readwise Reader.") })
        return
    end
    
    self:updateAvailableTags(documents)
    
    local filtered_documents = {}
    local excluded_count = 0
    local existing_count = 0
    
    for _, document in ipairs(documents) do
        if self:shouldSkipDocument(document) then
            excluded_count = excluded_count + 1
        elseif self:documentExists(document.id) then
            existing_count = existing_count + 1
        else
            table.insert(filtered_documents, document)
        end
    end
    
    if #filtered_documents == 0 and cleaned_count == 0 and archived_count == 0 then
        local msg = _("No new articles found and no changes to process.")
        if existing_count > 0 then
            msg = msg .. "\n" .. T(_("Skipped %1 existing articles."), existing_count)
        end
        if excluded_count > 0 then
            msg = msg .. "\n" .. T(_("Excluded %1 articles due to tags/locations."), excluded_count)
        end
        UIManager:show(InfoMessage:new{ text = msg })
        
        self.last_sync_time = sync_start_time
        self:saveSettings()
        return
    end
    
    local downloaded = 0
    local skipped = 0
    local failed = 0
    
    for i, document in ipairs(filtered_documents) do
        self:showProgress(T(_("Downloading %1 of %2…"), i, #filtered_documents))
        
        local result = self:downloadDocument(document)
        
        if result == "downloaded" then
            downloaded = downloaded + 1
        elseif result == "skipped" then
            skipped = skipped + 1
        else
            failed = failed + 1
        end
    end
    
    self:hideProgress()
    
    self.last_sync_time = sync_start_time
    self:saveSettings()
    
    local msg = _("Sync complete:")
    
    if downloaded > 0 then
        msg = msg .. "\n" .. T(_("Downloaded: %1"), downloaded)
    end
    
    if existing_count > 0 then
        msg = msg .. "\n" .. T(_("Skipped (already exists): %1"), existing_count)
    end
    
    if skipped > 0 then
        msg = msg .. "\n" .. T(_("Skipped (other): %1"), skipped)
    end
    
    if failed > 0 then
        msg = msg .. "\n" .. T(_("Failed: %1"), failed)
    end
    
    if excluded_count > 0 then
        msg = msg .. "\n" .. T(_("Excluded due to tags/locations: %1"), excluded_count)
    end
    
    if cleaned_count > 0 then
        msg = msg .. "\n" .. T(_("Cleaned up archived: %1"), cleaned_count)
    end
    
    if archived_count > 0 then
        msg = msg .. "\n" .. T(_("Archived in Readwise: %1"), archived_count)
        msg = msg .. "\n" .. T(_("Deleted locally: %1"), deleted_count)
    end
    
    if downloaded == 0 and skipped == 0 and failed == 0 and cleaned_count == 0 and archived_count == 0 and excluded_count == 0 and existing_count == 0 then
        msg = msg .. "\n" .. _("No changes to process.")
    end
    
    UIManager:show(InfoMessage:new{ text = msg })
    
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

function ReadwiseReader:onSynchronizeReadwiseReader()
    NetworkMgr:runWhenOnline(function()
        self:synchronize()
    end)
    return true
end

function ReadwiseReader:saveSettings()
    local settings = {
        access_token = self.access_token,
        directory = self.directory,
        archive_finished = self.archive_finished,
        last_sync_time = self.last_sync_time,
        available_tags = self.available_tags,
        excluded_tags = self.excluded_tags,
        document_tags = self.document_tags,
        document_categories = self.document_categories,
        available_locations = self.available_locations,
        excluded_locations = self.excluded_locations,
        document_locations = self.document_locations,
    }
    self.readwise_settings:saveSetting("readwisereader", settings)
    self.readwise_settings:flush()
end

function ReadwiseReader:readSettings()
    local readwise_settings = LuaSettings:open(DataStorage:getSettingsDir().."/readwisereader.lua")
    return readwise_settings
end

return ReadwiseReader
