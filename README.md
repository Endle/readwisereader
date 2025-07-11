# A KOReader plugin for Readwise Reader
A simple plugin for KOReader integration with the read later service Readwise Reader. A Readwise subscription is required. 
Key features:
- Articles in Readwise Reader saved to “Later” or “Shortlist” are downloaded to KOReader as HTML files.
- Images are downloaded where this is possible.
- Articles which have been read in KOReader and marked as complete will be moved to the Readwise Reader Archive at the next sync, and deleted from KOReader.
- At sync, articles which have been archived in Readwise Reader will be deleted from KOReader.
- Particular types of article, locations and document tags can be excluded from syncing in the settings menu.

Installation:
- Download the ZIP file of the plugin [here](https://github.com/tomtom800/readwisereader/archive/refs/heads/main.zip). Extract it.
- Attach your ereader to your computer. Copy the readwisereader.koplugin folder containing _meta.lua and main.lua from the extracted folder to the koreader/plugins folder. Restart KOReader.
- The plugin requires a Readwise access token, which can be obtained for free [here](https://readwise.io/access_token). 
- The token can be typed in manually in the Readwise Reader/Settings/Configure Readwise Reader menu, but this is difficult to do correctly. The letter O and the number 0, are easily confused as are the lowercase letter l, the uppercase letter I and the numeral 1. If the plugin is not working, check this first.
- You may prefer to copy and paste the access token directly from your computer into KOReader settings. To do this, first set the folder you want to download to in the Readwise Reader/Settings/Download folder menu. This will create the file koreader/settings/readwisereader.lua. Add the access token to this file in the following format:

```
-- ./settings/readwisereader.lua
return {
    ["readwisereader"] = {
        ["access_token"] = "{access token}"
        ["available_locations"] = {},
        ["available_tags"] = {},
        ["directory"] = "{download location}",
        ["document_categories"] = {},
        ["document_locations"] = {},
        ["document_tags"] = {},
        ["excluded_locations"] = {},
        ["excluded_tags"] = {},
    },
}
```
- The extension is then activated by selecting “Sync” in the Readwise Reader menu.
- By default, the extension will be added to the file menu with the prefix NEW:. The plugin will work in this format, but to remove the NEW: prefix and to move it to a different menu, add a line for  `"readwisereader",` in the appropriate place in koreader/frontend/ui/elements/filemanager_menu_order.lua
