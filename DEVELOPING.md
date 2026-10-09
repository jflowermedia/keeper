# Developing Keeper

Notes to self. Everything runs from the project folder:

    cd ~/Documents/GitHub/Keeper

## Everyday change

1. Edit the files in `Sources/Keeper/`.
2. `swift run` — builds and launches straight from source. Fastest way to try something.
3. When happy: `./build_app.sh --install` puts the real app in /Applications.
4. Commit and push:

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
| `Sources/Keeper/Tagging.swift` | teams, players, tags, the JSON library, roster CSV import |
| `Sources/Keeper/TagPanel.swift` | the tagging panel and the chips on each row |
| `Sources/Keeper/Renaming.swift` | filename tokens, presets, and building a name |
| `Sources/Keeper/PresetEditor.swift` | the preset builder sheet |
| `Sources/Keeper/MultiDragHandle.swift` | the drag-to-Finder handles |
| `build_app.sh` | turns the build into Keeper.app, makes the icon, signs it |
| `icon.png` / `make_icon.py` | the app icon and the script that draws it |

## Rules worth keeping

**Every new field on a stored type must be optional.** Swift's generated decoder throws on a
missing key for a non-optional property even when it has a default value, so adding
`var thing: String = ""` to `Team`, `Player` or `Tag` stops every existing `library.json`
from loading. Use `String?`. This has bitten once already.

**A clip's video and its XML must always end up with the same base name**, or they stop
pairing on the next scan. That's why `CopyJob` carries a whole clip rather than one file.

**Tags key off the UMID**, never the filename or path.

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
