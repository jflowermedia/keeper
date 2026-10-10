# Keeper

Built by [JFlowerMedia](https://jflowermedia.com/)

A macOS app for getting sports footage off a card and into a delivery. It reads the KEEP flag your camera writes into its XML sidecars, lets you tag clips to players and events, and copies them out renamed and sorted.

Built for a Sony ILCE-7SM3 (A7S III), where a marked clip's XML carries `status="KEEP"` on `<TargetMaterial>`. The flag word is configurable, so other cameras are likely to work too.

> **Alpha — version 0.3.** Tested against one camera on one Mac. It never modifies or deletes anything on your cards, but don't let it be the only copy of footage you care about: verify your clips landed before you wipe anything. Bug reports welcome in [Issues](../../issues).

<!-- Add a screenshot here: press Cmd-Shift-4 then Space to grab the window, then drag the
     file into the README editor on github.com and it uploads and inserts the link for you. -->

## Download

Grab the latest `Keeper.zip` from [Releases](../../releases), unzip it, and drag **Keeper.app** to your Applications folder. Requires macOS 13 or later.

### First launch: macOS will block it

You'll see **"Apple could not verify Keeper is free of malware."** That's expected. Keeper isn't notarized by Apple, which needs a paid developer account. The app is open source — every line of it is in this repo, and you can build it yourself if you'd rather not take my word for it.

To open it anyway:

1. Double-click Keeper, then click **Done** on the warning.
2. Open **System Settings → Privacy & Security** and scroll to **Security**. There'll be a line saying *"Keeper" was blocked to protect your Mac*, with an **Open Anyway** button.
3. Click **Open Anyway**, authenticate, then open Keeper again and click **Open**.

Once per version, then it opens normally. On macOS 14 and earlier, right-clicking the app and choosing **Open** does the same in one step — Apple removed that shortcut in macOS 15. Either way, this one command skips the whole dance:

```
xattr -dr com.apple.quarantine /Applications/Keeper.app
```

## Sorting clips

1. **Choose Folder…** (⌘O) and pick a card, an SSD, or any folder of clips. It scans everything underneath for `.xml` sidecars.
2. Filter by **IS KEEP**, **IS NOT KEEP**, or **ALL**.
3. Click a clip to preview it. Shift or ⌘-click for several, ⌘A for all.

   Transport keys work wherever the focus is: **Space** or **2** play and pause, **3** shuttles forward, **1** shuttles back. Press 1 or 3 again to step up through 2x, 4x and 8x. A readout in the corner of the viewer shows direction and speed.
4. Get them out, either way:
   - **drag** them — the **grip dots** at the left of a row drag that one clip, and the **drag bar** at the bottom right drags your selection, or everything the filter is showing when nothing is selected, or
   - **Export…** (⌘S) for anything more than a plain drag: renaming, folder layout, writing changed flags. See [Exporting](#exporting).

**Include XML** decides whether each clip's sidecar travels with its video when you drag.

### Changing the flag

Click a clip's **KEEP** badge to mark or unmark it, or press ⌘K for the one in the viewer. The **Mark** menu does a whole selection at once.

Changed clips show an orange badge with a pencil, and the footer counts how many you've changed. The tooltip tells you what the camera originally said, and the right-click menu can put it back.

**Nothing is written to your card.** The change lives in Keeper's library until you export the clip, and then only the *exported* sidecar is edited — `status="KEEP"` added to or removed from its `<TargetMaterial>`, with the rest of the file left byte-for-byte alone. The card keeps whatever you flagged in camera.

Two things follow from that. A change only reaches a copy if the sidecar goes with it, and the export sheet says so in as many words when it won't. And because the marks are keyed to the clip's UMID, they survive rescanning, renaming and moving the footage to another drive.

## Tagging

Press ⌘E for the tagging panel.

**Import a roster** — a CSV of `team, number, name`, plus optional `code` and `position` columns. A header row is optional; without a team column the file's own name becomes the team. Several teams can live in one file. `roster-yateley-wood-pigeons.csv` is in this repo to test with.

```csv
team,code,number,name,position
Yateley Wood Pigeons,YWP,17,Finn Marchetti,Forward
Yateley Wood Pigeons,YWP,1,Callum Prentice,Goalie
```

The `code` column is the short form used in filenames. Give each roster its own and a single preset serves every team you shoot. Team names must be distinct. A club's men's and women's sides are two teams, so give them names that differ — calling both by the club name alone makes the second import replace the first.

**Tag a clip** — click a player, click a category. The selection clears straight afterwards, so the usual case (one player scores, another assists) is: #15, Goal, #17, Assist. Select several players before clicking a category when they genuinely share it; each gets their own tag.

Colour tells you two different things. A ring in the accent colour means **picked, about to be tagged**. Green with a tick means **already on this clip** — both for players and for categories — so you can see what a clip already carries without reading the list underneath. A player who is both shows the accent ring and keeps the green tick.

Picking a player applies to the clip you're looking at, so it clears when you move to another one. Green updates to match whatever is now in the viewer. The chips only cover the roster currently on show, so a tag belonging to another team is labelled with its team name in the list instead.

**Categories** start as Goal, Assist, Save, Hit, Penalty, Faceoff, Shot, Celebration, Interview, B-Roll. Add your own with the **+**, remove one by right-clicking it. Their order is also the tag priority — see below.

**Re-importing updates what's already tagged.** Fix a spelling or add a column, import again, and existing tags pick it up, matched on team and jersey number. There's also *Update Tags from Roster* in the panel's menu.

**Filter by tag** — the bar under the toolbar narrows by team, player, position and category, in any combination, on top of the KEEP filter. "Every clip of #17 scoring that I marked KEEP" is three clicks, and so is "every save by a goalie". Choosing a team also narrows the player and position menus to that roster.

**Remove tags** in bulk with the button at the foot of the panel. It acts on your selection, or everything the filter is showing when nothing is selected, and asks first.

## Exporting

**Export…** (⌘S) opens one sheet that asks four things and shows you the answer to each before you commit.

**Which clips** — the ones you've selected, or everything the filter is showing. It opens on whichever you'd expect: your selection if you made one, otherwise everything in view. The filters in play are printed underneath, so there's no exporting last week's team by accident.

**Naming** — a preset, or the camera's own names. Pick one and the sheet shows a real before-and-after from the first clip in the batch.

**Where they go** — the whole decision, in two lines:

- *Copy to another folder* — a renamed, sorted copy somewhere else. The originals stay exactly where they are.
- *Rename them where they already are* — nothing is copied, so you don't end up with the same footage twice. See [below](#renaming-footage-youve-already-offloaded).

**Along with the video** — whether each clip's sidecar comes too, and what happens to any KEEP flags you changed.

The button at the bottom right says what is actually about to happen — *Copy 70 Clips*, *Rename 35 Clips*, *Write 3 Flags* — and the line beside it totals the files and the data. If something's missing, that line says what instead of leaving the button to fail quietly.

### Folder layout

When you're copying, *Layout* decides how the destination is arranged:

- *One folder* — everything together.
- *Folder per category* — one copy of each clip, in the folder for its highest-priority tag. The folder and the filename agree, and a clip is never duplicated.
- *Folder per player* — a copy in each tagged player's folder, so every player's folder is complete. This one duplicates by design.

### Filenames

Pick a preset, or leave names alone. The built-in **Standard** preset gives:

```
C7531_261003_YWP_Marchetti_Goal.MP4
```

Original name, shoot date, team code, player surname, tag. The team code comes from the roster's `code` column. The date comes from the XML's `CreationDate`, so it's when the camera rolled rather than when the file was last touched.

Build your own per client in **Edit Presets…**: name it, set a fallback team code, choose the separator, and stack up the parts — original name, date in two formats, team code, roster team, player surname, first name or number, the top tag, or every tag. A live preview shows the result as you go. Empty parts drop out, so an untagged clip comes out `C7532_261003_YWP.MP4` rather than with gaps.

**Tag priority** decides which tag lands in the filename, and which folder the clip goes to, when it carries several. It's the order of the category list, set in the preset editor.

### Renaming footage you've already offloaded

If you pulled footage off in a hurry to cut something on the day, it's sitting on your drive under the camera's names. Tagging it later and copying it out again would leave you with the same footage twice — once named, once not.

Instead, scan that folder, tag it, then export with **Rename them where they already are**. It renames the footage in place, sidecars included, and writes in any KEEP flags you've changed. Nothing is copied, so you don't end up with the footage twice.

So the workflow for footage already on your drive is: scan the folder → tag → Export → *Rename them where they already are*. There's no copy step, because the files are already where you want them.

Two things to know. It's refused on a camera card — Keeper only ever reads those, so copy the footage off first. And it will **break the media links in any edit already built on those files**, which the sheet warns you about in orange. Use it on footage whose rush edit is finished, or before you start cutting.

Each clip's XML is renamed to match its video, so the pair still find each other when you scan that folder later. Renaming only happens on export — dragging to Finder keeps the camera names, because macOS gives the app no say in what a dropped file is called.

## Copy safety

- Free space at the destination is checked against the total before anything is written.
- A file already there with the same name and size is skipped as a duplicate.
- A clip's video and sidecar are named together, so they can never be split apart by a clash.
- Every copy is size-checked afterwards; a mismatch is reported as a failure, not a success.
- A progress bar along the bottom tracks bytes, not file count, so it doesn't lurch.

## Debug mode

⌘D for a log showing how many XML and video files were found, which XML paired with which video, exactly what in each XML marked it KEEP, sidecars that matched no video, videos with no sidecar, and the result of every copy. **Copy Log** puts it on the clipboard — the most useful thing to paste into a bug report.

## If KEEP clips aren't detected

Right-click a clip and choose **Show XML…** to see what yours contains, then type the exact word it uses into **Flag word** and press Return. A clip counts as KEEP when that word turns up in an element name, attribute name, attribute value or text, and isn't set to false/0/off/no.

## How tags stay attached

Tags are keyed to the **UMID** in each clip's XML — the unique ID the camera writes per clip. Not the filename, which comes round again every time a card's numbering resets, and not the path, which changes the moment you move footage to a drive.

So a tag follows its clip when you rename it, copy it to an SSD, or archive it. Each tag also records the clip's name, drive and path, so the library stays readable when that drive isn't plugged in.

Everything lives in `~/Library/Application Support/Keeper/library.json` — teams, categories, presets and tags in one readable file. Worth backing up once you've tagged a game you care about.

## Build from source

Needs macOS 13+ and Xcode's command line tools (`xcode-select --install`).

```
git clone https://github.com/jflowermedia/keeper.git
cd keeper
chmod +x build_app.sh
./build_app.sh --install
```

See [DEVELOPING.md](DEVELOPING.md) for the rest.

## Known gaps

- No in-app roster editing — change the CSV and import it again.
- No undo on tag deletion.
- Proxy files in a `SUB` folder aren't handled, only the main clip and its XML.
- Clips with no XML sidecar can't be listed or tagged. Debug mode names them.

## Credits

Built by **JFlowerMedia**

- Website: [jflowermedia.com](https://jflowermedia.com/)
- Instagram: [@jflowermedia](https://www.instagram.com/jflowermedia/)

## License

MIT, see [LICENSE](LICENSE).

## Disclaimer

Keeper is alpha software, shared in good faith and provided as is, without warranty of any kind.

It is built to be read-only on your cards and drives — it copies files and never modifies or deletes your originals — and it checks every copy against its source before reporting success. But no software is free of bugs, and I can't test against every camera, card, file system and Mac out there.

Your footage remains your responsibility. Confirm your clips have copied across and open correctly before you format a card or delete anything, and keep a second copy of work that matters to you. Use at your own risk: no liability is accepted for footage that is lost, corrupted or missed, however it happens.
