# A KOReader plugin for Readwise and Readwise Reader
A plugin for KOReader integration with the highlight saving and read later services Readwise and Readwise Reader. A Readwise subscription is required. 

## Key features:
- Articles in Readwise Reader saved to “Inbox”, “Later” or “Shortlist” are downloaded to KOReader as HTML files.
- Images are downloaded where this is possible.
- Articles which have been read in KOReader and marked as “finished” will be moved to the Readwise Reader Archive at the next sync, and deleted from KOReader.
- At sync, articles which have been archived in Readwise Reader will be deleted from KOReader.
- Particular types of article, locations and document tags can be excluded from syncing in the settings menu.
- Optionally, the plugin will only sync articles tagged as 'koreader' in Readwise (off by default).
- The number of articles downloaded per sync can be limited in the settings menu (default: unlimited).
- Highlights and notes saved in KOReader are exported during sync (disabled by default - enable in the settings menu). Highlights from downloaded Reader articles are attached to the original document in Reader; other books use the Readwise highlights API. Successful Reader exports are remembered locally, and editing or clearing a note updates the existing highlight.
- Very image heavy files will download, but may cause KOReader to crash if the file is very large and your ereader can’t cope with this. Due to the way images are saved and the limitations of HTML files, this is more of an issue than with EPUBs. To mitigate this, there is a setting to allow the user to cap the size of a file, after which further images are not downloaded. This is set to 10MB by default, but may be changed according to the limits of the user’s setup. There is also a toggle to turn off image downloads completely if required.

## Limitations and Known Issues:
- Highlight export is one way: highlights created or changed in Reader are not imported into KOReader.
- Reader highlight export requires the selected text to match the original article. If Reader rejects a selection, or any highlight export fails, sync stops before deleting local articles and annotations. Retry after resolving the error; successfully exported Reader highlights will be skipped. The Advanced sync archive/delete actions remain explicit manual actions.
- Existing highlights previously exported through the Readwise highlights API are not migrated or removed. The first export with this version creates highlights on the original Reader document. Export history is stored in the plugin settings; resetting those settings loses the local record of successful exports. A lost server response can also leave an export's outcome unknown.
- Reader exports identify a passage by its document ID and exact text. Identical passages in one document share one export record; the API chooses the matching location. Highlight text edits create a new highlight, and deleting a highlight locally does not delete it in Reader.
- I am not planning to add any options to style the documents. However there are lots of tweaks you can apply as a user - see [here](https://koreader.rocks/user_guide/#L1-customizingappearance). 

## Installation:
- Download the [ZIP of the plugin](https://github.com/Endle/readwisereader/releases/). Extract it.
- Attach your ereader to your computer. Copy the `readwisereader.koplugin` folder containing _meta.lua and main.lua from the extracted folder to the `koreader/plugins` folder. Restart KOReader.
- The plugin requires a Readwise access token, which subscribers can obtain [here](https://readwise.io/access_token).
- The token can be typed in manually in the Readwise Reader/Settings/Configure Readwise Reader menu, but this is difficult to do correctly. It's easy to be confused by the letter O and the number 0, or the lowercase letter l, the uppercase letter I and the numeral 1. If the plugin is not working, check this first.
- You may prefer to copy and paste the access token directly from your computer into KOReader settings. To do this, first set the folder you want to download to in the Readwise Reader/Settings/Download folder menu. This will create the file koreader/settings/readwisereader.lua. Add the access token to this file in the following format:

```
-- ./settings/readwisereader.lua
return {
    ["readwisereader"] = {
        ["access_token"] = "{access token}",
        ["available_locations"] = {},
        ["available_tags"] = {},
        ["directory"] = "{download location}",
        ["document_categories"] = {},
        ["document_locations"] = {},
        ["document_tags"] = {},
        ["excluded_locations"] = {},
        ["excluded_tags"] = {},
        ["max_articles_to_download"] = 0,  -- 0 = unlimited
    },
}
```
- The extension is then activated by selecting “Sync” in the Readwise Reader menu.
- By default, the extension will be added to the file menu with the prefix NEW:. The plugin will work in this format, but to remove the NEW: prefix and to move it to a different menu, add a line for  `"readwisereader",` in the appropriate place in koreader/frontend/ui/elements/filemanager_menu_order.lua

## Bug reporting
If reporting a bug, especially one that causes KOReader to crash, please share logging from your device in koreader/crash.log. Errors and crashes are clearly marked. To ensure that you just capture the relevant logs, delete the file, let KOReader regenerate it for you, then save the file after the issue has occurred.

## Development
Notes for devs and power-users. Don't proceed unless you know the meaning of each step.

### Regression checks

Run `luajit tests/highlights_test.lua` from the repository root. These tests stub KOReader and HTTP to cover Reader export routing, saved export history, note updates, partial failures, rate-limit retries, and preservation of local files on export failure. CI also runs these checks. Actual text anchoring still needs a device and Reader account: test selections within and across paragraphs, styled text, punctuation, and note edits before release.

### Test KOReader on Linux PC
KOReader has [Linux release](https://github.com/koreader/koreader/wiki/Installation-on-desktop-linux), so it's a breeze to test this plugin on Linux.

1. Install KOReader [via Flatpak](https://flathub.org/en/apps/rocks.koreader.KOReader)
2. `git clone git@github.com:Endle/readwisereader.git`
3. Check plugin directory `$HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins` - Thanks to [MountainToppish](https://www.reddit.com/r/koreader/comments/1mt7g9x/how_to_add_plugins_to_koreader_installed_from/)
4. Install the plugin by `cd  $HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins && ln -s $HOME/<source_path>/readwisereader.koplugin`
5. Restart KOReader
