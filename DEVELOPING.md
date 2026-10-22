# Developing Keeper

Notes to self. Everything runs from the project folder:

    cd ~/Documents/GitHub/Keeper

## Everyday change

1. Edit the files in `Sources/Keeper/`.
2. `swift run Keeper --self-check` — the three parsers that have broken before. Seconds, and worth it before anything else.
3. `swift run` — builds and launches straight from source. Fastest way to try something.
4. When happy: `./build_app.sh --install` puts the real app in /Applications.
5. Commit and push:

```
git add .
git commit -m "Short description of what changed"
git push
```

Pushing does **not** give anyone a new app. Downloads come from Releases, so until you cut one, the published app stays as it was.

## Cutting a release

1. Bump the version: `AppInfo.version` near the top of `Sources/Keeper/KeeperApp.swift`. That's the only place — the build script reads it and stamps the app bundle to match. Drop `stage` to `"beta"` or `""` when it earns it.
2. Commit and push that change.
3. Build and package:

```
./build_app.sh
ditto -c -k --keepParent Keeper.app Keeper.zip
open .
```

4. Go to https://github.com/jflowermedia/keeper/releases/new
   - Tag `v0.2.0` (add `-alpha` or `-beta` while it's still rough)
   - Title `Keeper 0.2`
   - Notes: what changed since last time
   - Tick **Set as a pre-release** if it's still alpha or beta
   - Drag `Keeper.zip` into the attachments box
   - Publish

`ditto`, not Finder's Compress — plain zipping can break an app bundle.

## The app icon

`icon.png` is the app's icon — replace it with any square PNG (1024×1024 ideal) and rebuild. `make_icon.py` draws the current one if you'd rather edit than replace: `python3 make_icon.py`, needs `pip install cairosvg`.

## Notarizing (removing the macOS warning)

Downloaders get "Apple could not verify Keeper is free of malware" until the app is notarized. That needs a paid Apple Developer account, $99/year. One-time setup: create a **Developer ID Application** certificate in Xcode → Settings → Accounts, then

```
xcrun notarytool store-credentials NOTARY --apple-id you@example.com --team-id AB12CD34EF
```

Then every release build (`security find-identity -v -p codesigning` lists the certificate name):

```
DEVID="Developer ID Application: Your Name (AB12CD34EF)" NOTARY_PROFILE=NOTARY ./build_app.sh --notarize
```

## Version numbering

`MAJOR.MINOR.PATCH`

- `0.1.1` — bug fix, nothing new
- `0.2.0` — new feature
- `1.0.0` — first version you'd call finished

## Which file does what

| File | Holds |
|---|---|
| `Sources/Keeper/KeeperApp.swift` | app entry point, menus, About box, version and links |
| `Sources/Keeper/ContentView.swift` | the whole UI: toolbar, filter bar, list, preview, transport keys, debug panel |
| `Sources/Keeper/AppState.swift` | what the app knows and does: scanning, filtering, copying, logging |
| `Sources/Keeper/Clip.swift` | card scanning, XML parsing (KEEP flag, UMID, shoot date), file helpers |
| `Sources/Keeper/Tagging.swift` | teams, players, tags, keep overrides, the JSON library, roster CSV import |
| `Sources/Keeper/KeepWriter.swift` | writes a changed KEEP flag into a copied sidecar |
| `Sources/Keeper/TagPanel.swift` | the tagging panel and the chips on each row |
| `Sources/Keeper/Renaming.swift` | filename tokens, presets, and building a name |
| `Sources/Keeper/ExportSheet.swift` | the one sheet that decides what leaves and how |
| `Sources/Keeper/RosterEditor.swift` | editing teams and players after import |
| `Sources/Keeper/PresetEditor.swift` | the preset builder sheet |
| `Sources/Keeper/MultiDragHandle.swift` | the drag-to-Finder handles |
| `Sources/Keeper/Shortcuts.swift` | which key does what, and the rules about changing it |
| `Sources/Keeper/TagFlow.swift` | the keyboard tagging flow: which rosters are in play, the cursors, the key machine |
| `Sources/Keeper/ShortcutsSheet.swift` | the shortcut editor and its key recorder |
| `Sources/Keeper/SelfCheck.swift` | `--self-check` — the CSV parser, the stored format, the scanner |
| `build_app.sh` | turns the build into Keeper.app, makes the icon, signs it |
| `icon.png` / `make_icon.py` | the app icon and the script that draws it |

## Checks

```
swift run Keeper --self-check
```

Three suites covering the three things that have actually shipped broken: the CSV reader
(CRLF, a byte-order mark, quoting), the stored library format (an older `library.json`
decoding), and sidecar pairing (a card index not stealing a clip's identity). They print a
line each and a count, and exit non-zero on a failure.

**They are not an XCTest target, and must not become one.** XCTest ships with Xcode; the
Command Line Tools are all this app needs to build, and that's what the README tells people
to install. A test target can therefore only run on a machine set up differently from the one
that builds the app — which is how a suite ends up never being run at all. That happened:
the target was added, recommended three times, and errored with `no such module 'XCTest'` the
first time anyone tried it. Hence a dozen lines of harness in `SelfCheck.swift` instead.

Everything in there works on bytes or a folder under `FileManager.default.temporaryDirectory`.
Nothing goes near the real `library.json` — a check that touched it could delete a season of
tagging. Keep it that way.

Adding one means finding a seam that takes data rather than a file path.
`TagLibrary.decodeArchive(_:)` exists for exactly that: it's the whole of `load()` with the
`Data(contentsOf:)` taken out.

## Rules worth keeping

**Every new field on a stored type must be optional, and the decoder is hand-written as
well.** Swift's generated decoder throws on a missing key for a non-optional property even
when it has a default value, so adding `var thing: String = ""` to `Team`, `Player` or `Tag`
would stop every existing `library.json` from loading. Use `String?`. This has bitten once
already, and `Team.code` and `Team.league` are both optional for that reason. Belt and
braces: `Player`, `Team`, `Tag` and `KeyCombo` each have an `init(from:)` written by hand in
an extension, where every field is read with `decodeIfPresent` and falls back to its default.
That means a field someone forgets to make optional can't break loading either. Those
initialisers live in extensions on purpose — declaring one in the type's own body would
suppress the memberwise initialiser everything else uses.

**`Character` is a grapheme cluster, and `"\r\n"` is one of them.** `"\r\n".count == 1` in
Swift, so iterating a CRLF file's Characters never yields a bare `"\n"`. A parser switching
on `"\n"` matches nothing, appends every line ending into a field, and returns the whole
file as a single row — which then reads as an empty file once the header is removed. This
shipped, and it broke every roster exported from Excel or Numbers, both of which write CRLF.
`CSV.parse` now normalises line endings before the loop, and `CSV.readText` strips a UTF-8
BOM for the same reason: Excel writes one, and it rides along on the first heading so that
column goes unrecognised. Anything parsed character by character needs the same care.

**An import replaces the whole team, so anything the CSV doesn't carry must be read back
off the existing team first.** `importRoster` falls back to the current `code` and `league`
when those columns are absent. Without that, re-importing a bare `team, number, name` file
to fix a spelling silently wipes the team's filename code — which only shows up later, in a
filename that's missing a word.

**A clip's video and its XML must always end up with the same base name**, or they stop
pairing on the next scan. That's why `CopyJob` carries a whole clip rather than one file.

**Tags key off the UMID**, never the filename or path.

**Sidecar claims are settled strongest first, not in file order.** A card index — Sony writes
`MEDIAPRO.XML` — lists every clip on the card, so it can reference `C7787.MP4` exactly as
readily as `C7787M01.XML` is named after it. `ClipScanner` therefore collects every claim with
a `MatchStrength` (named, referenced, prefix) and settles them in that order, so a clip's own
sidecar always wins. Before this it settled as it went, and the only thing keeping the index
from claiming a clip was that `CLIP/` sorts before `MEDIAPRO.XML`. Had the index won, that
clip would have taken the index's KEEP flag and UMID, and its real sidecar would have been
reported unmatched. Don't reintroduce assign-as-you-go.

**A player's identity is `teamID/number`, and a team's is the slug of its first name.** Both
are computed, not stored, so anything that changes a number or a team id detaches the tags
hanging off it. That's why `TagLibrary.apply(_:to:)` is a single call rather than a setter
per field: it migrates tags for renumbered players *before* replacing the roster, in one
pass so two players swapping numbers can't be applied twice. Renaming a team deliberately
leaves `Team.id` alone — only `name` changes — and `refreshTagsFromRoster` then carries the
new name onto the tags. Don't add a path that writes a team id.

**Nothing is ever written to a card.** A changed KEEP flag is held in the library and
applied to the *copied* sidecar by `KeepWriter`, after the copy has been size-checked.
Three things hold that line, and all three have to stay:

- in-place renaming is refused on anything matching `FileUtil.looksLikeCameraCard`, both by
  the sheet and again inside `renameInPlace()`;
- a copy destination matching the same test is blocked by `exportBlocker`;
- the copy loop's "sidecar already at the destination" branch applies the flag only when
  `!FileUtil.sameFile(target, src)`. Without that check, copying into the folder the clips
  are already in makes target and source the same file, and the flag gets written into the
  original — on a card, that's the promise broken.

**One export path.** `ExportSheet` is the only way into `copy(to:)` and `renameInPlace()`,
and `exportClips` is the only scope either of them reads. Adding a second entry point —
a toolbar shortcut that skips the sheet, say — reintroduces the thing that made the old
two-button footer confusing: an action whose scope and destination you couldn't see.
The sheet is also the confirmation, which is why `renameInPlace()` no longer runs an
`NSAlert` of its own. Anything that could surprise someone belongs on the sheet, stated
plainly, and the action button's label must name the real count — `exportRenameCount`,
not the size of the scope.

**`exportBlocker` disables; `exportCaution` only takes away the Return key.** Blockers are
for things that cannot work. Cautions are for things that work but probably aren't what was
meant — copying clips into the folder they already live in, which is how you end up with
the footage twice. Because the sheet remembers the last destination, that's a one-keystroke
mistake, so `returnIsSafe` withholds `.defaultAction` from both that and in-place renaming.
Don't promote a caution to a blocker without a reason: the user is allowed to do it.

**Every method that changes a flag or a tag takes an `undoLabel`, and it isn't optional to
pass.** `TagLibrary` keeps a stack of `Edit`s, each one *the state before a change* rather
than the change itself — which is what lets `apply` return the edit that reverses it, so undo
and redo are the same code run in opposite directions. The label is `String?` and required at
the call site, so adding a new mutation forces a decision about whether it can be taken back.
Pass nil only for bookkeeping that follows something already written to disk: `renameInPlace`
clears an override *because the sidecar on disk now carries that flag*, and undoing that would
leave the library disagreeing with the file. Those are the only two nil sites, both commented.

Record **before** mutating, and only when something will actually change — the bulk setter
works out which clips will move and records just those, so marking a selection that's already
KEEP neither writes the library nor leaves a dead step in the stack. Several changes that
happened on one click have to be one step: that's why `add` takes an array, and why tagging
three players comes off with one ⌘Z.

The stack is memory-only and cleared whenever the library is replaced wholesale — `load` and
`restore` — because those edits describe a library that no longer exists. Roster edits are
deliberately *not* undoable this way; the backups are the route back from those, and the
undo stack survives one because a keep override is keyed by UMID and owes nothing to a roster.

This one isn't covered by `--self-check`: it lives on a singleton whose `save()` writes the
real `library.json`, and a check that touched that could delete a season of tagging. If it
grows, the thing to extract is `apply` as a pure function over `(keepOverrides, tags)`.

**Shortcuts are data, not literals.** `Shortcuts` holds the bindings and `KeeperApp` reads
them with `shortcuts.equivalent(_:)`. It observes the store rather than just reading it,
because the key equivalents are baked into the menu items when the scene body runs — without
the observation a changed key wouldn't take effect until the next launch. Two invariants hold
the editor together: a review key never carries a modifier (which is what lets the event
monitor bail out the moment anything is held down), and a menu command always carries ⌘
(or it would fire while someone was typing). `assign` swaps two bindings rather than letting
either end up with no key, and refuses to take an action's last one — a menu item with no
equivalent is a command you can't reach and can't get back except with Reset.

**The keyboard flow takes only the keys it's using, at the stage it's on.** That rule is
`FlowKeyState.claims`, and it's what keeps Space playing the clip and 1/3 shuttling while
you tag. Two traps are already paid for in there: Escape is *not* claimed at the clip stage,
because swallowing it would take away the way out of the full-screen preview; and ← → aren't
either, because nothing at that stage moves sideways. Digits are claimed only at the player
stage and letters only at the category stage, so a jersey number and a shuttle key can share
a key without either being lost. Before adding a claim, ask what that key already does.

`FlowKeyState` is a plain class holding two mirrored values — on/off, and the stage — because
the monitor needs both to decide and can't read `AppState`. It reads the stored toggle in its
own `init`, which matters: property observers don't fire for assignments inside an
initialiser, so `AppState.init` setting `keyboardFlow` would otherwise leave the mirror
saying off until something toggled it.

**The arrows keep a positional anchor, because marking a clip removes it from the list.**
`selectRelative` looks the previewed clip up in `visible` — and marking it KEEP while
filtering by KEEP means it isn't there any more. Without an anchor the lookup fails, the
"nothing selected yet" branch takes over, and ⌘K sends you back to the top of the card.
That shipped. `toggleKeep` records the clip's index *before* changing the flag, and only for
the clip in the viewer, so a badge click on another row leaves the anchor where the preview
is. The clip that was after it has slid into its place, which is why the anchor itself is the
next one rather than the anchor plus one.

**The grid and the cursor index the same list, and that list is `flowPlayers`.**
`activeTeams` is what's in play, `shownTeams` is the one bench drawn, `rosterPlayers` is that
bench, and `flowPlayers` is `rosterPlayers` narrowed by whatever number is being typed. The
grid draws `flowPlayers` and the cursor indexes `flowPlayers`, so a filtered grid can't point
at a player who isn't on it. `flowPlayer` — the one picked — deliberately looks itself up in
`rosterPlayers` instead, because a pick must not evaporate when a filter changes.

**A chip's identity is `GridID.player(at:_:)`, and it is defined once.** Two things need it
to agree: the grid builds it, and the cursor's `scrollTo` looks it up. It carries the
position *and* the player for two separate reasons, both of which have bitten. A bare index
repeats across rosters, so switching bench handed the new roster the old one's identities and
SwiftUI reused the views rather than updating them — the pill changed and the grid didn't.
And `Player.id` is `teamID/number`, which two players wearing the same number share.

**No `Section` inside a `ForEach` inside a `LazyVGrid`.** The headers never drew and the grid
went on showing rosters that had left the data. There's one bench on screen now so the
question doesn't arise, but if headings ever come back, they're a `Text` above their own grid. The cursor is one
index into the rosters flattened end to end, so the grid and the ← → key have to agree about
where each block begins. They each worked it out for themselves at first, which is two
chances to be wrong by one.

**The key monitor steps aside for anything in front of the main window.** Four tests, and
each one is there for a reason. A text field being edited; `NSApp.modalWindow` non-nil; the
event's window being an `NSPanel`; a sheet, either as the event's window or attached to it.

The file picker is why. `NSOpenPanel.runModal()` opens a window of its own and runs a modal
loop: it isn't a sheet, and its first responder is the file list rather than a text field, so
it slipped past the only two tests that were here. Arrowing to a folder in the picker was
read as "next clip", and `selectRelative` replaces the whole selection with that clip — so
choosing an export folder with the keyboard threw away the clips being exported, and the
sheet went on saying "the 1 clip you've selected". It only happened when the folder was
reached by keyboard, which made it look intermittent. There are nine modal panels and alerts
in the app and every one of them was exposed.

`selectRelative` refuses outright while `aSheetIsUp`, as a second line of defence: a sheet
showing a count of what it will act on must not have that count move underneath it.

Adding a window of our own means checking it against those four tests. `FullScreenWindow` is
an `NSWindow` rather than an `NSPanel` for exactly this reason — the transport keys and
Escape have to keep working there.

**A hand-made multi-selection is not the flow's to throw away.** Two things were taking it.
`FlowKeyState.claims` must leave ⇧↑ and ⇧↓ alone at the clip step — that's the list's own
extend-the-range gesture, and claiming it meant every press collapsed the selection to one
clip instead of growing it, so picking a range for export was impossible with keyboard
tagging on. And anything that advances on its own — marking with `advanceAfterMark`, tagging
with `advanceAfterTag`, the keyboard flow filing a tag — goes through `advanceAfterAction`,
which stands still while more than one clip is selected. A plain arrow still collapses it;
that one is the user asking to move.

**The key monitor can't touch `AppState`.** It runs outside the main actor and `AppState` is
`@MainActor`, so the arrow keys post `.keeperMoveSelection` and `ContentView` does the move.
The notification carries a token because every open window's view hears it and they share one
`AppState` — without it, a second window would move the selection twice per press.

**Rolling backups are throttled, and the Restore menu's list is cached.** `save()` runs on
every tag, so `backUpIfDue` takes a copy at most every ten minutes — otherwise all ten slots
would hold the same minute and the morning's work would be gone. The menus are rebuilt
whenever anything on `AppState` changes, including each file of a copy, so `libraryBackups`
is a stored array refreshed on launch and on `.keeperLibraryBackedUp`, not a folder listing
behind a computed property.

**A copy stops after five consecutive failures.** A destination that has filled up, gone
offline or turned out read-only fails every file, and the old behaviour was seventy identical
log lines and a status that read like success with a footnote. Failures are counted per file
by comparing `failed` before and after, and the reset is guarded on `folderReady` — with no
folder the inner loop neither succeeds nor fails, so resetting there would stop a destination
refusing every folder from ever tripping the limit. The status says STOPPED and how far it
got, because the one thing that must not happen is formatting a card on the strength of a
copy that didn't finish.

**Everything on the sheet is computed, so it must stay cheap.** `exportFileCount` and
`exportSize` use the sizes recorded during the scan rather than stat'ing every file, and
`exportClipsInsideDestination` resolves each distinct folder once. `copiesPerClip` has to
keep agreeing with the folder maths in `copyPlan()`.

## Handy

```
git status --short      # what have I changed?
git diff                # show me the actual changes
git log --oneline       # history
git checkout -- FILE    # throw away my changes to one file
swift run               # run from source without installing
```

## If a build breaks

Clear the build cache and try again:

```
rm -rf .build
./build_app.sh --install
```

Yellow `warning:` lines are normal and can be ignored. Only red `error:` lines stop the build.
