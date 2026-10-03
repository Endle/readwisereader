-- Readwise HTTP transport: authentication, JSON, timeouts and bounded retries.
-- UI belongs to the caller; on_rate_limit receives seconds before waiting and
-- nil after waiting. get_token reads the current token when a request starts.
local logger = require("logger")
local JSON = require("json")
local rapidjson = require("rapidjson")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local API_ENDPOINT = "https://readwise.io/api/v3"
local HIGHLIGHTS_API_ENDPOINT = "https://readwise.io/api/v2"

-- Both JSON decoders represent null as a *truthy* sentinel (LuaJSON a function,
-- rapidjson a lightuserdata), so `x or "default"` guards silently pass it through.
local JSON_NULL = JSON.util and JSON.util.null
local RAPIDJSON_NULL = rapidjson.null

local function stripJsonNulls(value)
    if value == JSON_NULL or value == RAPIDJSON_NULL then
        return nil
    end
    if type(value) ~= "table" then
        return value
    end
    for k, v in pairs(value) do
        if v == JSON_NULL or v == RAPIDJSON_NULL then
            value[k] = nil
        elseif type(v) == "table" then
            stripJsonNulls(v)
        end
    end
    return value
end

local ReadwiseAPI = {}
ReadwiseAPI.__index = ReadwiseAPI

function ReadwiseAPI:new(options)
    local client = setmetatable({
        get_token = assert(options.get_token),
        on_rate_limit = options.on_rate_limit,
    }, self)
    client:resetRateLimit()
    return client
end

function ReadwiseAPI:resetRateLimit()
    self.api_call_count = 0
    self.sync_start_time = nil
    self.needs_rate_limiting = false
end

function ReadwiseAPI:checkRateLimit()
    -- Only start counting after we make some API calls
    if self.api_call_count == 0 then
        self.sync_start_time = os.time()
        self.api_call_count = 1
        return
    end

    self.api_call_count = self.api_call_count + 1

    -- After 5 API calls, check if we need rate limiting
    if self.api_call_count == 5 and not self.needs_rate_limiting then
        local elapsed = os.time() - self.sync_start_time
        if elapsed < 20 then -- 5 calls in under 20 seconds suggests large library
            self.needs_rate_limiting = true
            logger.dbg("ReadwiseAPI: enabling rate limiting after", self.api_call_count, "calls in", elapsed, "seconds")
        end
    end

    -- Apply rate limiting if needed
    if self.needs_rate_limiting and self.api_call_count > 3 then
        -- Reader API limit is 20/minute, so wait 3 seconds between calls to be safe
        logger.dbg("ReadwiseAPI: applying 3 second rate limit delay")
        socket.sleep(3)
    end
end

function ReadwiseAPI:handleRetryAfter(code, headers)
    -- Handle 429 rate limit responses
    if code == 429 then
        local retry_after = 60 -- Default to 60 seconds
        if headers and headers["retry-after"] then
            retry_after = tonumber(headers["retry-after"]) or 60
        end

        -- Enable rate limiting for future calls
        self.needs_rate_limiting = true

        logger.warn("ReadwiseAPI: hit rate limit, waiting", retry_after, "seconds")
        if self.on_rate_limit then self.on_rate_limit(retry_after) end
        socket.sleep(retry_after)
        if self.on_rate_limit then self.on_rate_limit() end

        return true -- Indicate we should retry
    end
    return false
end

function ReadwiseAPI:requestReader(method, endpoint, body)
    local headers = {
        ["Authorization"] = "Token " .. self.get_token(),
        ["Content-Type"] = "application/json",
    }

    local sink = {}
    local request = {
        url = API_ENDPOINT .. endpoint,
        method = method,
        headers = headers,
    }

    -- kept in scope so every attempt can rebuild the single-use source
    local json_body
    if body then
        json_body = JSON.encode(body)
        request.headers["Content-Length"] = tostring(#json_body)
    end

    logger.dbg("ReadwiseAPI:requestReader:", method, endpoint)

    local max_attempts = 3
    local code, resp_headers, status

    for attempt = 1, max_attempts do
        sink = {}
        request.sink = ltn12.sink.table(sink)
        if body then
            request.source = ltn12.source.string(json_body)
        end

        self:checkRateLimit()
        socketutil:set_timeout(10, 60)
        code, resp_headers, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        if attempt == max_attempts then break end

        if resp_headers == nil then
            -- network layer: only the Kindle TLS "wantread" error is worth retrying,
            -- and never for a POST, which may already have created the object
            -- (the wantread retry was added in #15 after intermittent failures on a Kindle Paperwhite)
            if method == "POST" or not tostring(status or code or ""):match("wantread") then break end
            logger.dbg("ReadwiseAPI:requestReader: wantread error, attempt", attempt, "of", max_attempts)
            socket.sleep(2)
        elseif code == 429 then
            self:handleRetryAfter(code, resp_headers)  -- sleeps for Retry-After
        else
            break
        end
    end

    if resp_headers == nil then
        logger.err("ReadwiseAPI:requestReader: network error", status or code)
        return nil, "network_error"
    end

    if code == 200 or code == 201 or code == 204 then
        local content = table.concat(sink)
        if content ~= "" then
            local ok, result = pcall(JSON.decode, content)
            if ok then
                result = stripJsonNulls(result)
            end
            if ok and result ~= nil then
                return result
            else
                logger.err("ReadwiseAPI:requestReader: invalid JSON response")
                return nil, "json_error"
            end
        else
            return true
        end
    else
        -- the body is Reader's explanation, e.g. why /save/ rejected a highlight
        local error_body = table.concat(sink)
        logger.err("ReadwiseAPI:requestReader: HTTP error", code, status, error_body)
        return nil, "http_error", code, error_body
    end
end

function ReadwiseAPI:createReadwiseHighlights(highlights)
    local sink = {}
    local body_json, response, err

    body_json, err = rapidjson.encode({ highlights = highlights })
    if not body_json then
        return nil, "Cannot encode body: " .. (err or "unknown error")
    end

    local source = ltn12.source.string(body_json)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    local request = {
        url = HIGHLIGHTS_API_ENDPOINT .. "/highlights",
        method = "POST",
        sink = ltn12.sink.table(sink),
        source = source,
        headers = {
            ["Authorization"] = "Token " .. self.get_token(),
            ["Content-Length"] = #body_json,
            ["Content-Type"] = "application/json",
        },
    }

    local code, __, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, "Request failed: " .. (status or code or "network unreachable")
    end

    -- ltn12 delivers the body in BLOCKSIZE (2048 byte) chunks, so sink[1] is only the
    -- first one; anything larger has to be joined before it will parse.
    local content = table.concat(sink)
    if content == "" then
        return nil, "No response from server"
    end

    response, err = rapidjson.decode(content)
    if not response then
        return nil, "Unable to decode server response: " .. (err or "unknown error")
    end

    return stripJsonNulls(response)
end

return ReadwiseAPI
