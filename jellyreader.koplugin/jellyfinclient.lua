--[[--
Minimal Jellyfin REST client used by the Jellyfin plugin.

Only depends on LuaSocket/LuaSec and a JSON library, so it can be
exercised outside of KOReader.
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

local json_decode, json_encode
do
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok then
        json_decode, json_encode = rapidjson.decode, rapidjson.encode
    else
        local ok_cjson, cjson = pcall(require, "cjson")
        if ok_cjson then
            json_decode, json_encode = cjson.decode, cjson.encode
        else
            local json = require("json")
            json_decode, json_encode = json.decode, json.encode
        end
    end
end

-- KOReader's socketutil sets sane timeouts; fall back to plain LuaSocket elsewhere.
local socketutil
do
    local ok, mod = pcall(require, "socketutil")
    if ok then socketutil = mod end
end

local CLIENT_NAME = "JellyReader"
local CLIENT_VERSION = "1.0.0"

local function urlEncode(str)
    return (tostring(str):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function buildQuery(params)
    if not params then return "" end
    local keys = {}
    for k in pairs(params) do table.insert(keys, k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = params[k]
        if v ~= nil then
            table.insert(parts, urlEncode(k) .. "=" .. urlEncode(v))
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

local function isString(v)
    return type(v) == "string" and v ~= ""
end

local JellyfinClient = {}
JellyfinClient.__index = JellyfinClient

--- Creates a client.
-- @param opts table with server, device_id, device_name, token (optional), user_id (optional)
function JellyfinClient.new(opts)
    local self = setmetatable({}, JellyfinClient)
    self.server = (opts.server or ""):gsub("/+$", "")
    self.device_id = opts.device_id
    self.device_name = opts.device_name or "Kindle"
    self.token = opts.token
    self.user_id = opts.user_id
    return self
end

function JellyfinClient:authHeader()
    local h = string.format('MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"',
        CLIENT_NAME, self.device_name, self.device_id, CLIENT_VERSION)
    if self.token then
        h = h .. string.format(', Token="%s"', self.token)
    end
    return h
end

function JellyfinClient:headers(extra)
    local auth = self:authHeader()
    local h = {
        ["Accept"] = "application/json",
        ["Authorization"] = auth,
        -- Older servers only look at this one.
        ["X-Emby-Authorization"] = auth,
    }
    if self.token then
        h["X-Emby-Token"] = self.token
    end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

-- Seconds a request may wait without receiving anything. KOReader's default for
-- "large content" is 10 s, which is too short for a Kindle waking its Wi-Fi from
-- power saving or a server busy with a big library.
-- Read requests are retried `retries` times after a timeout or dropped connection.
local config = {
    block_timeout = 20,
    total_timeout = 60,
    retries = 2,
    retry_delays = { 1, 3 },
}

local function setTimeout(large)
    if socketutil then
        if large then
            -- Big comics over slow Wi-Fi: no total time limit, only a stall timeout.
            socketutil:set_timeout(30, -1)
        else
            socketutil:set_timeout(config.block_timeout, config.total_timeout)
        end
    else
        http.TIMEOUT = large and 30 or config.block_timeout
    end
end

local function resetTimeout()
    if socketutil then socketutil:reset_timeout() end
end

--- Performs a raw request. Returns code (number or error string), response headers, body.
function JellyfinClient:rawRequest(method, path, body, sink)
    local chunks = {}
    local source, headers
    if body then
        headers = self:headers({
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        })
        source = ltn12.source.string(body)
    else
        headers = self:headers()
    end
    setTimeout(sink ~= nil)
    local code, resp_headers = socket.skip(1, http.request{
        url = self.server .. path,
        method = method,
        headers = headers,
        source = source,
        sink = sink or ltn12.sink.table(chunks),
        redirect = true,
    })
    resetTimeout()
    return code, resp_headers or {}, table.concat(chunks)
end

local function networkErrorText(code, attempts)
    local what
    if code == "timeout" or code == "wantread" or code == "sink timeout" then
        what = "The server did not answer in time"
    elseif code == "connection refused" then
        what = "The server refused the connection (is Jellyfin running, and is the port right?)"
    elseif type(code) == "string" and code:match("host not found") then
        what = "Server address not found (check the address; .local names often don't work on Kindle)"
    else
        what = "Network error: " .. tostring(code)
    end
    if attempts > 1 then
        what = what .. string.format(" (tried %d times)", attempts)
    end
    return what .. ". JellyReader → Test connection can help find the cause."
end

--- JSON request. Returns decoded table on success, or nil, error message, http code.
-- Read (GET) requests are retried on network errors such as timeouts.
function JellyfinClient:request(method, path, params, body)
    local encoded = body and json_encode(body) or nil
    local url_path = path .. buildQuery(params)
    local attempts = 0
    local code, _headers, resp
    while true do
        attempts = attempts + 1
        code, _headers, resp = self:rawRequest(method, url_path, encoded)
        if type(code) == "number" or method ~= "GET" or attempts > config.retries then break end
        socket.sleep(config.retry_delays[attempts] or 3)
    end
    if type(code) ~= "number" then
        return nil, networkErrorText(code, attempts), code
    end
    if code == 401 then
        return nil, "Not authorized (401). Please log in again.", code
    end
    if code < 200 or code >= 300 then
        return nil, string.format("Server returned HTTP %d", code), code
    end
    if resp == nil or resp == "" then
        return {}, nil, code
    end
    local ok, decoded = pcall(json_decode, resp)
    -- Some endpoints (e.g. /QuickConnect/Enabled) return a bare true/false.
    if not ok or decoded == nil then
        return nil, "Could not parse server response", code
    end
    return decoded, nil, code
end

--- Tries the modern endpoint, falling back to the legacy /Users/{id}/... one on 404.
function JellyfinClient:getWithFallback(path, legacy_path, params)
    local result, err, code = self:request("GET", path, params)
    if not result and code == 404 and legacy_path then
        local legacy_params = {}
        for k, v in pairs(params or {}) do
            if k ~= "userId" then legacy_params[k] = v end
        end
        return self:request("GET", legacy_path, legacy_params)
    end
    return result, err, code
end

function JellyfinClient:ping()
    local info, err, code = self:request("GET", "/System/Info/Public")
    if not info then return nil, err, code end
    return info
end

function JellyfinClient:login(username, password)
    self.token = nil
    local result, err, code = self:request("POST", "/Users/AuthenticateByName", nil, {
        Username = username,
        Pw = password or "",
    })
    if not result then return nil, err, code end
    return self:acceptLogin(result)
end

function JellyfinClient:acceptLogin(result)
    if type(result) ~= "table" or not isString(result.AccessToken) or type(result.User) ~= "table" then
        return nil, "Unexpected login response"
    end
    self.token = result.AccessToken
    self.user_id = result.User.Id
    return {
        token = self.token,
        user_id = self.user_id,
        user_name = result.User.Name,
    }
end

-- Quick Connect: the user approves a short code from another signed-in Jellyfin app.

function JellyfinClient:quickConnectEnabled()
    local result = self:request("GET", "/QuickConnect/Enabled")
    return result == true
end

--- Returns { Secret = ..., Code = "123456" } or nil, err.
function JellyfinClient:quickConnectInitiate()
    self.token = nil
    local result, err, code = self:request("POST", "/QuickConnect/Initiate")
    if not result and (code == 404 or code == 405) then
        -- Jellyfin 10.8 and older used GET.
        result, err, code = self:request("GET", "/QuickConnect/Initiate")
    end
    if not result then
        if code == 401 then return nil, "Quick Connect is disabled on this server." end
        return nil, err, code
    end
    if type(result) ~= "table" or not isString(result.Secret) then
        return nil, "Unexpected Quick Connect response"
    end
    return result
end

--- Returns true once the code was approved, false while waiting, or nil, err.
function JellyfinClient:quickConnectCheck(secret)
    local result, err, code = self:request("GET", "/QuickConnect/Connect", { secret = secret })
    if not result then return nil, err, code end
    return type(result) == "table" and result.Authenticated == true
end

function JellyfinClient:loginQuickConnect(secret)
    local result, err, code = self:request("POST", "/Users/AuthenticateWithQuickConnect", nil,
        { Secret = secret })
    if not result then return nil, err, code end
    return self:acceptLogin(result)
end

function JellyfinClient:logout()
    if self.token then
        self:request("POST", "/Sessions/Logout")
    end
    self.token = nil
end

-- ChildCount is left out on purpose: the server needs an extra query per folder for it.
local ITEM_FIELDS = "Path,SortName,ParentId,DateCreated"

--- Returns the user's libraries (all of them; caller filters).
function JellyfinClient:getLibraries()
    local result, err, code = self:getWithFallback("/UserViews",
        "/Users/" .. self.user_id .. "/Views",
        { userId = self.user_id })
    if not result then return nil, err, code end
    return result.Items or {}
end

local PAGE_SIZE = 100

--- Fetches all pages of an /Items query.
function JellyfinClient:getAllItems(params)
    local items = {}
    local start = 0
    while true do
        local p = {}
        for k, v in pairs(params) do p[k] = v end
        p.userId = self.user_id
        p.startIndex = start
        p.limit = PAGE_SIZE
        p.fields = p.fields or ITEM_FIELDS
        p.enableImages = "false"
        -- Counting all matches is an extra query on the server; a short page means we're done.
        p.enableTotalRecordCount = "false"
        local result, err, code = self:getWithFallback("/Items",
            "/Users/" .. self.user_id .. "/Items", p)
        if not result then return nil, err, code end
        local page = result.Items or {}
        for _, item in ipairs(page) do table.insert(items, item) end
        start = start + #page
        if #page < PAGE_SIZE then break end
    end
    return items
end

function JellyfinClient:getChildren(parent_id)
    return self:getAllItems{
        parentId = parent_id,
        sortBy = "SortName",
        sortOrder = "Ascending",
    }
end

function JellyfinClient:search(term)
    return self:getAllItems{
        searchTerm = term,
        recursive = "true",
        includeItemTypes = "Book",
        sortBy = "SortName",
    }
end

function JellyfinClient:getLatest(parent_id)
    local params = {
        userId = self.user_id,
        parentId = parent_id,
        includeItemTypes = "Book",
        limit = 50,
        fields = ITEM_FIELDS,
        enableImages = "false",
    }
    local result, err, code = self:getWithFallback("/Items/Latest",
        "/Users/" .. self.user_id .. "/Items/Latest", params)
    if not result then return nil, err, code end
    -- This endpoint returns a bare array.
    return result
end

--- Returns an item's parent folders, nearest first, without the server's hidden root folders.
function JellyfinClient:getAncestors(item_id)
    local result, err, code = self:request("GET", "/Items/" .. item_id .. "/Ancestors",
        { userId = self.user_id })
    if not result then return nil, err, code end
    local folders = {}
    for _, a in ipairs(result) do
        if a.Type ~= "AggregateFolder" and a.Type ~= "UserRootFolder" then
            table.insert(folders, a)
        end
    end
    return folders
end

--- Returns ok, err, http code (code is not a number on network errors).
function JellyfinClient:setPlayed(item_id, played)
    local method = played and "POST" or "DELETE"
    local result, err, code = self:request(method, "/UserPlayedItems/" .. item_id,
        { userId = self.user_id })
    if not result and code == 404 then
        result, err, code = self:request(method,
            "/Users/" .. self.user_id .. "/PlayedItems/" .. item_id)
    end
    return result ~= nil, err, code
end

--- The user's data for one item (Played, PlaybackPositionTicks, LastPlayedDate, ...).
function JellyfinClient:getUserData(item_id)
    return self:getWithFallback("/UserItems/" .. item_id .. "/UserData",
        "/Users/" .. self.user_id .. "/Items/" .. item_id .. "/UserData",
        { userId = self.user_id })
end

--- Saves a reading position. Needs Jellyfin 10.9+.
-- Returns ok, err, http code.
function JellyfinClient:setPosition(item_id, ticks)
    local result, err, code = self:request("POST", "/UserItems/" .. item_id .. "/UserData",
        { userId = self.user_id },
        {
            PlaybackPositionTicks = math.floor(ticks),
            LastPlayedDate = os.date("!%Y-%m-%dT%H:%M:%S.0000000Z"),
        })
    return result ~= nil, err, code
end

--- Books with a saved position (from any device).
function JellyfinClient:getResume()
    local params = {
        userId = self.user_id,
        mediaTypes = "Book",
        limit = 20,
        fields = ITEM_FIELDS,
        enableImages = "false",
    }
    local result, err, code = self:getWithFallback("/UserItems/Resume",
        "/Users/" .. self.user_id .. "/Items/Resume", params)
    if not result then return nil, err, code end
    return result.Items or {}
end

function JellyfinClient:getAuthors(parent_id)
    local result, err, code = self:request("GET", "/Persons", {
        userId = self.user_id,
        parentId = parent_id,
        personTypes = "Author",
        enableImages = "false",
    })
    if not result then return nil, err, code end
    return result.Items or {}
end

function JellyfinClient:getGenres(parent_id)
    local result, err, code = self:request("GET", "/Genres", {
        userId = self.user_id,
        parentId = parent_id,
        includeItemTypes = "Book",
        sortBy = "SortName",
        enableImages = "false",
    })
    if not result then return nil, err, code end
    return result.Items or {}
end

--- All books matching extra filters (personIds, genreIds, parentId...), recursively.
function JellyfinClient:getBooks(filters)
    local params = {
        recursive = "true",
        includeItemTypes = "Book",
        sortBy = "SortName",
    }
    for k, v in pairs(filters) do params[k] = v end
    return self:getAllItems(params)
end

function JellyfinClient:getCollections()
    return self:getAllItems{
        includeItemTypes = "BoxSet",
        recursive = "true",
        sortBy = "SortName",
    }
end

--- Best-effort file extension for an item ("epub", "cbz", ...).
function JellyfinClient.getExtension(item, resp_headers)
    if isString(item.Path) then
        local ext = item.Path:match("%.([%w]+)$")
        if ext then return ext:lower() end
    end
    if resp_headers then
        local cd = resp_headers["content-disposition"]
        if cd then
            local ext = cd:match('filename%*?=[^;]-%.([%w]+)"?%s*$')
                or cd:match('filename%*?=[^;]-%.([%w]+)"?;')
            if ext then return ext:lower() end
        end
    end
    if isString(item.Container) then
        return item.Container:match("^[^,]+"):lower()
    end
    return nil
end

--- Downloads an item's original file into `dir` as `basename`.<ext>.
-- Returns the final path, or nil, err.
function JellyfinClient:download(item, dir, basename)
    local tmp = dir .. "/." .. basename .. ".part"
    local fh, ferr = io.open(tmp, "wb")
    if not fh then return nil, "Cannot write file: " .. tostring(ferr) end
    local code, headers = self:rawRequest("GET", "/Items/" .. item.Id .. "/Download",
        nil, ltn12.sink.file(fh))
    -- ltn12.sink.file closes the handle when done.
    if code ~= 200 then
        os.remove(tmp)
        if code == 401 or code == 403 then
            return nil, "Download not permitted. Enable \"Allow media downloading\" for this user in Jellyfin."
        end
        return nil, type(code) == "number" and string.format("Download failed (HTTP %d)", code)
            or ("Download failed: " .. tostring(code))
    end
    local ext = JellyfinClient.getExtension(item, headers) or "epub"
    local path = dir .. "/" .. basename .. "." .. ext
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, "Cannot save file: " .. tostring(rerr)
    end
    return path
end

--- Times each step of talking to the server, to find where slowness comes from.
-- Returns { { name =, ok =, seconds =, detail = }, ... }
function JellyfinClient:diagnose()
    local results = {}
    local function step(name, fn)
        local t0 = socket.gettime()
        local ok, detail, code = fn()
        table.insert(results, { name = name, ok = ok, seconds = socket.gettime() - t0, detail = detail, code = code })
        return ok
    end
    local ok = step("Reach server", function()
        local info, err, code = self:request("GET", "/System/Info/Public")
        if not info then return false, err, code end
        return true, "Jellyfin " .. tostring(type(info) == "table" and info.Version or "?")
    end)
    if not ok or not self.token then return results end
    ok = step("List libraries", function()
        local libs, err = self:getLibraries()
        if not libs then return false, err end
        return true, #libs .. " libraries"
    end)
    if not ok then return results end
    local book
    step("List books", function()
        local result, err = self:getWithFallback("/Items", "/Users/" .. self.user_id .. "/Items", {
            userId = self.user_id,
            recursive = "true",
            includeItemTypes = "Book",
            limit = PAGE_SIZE,
            fields = ITEM_FIELDS,
            enableImages = "false",
            enableTotalRecordCount = "false",
        })
        if not result then return false, err end
        local items = result.Items or {}
        book = items[1]
        return book ~= nil, book and (#items .. " books in one page") or "no books found"
    end)
    if book then
        step("Download speed", function()
            local bytes, limit = 0, 2 * 1024 * 1024
            local t0 = socket.gettime()
            local function sink(chunk)
                if chunk then
                    bytes = bytes + #chunk
                    if bytes >= limit then return nil, "enough" end -- stop after 2 MB
                end
                return 1
            end
            local code = self:rawRequest("GET", "/Items/" .. book.Id .. "/Download", nil, sink)
            if bytes == 0 then
                if type(code) == "number" then
                    return false, string.format("HTTP %d", code)
                end
                return false, networkErrorText(code, 1)
            end
            return true, string.format("%.0f KB/s", bytes / 1024 / math.max(socket.gettime() - t0, 0.001))
        end)
    end
    return results
end

JellyfinClient.buildQuery = buildQuery
JellyfinClient.config = config
return JellyfinClient
