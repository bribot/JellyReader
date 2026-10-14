-- Runs the plugin's UI code against the mock server with KOReader widgets stubbed out.
-- usage: luajit test_all.lua PORT DIR MODE(modern|legacy)
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/../jellyreader.koplugin/?.lua;" .. package.path
local port, dir, mode = arg[1], arg[2], arg[3]
local LEGACY = mode == "legacy"
local http = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")

---------------------------------------------------------------- stubs
local shown, opened, closed, events = {}, nil, {}, {}
local scheduled = {}
ONLINE = true
local function widget(name) return { new = function(cls, o) o = o or {}; o._kind = name
    o.getFields = function(self) return self._answers end
    o.getInputText = function(self) return self._answer end
    o.onShowKeyboard = function() end
    return o end } end
local settings_store
local LuaSettings = { open = function(_, f) local s = {data={}}
    function s:readSetting(k) return self.data[k] end
    function s:saveSetting(k,v) self.data[k]=v end
    function s:delSetting(k) self.data[k]=nil end
    function s:flush() end
    function s:isTrue(k) return self.data[k]==true end
    function s:flipTrue(k) self.data[k] = not self.data[k] or nil end
    function s:nilOrTrue(k) return self.data[k]==nil or self.data[k]==true end
    function s:flipNilOrTrue(k) if self:nilOrTrue(k) then self.data[k]=false else self.data[k]=nil end end
    settings_store = s; return s end }
local function sh(cmd) local ok = os.execute(cmd); return ok == 0 or ok == true end
local function isdir(p) return sh("test -d '"..p.."'") end
-- DocSettings: sidecar is "<file without ext>.sdr/metadata.lua" (KOReader's "doc" location)
local function sdrOf(p) return (p:gsub("%.[^./]+$", "")) .. ".sdr" end
local sidecars = {}
local DocSettings = {
    hasSidecarFile = function(_, p) return isdir(sdrOf(p)) end,
    open = function(_, p) local ds = { data = {}, p = p }
        for k, v in pairs(sidecars[p] or {}) do ds.data[k] = v end -- existing settings are loaded
        function ds:saveSetting(k, v) self.data[k] = v end
        function ds:delSetting(k) self.data[k] = nil end
        function ds:readSetting(k) return self.data[k] end
        function ds:flush() sh("mkdir -p '"..sdrOf(self.p).."'"); sidecars[self.p] = self.data end
        return ds end,
    updateLocation = function(p) sh("rm -rf '"..sdrOf(p).."'"); sidecars[p] = nil end,
}
local subprocs = {}
local ffiutil = {
    template = function(s, ...) local a = {...}; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end,
    -- Subprocesses run when first polled, so a download can be "in progress" for a while.
    runInSubProcess = function(fn, with_pipe) local id = #subprocs + 1
        subprocs[id] = { fn = fn, out = "" }; return id, id end,
    isSubProcessDone = function(id) local sp = subprocs[id]
        if not sp.done then sp.fn(id, id); sp.done = true end return true end,
    writeToFD = function(fd, s) subprocs[fd].out = s end,
    readAllFromFD = function(fd) return subprocs[fd].out end,
    sleep = function() end,
}
local stubs = {
  ["gettext"] = function(s) return s end,
  ["ui/widget/buttondialog"] = widget("ButtonDialog"),
  ["ui/widget/confirmbox"] = widget("ConfirmBox"),
  ["datastorage"] = { getSettingsDir=function() return dir end, getDataDir=function() return dir end },
  ["device"] = { model="KindlePaperWhite5", home_dir=dir },
  ["dispatcher"] = { registerAction=function() end },
  ["docsettings"] = DocSettings,
  ["ui/event"] = { new = function(_, name, arg1) return { name = name, arg = arg1 } end },
  ["ui/widget/infomessage"] = widget("InfoMessage"),
  ["ui/widget/inputdialog"] = widget("InputDialog"),
  ["luasettings"] = LuaSettings,
  ["ui/widget/menu"] = widget("Menu"),
  ["ui/widget/multiinputdialog"] = widget("MultiInputDialog"),
  ["ui/network/manager"] = { runWhenOnline=function(_, f) ONLINE=true; f() end, isOnline=function() return ONLINE end },
  ["ui/uimanager"] = { show=function(_, w) table.insert(shown, w) end, close=function(_, w) closed[w]=true end,
                       forceRePaint=function() end, nextTick=function(_, f) f() end,
                       scheduleIn=function(_, s, f) table.insert(scheduled, f) end },
  ["ui/widget/container/widgetcontainer"] = { extend=function(_, o) return o end },
  ["ffi/util"] = ffiutil,
  ["libs/libkoreader-lfs"] = { attributes=function(p, k) local f=io.open(p) if not f then return nil end
        if k=="size" then local n=f:seek("end"); f:close(); return n end f:close()
        return isdir(p) and "directory" or "file" end,
        rmdir=function(p) sh("rmdir '"..p.."' 2>/dev/null") end },
  ["logger"] = { err=print, warn=function() end, info=function() end, dbg=function() end },
  ["util"] = { trim=function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end, makePath=function(p) sh("mkdir -p '"..p.."'") end,
               diskUsage=function() return { available = FREE or 10^10 } end },
  ["apps/reader/readerui"] = { showReader=function(_, p) opened = p end },
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
G_reader_settings = { readSetting=function() return nil end }

---------------------------------------------------------------- helpers
local function last(kind) for i=#shown,1,-1 do if shown[i]._kind==kind then return shown[i] end end end
local function texts(menu) local t = {} for _, it in ipairs(menu.item_table) do t[#t+1] = it.text end return table.concat(t, " | ") end
local function find(menu, text)
    for _, it in ipairs(menu.item_table) do if it.text==text then return it end end
    for _, it in ipairs(menu.item_table) do if it.text and it.text:find(text, 1, true) == 1 then return it end end
    error("no item '"..text.."' in: "..texts(menu), 2) end
local function runScheduled() local n = 0
    while #scheduled > 0 do local f = table.remove(scheduled, 1); f(); n = n + 1; assert(n < 100, "runaway schedule") end end
local function server(path, body)
    local out = {}
    http.request{ url = "http://127.0.0.1:"..port..path, method = body and "POST" or "GET",
        headers = { Authorization = 'MediaBrowser Client="t", DeviceId="t"', ["Content-Type"]="application/json",
                    ["Content-Length"] = body and #body or nil },
        source = body and ltn12.source.string(body), sink = ltn12.sink.table(out) }
    local s = table.concat(out); return s ~= "" and cjson.decode(s) or nil end
local function serverState() return server("/__state") end
local function have(id) return P:getLocalPath(id) ~= nil end
-- A fake open document. kind: "paging" (comics/PDF) or "rolling" (EPUB)
local function reader(id, pages, kind, page)
    P.ui.document = { file = P:getLocalPath(id), getPageCount=function() return pages or 5 end }
    P.ui.paging, P.ui.rolling = nil, nil
    if kind == "paging" then P.ui.paging = { current_page = page or 1 }
    elseif kind == "rolling" then P.ui.rolling = { pct = page or 0, getLastPercent=function(self) return self.pct end } end
    P.ui.handleEvent = function(_, ev) table.insert(events, ev) end
    P.end_reached, P.seen_first_page, P.prefetch_checked = nil, nil, nil
end
-- Reads the open document from page 1 to its last page.
local function readToEnd() local total = P.ui.document:getPageCount()
    if P.ui.paging then P.ui.paging.current_page = 1 end
    P:onPageUpdate(1); if P.ui.paging then P.ui.paging.current_page = total end; P:onPageUpdate(total) end
-- What the plugin passes when opening a part from a series it knows (next part, Continue reading).
function sagaCtx() return { dir = P:getDownloadDir() .. "/Comics/Saga", parent_id = "f1", is_series = true, series_name = "Saga", ids = { "L3", "f1" } } end
local function nodoc() P.ui.document = nil; P.ui.paging = nil; P.ui.rolling = nil end
local function section(name) io.write("  ", name, " … ") io.flush() end
local function ok() print("ok") end

---------------------------------------------------------------- setup
P = require("main")
local registered
P.ui = { menu = { registerToMainMenu=function(_, p) registered=p end } }
-- settings from the old plugin name are moved over; the old plugin folder triggers a warning
do local f = io.open(dir .. "/jellyfin.lua", "w"); f:write("return { server = 'old' }"); f:close() end
sh("mkdir -p '" .. dir .. "/plugins/jellyfin.koplugin'")
P.path = dir .. "/plugins/jellyreader.koplugin"
P:init(); assert(registered==P)
do local f = assert(io.open(dir .. "/jellyreader.lua"), "settings not migrated"); assert(f:read("*a"):match("old")); f:close() end
assert(last("InfoMessage") and last("InfoMessage").text:match("jellyfin%.koplugin"), "no warning about old plugin")
local mm = {}; P:addToMainMenu(mm)
local function mi(prefix)
    for _, it in ipairs(mm.jellyreader.sub_item_table_func()) do
        local t = it.text or it.text_func()
        if t:find(prefix, 1, true) == 1 then return it end
    end
    error("no main menu item "..prefix) end
local tm = { updateItems=function() end }

section("login")
mi("Log in").callback(tm)
local dlg = last("MultiInputDialog"); dlg._answers = {"127.0.0.1:"..port.."/", "bri", "bad"}
dlg.buttons[2][2].callback(); assert(last("InfoMessage").text:match("Login failed"))
mi("Log in").callback(tm); dlg = last("MultiInputDialog"); dlg._answers = {" 127.0.0.1:"..port, "bri", "pw ✓"}
dlg.buttons[2][2].callback(); assert(P:isLoggedIn(), "not logged in")
assert(settings_store.data.server=="http://127.0.0.1:"..port)
assert(mi("Log out (bri"))
ok()

section("quick connect")
mi("Log out").callback(tm); assert(not P:isLoggedIn())
mi("Log in").callback(tm); dlg = last("MultiInputDialog"); dlg._answers = {"127.0.0.1:"..port, "", ""}
dlg.buttons[1][1].callback()
local code_box = last("InfoMessage"); assert(code_box.text:match("123456"), code_box.text)
runScheduled() -- polls until approved (mock approves on 2nd check)
assert(P:isLoggedIn() and closed[code_box], "quick connect login failed")
assert(last("InfoMessage").text == "Logged in as bri.")
-- disabled on server
server("/__set", '{"qc_enabled": false}')
local token = settings_store.data.token
mi("Log out").callback(tm); mi("Log in").callback(tm); dlg = last("MultiInputDialog"); dlg._answers = {"127.0.0.1:"..port, "", ""}
dlg.buttons[1][1].callback(); assert(last("InfoMessage").text:match("turned off"), last("InfoMessage").text)
server("/__set", '{"qc_enabled": true}')
mi("Log in").callback(tm); dlg = last("MultiInputDialog"); dlg._answers = {"127.0.0.1:"..port, "bri", "pw ✓"}
dlg.buttons[2][2].callback(); assert(P:isLoggedIn())
ok()

section("browse home")
mi("Browse library").callback()
local home = last("Menu")
assert(texts(home) == "Books | Comics | Collections | Search…", texts(home))
find(home, "Books").callback()
local books = last("Menu")
assert(texts(books):match("^Continue: Book 0 | Download all parts %(250%) | Recently added | By author | By genre | Sort: Name | Book 0 | Book 1 |"), texts(books):sub(1, 200))
assert(find(books, "Book 1").mandatory=="✓ EPUB")
find(books, "Recently added").callback(); assert(#last("Menu").item_table==3)
ok()

section("open book (library root, no series)")
find(books, "Book 0").callback()
assert(opened and opened:match("/Jellyfin/Books/Book 0%.epub$"), tostring(opened))
assert(closed[home] and closed[books] and #P.menu_stack==0)
local rec = P:getDownload("b000"); assert(rec.series == false and rec.next == nil, "library-root books are not a series")
reader("b000", 10, "rolling", 0); P:onReaderReady()
P:onPageUpdate(1); P:onPageUpdate(10)
assert(not last("ConfirmBox") or not last("ConfirmBox").text:match("Next"), "no next-part prompt for standalone books")
assert(P:getDownload("b000").finished)
ok()

section("sort & filter")
nodoc(); mi("Browse library").callback(); home = last("Menu"); find(home, "Comics").callback()
local comics = last("Menu"); find(comics, "Saga/").callback()
local saga = last("Menu")
assert(texts(saga) == "Continue: Saga 02 | Download all parts (3) | Sort: Name | Saga 01 | Saga 02 | Saga 03", texts(saga))
find(saga, "Sort:").callback(); last("ButtonDialog").buttons[3][1].callback() -- release date
saga = last("Menu"); assert(closed[saga] == nil)
assert(texts(saga):match("Sort: Release date | Saga 03 | Saga 02 | Saga 01$"), texts(saga))
find(saga, "Sort:").callback(); last("ButtonDialog").buttons[2][1].callback() -- date added, newest first
saga = last("Menu"); assert(texts(saga):match("| Saga 03 | Saga 02 | Saga 01$"), texts(saga))
find(saga, "Sort:").callback(); last("ButtonDialog").buttons[4][1].callback() -- unread only
saga = last("Menu"); assert(texts(saga):match("· unread only | Saga 03 | Saga 02$"), texts(saga))
find(saga, "Sort:").callback(); last("ButtonDialog").buttons[4][1].callback()
find(saga, "Sort:").callback(); last("ButtonDialog").buttons[1][1].callback()
saga = last("Menu"); assert(texts(saga):match("Sort: Name | Saga 01 | Saga 02 | Saga 03$"), texts(saga))
ok()

section("authors, genres, collections")
find(comics, "By author").callback(); local authors = last("Menu"); assert(texts(authors) == "Brian K. Vaughan")
find(authors, "Brian K. Vaughan").callback(); local bkv = last("Menu")
assert(texts(bkv) == "Sort: Name | Saga 01 | Saga 02 | Saga 03", texts(bkv))
find(comics, "By genre").callback(); find(last("Menu"), "Sci-Fi").callback()
assert(texts(last("Menu")) == "Sort: Name | Saga 01 | Saga 02 | Saga 03")
find(home, "Collections").callback(); find(last("Menu"), "Favorites").callback()
local fav = last("Menu"); assert(texts(fav):match("Download all parts %(2%) | Sort: Name | Book 5 | Saga 02$"), texts(fav))
-- a book opened from a collection still lands in its real series folder, with series info
opened = nil; find(fav, "Saga 02").callback()
assert(opened:match("/Jellyfin/Comics/Saga/Saga 02%.cbz$"), opened)
local r2 = P:getDownload("s2"); assert(r2.series and r2.next and r2.next.Id == "s3", "series info resolved via ancestors")
P:deleteLocal("s2")
ok()

section("comic defaults & manga")
-- defaults: whole page, contrast 1.0 -> only zoom_mode is set
nodoc(); mi("Browse library").callback(); home = last("Menu"); find(home, "Comics").callback(); comics = last("Menu")
opened = nil; find(comics, "Saga: Vol/1?").callback()
assert(sidecars[opened] and sidecars[opened].zoom_mode == "page" and sidecars[opened].kopt_contrast == nil
    and sidecars[opened].inverse_reading_order == nil and sidecars[opened].kopt_page_scroll == nil, "comic defaults not applied")
-- an EPUB gets no comic settings
assert(sidecars[P:getLocalPath("b000")] == nil)
-- change settings, mark the Comics library as manga
local comic_items = mi("Comics").sub_item_table_func()
assert(comic_items[3].text_func() == "View mode: KOReader default", comic_items[3].text_func())
comic_items[2].sub_item_table[3].callback() -- content
comic_items[3].sub_item_table[3].callback() -- continuous
assert(comic_items[3].text_func() == "View mode: Continuous (scroll)")
assert(comic_items[3].sub_item_table[3].checked_func() and not comic_items[3].sub_item_table[1].checked_func())
comic_items[4].sub_item_table[3].callback() -- 2.0
nodoc(); mi("Browse library").callback(); home = last("Menu")
find(home, "Comics").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
-- a comic of this library is already downloaded: offered, declined ("Only new downloads")
assert(last("ConfirmBox").text:match("right%-to%-left") and last("ConfirmBox").cancel_text == "Only new downloads")
mi("Browse library").callback(); home = last("Menu"); assert(find(home, "Comics").mandatory == "manga")
find(home, "Comics").callback(); comics = last("Menu"); find(comics, "Saga/").callback(); saga = last("Menu")
opened = nil; find(saga, "Saga 01").callback()
local sc = sidecars[opened]; assert(sc.zoom_mode == "content" and sc.kopt_contrast == 2.0 and sc.inverse_reading_order == true
    and sc.kopt_page_scroll == 1, "manga + custom comic settings not applied")
-- page mode writes 0; back to KOReader default writes nothing
comic_items[3].sub_item_table[2].callback()
P:deleteLocal("s2"); P:openItem({ Id = "s2", Name = "Saga 02", Path = "/c/Saga/Saga 02.cbz", ParentId = "f1" }, sagaCtx())
assert(sidecars[opened].kopt_page_scroll == 0, tostring(sidecars[opened].kopt_page_scroll))
comic_items[3].sub_item_table[1].callback()
P:deleteLocal("s2"); P:openItem({ Id = "s2", Name = "Saga 02", Path = "/c/Saga/Saga 02.cbz", ParentId = "f1" }, sagaCtx())
assert(sidecars[opened].kopt_page_scroll == nil)
P:deleteLocal("s2")
opened = P:getLocalPath("s1")
-- existing KOReader settings are never overwritten (re-download keeps .sdr)
sidecars[opened].zoom_mode = "pagewidth"; P:deleteLocal("s1", true)
P:openItem({ Id = "s1", Name = "Saga 01", Path = "/c/Saga/Saga 01.cbz", ParentId = "f1" }, sagaCtx())
assert(sidecars[opened].zoom_mode == "pagewidth", "overwrote user's settings")
-- off again
find(home, "Comics").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
assert(not P:isManga({ "L3" }))
ok()

section("apply comic settings to downloaded books")
local function citem(prefix)
    for _, it in ipairs(mi("Comics").sub_item_table_func()) do
        local t = it.text or it.text_func()
        if t:find(prefix, 1, true) == 1 then return it end
    end
    error("no comics menu item " .. prefix) end
-- start clean: defaults, nothing manga
for _, k in ipairs({ "comic_zoom", "comic_contrast", "comic_view_mode", "manga" }) do P.settings:delSetting(k) end
nodoc(); P:closeAllMenus()
for _, d in ipairs(P:listDownloads()) do P:deleteLocal(d.id) end
mi("Browse library").callback(); home = last("Menu"); find(home, "Comics").callback(); comics = last("Menu")
find(comics, "Saga/").callback(); saga = last("Menu")
find(saga, "Saga 01").callback(); local p1 = P:getLocalPath("s1")
nodoc(); P:openItem({ Id = "b000", Name = "Book 0", Path = "/media/b0.epub", ParentId = "L1" }); local pb = P:getLocalPath("b000")
assert(P:getDownload("s1").ids[1] == "L3" and P:getDownload("s1").ids[2] == "f1", "folder chain not recorded")
-- the user tweaked this comic in KOReader
sidecars[p1].zoom_mode = "pagewidth"; sidecars[p1].kopt_page_scroll = 1; sidecars[p1].last_page = 7
assert(citem("Apply to downloaded comics now").text_func() == "Apply to downloaded comics now (1)")
-- change the comic settings, then apply
local ci = mi("Comics").sub_item_table_func()
ci[2].sub_item_table[3].callback() -- fit: content
ci[3].sub_item_table[2].callback() -- view: page
ci[4].sub_item_table[2].callback() -- contrast 1.5
citem("Apply to downloaded comics now").callback()
local cb = last("ConfirmBox"); assert(cb.text:match("1 downloaded books") and cb.text:match("replaces changes"), cb.text)
cb.ok_callback()
local sc = sidecars[p1]
assert(sc.zoom_mode == "content" and sc.kopt_page_scroll == 0 and sc.kopt_contrast == 1.5, "not applied")
assert(sc.last_page == 7, "reading position must be kept")
assert(sidecars[pb] == nil, "EPUB must not get comic settings")
assert(last("InfoMessage").text == "Updated 1 downloaded book.", last("InfoMessage").text)
-- back to defaults: contrast reset, view mode handed back to KOReader
ci[3].sub_item_table[1].callback(); ci[4].sub_item_table[1].callback()
citem("Apply to downloaded comics now").callback(); last("ConfirmBox").ok_callback()
assert(sidecars[p1].kopt_page_scroll == nil and sidecars[p1].kopt_contrast == 1.0)
-- the open book is skipped (KOReader would overwrite it on close)
ci[2].sub_item_table[2].callback() -- page width
reader("s1", 10, "paging", 1)
citem("Apply to downloaded comics now").callback(); last("ConfirmBox").ok_callback()
assert(sidecars[p1].zoom_mode == "content", "changed the open book")
assert(last("InfoMessage").text:match("open book was skipped"), last("InfoMessage").text)
nodoc()
-- turning a library into manga offers to update its downloaded parts
find(home, "Comics").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
cb = last("ConfirmBox"); assert(cb.text:match("will open right%-to%-left") and cb.cancel_text == "Only new downloads", cb.text)
cb.ok_callback(); assert(sidecars[p1].inverse_reading_order == true and sidecars[p1].zoom_mode == "pagewidth")
assert(P:getDownload("s1").rtl == true)
-- and back off
find(home, "Comics").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
last("ConfirmBox").ok_callback(); assert(sidecars[p1].inverse_reading_order == nil, "RTL not removed")
-- toggling a folder with nothing downloaded just informs
find(home, "Books").hold_callback(); P:deleteLocal("b000")
local nconf = #shown; last("ButtonDialog").buttons[4][1].callback()
assert(shown[#shown]._kind == "InfoMessage" and shown[#shown].text:match("right%-to%-left"))
find(home, "Books").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
-- downloads from older versions (no folder chain) use their direct folder
local r1 = P:getDownload("s1"); r1.ids = nil; P:rememberDownload("s1", r1)
P:setManga({ Id = "f1", Name = "Saga" }, true); last("ConfirmBox").ok_callback()
assert(sidecars[p1].inverse_reading_order == true, "old record not handled")
P:setManga({ Id = "f1", Name = "Saga" }, false); last("ConfirmBox").ok_callback()
for _, k in ipairs({ "comic_zoom", "comic_contrast", "comic_view_mode", "manga" }) do P.settings:delSetting(k) end
P:closeAllMenus()
ok()

section("manga overrides & reader toggle")
for _, k in ipairs({ "manga", "manga_off" }) do P.settings:delSetting(k) end
nodoc(); P:closeAllMenus()
for _, d in ipairs(P:listDownloads()) do P:deleteLocal(d.id) end
-- library on, one series switched back off inside it
mi("Browse library").callback(); home = last("Menu")
find(home, "Comics").hold_callback(); last("ButtonDialog").buttons[4][1].callback()
find(home, "Comics").callback(); comics = last("Menu")
assert(find(comics, "Saga/").mandatory:match("^manga"), "inherited manga not shown")
find(comics, "Saga/").hold_callback()
local bd = last("ButtonDialog"); assert(bd.buttons[4][1].text:match("^✓"), "inherited state not checked")
bd.buttons[4][1].callback()
assert(P.settings:readSetting("manga_off").f1 == "Saga", "override not stored")
assert(not P:isManga({ "L3", "f1" }) and P:isManga({ "L3" }) and P:isManga({ "L3", "other" }))
local summary; for _, it in ipairs(mi("Comics").sub_item_table_func()) do if (it.text or ""):match("^Right%-to%-left") then summary = it.text end end
assert(summary == "Right-to-left (manga): Comics · except Saga", tostring(summary))
find(comics, "Saga/").callback(); saga = last("Menu")
find(saga, "Saga 01").callback(); local q1 = P:getLocalPath("s1")
assert(sidecars[q1].inverse_reading_order == nil, "series override ignored")
nodoc(); P:openItem({ Id = "s2", Name = "Saga 02", Path = "/c/Saga/Saga 02.cbz", ParentId = "f1" }, sagaCtx()); local q2 = P:getLocalPath("s2")
-- the reader menu has the toggle (and only the reader); the menu list is not cut short
nodoc(); local fm_count = #mm.jellyreader.sub_item_table_func()
for _, it in ipairs(mm.jellyreader.sub_item_table_func()) do assert(not (it.text_func and it.text_func():match("^Manga"))) end
reader("s1", 10, "paging", 1); events = {}
local rm = mm.jellyreader.sub_item_table_func(); assert(#rm == fm_count + 1, #rm .. " vs " .. fm_count)
local toggle = rm[3]; assert(toggle.text_func() == "Manga: read right-to-left (Saga)", toggle.text_func())
assert(not toggle.checked_func() and toggle.enabled_func())
toggle.callback()
assert(events[1].name == "ToggleReadingOrder" and events[1].arg == true, "open book not switched")
assert(P:isManga({ "L3", "f1" }) and P.settings:readSetting("manga_off").f1 == nil)
assert(toggle.checked_func())
cb = last("ConfirmBox"); assert(cb.text:match("Saga will open right%-to%-left") and cb.text:match(" 1 downloaded"), cb.text)
cb.ok_callback()
assert(sidecars[q2].inverse_reading_order == true, "other part not updated")
assert(not last("InfoMessage").text:match("skipped"), "open book reported as skipped")
-- and off again
events = {}; toggle.callback(); assert(events[1].arg == false and not P:isManga({ "L3", "f1" }))
last("ConfirmBox").ok_callback(); assert(sidecars[q2].inverse_reading_order == nil)
-- a book not from Jellyfin: toggle disabled
P.ui.document = { file = "/elsewhere.cbz", getPageCount = function() return 1 end }
assert(not mm.jellyreader.sub_item_table_func()[3].enabled_func())
for _, k in ipairs({ "manga", "manga_off" }) do P.settings:delSetting(k) end
nodoc(); P:closeAllMenus()
ok()

section("offline sync queue")
-- finish s1 while offline: marked read locally, queued, sent when Wi-Fi comes back
local was_played = {}; for _, id in ipairs(serverState().played) do was_played[id] = true end
server("/__set", '{"ticks": {}}')
ONLINE = false
reader("s1", 20, "paging", 1); P:onReaderReady(); readToEnd()
assert(P:pendingCount() == 1, "not queued")
-- s1 was already played on the server in the fixtures; use s3 for a real change
ONLINE = false
P.ui.document = nil
P:queueSync("s3", { played = true })
assert(P:pendingCount() == 2)
local st = serverState(); for _, id in ipairs(st.played) do assert(id ~= "s3", "sent while offline") end
ONLINE = true; P:onNetworkConnected(); runScheduled()
assert(P:pendingCount() == 0, "queue not flushed")
local played = {}; for _, id in ipairs(serverState().played) do played[id] = true end
assert(played.s3 and played.s1, "not marked read on server")
-- server errors keep the update queued; a deleted book is dropped
P:queueSync("s3", { played = false }); P:queueSync("gone", { played = true })
local saved_server = settings_store.data.server
settings_store.data.server = "http://127.0.0.1:1" -- nothing listens there
assert(not P:flushSync() and P:pendingCount() == 2, "network error must keep the queue")
settings_store.data.server = saved_server
assert(P:flushSync() and P:pendingCount() == 0)
ok()

section("position sync")
if LEGACY then
    -- Jellyfin 10.8 has no position endpoint: positions are dropped quietly, read status still works.
    reader("s2", 30, "paging", 1); P:openItem({ Id = "s2", Name = "Saga 02", ParentId = "f1" }, sagaCtx())
    reader("s2", 30, "paging", 7); P:onCloseDocument()
    assert(P:pendingCount() == 0 and next(serverState().ticks) == nil)
    print("ok (legacy: no position endpoint, skipped)")
else
    -- push on close: paging = page index * 10000 (same as Jellyfin web comics reader)
    P:openItem({ Id = "s2", Name = "Saga 02", ParentId = "f1" }, sagaCtx())
    reader("s2", 30, "paging", 7); P:onCloseDocument()
    assert(serverState().ticks.s2 == 60000, cjson.encode(serverState().ticks))
    -- rolling = fraction * 10^7 (same as Jellyfin web EPUB reader)
    assert(not have("b000"), "finished b000 should have been auto-cleaned")
    nodoc(); P:openItem({ Id = "b000", Name = "Book 0", ParentId = "L1" })
    reader("b000", 100, "rolling", 0.25); P:onCloseDocument()
    assert(serverState().ticks.b000 == 2500000, cjson.encode(serverState().ticks))
    -- suspend only queues
    reader("b000", 100, "rolling", 0.3); P:onSuspend(); assert(P:pendingCount() == 1); P:flushSync()
    -- pull: server ahead -> offer jump
    server("/__set", '{"ticks": {"s2": 190000}}') -- page 20
    reader("s2", 30, "paging", 7); events = {}; P:onReaderReady()
    local cb = last("ConfirmBox"); assert(cb.text:match("page 20 of 30"), cb.text)
    cb.ok_callback(); assert(events[1].name == "GotoPage" and events[1].arg == 20)
    server("/__set", '{"ticks": {"b000": 5000000}}')
    reader("b000", 100, "rolling", 0.3); events = {}; P:onReaderReady()
    cb = last("ConfirmBox"); assert(cb.text:match("50 %%"), cb.text); cb.ok_callback()
    assert(events[1].name == "GotoPercent" and math.abs(events[1].arg - 50) < 1e-9)
    -- server behind -> no prompt
    local n = #shown; reader("s2", 30, "paging", 25); P:onReaderReady(); assert(#shown == n, "prompted although server is behind")
    -- unsent local position wins over the server's
    ONLINE = false; reader("s2", 30, "paging", 26); P:onCloseDocument(); ONLINE = true
    n = #shown; reader("s2", 30, "paging", 1); P:onReaderReady(); assert(serverState().ticks.s2 == 250000)
    -- the pending update was flushed by onReaderReady before pulling, and the server now equals local
    ok()
end

section("continue reading")
nodoc()
P.settings:saveSetting("reading", nil)
-- reading s2 (unfinished) -> Saga entry shows Saga 02
reader("s2", 30, "paging", 3); P:onReaderReady(); nodoc()
local entries = P:getContinueEntries(false); assert(#entries == 1 and entries[1].item.Id == "s2", #entries)
-- finishing it moves the series to Saga 03 (works offline)
ONLINE = false
reader("s2", 30, "paging", 1); P:onReaderReady(); readToEnd()
assert(last("ConfirmBox").text:match("Next: Saga 03"))
entries = P:getContinueEntries(false); assert(entries[1].item.Id == "s3" and entries[1].series_name == "Saga", entries[1].item.Id)
ONLINE = true; P:flushSync(); nodoc()
-- a book in progress elsewhere shows up from the server (not when offline)
if not LEGACY then
    server("/__set", '{"ticks": {"b010": 3000000}}')
    entries = P:getContinueEntries(true)
    local found; for _, e in ipairs(entries) do if e.item.Id == "b010" then found = e end end
    assert(found and found.from_server, "server resume missing")
end
-- shown at the top of Browse; tapping downloads the next part into the series folder
P:deleteLocal("s3")
mi("Browse library").callback(); home = last("Menu")
local first = home.item_table[1]; assert(first.text == "▶ Saga · Saga 03", first.text)
opened = nil; first.callback(); assert(opened and opened:match("/Comics/Saga/Saga 03%.cbz$"), tostring(opened))
-- Continue reading works offline from the main menu
ONLINE = false; nodoc(); mi("Continue reading").callback()
local cont = last("Menu"); assert(cont.title == "Continue reading" and find(cont, "▶ Saga · Saga 03").mandatory == "↓")
-- finishing the last part removes the series; hold removes manually
reader("s3", 5, "paging", 1); P:onReaderReady(); readToEnd()
entries = P:getContinueEntries(false)
for _, e in ipairs(entries) do assert(e.item.Id ~= "s3", "finished series still listed") end
nodoc(); if not have("b000") then P:openItem({ Id = "b000", Name = "Book 0", ParentId = "L1" }) end
reader("b000", 100, "rolling", 0.1); P:onReaderReady(); nodoc()
mi("Continue reading").callback(); cont = last("Menu"); find(cont, "▶ Book 0").hold_callback(); last("ConfirmBox").ok_callback()
for _, e in ipairs(P:getContinueEntries(false)) do assert(e.item.Id ~= "b000") end
ONLINE = true
ok()

section("background download of next part")
-- reading s1; at 80 % the next part downloads in the background
P:deleteLocal("s2"); P:deleteLocal("s3")
P:openItem({ Id = "s1", Name = "Saga 01", ParentId = "f1" }, sagaCtx())
local s1rec = P:getDownload("s1"); assert(s1rec.next and s1rec.next.Id == "s2")
reader("s1", 10, "paging", 1); P:onReaderReady()
P:onPageUpdate(5); assert(#subprocs == 0, "prefetched too early")
P:onPageUpdate(8); assert(#subprocs == 1, "no background download at 80%")
assert(not have("s2"), "should still be in progress")
P:onPageUpdate(9); assert(#subprocs == 1, "started twice")
-- reaching the end while it's running: prompt says "Open next", opening waits for it
P.ui.paging.current_page = 10; P:onPageUpdate(10)
local cb = last("ConfirmBox"); assert(cb.ok_text == "Open next", cb.ok_text)
opened = nil; cb.ok_callback()
assert(opened and opened:match("/Comics/Saga/Saga 02%.cbz$"), tostring(opened))
assert(have("s2") and #subprocs == 1, "downloaded twice")
assert(sidecars[opened] and sidecars[opened].zoom_mode, "background download skipped comic defaults")
-- poll path: background download finishing on its own
reader("s2", 10, "paging", 1); P:onReaderReady(); P:onPageUpdate(9); assert(#subprocs == 2)
runScheduled(); assert(have("s3"), "poll did not record finished download")
-- off when Wi-Fi is off, or disabled
ONLINE = false; P:deleteLocal("s3"); reader("s2", 10, "paging", 1); P:onPageUpdate(9); assert(#subprocs == 2); ONLINE = true
mi("Download next part in the background").callback()
reader("s2", 10, "paging", 1); P:onPageUpdate(9); assert(#subprocs == 2)
mi("Download next part in the background").callback()
ok()

section("storage (regression)")
nodoc()
local sitems = mi("Storage").sub_item_table_func()
assert(sitems[1].text_func():match("^Manage downloads %(.- MB, .- free%)$"))
-- auto-clean finished parts when opening another book
P:openItem({ Id = "s1", Name = "Saga 01", ParentId = "f1" }, sagaCtx())
P:setFinished("s1", true)
reader("s2", 10, "paging", 1); P:onReaderReady()
assert(not have("s1") and have("s2"), "finished part not auto-deleted")
-- low disk space blocks downloads
FREE = 10 * 1024 * 1024; nodoc()
local ok_dl, err_dl = P:downloadItem({ Id = "b200", Name = "Book 200", ParentId = "L1" })
assert(not ok_dl and err_dl:match("almost full"), tostring(err_dl)); FREE = nil
-- manage screen
P:showDownloadsManager(); local mgr = last("Menu")
assert(mgr.title:match("^Downloads: .- MB · .- free$"), mgr.title)
find(mgr, "Delete all downloads").callback(); last("ConfirmBox").ok_callback()
assert(#P:listDownloads() == 0)
ok()

section("network robustness")
local C = require("jellyfinclient")
C.config.block_timeout = 1; C.config.retry_delays = { 0.1, 0.1 }
nodoc(); P:closeAllMenus()
-- one stalled request (Wi-Fi waking up): retried, user sees nothing
server("/__set", '{"stall": 1, "stall_secs": 2}')
local n_err = #shown
mi("Browse library").callback(); home = last("Menu")
assert(home and find(home, "Books"), "retry did not recover")
for i = n_err + 1, #shown do assert(not (shown[i].text or ""):match("did not answer"), "error shown despite retry") end
-- a longer outage: clear message after 3 attempts
server("/__set", '{"stall": 5, "stall_secs": 2}')
P:closeAllMenus(); mi("Browse library").callback()
local msg = last("InfoMessage").text
assert(msg:match("did not answer in time %(tried 3 times%)") and msg:match("Test connection"), msg)
server("/__set", '{"stall": 0, "stall_secs": 0}')
-- paging without total counts: 250 books = 3 requests of 100
server("/__set", '{"reset_counts": true}')
P:closeAllMenus(); mi("Browse library").callback(); home = last("Menu"); find(home, "Books").callback()
assert(serverState().item_queries == 3, serverState().item_queries)
local nbooks = 0; for _, it in ipairs(last("Menu").item_table) do if (it.text or ""):match("^Book %d+$") then nbooks = nbooks + 1 end end
assert(nbooks == 250, nbooks)
-- test connection: all good
P:closeAllMenus(); mi("Test connection").callback()
msg = last("InfoMessage").text
for _, step in ipairs({ "✓ Reach server", "✓ List libraries", "✓ List books", "✓ Download speed" }) do
    assert(msg:find(step, 1, true), msg) end
assert(msg:match("%d+ KB/s"), msg)
assert(not msg:match("Everything looks fine") and not msg:match("likely cause"), "advice text should be gone")
-- slow server lists, fast ping -> blames the server
C.config.block_timeout = 5
server("/__set", '{"stall": 2, "stall_secs": 5.5}')
mi("Test connection").callback(); msg = last("InfoMessage").text
assert(msg:find("✓ Reach server", 1, true) and tonumber(msg:match("List libraries: (%d+)")) >= 5, msg)
server("/__set", '{"stall": 0, "stall_secs": 0}')
C.config.block_timeout = 1
-- unreachable server
local good = settings_store.data.server; settings_store.data.server = "http://127.0.0.1:1"
mi("Test connection").callback(); msg = last("InfoMessage").text
assert(msg:find("✗ Reach server", 1, true) and msg:match("refused the connection"), msg)
-- something else answers at that address (e.g. missing reverse proxy path)
settings_store.data.server = good .. "/wrongpath"
mi("Test connection").callback(); msg = last("InfoMessage").text
assert(msg:find("✗ Reach server", 1, true) and msg:match("HTTP 404"), msg)
settings_store.data.server = good
C.config.block_timeout = 20; C.config.retry_delays = { 1, 3 }
ok()

section("expired session")
settings_store.data.token = "expired"; mi("Browse library").callback()
assert(last("MultiInputDialog") and not P:isLoggedIn())
ok()

print("ALL TESTS PASSED (" .. mode .. ")")
