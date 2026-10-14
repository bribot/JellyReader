# JellyReader — Jellyfin for KOReader (Kindle / KUAL)

A KOReader plugin to browse your Jellyfin **Books** libraries (EPUB, PDF, MOBI, CBZ comics, …) from your
jailbroken Kindle, download items and read them right away in KOReader.

## Features
- **Logging in:**
  - Log in with your username and password, or use **Quick Connect**: the Kindle shows a
    6-digit code that you approve in the Jellyfin app on your phone, so there's no password to type.
  - Only an access token is stored, never the password.
- **Browsing:**
  - **Continue reading** at the top: each series you've started, with its current or next part,
    plus books in progress on other devices.
  - Browse by folder, by author, by genre or by collection, see "Recently added", and search.
  - Sort lists by name, date added or release date, and optionally show unread items only.
- **Reading:**
  - Tap an item to download and open it. If it's already on the Kindle, it opens straight away.
  - Long-press an item to download only, download again, mark it read or unread in Jellyfin, or delete the local copy.
- **Series and multi-part comics:**
  - Downloads are saved in folders that match Jellyfin, e.g. `Jellyfin/Comics/Saga/Saga 01.cbz`.
  - On the last page of a part, you're offered **Open next part**.
  - At 80 % through a part, the next part **downloads in the background** if Wi-Fi is on, so it opens instantly.
  - Inside a series folder, **Continue: …** opens the first unread part, and **Download all parts** saves the whole series.
  - Long-press a folder to download or delete all of its parts.
- **Comics and manga** (JellyReader → Comics):
  - New comics open with your chosen fit (whole page, page width, or margins trimmed), view mode
    (page by page, or continuous scrolling for webtoons) and contrast.
  - Long-press a library or folder and choose **Manga: read right-to-left**, or switch it while reading
    with **JellyReader → Manga: read right-to-left**, which flips the open book immediately.
    Everything inside a manga folder reads right-to-left; a single series can be switched back off.
  - Settings you change yourself in KOReader are never overwritten, unless you choose
    **Apply to downloaded comics now**, which updates every comic already on the Kindle
    (your reading position is kept). Turning manga on or off for a folder offers the same for its parts.
- **Sync with Jellyfin:**
  - Finished books are marked as read.
  - Your reading position is saved, in the same format as the Jellyfin web reader.
  - When Jellyfin has a later position (from the web reader or another device), you're offered a jump there.
  - Anything that happens offline is queued and sent the next time Wi-Fi connects.
- **Storage management** (JellyReader → Storage):
  - **Delete finished parts automatically** (on by default): once you open another book, parts you've finished are deleted.
    KOReader's small progress file is kept, so downloading a part again continues where you were.
  - **Storage limit** (off, or 500 MB to 8 GB): above it, the oldest finished parts are deleted first, and
    **Download all parts** stops at the limit. Parts you haven't finished are never deleted automatically.
  - Downloads always stop when less than 50 MB is free.
  - **Manage downloads** shows every download with its size, plus **Delete finished** and **Delete all** buttons.
- Each list shows ↓ for downloaded items, ✓ for read items, and the file type.

## Requirements
- A jailbroken Kindle with **KUAL** and **KOReader** installed (KOReader is started from KUAL).
- Jellyfin 10.8 or newer. **Reading position sync needs 10.9 or newer**; everything else works on 10.8.
- On the Jellyfin server:
  - A library with content type **Books**. For comics, a "Mixed content" library works too.
  - Your user needs **Allow media downloading** turned on
    (Dashboard → Users → *user* → Allow media downloading).
  - For Quick Connect: Dashboard → General → **Enable Quick Connect**.
  - Authors and genres come from the books' metadata: EPUB metadata, and `ComicInfo.xml` inside comics.

## Install
1. Download this repository (Code → Download ZIP) and unzip it.
2. Connect the Kindle over USB.
3. Copy the `jellyreader.koplugin` folder into `koreader/plugins/` on the Kindle,
   so you end up with `/mnt/us/koreader/plugins/jellyreader.koplugin/main.lua`.
4. Eject the Kindle, then open KUAL → KOReader.

**Upgrading from the plugin's old name (`jellyfin.koplugin`):** delete the old
`koreader/plugins/jellyfin.koplugin` folder. Your login, settings, downloads and gestures
carry over automatically. JellyReader shows a reminder while the old folder is still there.

## Use
1. In KOReader, tap the top menu, then the 🔍 (search) tab → **JellyReader** → **Log in to server**.
   Enter the server address, e.g. `http://192.168.1.10:8096` (use the LAN IP, not `localhost`).
   Then either enter your username and password, or tap **Quick Connect**.
2. Choose **Browse library**, or **Continue reading** (works offline).
3. Optional: under Settings → Taps and gestures → Gesture manager, assign gestures to:
   - **JellyReader: library** and **JellyReader: continue reading** (General)
   - **JellyReader: open next part** (Reader)

By default, files are saved to `/mnt/us/documents/Jellyfin/<Library>/<Folder>/`. You can change this in the
JellyReader menu. Because of that location, downloaded EPUBs and PDFs also show up in the stock
Kindle library. Comics (CBZ/CBR) only open in KOReader.

## Troubleshooting
- **Download not permitted**: turn on "Allow media downloading" for the user (see above).
- **Timeouts or network errors**: run **JellyReader → Test connection**. It times each step (reaching the
  server, listing libraries and books, download speed), which shows where the slowness is. Requests that time out are retried automatically (3 attempts).
  A plain `http://` LAN address is the most reliable; with HTTPS, the Kindle needs a certificate it trusts.
- **No book libraries found**: the library's content type has to be *Books* or *Mixed*.
- **Quick Connect is turned off**: an administrator must enable it in Dashboard → General.
- **Updates waiting to be sent**: JellyReader → Sync with Jellyfin shows how many, and has a button to send them now.

## Development
`tests/run.sh` runs the test suites against a mock Jellyfin server (`tests/mock.py`), once behaving
like Jellyfin 10.9+ and once like Jellyfin 10.8. KOReader's widgets are replaced by small stubs, so the
tests cover the plugin's logic and its use of the Jellyfin API, not what it looks like on a Kindle.
Requirements: `luajit`, `lua-socket`, `lua-sec`, `lua-cjson` and `python3`.

## License
Copyright (C) 2026 bribot

JellyReader is free software: you can redistribute it and/or modify it under the terms of the
GNU Affero General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY; see the [LICENSE](LICENSE) file for the full text.
This is the same license KOReader uses.
