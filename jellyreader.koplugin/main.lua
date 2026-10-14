--[[--
JellyReader: browse book/comic libraries on a Jellyfin server, download
items and open them in KOReader.

@module koplugin.jellyreader
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local JellyfinClient = require("jellyfinclient")

-- Collection types that can contain readable things. "folders"/nil cover
-- "mixed content" libraries, which are also commonly used for comics.
local READABLE_COLLECTIONS = {
    books = true,
    folders = true,
    mixed = true,
}

local COMIC_EXTENSIONS = { cbz = true, cbr = true, cb7 = true, cbt = true }

-- Jellyfin web reader position formats (kept compatible so both readers agree):
-- page-based documents (comics, PDF): ticks = page index (0-based) * 10000
-- reflowable documents (EPUB...):     ticks = fraction read * 10^7
local TICKS_PER_PAGE = 10000
local TICKS_FULL_BOOK = 10000000

local PREFETCH_AT = 0.8 -- start downloading the next part at 80 %

-- A background download of the next part. Module-level so it survives the
-- reader being closed and reopened on another document.
local prefetch = nil

local JellyReader = WidgetContainer:extend{
    name = "jellyreader",
    is_doc_only = false,
}

function JellyReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("jellyfin_browse", {
        category = "none",
        event = "JellyfinBrowse",
        title = _("JellyReader: library"),
        general = true,
    })
    Dispatcher:registerAction("jellyfin_continue", {
        category = "none",
        event = "JellyfinContinue",
        title = _("JellyReader: continue reading"),
        general = true,
    })
    Dispatcher:registerAction("jellyfin_next_part", {
        category = "none",
        event = "JellyfinNextPart",
        title = _("JellyReader: open next part"),
        reader = true,
    })
end

function JellyReader:init()
    -- One settings object shared by every instance (file browser and reader),
    -- so they never overwrite each other's changes.
    if not JellyReader.settings then
        JellyReader.settings = LuaSettings:open(self:settingsFile())
    end
    self:warnAboutOldPlugin()
    if not self.settings:readSetting("device_id") then
        local id = {}
        math.randomseed(os.time())
        for _i = 1, 16 do table.insert(id, string.format("%02x", math.random(0, 255))) end
        self.settings:saveSetting("device_id", table.concat(id))
        self.settings:flush()
    end
    self.menu_stack = {}
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

--- Settings file, moving over the one from before the plugin was renamed (jellyfin.koplugin).
function JellyReader:settingsFile()
    local dir = DataStorage:getSettingsDir()
    local path = dir .. "/jellyreader.lua"
    local old = dir .. "/jellyfin.lua"
    if lfs.attributes(path, "mode") ~= "file" and lfs.attributes(old, "mode") == "file" then
        local fin = io.open(old, "rb")
        if fin then
            local data = fin:read("*a")
            fin:close()
            local fout = io.open(path, "wb")
            if fout then
                fout:write(data)
                fout:close()
                logger.info("JellyReader: moved settings from", old)
            end
        end
    end
    return path
end

local warned_old_plugin = false

--- Both plugins at once would show two menus; ask to remove the old folder.
function JellyReader:warnAboutOldPlugin()
    if warned_old_plugin or type(self.path) ~= "string" then return end
    local old = self.path:gsub("[^/]+/?$", "jellyfin.koplugin")
    if old ~= self.path and lfs.attributes(old, "mode") == "directory" then
        warned_old_plugin = true
        UIManager:show(InfoMessage:new{
            text = T(_("JellyReader replaces the old Jellyfin plugin. Please delete this folder and restart KOReader:\n\n%1"), old),
        })
    end
end

function JellyReader:getClient()
    return JellyfinClient.new{
        server = self.settings:readSetting("server"),
        device_id = self.settings:readSetting("device_id"),
        device_name = Device.model or "Kindle",
        token = self.settings:readSetting("token"),
        user_id = self.settings:readSetting("user_id"),
    }
end

function JellyReader:isLoggedIn()
    return self.settings:readSetting("token") ~= nil
        and self.settings:readSetting("user_id") ~= nil
end

function JellyReader:getDownloadDir()
    local dir = self.settings:readSetting("download_dir")
    if not dir then
        local home = G_reader_settings:readSetting("home_dir")
            or Device.home_dir
            or DataStorage:getDataDir()
        dir = home .. "/Jellyfin"
    end
    return dir
end

function JellyReader:addToMainMenu(menu_items)
    menu_items.jellyreader = {
        text = _("JellyReader"),
        sorting_hint = "search",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

local function settingToggle(self, key, text, help_text)
    return {
        text = text,
        help_text = help_text,
        checked_func = function() return self.settings:nilOrTrue(key) end,
        callback = function()
            self.settings:flipNilOrTrue(key)
            self.settings:flush()
        end,
    }
end

function JellyReader:getMainMenuItems()
    -- Only in the reader: reading direction of the open book's series.
    local manga_item = {
        text_func = function()
            local target = self:currentMangaTarget()
            return target and T(_("Manga: read right-to-left (%1)"), target.name)
                or _("Manga: read right-to-left")
        end,
        help_text = _([[Switches this book to right-to-left now, and remembers it for its whole folder (series), including parts you download later.]]),
        enabled_func = function() return self:currentMangaTarget() ~= nil end,
        checked_func = function()
            local target = self:currentMangaTarget()
            return target ~= nil and self:recordIsManga(target.rec)
        end,
        callback = function() self:toggleMangaForCurrent() end,
    }
    local items = {
        {
            text = _("Continue reading"),
            callback = function() self:onJellyfinContinue() end,
        },
        {
            text = _("Open next part"),
            enabled_func = function() return self:getCurrentItemId() ~= nil end,
            callback = function() self:onJellyfinNextPart() end,
        },
        {
            text = _("Browse library"),
            enabled_func = function() return self:isLoggedIn() end,
            callback = function() self:onJellyfinBrowse() end,
        },
        {
            text = _("Search"),
            enabled_func = function() return self:isLoggedIn() end,
            callback = function() self:showSearchDialog() end,
            separator = true,
        },
        {
            text = _("Storage"),
            sub_item_table_func = function()
                return self:getStorageMenuItems()
            end,
        },
        {
            text = _("Comics"),
            sub_item_table_func = function()
                return self:getComicMenuItems()
            end,
        },
        {
            text = _("Sync with Jellyfin"),
            sub_item_table = {
                settingToggle(self, "sync_finished", _("Mark as read when finished")),
                settingToggle(self, "sync_position", _("Sync reading position"),
                    _([[Saves your page in Jellyfin when you close a book, and offers to jump ahead when Jellyfin has a later position (for example from the Jellyfin web reader or another device). Needs Jellyfin 10.9 or newer.]])),
                {
                    text_func = function()
                        return T(_("Send pending updates now (%1)"), self:pendingCount())
                    end,
                    enabled_func = function() return self:pendingCount() > 0 end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:runOnline(function()
                            self:flushSync()
                            touchmenu_instance:updateItems()
                        end)
                    end,
                },
            },
        },
        settingToggle(self, "prefetch", _("Download next part in the background"),
            _([[When you are 80 % through a part and Wi-Fi is on, the next part is downloaded in the background so it opens instantly.]])),
        {
            text_func = function()
                return T(_("Download folder: %1"), self:getDownloadDir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        self.settings:saveSetting("download_dir", path)
                        self.settings:flush()
                        touchmenu_instance:updateItems()
                    end,
                }:chooseDir(self:getDownloadDir())
            end,
        },
        {
            text = _("Test connection"),
            enabled_func = function() return self.settings:readSetting("server") ~= nil end,
            callback = function()
                self:runOnline(function() self:testConnection() end)
            end,
        },
        {
            text_func = function()
                if self:isLoggedIn() then
                    return T(_("Log out (%1 @ %2)"),
                        self.settings:readSetting("user_name") or "?",
                        self.settings:readSetting("server") or "?")
                end
                return _("Log in to server")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if self:isLoggedIn() then
                    self:logout()
                    touchmenu_instance:updateItems()
                else
                    self:showLoginDialog(function() touchmenu_instance:updateItems() end)
                end
            end,
        },
    }
    if self.ui.document then
        table.insert(items, 3, manga_item)
    end
    return items
end

---------------------------------------------------------------- helpers

function JellyReader:showError(msg)
    UIManager:show(InfoMessage:new{
        text = msg or _("Unknown error"),
        icon = "notice-warning",
    })
end

--- Runs fn while a "please wait" message is shown (network calls block the UI).
function JellyReader:withBusy(text, fn)
    local info = InfoMessage:new{ text = text, dismissable = false }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, a, b, c = pcall(fn)
    UIManager:close(info)
    if not ok then
        logger.err("JellyReader:", a)
        return nil, tostring(a)
    end
    return a, b, c
end

function JellyReader:runOnline(fn)
    NetworkMgr:runWhenOnline(fn)
end

local function copyList(t)
    local c = {}
    for i, v in ipairs(t or {}) do c[i] = v end
    return c
end

--- A folder chain (library first) extended by one folder.
local function chainWith(parent_ids, id)
    local ids = copyList(parent_ids)
    table.insert(ids, id)
    return ids
end

local function booksOnly(jf_items)
    local books = {}
    for _i, it in ipairs(jf_items) do
        if not it.IsFolder then table.insert(books, it) end
    end
    return books
end

local function isPlayed(it)
    return type(it.UserData) == "table" and it.UserData.Played == true
end

--- Folders that hold the parts of one series (not libraries or collections).
local function isSeriesFolder(folder)
    local t = folder and folder.Type
    return t ~= nil and t ~= "CollectionFolder" and t ~= "UserView"
        and t ~= "BoxSet" and t ~= "AggregateFolder" and t ~= "UserRootFolder"
end

local function minimalItem(it)
    return { Id = it.Id, Name = it.Name, Path = it.Path, Container = it.Container, ParentId = it.ParentId }
end

local function nextSibling(siblings, item_id)
    for i, s in ipairs(siblings or {}) do
        if s.Id == item_id then return siblings[i + 1] end
    end
end

local function safeFilename(name)
    name = tostring(name or "book")
    name = name:gsub('[%c/\\:%*%?"<>|]', "_"):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #name > 100 then name = name:sub(1, 100) end
    if name == "" then name = "book" end
    return name
end

---------------------------------------------------------------- auth

function JellyReader:showLoginDialog(on_success)
    local dialog
    local function readServer()
        local server = util.trim(dialog:getFields()[1] or "")
        if server == "" then return nil end
        if not server:match("^https?://") then
            server = "http://" .. server
        end
        return (server:gsub("/+$", ""))
    end
    dialog = MultiInputDialog:new{
        title = _("Jellyfin login"),
        fields = {
            {
                text = self.settings:readSetting("server") or "",
                hint = "http://192.168.1.10:8096",
            },
            {
                text = self.settings:readSetting("user_name") or "",
                hint = _("Username"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Quick Connect (no password)"),
                    callback = function()
                        local server = readServer()
                        if not server then
                            self:showError(_("Enter the server address first."))
                            return
                        end
                        UIManager:close(dialog)
                        self:runOnline(function()
                            self:doQuickConnect(server, on_success)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Log in"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local server = readServer()
                        local user = util.trim(fields[2] or "")
                        local password = fields[3] or ""
                        if not server or user == "" then
                            self:showError(_("Server address and username are required."))
                            return
                        end
                        UIManager:close(dialog)
                        self:runOnline(function()
                            self:doLogin(server, user, password, on_success)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function JellyReader:newLoginClient(server)
    return JellyfinClient.new{
        server = server,
        device_id = self.settings:readSetting("device_id"),
        device_name = Device.model or "Kindle",
    }
end

function JellyReader:saveLogin(server, result, fallback_name, on_success)
    self.settings:saveSetting("server", server)
    self.settings:saveSetting("user_name", result.user_name or fallback_name)
    self.settings:saveSetting("token", result.token)
    self.settings:saveSetting("user_id", result.user_id)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = T(_("Logged in as %1."), result.user_name or fallback_name or "?"),
        timeout = 2,
    })
    self:flushSync()
    if on_success then on_success() end
end

function JellyReader:doLogin(server, user, password, on_success)
    local client = self:newLoginClient(server)
    local result, err = self:withBusy(_("Logging in…"), function()
        return client:login(user, password)
    end)
    if not result then
        self:showError(T(_("Login failed:\n%1"), err))
        return
    end
    self:saveLogin(server, result, user, on_success)
end

local QUICK_CONNECT_POLL_SEC = 3
local QUICK_CONNECT_TIMEOUT_SEC = 300

function JellyReader:doQuickConnect(server, on_success)
    local client = self:newLoginClient(server)
    local qc, err = self:withBusy(_("Contacting server…"), function()
        if not client:quickConnectEnabled() then
            return nil, _("Quick Connect is turned off on this server.\nAn administrator can enable it in Dashboard → General → Quick Connect.")
        end
        return client:quickConnectInitiate()
    end)
    if not qc then
        self:showError(T(_("Quick Connect failed:\n%1"), err))
        return
    end

    local done = false
    local box
    box = InfoMessage:new{
        text = T(_([[Quick Connect code:

%1

In the Jellyfin app on your phone or computer, open your profile → Quick Connect and enter this code.

Tap here to cancel.]]), qc.Code),
        dismiss_callback = function() done = true end,
    }
    UIManager:show(box)
    local deadline = os.time() + QUICK_CONNECT_TIMEOUT_SEC
    local function finish()
        done = true
        UIManager:close(box)
    end
    local poll
    poll = function()
        if done then return end
        local approved, perr = client:quickConnectCheck(qc.Secret)
        if approved then
            finish()
            local result, lerr = client:loginQuickConnect(qc.Secret)
            if result then
                self:saveLogin(server, result, nil, on_success)
            else
                self:showError(T(_("Quick Connect failed:\n%1"), lerr))
            end
        elseif approved == nil then
            finish()
            self:showError(T(_("Quick Connect failed:\n%1"), perr))
        elseif os.time() > deadline then
            finish()
            self:showError(_("The Quick Connect code expired. Please try again."))
        else
            UIManager:scheduleIn(QUICK_CONNECT_POLL_SEC, poll)
        end
    end
    UIManager:scheduleIn(QUICK_CONNECT_POLL_SEC, poll)
end

function JellyReader:testConnection()
    local client = self:getClient()
    if not self:isLoggedIn() then client.token = nil end
    local results = self:withBusy(_("Testing connection…\nThis takes up to a minute."), function()
        return client:diagnose()
    end) or {}
    local lines = { T(_("Server: %1"), self.settings:readSetting("server") or "?"), "" }
    for _i, r in ipairs(results) do
        table.insert(lines, string.format("%s %s: %.1f s", r.ok and "\u{2713}" or "\u{2717}", _(r.name), r.seconds))
        if r.detail then table.insert(lines, "    " .. r.detail) end
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function JellyReader:logout()
    local client = self:getClient()
    if NetworkMgr:isOnline() then
        pcall(client.logout, client)
    end
    self.settings:delSetting("token")
    self.settings:delSetting("user_id")
    self.settings:flush()
end

function JellyReader:handleApiError(err, code)
    if code == 401 then
        self.settings:delSetting("token")
        self.settings:flush()
        self:closeAllMenus()
        self:showError(_("Your Jellyfin session expired. Please log in again."))
        self:showLoginDialog()
    else
        self:showError(err)
    end
end

---------------------------------------------------------------- menus

function JellyReader:closeAllMenus()
    for i = #self.menu_stack, 1, -1 do
        UIManager:close(self.menu_stack[i])
    end
    self.menu_stack = {}
end

function JellyReader:pushMenu(title, item_table)
    local menu
    menu = Menu:new{
        title = title,
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu, item)
            if item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            for i = #self.menu_stack, 1, -1 do
                if self.menu_stack[i] == menu then
                    table.remove(self.menu_stack, i)
                    break
                end
            end
        end,
    }
    table.insert(self.menu_stack, menu)
    UIManager:show(menu)
    return menu
end

--- Replaces menu (if given) with a freshly built one.
function JellyReader:replaceMenu(menu, title, item_table)
    if menu then menu.close_callback() end
    return self:pushMenu(title, item_table)
end

---------------------------------------------------------------- browsing

function JellyReader:onJellyfinBrowse()
    if not self:isLoggedIn() then
        self:showLoginDialog(function() self:onJellyfinBrowse() end)
        return true
    end
    self:runOnline(function() self:showLibraries() end)
    return true
end

local MAX_CONTINUE_ON_HOME = 5

function JellyReader:showLibraries()
    local client = self:getClient()
    local libs, err, code = self:withBusy(_("Loading libraries…"), function()
        return client:getLibraries()
    end)
    if not libs then return self:handleApiError(err, code) end
    self:flushSync()

    local items = {}
    local continue = self:getContinueEntries(true)
    for i, entry in ipairs(continue) do
        if i > MAX_CONTINUE_ON_HOME then
            table.insert(items, {
                text = T(_("All in Continue reading (%1)…"), #continue),
                callback = function() self:showContinue() end,
            })
            break
        end
        table.insert(items, self:makeContinueEntry(entry))
    end
    if #items > 0 then items[#items].separator = true end

    local lib_count = 0
    for _i, lib in ipairs(libs) do
        local ctype = lib.CollectionType
        if type(ctype) ~= "string" or READABLE_COLLECTIONS[ctype] then
            lib_count = lib_count + 1
            table.insert(items, {
                text = lib.Name,
                mandatory = self:isManga({ lib.Id }) and _("manga") or (ctype == "books" and _("books") or nil),
                callback = function() self:showFolder(lib) end,
                hold_callback = function() self:showFolderActions(lib) end,
            })
        end
    end
    table.insert(items, {
        text = _("Collections"),
        callback = function() self:showCollections() end,
    })
    table.insert(items, {
        text = _("Search…"),
        callback = function() self:showSearchDialog() end,
    })
    if lib_count == 0 then
        self:showError(_("No book libraries found on this server."))
    end
    self:pushMenu(T(_("JellyReader: %1"), self.settings:readSetting("user_name") or ""), items)
end

---------------------------------------------------------------- sort & filter

local SORTS = {
    { id = "name", text = _("Name") },
    { id = "added", text = _("Date added (newest first)") },
    { id = "released", text = _("Release date") },
}

function JellyReader:getView()
    return self.settings:readSetting("view_sort") or "name",
        self.settings:isTrue("view_unread")
end

local function sortItems(list, sort)
    if sort == "name" then return list end -- server order
    local sorted = copyList(list)
    local index = {}
    for i, it in ipairs(list) do index[it] = i end
    local function key(it)
        if sort == "added" then return it.DateCreated end
        return it.PremiereDate or (it.ProductionYear and tostring(it.ProductionYear))
    end
    table.sort(sorted, function(a, b)
        local ka, kb = key(a), key(b)
        if type(ka) ~= "string" then ka = nil end
        if type(kb) ~= "string" then kb = nil end
        if ka and kb and ka ~= kb then
            if sort == "added" then return ka > kb end
            return ka < kb
        end
        if (ka == nil) ~= (kb == nil) then return ka ~= nil end -- undated last
        return index[a] < index[b]
    end)
    return sorted
end

--- Applies the current view (sort, unread only) to a list of items for display.
function JellyReader:viewItems(list)
    local sort, unread_only = self:getView()
    local folders, books = {}, {}
    for _i, it in ipairs(list) do
        if it.IsFolder then
            table.insert(folders, it)
        elseif not (unread_only and isPlayed(it)) then
            table.insert(books, it)
        end
    end
    local out = sortItems(folders, sort)
    for _i, b in ipairs(sortItems(books, sort)) do table.insert(out, b) end
    return out
end

function JellyReader:makeViewEntry(on_change)
    local sort, unread_only = self:getView()
    local sort_text
    for _i, s in ipairs(SORTS) do
        if s.id == sort then sort_text = s.text end
    end
    return {
        text = T(_("Sort: %1%2"), sort_text, unread_only and _(" · unread only") or ""),
        mandatory = "\u{2195}",
        callback = function()
            local dialog
            local buttons = {}
            for _i, s in ipairs(SORTS) do
                table.insert(buttons, {{
                    text = (s.id == sort and "\u{2713} " or "") .. T(_("Sort by %1"), s.text:lower()),
                    callback = function()
                        UIManager:close(dialog)
                        self.settings:saveSetting("view_sort", s.id)
                        self.settings:flush()
                        on_change()
                    end,
                }})
            end
            table.insert(buttons, {{
                text = unread_only and _("Show read items too") or _("Show unread only"),
                callback = function()
                    UIManager:close(dialog)
                    self.settings:flipTrue("view_unread")
                    self.settings:flush()
                    on_change()
                end,
            }})
            dialog = ButtonDialog:new{ title = _("Sort and filter"), title_align = "center", buttons = buttons }
            UIManager:show(dialog)
        end,
    }
end

---------------------------------------------------------------- folders

--- Context shared by all items of one folder: where they go on disk and their reading order.
-- { crumbs = {"Comics", "Saga"}, ids = {lib_id, folder_id}, parent_id = "...",
--   siblings = {book items in name order}, is_series = bool, series_name = "...", rtl = bool,
--   virtual = true for lists that are not real folders (collections, authors, genres) }
function JellyReader:folderContext(folder, parent, children)
    local crumbs = copyList(parent and parent.crumbs)
    local ids = copyList(parent and parent.ids)
    table.insert(ids, folder.Id)
    if folder.Type == "BoxSet" then
        return { virtual = true, siblings = booksOnly(children or {}), ids = ids }
    end
    table.insert(crumbs, folder.Name)
    return {
        crumbs = crumbs,
        ids = ids,
        parent_id = folder.Id,
        siblings = children and booksOnly(children) or nil,
        is_series = isSeriesFolder(folder),
        series_name = folder.Name,
        rtl = self:isManga(ids),
    }
end

function JellyReader:showFolder(folder, parent, cached_children, menu_to_replace)
    local children = cached_children
    if not children then
        local client = self:getClient()
        local err, code
        children, err, code = self:withBusy(_("Loading…"), function()
            return client:getChildren(folder.Id)
        end)
        if not children then return self:handleApiError(err, code) end
    end

    local ctx = self:folderContext(folder, parent, children)
    local books = ctx.siblings
    local menu
    local items = {}
    if #books > 1 then
        local next_unread
        for _i, b in ipairs(books) do
            if not isPlayed(b) then next_unread = b break end
        end
        if next_unread then
            table.insert(items, {
                text = T(_("Continue: %1"), next_unread.Name),
                mandatory = "\u{25B6}",
                callback = function() self:openItem(next_unread, ctx) end,
            })
        end
        table.insert(items, {
            text = T(_("Download all parts (%1)"), #books),
            mandatory = "\u{2193}",
            callback = function() self:downloadAll(ctx) end,
        })
    end
    if folder.Type == "CollectionFolder" then
        table.insert(items, {
            text = _("Recently added"),
            mandatory = "\u{2605}",
            callback = function() self:showLatest(folder) end,
        })
        table.insert(items, {
            text = _("By author"),
            callback = function() self:showAuthors(folder) end,
        })
        table.insert(items, {
            text = _("By genre"),
            callback = function() self:showGenres(folder) end,
        })
    end
    if #children > 1 then
        table.insert(items, self:makeViewEntry(function()
            self:showFolder(folder, parent, children, menu)
        end))
    end
    if #items > 0 then items[#items].separator = true end
    self:appendItemEntries(items, self:viewItems(children), ctx)
    if #children == 0 then
        self:showError(_("This folder is empty."))
        return
    end
    menu = self:replaceMenu(menu_to_replace, folder.Name, items)
end

--- A list of books that are not one folder (author, genre, search...).
function JellyReader:showBookList(title, list, menu_to_replace)
    local ctx = { virtual = true, siblings = booksOnly(list) }
    local menu
    local items = {}
    if #list > 1 then
        table.insert(items, self:makeViewEntry(function()
            self:showBookList(title, list, menu)
        end))
        items[1].separator = true
    end
    self:appendItemEntries(items, self:viewItems(list), ctx)
    menu = self:replaceMenu(menu_to_replace, title, items)
end

function JellyReader:showLatest(folder)
    local client = self:getClient()
    local latest, err, code = self:withBusy(_("Loading…"), function()
        return client:getLatest(folder.Id)
    end)
    if not latest then return self:handleApiError(err, code) end
    if #latest == 0 then
        self:showError(_("Nothing here yet."))
        return
    end
    local items = {}
    self:appendItemEntries(items, latest, { virtual = true })
    self:pushMenu(T(_("Recently added: %1"), folder.Name), items)
end

--- Shows a list of names (authors, genres, collections) that each open a book list.
function JellyReader:showNameList(title, loader, on_select, empty_text)
    local client = self:getClient()
    local list, err, code = self:withBusy(_("Loading…"), function() return loader(client) end)
    if not list then return self:handleApiError(err, code) end
    if #list == 0 then
        self:showError(empty_text)
        return
    end
    local items = {}
    for _i, entry in ipairs(list) do
        table.insert(items, {
            text = entry.Name or "?",
            mandatory = tonumber(entry.ChildCount) and tostring(entry.ChildCount) or nil,
            callback = function() on_select(entry) end,
        })
    end
    self:pushMenu(title, items)
end

function JellyReader:showFilteredBooks(title, filters)
    local client = self:getClient()
    local books, err, code = self:withBusy(_("Loading…"), function()
        return client:getBooks(filters)
    end)
    if not books then return self:handleApiError(err, code) end
    if #books == 0 then
        self:showError(_("No books found."))
        return
    end
    self:showBookList(title, books)
end

function JellyReader:showAuthors(lib)
    self:showNameList(T(_("Authors: %1"), lib.Name),
        function(client) return client:getAuthors(lib.Id) end,
        function(person)
            self:showFilteredBooks(person.Name, { personIds = person.Id, parentId = lib.Id })
        end,
        _("No authors found. Jellyfin reads authors from EPUB metadata and ComicInfo.xml in comics."))
end

function JellyReader:showGenres(lib)
    self:showNameList(T(_("Genres: %1"), lib.Name),
        function(client) return client:getGenres(lib.Id) end,
        function(genre)
            self:showFilteredBooks(genre.Name, { genreIds = genre.Id, parentId = lib.Id })
        end,
        _("No genres found."))
end

function JellyReader:showCollections()
    self:showNameList(_("Collections"),
        function(client) return client:getCollections() end,
        function(boxset) self:showFolder(boxset) end,
        _("No collections on this server."))
end

function JellyReader:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Jellyfin books"),
        input = self.last_search or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local term = util.trim(dialog:getInputText() or "")
                        UIManager:close(dialog)
                        if term == "" then return end
                        self.last_search = term
                        self:runOnline(function() self:showSearchResults(term) end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function JellyReader:showSearchResults(term)
    local client = self:getClient()
    local results, err, code = self:withBusy(_("Searching…"), function()
        return client:search(term)
    end)
    if not results then return self:handleApiError(err, code) end
    if #results == 0 then
        self:showError(T(_("No results for \"%1\"."), term))
        return
    end
    self:showBookList(T(_("Search: %1"), term), results)
end

--- Turns Jellyfin items into menu entries (in the given order).
-- ctx is the folder context when browsing a folder.
function JellyReader:appendItemEntries(items, jf_items, ctx)
    local parent = ctx and not ctx.virtual and ctx or nil
    for _i, it in ipairs(jf_items) do
        if it.IsFolder then
            local count = tonumber(it.ChildCount)
            table.insert(items, {
                text = it.Name .. "/",
                mandatory = (self:isManga(chainWith(parent and parent.ids, it.Id)) and _("manga") .. " " or "")
                    .. (count and tostring(count) or ""),
                callback = function() self:showFolder(it, parent) end,
                hold_callback = function() self:showFolderActions(it, parent) end,
            })
        else
            table.insert(items, self:makeBookEntry(it, ctx))
        end
    end
end

function JellyReader:makeBookEntry(it, ctx)
    local marks = {}
    if self:getLocalPath(it.Id) then table.insert(marks, "\u{2193}") end -- downloaded
    if isPlayed(it) then table.insert(marks, "\u{2713}") end -- read
    local ext = JellyfinClient.getExtension(it)
    if ext then table.insert(marks, ext:upper()) end
    return {
        text = it.Name or it.Id,
        mandatory = #marks > 0 and table.concat(marks, " ") or nil,
        callback = function() self:openItem(it, ctx) end,
        hold_callback = function() self:showItemActions(it, ctx) end,
    }
end

function JellyReader:showFolderActions(folder, parent)
    local function withContext(fn)
        self:runOnline(function()
            local client = self:getClient()
            local children, err, code = self:withBusy(_("Loading…"), function()
                return client:getChildren(folder.Id)
            end)
            if not children then return self:handleApiError(err, code) end
            fn(self:folderContext(folder, parent, children))
        end)
    end
    local parent_ids = parent and parent.ids or nil
    local manga = self:isManga(chainWith(parent_ids, folder.Id))
    local dialog
    dialog = ButtonDialog:new{
        title = folder.Name,
        title_align = "center",
        buttons = {
            {{
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    self:showFolder(folder, parent)
                end,
            }},
            {{
                text = _("Download all parts"),
                callback = function()
                    UIManager:close(dialog)
                    withContext(function(ctx) self:downloadAll(ctx) end)
                end,
            }},
            {{
                text = _("Delete downloaded parts"),
                callback = function()
                    UIManager:close(dialog)
                    withContext(function(ctx) self:deleteAll(ctx) end)
                end,
            }},
            {{
                text = manga and _("\u{2713} Manga: read right-to-left") or _("Manga: read right-to-left"),
                callback = function()
                    UIManager:close(dialog)
                    self:setManga(folder, not manga, parent_ids)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

---------------------------------------------------------------- comics & manga

-- Manga (right-to-left) is set per folder and inherited by everything inside it.
-- "manga" holds folders switched on, "manga_off" folders switched back off inside a
-- manga folder. `ids` is a folder chain from the library down; the nearest folder
-- with an explicit setting wins.
function JellyReader:isManga(ids)
    local on = self.settings:readSetting("manga") or {}
    local off = self.settings:readSetting("manga_off") or {}
    ids = ids or {}
    for i = #ids, 1, -1 do
        if off[ids[i]] then return false end
        if on[ids[i]] then return true end
    end
    return false
end


--- Sets reading direction for a folder. `parent_ids` is the chain above it (to know
-- what it would inherit). With `quiet`, nothing is shown.
--- The folder (series) of the open book, for the reader's manga toggle.
function JellyReader:currentMangaTarget()
    local item_id = self:getCurrentItemId()
    local rec = item_id and self:getDownload(item_id)
    if not rec or not rec.parent_id then return nil end
    local ids = rec.ids or { rec.parent_id }
    local parent_ids = copyList(ids)
    if parent_ids[#parent_ids] == rec.parent_id then table.remove(parent_ids) end
    return {
        item_id = item_id,
        rec = rec,
        folder = { Id = rec.parent_id, Name = rec.series_name or (rec.dir or ""):match("([^/]+)$") or "?" },
        name = rec.series_name or (rec.dir or ""):match("([^/]+)$") or "?",
        parent_ids = parent_ids,
    }
end

function JellyReader:toggleMangaForCurrent()
    local target = self:currentMangaTarget()
    if not target then return end
    local on = not self:recordIsManga(target.rec)
    self:setManga(target.folder, on, target.parent_ids, true)
    target.rec.rtl = on or nil
    self:rememberDownload(target.item_id, target.rec)
    -- The open book switches right away; KOReader saves it when the book is closed.
    self.ui:handleEvent(Event:new("ToggleReadingOrder", on))
    local others = 0
    for _i, d in ipairs(self:listDownloads()) do
        if d.id ~= target.item_id then
            for _j, id in ipairs(d.rec.ids or { d.rec.parent_id }) do
                if id == target.folder.Id then others = others + 1 break end
            end
        end
    end
    if others > 0 then
        self:confirmApplyToDownloaded(on and T(_("%1 will open right-to-left."), target.name)
            or T(_("%1 will open left-to-right."), target.name), true)
    end
end

function JellyReader:setManga(folder, on, parent_ids, quiet)
    local manga = self.settings:readSetting("manga") or {}
    local off = self.settings:readSetting("manga_off") or {}
    manga[folder.Id], off[folder.Id] = nil, nil
    local inherited = self:isManga(parent_ids)
    if on and not inherited then
        manga[folder.Id] = folder.Name
    elseif not on and inherited then
        off[folder.Id] = folder.Name
    end
    self.settings:saveSetting("manga", manga)
    self.settings:saveSetting("manga_off", off)
    self.settings:flush()
    if quiet then return end
    local text = on and T(_("%1 will open right-to-left."), folder.Name)
        or T(_("%1 will open left-to-right."), folder.Name)
    local affected = 0
    for _i, d in ipairs(self:listDownloads()) do
        local ids = d.rec.ids or { d.rec.parent_id }
        for _j, id in ipairs(ids) do
            if id == folder.Id then affected = affected + 1 break end
        end
    end
    if affected > 0 then
        self:confirmApplyToDownloaded(text)
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    end
end

local ZOOM_CHOICES = {
    { id = "page", text = _("Whole page") },
    { id = "pagewidth", text = _("Page width") },
    { id = "content", text = _("Whole page, margins trimmed") },
}
local CONTRAST_CHOICES = { 1.0, 1.5, 2.0, 4.0 }
-- KOReader's "View mode" (kopt_page_scroll). nil leaves KOReader's own default alone.
local VIEW_MODE_CHOICES = {
    { id = nil, text = _("KOReader default") },
    { id = "page", text = _("Page"), value = 0 },
    { id = "continuous", text = _("Continuous (scroll)"), value = 1 },
}

function JellyReader:getComicMenuItems()
    local zoom_items, contrast_items, view_items = {}, {}, {}
    for _i, v in ipairs(VIEW_MODE_CHOICES) do
        table.insert(view_items, {
            text = v.text,
            radio = true,
            checked_func = function()
                return self.settings:readSetting("comic_view_mode") == v.id
            end,
            callback = function()
                self.settings:saveSetting("comic_view_mode", v.id)
                self.settings:flush()
            end,
        })
    end
    for _i, z in ipairs(ZOOM_CHOICES) do
        table.insert(zoom_items, {
            text = z.text,
            radio = true,
            checked_func = function()
                return (self.settings:readSetting("comic_zoom") or "page") == z.id
            end,
            callback = function()
                self.settings:saveSetting("comic_zoom", z.id)
                self.settings:flush()
            end,
        })
    end
    for _i, c in ipairs(CONTRAST_CHOICES) do
        table.insert(contrast_items, {
            text = c == 1.0 and _("1.0 (unchanged)") or string.format("%.1f", c),
            radio = true,
            checked_func = function()
                return (self.settings:readSetting("comic_contrast") or 1.0) == c
            end,
            callback = function()
                self.settings:saveSetting("comic_contrast", c)
                self.settings:flush()
            end,
        })
    end
    local function names(key)
        local list = {}
        for _id, name in pairs(self.settings:readSetting(key) or {}) do table.insert(list, name) end
        table.sort(list)
        return list
    end
    local manga_list, except_list = names("manga"), names("manga_off")
    return {
        settingToggle(self, "comic_defaults", _("Apply these settings to new comics"),
            _([[Applied the first time a downloaded comic (CBZ, CBR, CB7, CBT) is opened. Changes you make in KOReader afterwards are kept.]])),
        {
            text_func = function()
                local z = self.settings:readSetting("comic_zoom") or "page"
                for _i, c in ipairs(ZOOM_CHOICES) do
                    if c.id == z then return T(_("Fit: %1"), c.text) end
                end
            end,
            sub_item_table = zoom_items,
        },
        {
            text_func = function()
                local mode = self.settings:readSetting("comic_view_mode")
                for _i, v in ipairs(VIEW_MODE_CHOICES) do
                    if v.id == mode then return T(_("View mode: %1"), v.text) end
                end
            end,
            help_text = _([[Page shows one page at a time. Continuous lets you scroll through pages like a long strip, which suits webtoons; it works best with Fit set to page width.]]),
            sub_item_table = view_items,
        },
        {
            text_func = function()
                return T(_("Contrast: %1"), string.format("%.1f", self.settings:readSetting("comic_contrast") or 1.0))
            end,
            sub_item_table = contrast_items,
        },
        {
            text_func = function()
                return T(_("Apply to downloaded comics now (%1)"), #self:downloadedBooksForSettings())
            end,
            enabled_func = function() return #self:downloadedBooksForSettings() > 0 end,
            keep_menu_open = true,
            callback = function() self:confirmApplyToDownloaded() end,
            separator = true,
        },
        {
            text = #manga_list > 0 and (T(_("Right-to-left (manga): %1"), table.concat(manga_list, ", "))
                    .. (#except_list > 0 and T(_(" · except %1"), table.concat(except_list, ", ")) or ""))
                or _("Right-to-left (manga): long-press a library or folder to set"),
            enabled = false,
        },
    }
end

local function isComicPath(path)
    return COMIC_EXTENSIONS[(path:match("%.(%w+)$") or ""):lower()] == true
end

--- Seeds KOReader's per-book settings before a book is opened for the first time.
-- With `force`, also rewrites the settings of a book that was already opened
-- (fit, view mode, contrast, reading direction), replacing changes made in KOReader.
-- Returns true if settings were written.
function JellyReader:applyReadingDefaults(path, rtl, force)
    local comic = isComicPath(path) and (force or self.settings:nilOrTrue("comic_defaults"))
    if not comic and not rtl and not force then return false end
    local ok, result = pcall(function()
        local DocSettings = require("docsettings")
        if not force and DocSettings:hasSidecarFile(path) then return false end -- keep the user's own settings
        local ds = DocSettings:open(path)
        if comic then
            ds:saveSetting("zoom_mode", self.settings:readSetting("comic_zoom") or "page")
            local contrast = self.settings:readSetting("comic_contrast") or 1.0
            if contrast ~= 1.0 or force then
                ds:saveSetting("kopt_contrast", contrast)
            end
            local mode = self.settings:readSetting("comic_view_mode")
            local value
            for _i, v in ipairs(VIEW_MODE_CHOICES) do
                if v.id and v.id == mode then value = v.value end
            end
            if value then
                ds:saveSetting("kopt_page_scroll", value)
            elseif force then
                ds:delSetting("kopt_page_scroll") -- back to KOReader's default
            end
        end
        if rtl then
            ds:saveSetting("inverse_reading_order", true)
        elseif force then
            ds:delSetting("inverse_reading_order")
        elseif not comic then
            return false
        end
        ds:flush()
        return true
    end)
    if not ok then
        logger.warn("JellyReader: could not apply reading settings:", result)
        return false
    end
    return result
end

--- Whether a downloaded book should read right-to-left under the current manga settings.
function JellyReader:recordIsManga(rec)
    if rec.ids then return self:isManga(rec.ids) end
    -- Downloads from older versions only know their direct folder.
    return self:isManga({ rec.parent_id }) or rec.rtl == true
end

function JellyReader:downloadedBooksForSettings()
    local list = {}
    for _i, d in ipairs(self:listDownloads()) do
        if isComicPath(d.rec.path) or self:recordIsManga(d.rec) or d.rec.rtl then
            table.insert(list, d)
        end
    end
    return list
end

--- Applies the current comic and manga settings to everything already downloaded.
--- With `open_handled`, the open book was already switched live (no "skipped" note).
function JellyReader:applyToDownloaded(open_handled)
    local current = self:getCurrentItemId()
    local updated, skipped_open = 0, false
    for _i, d in ipairs(self:downloadedBooksForSettings()) do
        if d.id == current then
            -- KOReader saves the open book's settings when it closes, which would undo ours.
            skipped_open = true
        else
            local rtl = self:recordIsManga(d.rec)
            if self:applyReadingDefaults(d.rec.path, rtl, true) then
                updated = updated + 1
                if (d.rec.rtl or false) ~= rtl then
                    d.rec.rtl = rtl or nil
                    self:rememberDownload(d.id, d.rec)
                end
            end
        end
    end
    local msg = updated == 1 and _("Updated 1 downloaded book.") or T(_("Updated %1 downloaded books."), updated)
    if skipped_open and open_handled then
        skipped_open = false
    end
    if skipped_open then
        msg = msg .. "\n\n" .. _("The open book was skipped: close it and apply again, or change it from KOReader's menu.")
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = skipped_open and nil or 3 })
end

function JellyReader:confirmApplyToDownloaded(intro, open_handled)
    local count = #self:downloadedBooksForSettings()
    if open_handled and self:getCurrentItemId() then count = count - 1 end
    if count == 0 then
        if not intro then
            UIManager:show(InfoMessage:new{ text = _("No downloaded comics."), timeout = 2 })
        end
        return
    end
    UIManager:show(ConfirmBox:new{
        text = (intro and intro .. "\n\n" or "")
            .. T(_("Apply the current comic settings (fit, view mode, contrast, reading direction) to %1 downloaded books?\n\nThis replaces changes you made to them in KOReader."), count),
        ok_text = _("Apply"),
        cancel_text = intro and _("Only new downloads") or _("Cancel"),
        ok_callback = function() self:applyToDownloaded(open_handled) end,
    })
end

---------------------------------------------------------------- local files

-- Download records, by Jellyfin item id:
-- { path = ".../Jellyfin/Comics/Saga/Saga 01.cbz", dir = ".../Saga",
--   item = { Id, Name, ... }, parent_id = "...", series = bool, series_name = "Saga",
--   next = { Id, Name, Path, Container }, rtl = bool, opened = time, finished = bool }
-- `next` lets us continue a series even when the Kindle is offline.
function JellyReader:getDownloads()
    return self.settings:readSetting("downloads") or {}
end

function JellyReader:getDownload(item_id)
    local rec = self:getDownloads()[item_id]
    if type(rec) == "string" then rec = { path = rec } end -- records from version 1.0
    return rec
end

function JellyReader:getLocalPath(item_id)
    local rec = self:getDownload(item_id)
    if rec and rec.path and lfs.attributes(rec.path, "mode") == "file" then
        return rec.path
    end
    return nil
end

function JellyReader:rememberDownload(item_id, rec)
    local downloads = self:getDownloads()
    downloads[item_id] = rec
    self.settings:saveSetting("downloads", downloads)
    self.settings:flush()
end

function JellyReader:forgetDownload(item_id)
    local downloads = self:getDownloads()
    downloads[item_id] = nil
    self.settings:saveSetting("downloads", downloads)
    self.settings:flush()
end

function JellyReader:getItemIdForPath(path)
    if not path then return nil end
    for id, rec in pairs(self:getDownloads()) do
        if (type(rec) == "table" and rec.path or rec) == path then return id end
    end
end

function JellyReader:getCurrentItemId()
    local doc = self.ui and self.ui.document
    return doc and self:getItemIdForPath(doc.file)
end

--- Fills in what a download needs (folder on disk, reading order) for items
-- that were not reached by browsing their folder (search, authors, next part...).
-- Never modifies the given context.
function JellyReader:resolveContext(it, ctx)
    if ctx and not ctx.virtual and (ctx.dir or ctx.crumbs)
            and (ctx.siblings or not ctx.parent_id or ctx.is_series == false) then
        return ctx
    end
    local r = {}
    if ctx and not ctx.virtual then
        for k, v in pairs(ctx) do r[k] = v end
    end
    local client = self:getClient()
    if not r.dir and not r.crumbs then
        local ancestors = client:getAncestors(it.Id)
        if ancestors and ancestors[1] then
            r.crumbs, r.ids = {}, {}
            for i = #ancestors, 1, -1 do
                table.insert(r.crumbs, ancestors[i].Name)
                table.insert(r.ids, ancestors[i].Id)
            end
            local parent = ancestors[1]
            r.parent_id = r.parent_id or parent.Id
            r.is_series = isSeriesFolder(parent)
            r.series_name = parent.Name
        else
            r.crumbs = {}
        end
    end
    r.parent_id = r.parent_id or (type(it.ParentId) == "string" and it.ParentId or nil)
    if r.siblings == nil and r.parent_id and r.is_series ~= false then
        local children = client:getChildren(r.parent_id)
        r.siblings = children and booksOnly(children) or nil
    end
    if r.rtl == nil then r.rtl = self:isManga(r.ids) end
    return r
end

function JellyReader:dirForContext(ctx)
    if ctx.dir then return ctx.dir end
    local dir = self:getDownloadDir()
    for _i, c in ipairs(ctx.crumbs or {}) do
        dir = dir .. "/" .. safeFilename(c)
    end
    return dir
end

--- Picks a file name in dir that no other downloaded item already uses.
function JellyReader:uniqueBasename(dir, it)
    local base = safeFilename(it.Name)
    local prefix = dir .. "/" .. base .. "."
    for id, rec in pairs(self:getDownloads()) do
        local p = type(rec) == "table" and rec.path or rec
        if id ~= it.Id and type(p) == "string" and p:sub(1, #prefix) == prefix
                and not p:sub(#prefix + 1):find("[/.]") then
            return base .. " (" .. it.Id:sub(1, 6) .. ")"
        end
    end
    return base
end

function JellyReader:makeRecord(it, path, ctx)
    local nxt = ctx.is_series ~= false and nextSibling(ctx.siblings, it.Id) or nil
    return {
        path = path,
        dir = path:match("^(.*)/[^/]*$"),
        item = minimalItem(it),
        parent_id = ctx.parent_id,
        series = ctx.is_series ~= false and ctx.parent_id ~= nil,
        series_name = ctx.series_name,
        next = nxt and minimalItem(nxt) or nil,
        rtl = ctx.rtl or nil,
        ids = ctx.ids,
        opened = os.time(),
    }
end

--- Downloads one item. Returns the local path, or nil, error, error kind.
-- `bulk` downloads (Download all parts) also respect the storage limit.
function JellyReader:downloadItem(it, ctx, busy_text, bulk)
    local room, room_err = self:makeRoom(bulk, it.Id)
    if not room then return nil, room_err, "nospace" end
    local client = self:getClient()
    local path, err = self:withBusy(busy_text or T(_("Downloading\n%1…"), it.Name or ""), function()
        ctx = self:resolveContext(it, ctx)
        local dir = self:dirForContext(ctx)
        if lfs.attributes(dir, "mode") ~= "directory" then
            util.makePath(dir)
        end
        return client:download(it, dir, self:uniqueBasename(dir, it))
    end)
    if not path then return nil, err end
    self:rememberDownload(it.Id, self:makeRecord(it, path, ctx))
    self:applyReadingDefaults(path, ctx.rtl)
    self:enforceLimit(it.Id)
    return path
end

function JellyReader:downloadAll(ctx)
    local books = ctx.siblings or {}
    local done, skipped, failed, last_err = 0, 0, 0, nil
    local stopped
    for i, b in ipairs(books) do
        if self:getLocalPath(b.Id) then
            skipped = skipped + 1
            if not ctx.virtual then
                -- Keep the reading order up to date for parts downloaded earlier.
                local rec = self:getDownload(b.Id)
                local nxt = ctx.is_series ~= false and nextSibling(books, b.Id) or nil
                rec.next = nxt and minimalItem(nxt) or nil
                rec.parent_id = rec.parent_id or ctx.parent_id
                rec.item = rec.item or minimalItem(b)
                self:rememberDownload(b.Id, rec)
            end
        else
            local path, err, kind = self:downloadItem(b, ctx,
                T(_("Downloading %1 of %2\n%3…"), i, #books, b.Name or ""), true)
            if path then
                done = done + 1
            elseif kind == "nospace" then
                stopped = err
                break
            else
                failed = failed + 1
                last_err = err
                if err and err:match("not permitted") then break end
            end
        end
    end
    local msg = T(_("Downloaded %1, already on device %2."), done, skipped)
    if failed > 0 then
        msg = msg .. "\n" .. T(_("%1 failed: %2"), failed, last_err)
    end
    if stopped then
        msg = msg .. "\n\n" .. stopped .. "\n" .. _("The remaining parts can be downloaded as you read.")
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = (failed > 0 or stopped) and nil or 3 })
end

--- Deletes a downloaded file. With keep_metadata, KOReader's small .sdr folder
-- (page, highlights) stays, so downloading the book again picks up where you were.
function JellyReader:deleteLocal(item_id, keep_metadata)
    local path = self:getLocalPath(item_id)
    if path then
        os.remove(path)
        if not keep_metadata then
            pcall(function() require("docsettings").updateLocation(path) end)
        end
        local dir = path:match("^(.*)/[^/]*$")
        if dir then lfs.rmdir(dir) end -- only succeeds if now empty
    end
    self:forgetDownload(item_id)
end

function JellyReader:deleteAll(ctx)
    local count = 0
    for _i, b in ipairs(ctx.siblings or {}) do
        if self:getLocalPath(b.Id) then count = count + 1 end
    end
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No parts downloaded."), timeout = 2 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1 downloaded parts?"), count),
        ok_text = _("Delete"),
        ok_callback = function()
            for _i, b in ipairs(ctx.siblings) do self:deleteLocal(b.Id) end
        end,
    })
end

function JellyReader:openPath(path)
    self:closeAllMenus()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function JellyReader:openItem(it, ctx)
    self:waitForPrefetch(it.Id)
    local path = self:getLocalPath(it.Id)
    if path then
        self:openPath(path)
        return
    end
    self:runOnline(function()
        local downloaded, err = self:downloadItem(it, ctx)
        if downloaded then
            self:openPath(downloaded)
        else
            self:showError(err)
        end
    end)
end

function JellyReader:showItemActions(it, ctx)
    local local_path = self:getLocalPath(it.Id)
    local played = isPlayed(it)
    local dialog
    local buttons = {
        {{
            text = local_path and _("Open") or _("Download and open"),
            callback = function()
                UIManager:close(dialog)
                self:openItem(it, ctx)
            end,
        }},
        {{
            text = local_path and _("Download again") or _("Download only"),
            callback = function()
                UIManager:close(dialog)
                self:runOnline(function()
                    local path, err = self:downloadItem(it, ctx)
                    if path then
                        UIManager:show(InfoMessage:new{ text = _("Downloaded."), timeout = 2 })
                    else
                        self:showError(err)
                    end
                end)
            end,
        }},
        {{
            text = played and _("Mark as unread in Jellyfin") or _("Mark as read in Jellyfin"),
            callback = function()
                UIManager:close(dialog)
                it.UserData = type(it.UserData) == "table" and it.UserData or {}
                it.UserData.Played = not played
                self:setFinished(it.Id, not played)
                self:queueSync(it.Id, { played = not played })
                local sent = self:flushSync()
                UIManager:show(InfoMessage:new{
                    text = sent and _("Updated.") or _("Saved. It will be sent to Jellyfin when you're online."),
                    timeout = 2,
                })
            end,
        }},
    }
    if local_path then
        table.insert(buttons, {{
            text = _("Delete downloaded file"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete %1?"), local_path),
                    ok_text = _("Delete"),
                    ok_callback = function() self:deleteLocal(it.Id) end,
                })
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = it.Name,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

---------------------------------------------------------------- storage

local MB = 1024 * 1024
-- Never fill the Kindle completely: it misbehaves badly when the disk is full.
local MIN_FREE_BYTES = 50 * MB
local LIMIT_CHOICES_MB = { 500, 1024, 2048, 4096, 8192 }

local function formatSize(bytes)
    if bytes >= 1024 * MB then
        return string.format("%.1f GB", bytes / (1024 * MB))
    end
    return string.format("%.1f MB", bytes / MB)
end

local function fileSize(path)
    return lfs.attributes(path, "size") or 0
end

--- Free bytes on the filesystem holding `dir` (nil if unknown).
local function freeBytes(dir)
    -- Needs an existing path; walk up until we find one.
    while dir and dir ~= "" and lfs.attributes(dir, "mode") ~= "directory" do
        dir = dir:match("^(.*)/[^/]*$")
    end
    if not dir or dir == "" then dir = "/" end
    local ok, usage = pcall(util.diskUsage, dir)
    if ok and type(usage) == "table" and usage.available then
        return usage.available
    end
    return nil
end

function JellyReader:setFinished(item_id, finished)
    local rec = self:getDownload(item_id)
    if not rec then return end
    rec.finished = finished or nil
    self:rememberDownload(item_id, rec)
end

--- All downloads whose file still exists: { {id=, rec=, size=}, ... }
-- Records for files deleted outside the plugin are dropped.
function JellyReader:listDownloads()
    local list, stale = {}, {}
    for id in pairs(self:getDownloads()) do
        local rec = self:getDownload(id)
        if rec.path and lfs.attributes(rec.path, "mode") == "file" then
            table.insert(list, { id = id, rec = rec, size = fileSize(rec.path) })
        else
            table.insert(stale, id)
        end
    end
    if #stale > 0 then
        local downloads = self:getDownloads()
        for _i, id in ipairs(stale) do downloads[id] = nil end
        self.settings:saveSetting("downloads", downloads)
        self.settings:flush()
    end
    table.sort(list, function(a, b) return a.rec.path < b.rec.path end)
    return list
end

function JellyReader:totalDownloadedBytes()
    local total = 0
    for _i, d in ipairs(self:listDownloads()) do total = total + d.size end
    return total
end

--- Finished downloads, least recently opened first, never the open book or `keep_id`.
function JellyReader:finishedOldestFirst(keep_id)
    local current = self:getCurrentItemId()
    local list = {}
    for _i, d in ipairs(self:listDownloads()) do
        if d.rec.finished and d.id ~= current and d.id ~= keep_id then
            table.insert(list, d)
        end
    end
    table.sort(list, function(a, b) return (a.rec.opened or 0) < (b.rec.opened or 0) end)
    return list
end

function JellyReader:getLimitBytes()
    local mb = self.settings:readSetting("storage_limit_mb")
    return mb and mb * MB or nil
end

--- Deletes finished parts (oldest first) while over the storage limit.
function JellyReader:enforceLimit(keep_id)
    local limit = self:getLimitBytes()
    if not limit then return end
    local total = self:totalDownloadedBytes()
    for _i, d in ipairs(self:finishedOldestFirst(keep_id)) do
        if total <= limit then break end
        logger.info("JellyReader: over storage limit, deleting", d.rec.path)
        self:deleteLocal(d.id, true)
        total = total - d.size
    end
end

--- Makes sure there is room for one more download, deleting finished parts
-- if needed. Returns true, or nil and a message.
function JellyReader:makeRoom(bulk, keep_id)
    local dir = self:getDownloadDir()
    local limit = bulk and self:getLimitBytes()
    local function problem()
        if limit and self:totalDownloadedBytes() >= limit then
            return T(_("Storage limit of %1 reached."), formatSize(limit))
        end
        local free = freeBytes(dir)
        if free and free < MIN_FREE_BYTES then
            return T(_("The Kindle is almost full (%1 free)."), formatSize(free))
        end
    end
    local why = problem()
    if not why then return true end
    for _i, d in ipairs(self:finishedOldestFirst(keep_id)) do
        self:deleteLocal(d.id, true)
        why = problem()
        if not why then return true end
    end
    return nil, why .. "\n" .. _("Delete some downloads in JellyReader → Storage → Manage downloads.")
end

--- Removes finished parts once you've moved on to another book.
function JellyReader:autoClean()
    if not self.settings:nilOrTrue("auto_clean") then return end
    local freed, count = 0, 0
    for _i, d in ipairs(self:finishedOldestFirst()) do
        self:deleteLocal(d.id, true)
        freed = freed + d.size
        count = count + 1
    end
    if count > 0 then
        logger.info("JellyReader: auto-deleted", count, "finished parts,", formatSize(freed))
    end
end

function JellyReader:getStorageMenuItems()
    local limit_items = {}
    local function addLimit(text, mb)
        table.insert(limit_items, {
            text = text,
            radio = true,
            checked_func = function()
                return self.settings:readSetting("storage_limit_mb") == mb
            end,
            callback = function()
                self.settings:saveSetting("storage_limit_mb", mb)
                self.settings:flush()
                self:enforceLimit()
            end,
        })
    end
    addLimit(_("No limit"), nil)
    for _i, mb in ipairs(LIMIT_CHOICES_MB) do addLimit(formatSize(mb * MB), mb) end

    return {
        {
            text_func = function()
                local free = freeBytes(self:getDownloadDir())
                return T(_("Manage downloads (%1, %2 free)"),
                    formatSize(self:totalDownloadedBytes()),
                    free and formatSize(free) or "?")
            end,
            callback = function() self:showDownloadsManager() end,
        },
        settingToggle(self, "auto_clean", _("Delete finished parts automatically"),
            _([[When you open another book, downloaded parts you have finished are deleted. Your reading position and highlights are kept, so downloading one again continues where you were.]])),
        {
            text_func = function()
                local limit = self:getLimitBytes()
                return T(_("Storage limit: %1"), limit and formatSize(limit) or _("none"))
            end,
            help_text = _([[Above the limit, the oldest finished parts are deleted, and "Download all parts" stops.]]),
            sub_item_table = limit_items,
        },
    }
end

function JellyReader:showDownloadsManager(menu_to_replace)
    local list = self:listDownloads()
    local total, finished_total, finished_count = 0, 0, 0
    for _i, d in ipairs(list) do
        total = total + d.size
        if d.rec.finished then
            finished_total = finished_total + d.size
            finished_count = finished_count + 1
        end
    end
    local free = freeBytes(self:getDownloadDir())
    local base = self:getDownloadDir() .. "/"
    local menu
    local function refresh() self:showDownloadsManager(menu) end
    local function confirmDelete(text, entries)
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = _("Delete"),
            ok_callback = function()
                for _i, d in ipairs(entries) do self:deleteLocal(d.id) end
                refresh()
            end,
        })
    end

    local items = {}
    if finished_count > 0 then
        local finished = {}
        for _i, d in ipairs(list) do
            if d.rec.finished then table.insert(finished, d) end
        end
        table.insert(items, {
            text = T(_("Delete finished (%1)"), finished_count),
            mandatory = formatSize(finished_total),
            callback = function()
                confirmDelete(T(_("Delete %1 finished downloads?"), finished_count), finished)
            end,
        })
    end
    if #list > 0 then
        table.insert(items, {
            text = T(_("Delete all downloads (%1)"), #list),
            mandatory = formatSize(total),
            callback = function()
                confirmDelete(T(_("Delete all %1 downloads (%2)?"), #list, formatSize(total)), list)
            end,
        })
    end
    for _i, d in ipairs(list) do
        local shown_path = d.rec.path:sub(1, #base) == base and d.rec.path:sub(#base + 1) or d.rec.path
        table.insert(items, {
            text = shown_path,
            mandatory = (d.rec.finished and "\u{2713} " or "") .. formatSize(d.size),
            callback = function()
                local dialog
                dialog = ButtonDialog:new{
                    title = shown_path,
                    title_align = "center",
                    buttons = {
                        {{
                            text = _("Open"),
                            callback = function()
                                UIManager:close(dialog)
                                self:openPath(d.rec.path)
                            end,
                        }},
                        {{
                            text = _("Delete"),
                            callback = function()
                                UIManager:close(dialog)
                                self:deleteLocal(d.id)
                                refresh()
                            end,
                        }},
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end
    if #list == 0 then
        table.insert(items, { text = _("No downloads.") })
    end
    menu = self:replaceMenu(menu_to_replace, T(_("Downloads: %1 · %2 free"), formatSize(total),
        free and formatSize(free) or "?"), items)
end

---------------------------------------------------------------- sync with Jellyfin

-- Updates waiting to be sent: { [item_id] = { played = bool|nil, ticks = number|nil } }
-- Kept until the server confirms them, so reading offline loses nothing.

function JellyReader:pendingCount()
    local n = 0
    for _id in pairs(self.settings:readSetting("pending_sync") or {}) do n = n + 1 end
    return n
end

function JellyReader:queueSync(item_id, change)
    local pending = self.settings:readSetting("pending_sync") or {}
    local p = pending[item_id] or {}
    if change.played ~= nil then
        p.played = change.played
        -- Marking as read resets the position in Jellyfin; an older position is meaningless.
        if change.played then p.ticks = nil end
    end
    if change.ticks then p.ticks = change.ticks end
    pending[item_id] = p
    self.settings:saveSetting("pending_sync", pending)
    self.settings:flush()
end

--- Sends pending updates if online. Returns true when nothing is left to send.
function JellyReader:flushSync()
    local pending = self.settings:readSetting("pending_sync") or {}
    if next(pending) == nil then return true end
    if self.syncing or not self:isLoggedIn() or not NetworkMgr:isOnline() then return false end
    self.syncing = true
    local client = self:getClient()
    local function settled(ok, code)
        -- Retry later on network errors, server errors and expired logins;
        -- drop updates the server rejects for good (e.g. a deleted book).
        return ok or (type(code) == "number" and code >= 400 and code < 500 and code ~= 401)
    end
    for id, p in pairs(pending) do
        local all_ok = true
        if p.played ~= nil then
            local ok, err, code = client:setPlayed(id, p.played)
            if settled(ok, code) then
                p.played = nil
            else
                logger.warn("JellyReader: sync failed, will retry:", err)
                all_ok = false
            end
        end
        if all_ok and p.ticks then
            local ok, err, code = client:setPosition(id, p.ticks)
            if settled(ok, code) then
                p.ticks = nil
            else
                logger.warn("JellyReader: sync failed, will retry:", err)
                all_ok = false
            end
        end
        if all_ok then pending[id] = nil else break end
    end
    self.settings:saveSetting("pending_sync", pending)
    self.settings:flush()
    self.syncing = false
    return next(pending) == nil
end

function JellyReader:onNetworkConnected()
    -- Give the connection a moment to settle before talking to the server.
    UIManager:scheduleIn(2, function() self:flushSync() end)
end

--- Current position in Jellyfin's format, or nil.
function JellyReader:currentTicks()
    local ui = self.ui
    if not ui or not ui.document then return nil end
    if ui.paging and ui.paging.current_page then
        return math.max(0, ui.paging.current_page - 1) * TICKS_PER_PAGE
    end
    if ui.rolling and ui.rolling.getLastPercent then
        local pct = ui.rolling:getLastPercent()
        if pct then return math.floor(pct * TICKS_FULL_BOOK) end
    end
end

--- Saves the current position for Jellyfin; sends it right away unless `queue_only`.
function JellyReader:pushPosition(queue_only)
    if not self.settings:nilOrTrue("sync_position") then return end
    local item_id = self:getCurrentItemId()
    if not item_id then return end
    local rec = self:getDownload(item_id)
    if rec.finished then return end -- already sent as "read"
    local ticks = self:currentTicks()
    if not ticks then return end
    if rec.synced_ticks == ticks then return end
    rec.synced_ticks = ticks
    self:rememberDownload(item_id, rec)
    self:queueSync(item_id, { ticks = ticks })
    if not queue_only then self:flushSync() end
end

function JellyReader:onCloseDocument()
    self:pushPosition()
end

-- Going to sleep must not wait for the network: just remember the position.
function JellyReader:onSuspend()
    self:pushPosition(true)
end

--- Offers to jump ahead when Jellyfin has a later position than this device.
function JellyReader:pullPosition(item_id)
    if not self.settings:nilOrTrue("sync_position") then return end
    if not self:isLoggedIn() or not NetworkMgr:isOnline() then return end
    local pending = self.settings:readSetting("pending_sync") or {}
    if pending[item_id] and pending[item_id].ticks then return end -- our position is newer
    local data = self:getClient():getUserData(item_id)
    if type(data) ~= "table" then return end
    -- Marking a book read clears its position in Jellyfin, so any position here
    -- is newer than that (e.g. re-reading a finished book).
    local ticks = tonumber(data.PlaybackPositionTicks)
    if not ticks or ticks <= 0 then return end
    local ui = self.ui
    local text, jump
    if ui.paging and ui.paging.current_page then
        local total = ui.document:getPageCount()
        local page = math.min(math.floor(ticks / TICKS_PER_PAGE) + 1, total)
        if page <= ui.paging.current_page then return end
        text = T(_("Jellyfin has a later position: page %1 of %2."), page, total)
        jump = function() ui:handleEvent(Event:new("GotoPage", page)) end
    elseif ui.rolling and ui.rolling.getLastPercent then
        local server = math.min(ticks / TICKS_FULL_BOOK, 1)
        local here = ui.rolling:getLastPercent() or 0
        if server - here < 0.01 then return end
        text = T(_("Jellyfin has a later position: %1 %."), math.floor(server * 100))
        jump = function() ui:handleEvent(Event:new("GotoPercent", server * 100)) end
    else
        return
    end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Jump there?"),
        ok_text = _("Jump"),
        cancel_text = _("Stay here"),
        ok_callback = jump,
    })
end

---------------------------------------------------------------- continue reading

-- What you're in the middle of, newest first. One entry per series (its current
-- or next part) and per standalone book:
-- { [key] = { key, title, item, dir, parent_id, series, series_name, rtl, updated } }

local function readingKey(item_id, rec)
    if rec and rec.series and rec.parent_id then return "s:" .. rec.parent_id end
    return "b:" .. item_id
end

function JellyReader:getReading()
    return self.settings:readSetting("reading") or {}
end

function JellyReader:saveReading(reading)
    self.settings:saveSetting("reading", reading)
    self.settings:flush()
end

function JellyReader:touchReading(item_id, rec, item)
    local reading = self:getReading()
    local key = readingKey(item_id, rec)
    reading[key] = {
        key = key,
        item = item or rec.item or { Id = item_id, Name = (rec.path or ""):match("([^/]+)%.[^.]+$") },
        dir = rec.dir,
        parent_id = rec.parent_id,
        series = rec.series or nil,
        series_name = rec.series_name,
        rtl = rec.rtl,
        ids = rec.ids,
        updated = os.time(),
    }
    self:saveReading(reading)
end

--- Called when a book is finished: the series moves on to its next part, or leaves the list.
function JellyReader:advanceReading(item_id, nxt)
    local rec = self:getDownload(item_id)
    local reading = self:getReading()
    local key = readingKey(item_id, rec)
    local entry = reading[key]
    if entry and entry.item and entry.item.Id ~= item_id then return end -- already moved on
    if rec and rec.series and nxt then
        local updated = entry or {}
        updated.key, updated.item, updated.updated = key, nxt, os.time()
        updated.dir, updated.parent_id = rec.dir, rec.parent_id
        updated.series, updated.series_name, updated.rtl, updated.ids = true, rec.series_name, rec.rtl, rec.ids
        reading[key] = updated
    else
        reading[key] = nil
    end
    self:saveReading(reading)
end

--- Continue-reading entries, newest first. With `with_server`, books that have a
-- position in Jellyfin (from other devices) are added when online.
function JellyReader:getContinueEntries(with_server)
    local list = {}
    local seen_items, seen_parents = {}, {}
    for _key, entry in pairs(self:getReading()) do
        if entry.item and entry.item.Id then
            table.insert(list, entry)
            seen_items[entry.item.Id] = true
            if entry.parent_id then seen_parents[entry.parent_id] = true end
        end
    end
    table.sort(list, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
    if with_server and self:isLoggedIn() and NetworkMgr:isOnline() then
        local resume = self:getClient():getResume()
        for _i, it in ipairs(resume or {}) do
            if not seen_items[it.Id] and not (it.ParentId and seen_parents[it.ParentId]) then
                table.insert(list, { key = "r:" .. it.Id, item = minimalItem(it), from_server = true })
                seen_items[it.Id] = true
            end
        end
    end
    return list
end

function JellyReader:continueContext(entry)
    if entry.from_server then return nil end
    return {
        ids = entry.ids,
        dir = entry.dir,
        parent_id = entry.parent_id,
        is_series = entry.series and true or false,
        series_name = entry.series_name,
        rtl = entry.rtl,
    }
end

function JellyReader:makeContinueEntry(entry, on_change)
    local item = entry.item
    local downloaded = self:getLocalPath(item.Id) ~= nil
    local text = item.Name or "?"
    if entry.series and entry.series_name and entry.series_name ~= "" then
        text = entry.series_name .. " · " .. text
    end
    return {
        text = "\u{25B6} " .. text,
        mandatory = downloaded and "\u{2193}" or (entry.from_server and _("other device") or nil),
        callback = function() self:openItem(item, self:continueContext(entry)) end,
        hold_callback = function()
            if entry.from_server then return end
            UIManager:show(ConfirmBox:new{
                text = T(_("Remove %1 from Continue reading?"), text),
                ok_text = _("Remove"),
                ok_callback = function()
                    local reading = self:getReading()
                    reading[entry.key] = nil
                    self:saveReading(reading)
                    if on_change then on_change() end
                end,
            })
        end,
    }
end

function JellyReader:showContinue(menu_to_replace)
    local entries = self:getContinueEntries(true)
    local menu
    local items = {}
    for _i, entry in ipairs(entries) do
        table.insert(items, self:makeContinueEntry(entry, function() self:showContinue(menu) end))
    end
    if #items == 0 then
        if menu_to_replace then menu_to_replace.close_callback() end
        UIManager:show(InfoMessage:new{
            text = _("Nothing in progress. Books and series you start reading will show up here."),
            timeout = 3,
        })
        return
    end
    menu = self:replaceMenu(menu_to_replace, _("Continue reading"), items)
end

function JellyReader:onJellyfinContinue()
    self:showContinue()
    return true
end

---------------------------------------------------------------- series reading

--- Finds the part after item_id: from the saved record when possible (works offline),
-- otherwise by asking the server.
function JellyReader:findNextPart(item_id)
    local rec = self:getDownload(item_id)
    if not rec then return nil end
    if rec.series == false then return nil, rec end
    if rec.next then return rec.next, rec end
    if rec.parent_id and NetworkMgr:isOnline() and self:isLoggedIn() then
        local children = self:getClient():getChildren(rec.parent_id)
        if children then
            local nxt = nextSibling(booksOnly(children), item_id)
            if nxt then
                rec.next = minimalItem(nxt)
                self:rememberDownload(item_id, rec)
                return rec.next, rec
            end
        end
    end
    return nil, rec
end

function JellyReader:nextPartContext(rec)
    return {
        ids = rec.ids,
        dir = rec.dir,
        parent_id = rec.parent_id,
        is_series = true,
        series_name = rec.series_name,
        rtl = rec.rtl,
    }
end

function JellyReader:openNextPart(item_id)
    local nxt, rec = self:findNextPart(item_id)
    if not nxt then
        UIManager:show(InfoMessage:new{ text = _("This is the last part."), timeout = 2 })
        return
    end
    -- Saved next to the current part; the server is asked for the order after it.
    self:openItem(nxt, self:nextPartContext(rec))
end

function JellyReader:onJellyfinNextPart()
    local item_id = self:getCurrentItemId()
    if not item_id then
        UIManager:show(InfoMessage:new{
            text = _("The open book was not downloaded from Jellyfin."),
            timeout = 2,
        })
        return true
    end
    local rec = self:getDownload(item_id)
    local nxt = rec.next
    if (nxt and self:getLocalPath(nxt.Id)) or (prefetch and nxt and prefetch.item.Id == nxt.Id)
            or NetworkMgr:isOnline() then
        self:openNextPart(item_id)
    else
        self:runOnline(function() self:openNextPart(item_id) end)
    end
    return true
end

--- Called once when the last page of a Jellyfin book is reached.
function JellyReader:onReachedEnd(item_id)
    self:setFinished(item_id, true)
    if self.settings:nilOrTrue("sync_finished") then
        self:queueSync(item_id, { played = true })
        self:flushSync()
    end
    local nxt = self:findNextPart(item_id)
    self:advanceReading(item_id, nxt)
    if not nxt then return end
    local ready = self:getLocalPath(nxt.Id) ~= nil or (prefetch ~= nil and prefetch.item.Id == nxt.Id)
    UIManager:show(ConfirmBox:new{
        text = T(_("End of this part.\n\nNext: %1"), nxt.Name or ""),
        ok_text = ready and _("Open next") or _("Download & open next"),
        cancel_text = _("Not now"),
        ok_callback = function() self:onJellyfinNextPart() end,
    })
end

function JellyReader:checkEnd(page)
    if self.end_reached then return end
    local doc = self.ui and self.ui.document
    if not doc or not page then return end
    local total = doc:getPageCount()
    if not total or total <= 0 then return end
    if not self.seen_first_page then
        -- Re-opening a book that was left on its last page shouldn't nag.
        self.seen_first_page = true
        if page >= total then
            self.end_reached = true
            local item_id = self:getCurrentItemId()
            if item_id then self:setFinished(item_id, true) end
            return
        end
    end
    if page / total >= PREFETCH_AT then self:maybePrefetch() end
    if page < total then return end
    local item_id = self:getCurrentItemId()
    if not item_id then return end
    self.end_reached = true
    UIManager:nextTick(function() self:onReachedEnd(item_id) end)
end

function JellyReader:onPageUpdate(page)
    self:checkEnd(page)
end

-- Swiping past the last page (or scroll mode, which has no page updates).
function JellyReader:onEndOfBook()
    if self.end_reached then return end
    local item_id = self:getCurrentItemId()
    if not item_id then return end
    self.end_reached = true
    UIManager:nextTick(function() self:onReachedEnd(item_id) end)
    -- Don't swallow the event: KOReader's own end-of-book actions need it.
end

function JellyReader:onReaderReady()
    local item_id = self:getCurrentItemId()
    if item_id then
        local rec = self:getDownload(item_id)
        rec.opened = os.time()
        rec.finished = nil -- reading it again
        self:rememberDownload(item_id, rec)
        self:touchReading(item_id, rec)
    end
    -- Done after the book is shown, so opening it is not slowed down.
    UIManager:nextTick(function()
        self:autoClean()
        if NetworkMgr:isOnline() then
            self:flushSync()
            if item_id then self:pullPosition(item_id) end
        end
    end)
end

---------------------------------------------------------------- background download

--- Starts downloading the next part when Wi-Fi is already on (never turns it on).
function JellyReader:maybePrefetch()
    if self.prefetch_checked then return end
    self.prefetch_checked = true
    if prefetch or not self.settings:nilOrTrue("prefetch") then return end
    if not self:isLoggedIn() or not NetworkMgr:isOnline() then return end
    local item_id = self:getCurrentItemId()
    if not item_id then return end
    local nxt, rec = self:findNextPart(item_id)
    if not nxt or self:getLocalPath(nxt.Id) then return end
    if not self:makeRoom(true, nxt.Id) then return end
    self:startPrefetch(nxt, rec)
end

function JellyReader:startPrefetch(nxt, rec)
    local dir = rec.dir
    if lfs.attributes(dir, "mode") ~= "directory" then util.makePath(dir) end
    local basename = self:uniqueBasename(dir, nxt)
    local client = self:getClient()
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local path, err = client:download(nxt, dir, basename)
        ffiutil.writeToFD(write_fd, path and ("OK:" .. path) or ("ERR:" .. tostring(err)), true)
    end, true)
    if not pid then
        logger.warn("JellyReader: could not start background download")
        return
    end
    logger.info("JellyReader: downloading next part in the background:", nxt.Name)
    prefetch = {
        pid = pid,
        fd = read_fd,
        item = nxt,
        ctx = self:nextPartContext(rec),
    }
    UIManager:scheduleIn(1, function() JellyReader.pollPrefetch(JellyReader) end)
end

function JellyReader.pollPrefetch(self)
    if not prefetch then return end
    if not ffiutil.isSubProcessDone(prefetch.pid) then
        UIManager:scheduleIn(1, function() JellyReader.pollPrefetch(self) end)
        return
    end
    self:finishPrefetch()
end

function JellyReader:finishPrefetch()
    local p = prefetch
    prefetch = nil
    local out = p.fd and ffiutil.readAllFromFD(p.fd) or ""
    local path = type(out) == "string" and out:match("^OK:(.+)$")
    if not path then
        logger.warn("JellyReader: background download failed:", out)
        return
    end
    local ctx = p.ctx
    local rec = self:makeRecord(p.item, path, ctx)
    rec.next = nil -- learned from the server when needed
    self:rememberDownload(p.item.Id, rec)
    self:applyReadingDefaults(path, ctx.rtl)
    logger.info("JellyReader: next part ready:", path)
end

--- If item_id is being downloaded in the background, waits for it to finish.
function JellyReader:waitForPrefetch(item_id)
    if not prefetch or prefetch.item.Id ~= item_id then return end
    self:withBusy(T(_("Finishing download\n%1…"), prefetch.item.Name or ""), function()
        while not ffiutil.isSubProcessDone(prefetch.pid) do
            ffiutil.sleep(1)
        end
    end)
    self:finishPrefetch()
end

return JellyReader
