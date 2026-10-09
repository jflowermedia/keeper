# Keeper

Built by [JFlowerMedia](https://jflowermedia.com/)

A small macOS app for sorting camera clips by the KEEP flag your camera writes into its XML sidecars.

> **Alpha — version 0.1.** Tested against one camera on one Mac. It never modifies or deletes anything on your card, but don't let it be the only copy of footage you care about: verify your clips landed before you wipe anything. Bug reports welcome in [Issues](../../issues).

Point it at an SD card and it pairs every clip with its XML, reads the flag, and shows you two lists: the clips you marked to keep and the ones you didn't. Preview them, then drag either group straight into Finder.

Built for a Sony ILCE-7SM3 (A7S III), where a marked clip's XML carries `status="KEEP"` on `<TargetMaterial>`. The flag word is configurable, so other cameras are likely to work too.

<!-- Add a screenshot here: press Cmd-Shift-4 to grab the window, then drag the file into
     the README editor on github.com and it uploads and inserts the link for you. -->

## Download

Grab the latest `Keeper.zip` from [Releases](../../releases), unzip it, and drag **Keeper.app** to your Applications folder. Releases are marked pre-release while the app is in alpha.

**The first time you open it,** right-click the app and choose **Open**, then click Open in the dialog. macOS blocks apps that aren't notarized by Apple, and notarizing requires a paid developer account. After that first time it opens normally. If you'd rather clear the flag outright:

```
xattr -dr com.apple.quarantine /Applications/Keeper.app
```

Requires macOS 13 or later. Apple silicon and Intel both work if you build from source; the release build is whatever the machine that built it is.

## Using it

1. **Choose Card…** (⌘O) and pick your SD card. It scans every folder for `.xml` files.
2. Filter by **IS KEEP**, **IS NOT KEEP**, or **ALL**.
3. Click a clip to preview it. Shift or ⌘-click for several, ⌘A for all.
4. Drag out either way:
   - the **grip dots** at the left of a row drag that one clip, or
   - the **drag bar** at the bottom right drags your selection; with nothing selected it drags everything the filter is showing. Its label says how many clips and how much data.
5. **Copy to Folder…** (⌘S) does the same through a folder picker instead.

**Include XML** (bottom right, on by default) decides whether each clip's XML sidecar travels with its video. It applies to dragging and to Copy to Folder alike.

Nothing on the card is ever modified or deleted.

## Copy safety

- Free space at the destination is checked against the total before anything is written.
- A file already there with the same name and size is skipped as a duplicate.
- A file with the same name but a **different** size is never overwritten: the new one lands as `C0001 2.MP4`, and the log says so.
- Every copy is size-checked afterwards; a mismatch is reported as a failure, not a success.

## Debug mode

Click **Debug** (the ladybug, ⌘D) for a log showing how many XML and video files were found, which XML paired with which video, exactly what in each XML marked it KEEP (e.g. `[<TargetMaterial> status="KEEP"]`), XML files that matched no video, videos with no sidecar, and the outcome of every copy. **Copy Log** puts it on the clipboard, which is the most useful thing to paste into a bug report.

## If KEEP clips aren't detected

Cameras store the flag differently. Right-click a clip and choose **Show XML…** to see what yours contains, then type the exact word it uses into **Flag word** and press Return.

A clip counts as KEEP when that word turns up in an element name, attribute name, attribute value or text, and isn't set to false/0/off/no.

## How clips are paired

Base names are matched first (`C0001.XML` ↔ `C0001.MP4`), then Sony's `C0001M01.XML` → `C0001.MP4`, and failing both, any video file named inside the XML. When the same base name appears twice on a card, the video sitting in the XML's own folder wins.

Videos without a sidecar can't be classified, so they don't appear in either list. Debug mode names them.

## Build from source

Needs macOS 13+ and Xcode's command line tools (`xcode-select --install`).

```
git clone https://github.com/YOURNAME/keeper.git
cd keeper
chmod +x build_app.sh
./build_app.sh --install
```

That builds `Keeper.app`, signs it ad-hoc, and copies it into `/Applications`. Leave off `--install` to leave it in the project folder. `swift run` runs it straight from source while you're changing things.

### Making a release build

Signing with a Developer ID and notarizing removes the right-click-to-open step for everyone who downloads it. It needs a paid Apple Developer account. Create a **Developer ID Application** certificate in Xcode → Settings → Accounts, store notarization credentials once:

```
xcrun notarytool store-credentials NOTARY --apple-id you@example.com --team-id AB12CD34EF
```

then build (`security find-identity -v -p codesigning` lists your certificate name):

```
DEVID="Developer ID Application: Jane Doe (AB12CD34EF)" NOTARY_PROFILE=NOTARY ./build_app.sh --notarize
```

### The app icon

`icon.png` is the app's icon; replace it with any square PNG and rebuild. `make_icon.py` draws the current one if you'd rather edit it than replace it (`python3 make_icon.py`, needs `pip install cairosvg`).

## Notes

- Thumbnails and preview use macOS's own decoder, so formats it can't read (some MXF, BRAW, R3D) show a grey thumbnail and won't play. Those files still drag and copy normally.
- Proxy files are not handled yet: only the main clip and its XML.

## Credits

Built by **JFlowerMedia**

- Website: [jflowermedia.com](https://jflowermedia.com/)
- Instagram: [@jflowermedia](https://www.instagram.com/jflowermedia/)

## License

MIT, see [LICENSE](LICENSE).
