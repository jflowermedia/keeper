# Working on Keeper

A macOS app that sorts camera clips by the KEEP flag in their Sony XML sidecars, tags
them against a roster, and copies them out renamed. SwiftUI + AppKit, built as a Swift
package, macOS 13+.

## The one rule

**Nothing is ever written to a camera card.** Not a flag, not a rename, not a sidecar.
A flag the user changes is applied to the *copy* at the destination. If a change would
put a write anywhere near the source, it's wrong — no matter how convenient.

## Building

```bash
./build_app.sh --install      # build and replace /Applications/Keeper.app
./build_app.sh                # build Keeper.app here, without installing
swift run Keeper --self-check # the checks; must pass before committing
```

There is **no Xcode on this machine**, only the Command Line Tools. That rules out
XCTest — a test target was added once and could never run. Don't add one back. The
checks live in the app behind `--self-check` with a hand-rolled harness in
`SelfCheck.swift`, which is why they're written as plain functions over pure values.

The version lives in one place, `AppInfo.version` in `KeeperApp.swift`, and
`build_app.sh` reads it out of the source to stamp the bundle. Bump it there and the
README badge, nothing else.

## Releasing

```bash
rm -rf Keeper.app && ./build_app.sh
defaults read "$PWD/Keeper.app/Contents/Info.plist" CFBundleShortVersionString
ditto -c -k --keepParent Keeper.app Keeper.zip    # distribution zip, not install
rm -rf Keeper.app
gh release create vX.Y.Z-alpha Keeper.zip --title "Keeper X.Y" --prerelease --notes-file NOTES.md
```

Every release so far is a pre-release. That matters: the update checker reads
`/releases`, not `/releases/latest`, because the latter excludes them.

Always print the stamped version before zipping. A zip of the wrong build looks
identical from outside.

Don't leave a built `Keeper.app` in the repo. It's gitignored, so an old one sits there
looking current and gets mistaken for the installed app.

## Commit messages

Plain subject and body. **No attribution or co-author trailers of any kind.**

Write the message to a file and use `git commit -F`. Messages here routinely contain
backticks and slashes, and `-m` has hung the shell on command substitution more than
once.

## House style

**Comments say why, not what.** The code says what. A comment earns its place by
recording a decision, a constraint, or a bug that's already been paid for. Several
comments in this codebase are the only record of a day lost to something.

**Say it, don't ignore it.** A key that does nothing with no explanation is how
"it doesn't work" starts. Every refused action sets `status` with a reason. Look at
`cycleFocus` for the canonical example.

**Every stored field is optional.** `Codable` on anything in `library.json` decodes with
`decodeIfPresent` and a default, because Swift's generated decoder throws on a missing
key even where a default is declared — and one missing key would throw the whole library
away. New fields are written *and* read; old ones keep being written for a version or
two so a downgrade still opens the file.

**One rule, one place.** When two bits of code have to agree, put the rule in one of
them and have the other call it. Both roster bugs this project has shipped were two
definitions of "taken" drifting apart.

## Things that have bitten, and will again

**A team keeps its id for life.** Tags are keyed to `teamID`, so renaming a team mustn't
change it. That means a team created by the **+** button still has the id `new-team`
after it's renamed — which broke the + button (it searched for a free *name*) and the CSV
import (it matched only on *id*, so it made a second team with the same name). Both now
go through `TagLibrary.freeTeamName` and `TagLibrary.importTarget`.

**A player's id is `team/number`.** Two players sharing a number share an id, and a
duplicate id in a SwiftUI list misbehaves rather than merely looking wrong. Blank numbers
count. The roster editor and the importer both refuse it; keep them in step.

**The key monitor has four guards and needs all of them.** `NSOpenPanel.runModal()` is
not a sheet, isn't modal in the way you'd guess, and its first responder isn't a text
field — so picking an export folder with the arrow keys was read as "next clip" and
collapsed the whole selection. See the comment in `ContentView`'s monitor.

**`FlowKeyState.claims` decides what the keyboard flow ever sees.** A key it doesn't
claim falls through to the transport keys. Adding a key to a stage handler without
adding it there means the key does something *else* — typing a digit at the categories
shuttled the clip for an entire release.

**Never put a modal up from inside a SwiftUI update.** `onReceive` runs as part of the
update cycle and `runModal` spins a nested run loop inside it. Hop with
`DispatchQueue.main.async` first, as the clear-tags path does.

**Adding an enum case breaks every exhaustive switch over it.** Twice now. After adding
one, search for switches over that type before building.

## Checking work without a compiler is over

Previous sessions had no Swift toolchain and leaned on brace-balance, closure and
exhaustiveness scanners to stand in for one. You have a compiler. **Build before
claiming anything works**, and run `swift run Keeper --self-check` before committing.

Still worth doing: when a rule is pure (version comparison, a scope, a filter), add it
to `SelfCheck.swift`. Those suites exist because each one is a bug that shipped.

## The person you're working with

Shoots junior and alumni hockey, and uses this app on real cards with footage that
matters. Prefers to be told what's wrong plainly, including when a request would be a
mistake. Asks for a QC pass after features — that means actually hunting for bugs and
reporting what was found, not a summary of what was built.

## Environment

`ls` is aliased to a modern replacement; `ls -t` fails. Use `command ls -t`.
