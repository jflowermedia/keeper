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

## Version numbering

`MAJOR.MINOR.PATCH`

- `0.1.1` — bug fix, nothing new
- `0.2.0` — new feature
- `1.0.0` — first version you'd call finished

## Which file does what

| File | Holds |
|---|---|
| `Sources/Keeper/KeeperApp.swift` | app entry point, menus, About box, version and links |
| `Sources/Keeper/ContentView.swift` | the whole UI: toolbar, list, preview, debug panel, welcome screen |
| `Sources/Keeper/AppState.swift` | what the app knows and does: scanning, filtering, copying, logging |
| `Sources/Keeper/Clip.swift` | card scanning and the XML flag parsing |
| `Sources/Keeper/MultiDragHandle.swift` | the drag-to-Finder handles |
| `build_app.sh` | turns the build into Keeper.app, makes the icon, signs it |
| `icon.png` / `make_icon.py` | the app icon and the script that draws it |

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
