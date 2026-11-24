<div align="center">

<img src="docs/icon-mocha.png" width="120" alt="">

# Keeper

**Do your first edit at the game.**

Flag good clips on the camera as you shoot. Keeper starts you on those,<br>
tags who's in them and what happened, and copies them out named and sorted.

[![Latest release](https://img.shields.io/github/v/release/jflowermedia/keeper?include_prereleases&label=release&color=cba6f7)](../../releases)
![macOS 13 or later](https://img.shields.io/badge/macOS-13%2B-1e1e2e)
![Free, MIT licence](https://img.shields.io/badge/licence-MIT-1e1e2e)

**[Download](../../releases)** &nbsp;·&nbsp; **[Guide](GUIDE.md)** &nbsp;·&nbsp; **[Report a problem](../../issues)**

</div>

<p align="center"><img src="docs/keeper-1.3.png" width="100%" alt="The Keeper window on the Picks tab: clips down the left with green KEEP and yellow OK badges and player tags, a clip playing top right, and the tagging panel under it with the roster on the left and numbered categories across the rest"></p>

| 1. Flag | 2. Tag | 3. Export | 4. Check |
|:--|:--|:--|:--|
| Press a button on the camera while you shoot. | Type a jersey number, then what happened. | Clips are copied out named from their tags. | Every copy is compared with the card. |

<p align="center"><code>C7531.MP4</code> &nbsp;→&nbsp; <code>C7531_261003_WHKY_Marchetti_Goal.MP4</code></p>

> [!NOTE]
> Alpha, version 1.4.1. Tested with one camera, a Sony A7S III, on one Mac. Keep a second copy of anything that matters.

## Copy safety

- **Nothing on a camera card is ever written, renamed or deleted.** Flags you change go on the copy.
- **Copies are checked.** Free space before, the size of every file after, and what's already there is skipped.
- **Tags follow the clip's camera ID**, so they survive renaming and copying.
- **Tags are backed up** automatically, ten versions deep, and <kbd>⌘Z</kbd> goes back forty steps.
- **The Mac stays awake** during a copy. (Closing the lid still sleeps it.)

## Install

Download **Keeper.zip** from [Releases](../../releases), unzip it, and drag **Keeper.app** to Applications.

Keeper isn't notarized by Apple, so macOS blocks the first launch:

1. Open Keeper and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway** beside Keeper.
3. Open Keeper again and click **Open**.

<details>
<summary>Or use Terminal, or build it yourself</summary>

Allow it in one line:

```
xattr -dr com.apple.quarantine /Applications/Keeper.app
```

Build from source (needs Xcode's command line tools).

```
git clone https://github.com/jflowermedia/keeper.git
cd keeper
./build_app.sh --install
```

</details>

## Guide

**[The guide](GUIDE.md)** is a shoot day in six steps. Shortcuts, settings and the rest are [on the same page](GUIDE.md#reference).

1. [Set up the camera](GUIDE.md#1-set-up-the-camera)
2. [Get your roster](GUIDE.md#2-get-your-roster)
3. [Open the card](GUIDE.md#3-open-the-card)
4. [Tag](GUIDE.md#4-tag)
5. [Export](GUIDE.md#5-export)
6. [Check, then format](GUIDE.md#6-check-then-format)

## Credits

Built by **JFlowerMedia** · [jflowermedia.com](https://jflowermedia.com/) · [@jflowermedia](https://www.instagram.com/jflowermedia/)

Themes use the [Catppuccin](https://github.com/catppuccin/catppuccin) palette, MIT. Keeper is [MIT licensed](LICENSE).

<details>
<summary>Disclaimer</summary>

Keeper is alpha software, provided as is, without warranty. It is built to be read-only on your cards and checks every copy, but no software is bug-free. Confirm your clips copied and open correctly before formatting a card, and keep a second copy of work that matters. No liability is accepted for lost or damaged footage.

</details>
