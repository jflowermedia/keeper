# Keeper

A macOS app for getting sports footage off a card and into a delivery. It reads the KEEP flag your camera writes into its XML sidecars, lets you tag clips to players and events, and copies them out renamed and sorted.

Built by [JFlowerMedia](https://jflowermedia.com/) · [Download](../../releases) · macOS 13 or later

> **Alpha, version 0.5.** Tested against one camera on one Mac. It never writes to your cards, but don't let it be the only copy of footage you care about. Bug reports welcome in [Issues](../../issues).

![The Keeper window: a scanned card listed down the left with KEEP badges and player tags on each clip, the selected clip playing in the middle, and the tagging panel open on the right showing a roster and the event categories](docs/keeper.png)

## What it does

**Reads the flag you set in camera.** Point it at a card, an SSD, or any folder of footage. It finds the XML sidecars, pairs each to its video, and filters to the clips you marked KEEP — or the ones you didn't, for warmups and B-roll. You can mark and unmark clips in the app too; those changes go into the exported sidecar, never onto the card.

**Previews without leaving the app.** Space plays and pauses, 1 and 3 shuttle back and forward through 2x, 4x and 8x.

**Tags clips to players and events.** Import a roster as a CSV, or type one in. Click a player, then a category — Goal, Save, Hit, or your own. Several players can be tagged on one clip with different categories, so one gets the goal and another the assist.

![The roster editor: teams listed down the left under their league headings, and on the right the selected team's name, filename code and league, above a list of players with editable number, name and position](docs/rosters.png)

**Filters by what you tagged.** Team, player, position and category, in any combination, on top of the KEEP filter. Every save by a goalie, or every clip of #17 you marked KEEP, is a few clicks.

**Renames to a client's convention.** Build a preset from the parts you want — original name, shoot date, team code, player surname, event — and keep one per client.

```
C7531_261003_WHKY_Marchetti_Goal.MP4
```

![The filename preset editor: a preview of the resulting filename at the top, then the preset name, team code and separator, then the name parts listed in order with a live example beside each, and the tag priority list below](docs/presets.png)

**Checks the card copied before you format it.** Point it at the folders you copied to — however many — and it accounts for every clip on the card. It matches on the camera's clip ID rather than the filename, so it still works after you've renamed everything, which no general file-compare tool can do.

**Exports in one sheet.** It shows which clips are included, the names it will produce, where they're going and how much data that is, before anything moves. Copy them out into one folder, a folder per player, or a folder per event — or rename footage you already offloaded where it sits, so you don't end up holding the same game twice. Clips can also be dragged straight into Finder.

![The Export sheet: radio buttons choosing between the selected clip and all 18 the filter is showing, a naming preset, a choice between copying to another folder and renaming in place, and a checkbox for the XML sidecar. The footer totals the clips, files and data, and the action button is disabled with a line saying to choose where the copies should go](docs/export.png)

## Copy safety

- Keeper never writes to, renames or deletes anything on a camera card. A flag you changed is applied to the copy; the card keeps what you set in camera.
- Free space at the destination is checked before anything is written.
- Every copy is size-checked against its source afterwards. A mismatch is reported as a failure, not a success.
- A file already there with the same name and size is skipped as a duplicate.
- A clip's video and sidecar are named together, so a filename clash can't separate them.
- Tags are keyed to the camera's UMID rather than the filename, so they survive renaming, copying to another drive, and a card restarting its numbering.

## Which cameras

Built against a **Sony ILCE-7SM3 (A7S III)**, where a flagged clip's XML carries `status="KEEP"` on `<TargetMaterial>`. The flag word is configurable and detection is deliberately loose, so other cameras that write an XML sidecar are likely to work. If yours doesn't, debug mode shows what's in your sidecars — open an issue with it.

## Install

Download `Keeper.zip` from [Releases](../../releases), unzip, and drag **Keeper.app** to Applications.

### macOS will block it on first launch

You'll see *"Apple could not verify Keeper is free of malware."* Keeper isn't notarized by Apple, which needs a paid developer account. The app is open source: every line is in this repo, and you can build it yourself rather than take my word for it.

1. Double-click Keeper, then click **Done** on the warning.
2. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** beside the line about Keeper.
3. Authenticate, open Keeper again, click **Open**.

Once per version. Or skip it in one command:

```
xattr -dr com.apple.quarantine /Applications/Keeper.app
```

### Build from source instead

Needs macOS 13+ and Xcode's command line tools (`xcode-select --install`).

```
git clone https://github.com/jflowermedia/keeper.git
cd keeper
chmod +x build_app.sh
./build_app.sh --install
```

[DEVELOPING.md](DEVELOPING.md) has the rest.

---

# Guide

## Shortcuts

| | |
|---|---|
| ⌘O | Choose folder |
| ⌘R | Rescan |
| Space or 2 | Play, pause |
| 1 and 3 | Shuttle back and forward — press again for 2x, 4x, 8x |
| ⌘F | Full screen preview (Escape to come back) |
| ⌘K | Toggle KEEP on the previewed clip |
| ⌘E | Tagging panel |
| ⌘I | Import roster CSV |
| ⌘⇧R | Edit rosters |
| ⌘S | Export |
| ⌘⇧V | Check the card copied |
| ⌘D | Debug log |

## Scanning

**Choose Folder…** takes a card, an SSD, or any folder, and scans everything underneath for `.xml` sidecars. Filter by **IS KEEP**, **IS NOT KEEP** or **ALL**. Click a clip to preview it, shift or ⌘-click for several, ⌘A for all.

## Changing a flag

Click a clip's **KEEP** badge, or ⌘K for the one in the viewer. The **Mark** menu does a whole selection at once. Changed clips get an orange badge; right-click to put it back.

Nothing is written to your card. The change is applied to the sidecar on export, and only if the sidecar goes with it — the export sheet says so when it won't.

## Rosters

Import a CSV with ⌘I. `roster-yateley-wood-pigeons.csv` is in this repo to test with.

```csv
league,team,code,number,name,position
MJHL,Virden Oil Capitals,VIR,27,Liam Goertzen,Forward
MJHL,Virden Oil Capitals,VIR,31,Micky Gross,Goalie
```

Only `number` and `name` are needed. A header row is optional, several teams can share a file, and without a `team` column the filename becomes the team.

- **`code`** is the short form used in filenames.
- **`league`** groups the team menus. `org`, `organisation`, `organization` and `group` work too.

Team names must be distinct, since importing one replaces any team of the same name — a club's men's and women's sides need names that differ. Re-importing updates existing tags, matched on team and number, and columns you leave out keep what's already set.

**⌘⇧R** edits rosters in the app: names, numbers, positions, team code and league, adding and removing players and teams.

Two players can't share a number and two teams can't share a name, because that's how Keeper tells them apart. Renumbering a player carries their existing tags across; removing a player leaves their tags behind, so prefer renumbering.

## Tagging

⌘E for the panel. Click a player, then a category. The selection clears straight after, so one player gets the goal and the next gets the assist. Select several players first when they genuinely share a category.

An accent ring means **picked**. A green tick means **already on this clip**.

Categories start as Goal, Assist, Save, Hit, Penalty, Faceoff, Shot, Celebration, Interview and B-Roll. Add with **+**, remove by right-clicking. Their order decides which tag wins when a clip has several.

The bar under the toolbar filters by team, player, position and category, on top of the KEEP filter.

## Exporting

⌘S opens one sheet, which asks four things:

- **Which clips** — your selection, or everything the filter is showing
- **Naming** — a preset or the camera's names, with a before-and-after
- **Where they go** — copy to another folder, or rename them in place
- **Along with the video** — whether the sidecar travels, and what happens to changed flags

The button names what it's about to do, and the line beside it totals the files and the data.

**Layout**, when copying:

- *One folder* — everything together
- *Folder per category* — one copy of each clip, in its top tag's folder
- *Folder per player* — a copy in each tagged player's folder, so every player's folder is complete

**Rename them where they already are** is for footage you've offloaded already: it renames in place so you don't end up holding the same game twice. It's refused on a card, and it breaks the media links in any edit already built on those files.

Dragging to Finder keeps the camera names — macOS gives the app no say in what a dropped file is called.

## Filenames

The built-in **Standard** preset gives `C7531_261003_YWP_Marchetti_Goal.MP4` — original name, shoot date, team code, player surname, tag. The date comes from the XML, so it's when the camera rolled.

Build your own in **Edit Presets…**: a name, a fallback team code, a separator, and the parts in order. Duplicate an existing preset for a new client rather than starting over. Empty parts drop out, so an untagged clip comes out `C7532_261003_YWP.MP4` rather than with gaps.

## If something's wrong

**Before formatting a card** — **Check Copied** at the bottom right, or ⌘⇧V. Add every folder you copied that card into, and it reports which clips are accounted for, which are missing, and which arrived the wrong size, with the gigabytes on the card set against the gigabytes found in each folder. Matching is by the camera's clip ID, so renamed copies are still recognised; that needs the XML sidecars to have travelled with them.

**No KEEP clips found** — right-click a clip, choose **Show XML…** to see what your camera writes, then type that word into **Flag word**.

**⌘D** opens the debug log: which sidecar paired with which video, what marked each clip, and the result of every copy. **Copy Log** puts it on the clipboard for a bug report.

**Your tags live in** `~/Library/Application Support/Keeper/library.json`, with teams, categories and presets. Worth backing up — there's no undo.

---

## Known gaps

- No undo on tag deletion, or on a roster edit.
- Proxy files in a `SUB` folder aren't handled, only the main clip and its sidecar.
- Clips with no XML sidecar can't be listed or tagged. Debug mode names them.

## Credits

Built by **JFlowerMedia** — [jflowermedia.com](https://jflowermedia.com/) · [@jflowermedia](https://www.instagram.com/jflowermedia/)

## License

MIT, see [LICENSE](LICENSE).

## Disclaimer

Keeper is alpha software, shared in good faith and provided as is, without warranty of any kind.

It is built to be read-only on your cards and drives, and it checks every copy against its source before reporting success. But no software is free of bugs, and I can't test against every camera, card, file system and Mac out there.

Your footage remains your responsibility. Confirm your clips have copied across and open correctly before you format a card or delete anything, and keep a second copy of work that matters to you. Use at your own risk: no liability is accepted for footage that is lost, corrupted or missed, however it happens.
