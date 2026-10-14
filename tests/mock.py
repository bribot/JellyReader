"""Mock Jellyfin server for plugin tests. Usage: mock.py PORT [modern|legacy]
legacy = Jellyfin 10.8: only /Users/{id}/... routes, no /UserItems, Quick Connect Initiate is GET."""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LEGACY = len(sys.argv) > 2 and sys.argv[2] == "legacy"
TOKEN = "tok123"; UID = "user1"

def book(id, name, parent, path=None, container=None, created="2024-01-01", premiere=None):
    b = {"Id": id, "Name": name, "IsFolder": False, "Type": "Book", "ParentId": parent,
         "DateCreated": created + "T00:00:00.0000000Z"}
    if path: b["Path"] = path
    if container: b["Container"] = container
    if premiere: b["PremiereDate"] = premiere + "T00:00:00.0000000Z"
    return b

BOOKS = [book(f"b{i:03d}", f"Book {i}", "L1", path=f"/media/b{i}.epub",
              created=f"2024-{1 + i % 12:02d}-{1 + i % 28:02d}") for i in range(250)]
COMICS = [book("c1", "Saga: Vol/1?", "L3", container="cbz"),
          {"Id": "f1", "Name": "Saga", "IsFolder": True, "ChildCount": 3, "Type": "Folder", "ParentId": "L3"}]
# Release dates deliberately out of name order to test sorting.
SAGA = [book(f"s{i}", f"Saga {i:02d}", "f1", path=f"/c/Saga/Saga {i:02d}.cbz",
             created=f"2025-0{i}-01", premiere=f"201{4 - i}-01-01") for i in (1, 2, 3)]
ALL = BOOKS + COMICS + SAGA
BYID = {x["Id"]: x for x in ALL}
LIBS = [{"Id": "L1", "Name": "Books", "CollectionType": "books", "Type": "CollectionFolder"},
        {"Id": "L2", "Name": "Movies", "CollectionType": "movies", "Type": "CollectionFolder"},
        {"Id": "L3", "Name": "Comics", "Type": "CollectionFolder"}]
ANC = {"L1": [LIBS[0]], "L3": [LIBS[2]], "f1": [COMICS[1], LIBS[2]]}
BOXSET = {"Id": "bx1", "Name": "Favorites", "IsFolder": True, "Type": "BoxSet", "ChildCount": 2}
BOXSET_ITEMS = ["b005", "s2"]

state = {"stall": 0, "stall_secs": 0, "item_queries": 0, "played": {"b001", "s1"}, "ticks": {}, "qc_checks": 0, "qc_enabled": True, "requests": []}

def with_userdata(it):
    it = dict(it)
    it["UserData"] = {"Played": it["Id"] in state["played"],
                      "PlaybackPositionTicks": state["ticks"].get(it["Id"], 0)}
    return it

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj=None, raw=None, headers={}):
        body = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code)
        for k, v in headers.items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def route(self, m):
        u = urlparse(self.path); p = u.path; q = {k: v[0] for k, v in parse_qs(u.query).items()}
        state["requests"].append(m + " " + p)
        a = self.headers.get("Authorization", "")
        assert 'DeviceId="' in a and 'Client="' in a, a
        authed = f'Token="{TOKEN}"' in a

        # --- test control
        if p == "/__state":
            return self.send(200, {"played": sorted(state["played"]), "ticks": state["ticks"], "item_queries": state["item_queries"]})
        if p == "/__set" and m == "POST":
            d = self.body()
            if "ticks" in d: state["ticks"].update(d["ticks"])
            if "qc_enabled" in d: state["qc_enabled"] = d["qc_enabled"]
            if "stall" in d: state["stall"], state["stall_secs"] = d["stall"], d["stall_secs"]
            if "reset_counts" in d: state["item_queries"] = 0
            return self.send(204)

        # --- unauthenticated
        if p == "/Users/AuthenticateByName" and m == "POST":
            if self.body() == {"Username": "bri", "Pw": "pw ✓"}:
                return self.send(200, {"AccessToken": TOKEN, "User": {"Id": UID, "Name": "bri"}})
            return self.send(401)
        if p == "/System/Info/Public":
            return self.send(200, {"Version": "10.10.3", "ServerName": "mock"})
        if p == "/QuickConnect/Enabled":
            return self.send(200, state["qc_enabled"])
        if p == "/QuickConnect/Initiate":
            if (m == "POST") == LEGACY: return self.send(405)
            if not state["qc_enabled"]: return self.send(401)
            state["qc_checks"] = 0
            return self.send(200, {"Secret": "sec", "Code": "123456", "Authenticated": False})
        if p == "/QuickConnect/Connect":
            if q.get("secret") != "sec": return self.send(404)
            state["qc_checks"] += 1
            return self.send(200, {"Secret": "sec", "Code": "123456", "Authenticated": state["qc_checks"] >= 2})
        if p == "/Users/AuthenticateWithQuickConnect" and m == "POST":
            if self.body() == {"Secret": "sec"} and state["qc_checks"] >= 2:
                return self.send(200, {"AccessToken": TOKEN, "User": {"Id": UID, "Name": "bri"}})
            return self.send(400)

        if not authed: return self.send(401)
        # Simulate a sleepy connection: the next N list requests hang before answering.
        if state["stall"] > 0 and p in ("/UserViews", "/Items", "/Users/user1/Items", "/Users/user1/Views"):
            state["stall"] -= 1
            time.sleep(state["stall_secs"])

        # Endpoints added in Jellyfin 10.9 don't exist on legacy servers.
        if LEGACY and (p in ("/UserViews", "/Items", "/Items/Latest") or p.startswith("/UserItems")
                       or p.startswith("/UserPlayedItems")):
            return self.send(404)
        p = re.sub(r"^/Users/user1/", "/", p)  # legacy aliases -> same handlers
        p = {"/Views": "/UserViews", "/Items/Resume": "/UserItems/Resume"}.get(p, p)

        if p == "/UserViews":
            return self.send(200, {"Items": LIBS})
        if p == "/Items":
            if q.get("includeItemTypes") == "BoxSet": src = [BOXSET]
            elif "searchTerm" in q: src = [b for b in BOOKS + SAGA if q["searchTerm"].lower() in b["Name"].lower()]
            elif q.get("personIds") == "p1" or q.get("genreIds") == "g1": src = SAGA
            elif q.get("parentId") == "bx1": src = [BYID[i] for i in BOXSET_ITEMS]
            elif q.get("recursive") == "true" and q.get("includeItemTypes") == "Book" and "parentId" not in q:
                src = [x for x in ALL if not x["IsFolder"]]
            else: src = {"L1": BOOKS, "L3": COMICS, "f1": SAGA}.get(q.get("parentId"), [])
            assert "ChildCount" not in q.get("fields", ""), q
            state["item_queries"] += 1
            s = int(q.get("startIndex", 0)); l = int(q.get("limit", 1000))
            # Like Jellyfin: no count when the client says it doesn't need one.
            total = 0 if q.get("enableTotalRecordCount") == "false" else len(src)
            return self.send(200, {"Items": [with_userdata(x) for x in src[s:s + l]], "TotalRecordCount": total})
        if p == "/Items/Latest":
            return self.send(200, [with_userdata(x) for x in BOOKS[:3]])
        if p == "/UserItems/Resume":
            src = [with_userdata(x) for x in ALL if state["ticks"].get(x["Id"], 0) > 0 and x["Id"] not in state["played"]]
            return self.send(200, {"Items": src, "TotalRecordCount": len(src)})
        if p == "/Persons":
            assert q.get("personTypes") == "Author", q
            return self.send(200, {"Items": [{"Id": "p1", "Name": "Brian K. Vaughan", "Type": "Person"}]})
        if p == "/Genres":
            return self.send(200, {"Items": [{"Id": "g1", "Name": "Sci-Fi", "Type": "Genre"}]})
        mm = re.match(r"^/(?:UserPlayedItems|PlayedItems)/(\w+)$", p)
        if mm:
            if mm.group(1) not in BYID: return self.send(404)
            if m == "POST":
                state["played"].add(mm.group(1)); state["ticks"].pop(mm.group(1), None)
            else:
                state["played"].discard(mm.group(1))
            return self.send(200, {"Played": m == "POST"})
        mm = re.match(r"^/(?:UserItems|Items)/(\w+)/UserData$", p)
        if mm:
            i = mm.group(1)
            if m == "POST":
                if LEGACY: return self.send(404)
                state["ticks"][i] = self.body()["PlaybackPositionTicks"]
            return self.send(200, with_userdata(BYID[i])["UserData"])
        mm = re.match(r"^/Items/(\w+)/Ancestors$", p)
        if mm:
            return self.send(200, ANC[BYID[mm.group(1)]["ParentId"]] + [{"Id": "root", "Name": "root", "Type": "AggregateFolder"}])
        mm = re.match(r"^/Items/(\w+)/Download$", p)
        if mm:
            if mm.group(1) == "nope": return self.send(403)
            hd = {"Content-Disposition": 'attachment; filename="saga.cbz"'} if mm.group(1) == "c1" else {}
            return self.send(200, raw=b"PK" + bytes(range(256)) * 4000, headers=hd)
        if p == "/Sessions/Logout": return self.send(204)
        self.send(404)

    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_DELETE(self): self.route("DELETE")

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
