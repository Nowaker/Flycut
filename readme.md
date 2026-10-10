# Flycut

## Nowaker fork

This fork uses the macOS app identity `net.nowaker.flycut` and the helper
identity `net.nowaker.flycuthelper`. The integration branch is
`master-nowaker-gpt`; `master-nowaker` is not modified by this effort.

### History and search

- Text history is stored in a local SQLite archive with no entry-count cap.
  Available disk space still limits storage.
- History is always saved locally. Pause capture to stop recording new text;
  clearing history does not securely erase retained events or backups.
- The main shortcut opens searchable history by default. Releasing the
  shortcut leaves it open. Use the arrow keys to select, Enter or double-click
  to paste, and Escape to close.
- Preferences > History can restore the original bezel on the main shortcut
  and assign a separate history shortcut.
- The recent menu/bezel count limits only those views, not saved history.
- Favorites refer to archived items. Clear History deletes known nonfavorites;
  favorites survive, and unseen offline copies can arrive after synchronization.
- Deletion hides items but is not secure erasure. Event logs and backups retain
  their original text. Previously discarded upstream clips cannot be recovered.

### First launch and migration

Quit upstream Flycut before the first normal fork launch so save-on-exit history
is flushed. Do not run both capture agents during normal use.

The fork imports the saved history and favorites once, without applying old
entry limits, and preserves the raw preference snapshot in its archive.
Matched history/favorite entries share one item; history order wins if the old
lists disagree. The original preference files are not rewritten.

If source access is denied or conflicting histories are found, capture stays
disabled instead of pretending an empty import succeeded. Use **Import Legacy
History...** to choose the original preferences plist, commonly:

```text
~/Library/Containers/com.generalarcade.flycut/Data/Library/Preferences/com.generalarcade.flycut.plist
~/Library/Preferences/com.generalarcade.flycut.plist
```

Alternatively, explicitly choose **Start New Archive...** to skip import. This
does not delete upstream data, but the new archive will not import it later.
Normal nonsandboxed storage is
`~/Library/Application Support/net.nowaker.flycut/Archive.sqlite`.

### Synchronization

Sync is off by default. Select one backend in Sync Settings:

- **Folder:** choose a folder replicated by Syncthing, iCloud Drive, or another
  tool. Immutable event files are exchanged; the live SQLite database stays local.
- **Server:** supply a collection UUID, service URL, and a private `.env` file
  containing `FLYCUT_SYNC_TOKEN`. See [service deployment](SyncService/deploy.txt)
  and the placeholder-only [.env.example](.env.example). Use HTTPS except for
  loopback or an explicitly opted-in numeric Tailscale address.
- **CloudKit:** available only in CloudKit-enabled builds with your own Apple
  provisioning. Events use a private iCloud zone. This backend is Apple-only;
  the Linux bridge supports folder and server backends.

Sharing existing history into a collection requires an explicit decision.
Remote imports do not replace the current clipboard or paste automatically.
Item IDs, favorites, and deletion events converge after offline changes.

### Linux bridge

The bridge autodetects GPaste2 or Klipper without replacing the desktop manager.
GPaste needs `xclip`/`xsel` on X11 or `wl-clipboard` on Wayland, and the logged-in
desktop session environment. Run from the repository root:

```bash
uv run --project LinuxBridge flycut-bridge --help
uv run --project LinuxBridge flycut-bridge init <collection-uuid>
uv run --project LinuxBridge flycut-bridge watch --desktop auto --folder <synced-folder>
uv run --project LinuxBridge flycut-bridge search <query> --limit 100
```

Service synchronization requires sourcing your private `.env` without printing
it, then selecting `--server <url>` instead of `--folder`. Sync and existing
manager-history import are opt-in. Polling may miss changes faster than its
interval. Explicit copy does not synthesize a paste key; Klipper also changes
PRIMARY selection. Imported events never write either clipboard selection.

### Building and checking

Full Xcode is required. Use the selected Xcode or set `DEVELOPER_DIR` to your
installation's `Contents/Developer` directory. CloudKit defaults to off:

```bash
xcodebuild -project Flycut.xcodeproj -scheme Flycut -configuration Release \
  -derivedDataPath build FLYCUT_CLOUDKIT=0 CODE_SIGNING_ALLOWED=NO build
bash FlycutEngine/Tests/run-archive-tests.sh
bash Sync/Tests/run-operator-driver.sh tmp/operator-check
bash Sync/Tests/run-sync-driver.sh tmp/sync-check
python3 -m unittest discover -s SyncService -p 'test_*.py' -v
uv run LinuxBridge/qa.py FlycutEngine/Tests/Fixtures/archive-v1.json
```

Enable CloudKit with `FLYCUT_CLOUDKIT=1` and set `FLYCUT_ICLOUD_CONTAINER` to your
provisioned container. Unsigned builds verify compilation, not account-backed
CloudKit sync. Actual paste requires Accessibility authorization for the app.
Ad-hoc signing does not guarantee that authorization survives rebuilds.
The Release app is produced at `build/Build/Products/Release/Flycut.app`.

## Upstream Flycut
<a href="https://github.com/TermiT/Flycut/releases"><img src="http://a3.mzstatic.com/us/r1000/047/Purple/fb/53/f2/mzi.mcaxwyjm.175x175-75.png" /></a>
<a href="https://macdownload.informer.com/flycut/"><img src="award-2021.png" /></a>
<a href="https://macdownload.informer.com/flycut/"><img src="award-2022.png" /></a>
<br />
**Description:**
Flycut is a clean and simple clipboard manager for developers. It's based on an open source app called Jumpcut.

On the Mac, every time you copy a code piece, Flycut stores it in history. Later, you can paste it using Shift-Command-V even if you have something different in your current clipboard. You can change the hotkey and other settings in preferences.

On iOS, every time you open Flycut, it checks for a new clipping and stores it in history. Later, you can tap any item in the history list to place it on the clipboard. You can also swipe web links in the history to open them without placing them on the clipboard.

Developed by developers for developers.

**Donation:**
If you like Flycut, you can donate [here](https://paypal.me/flycut)

## Install

***For OSX 10.13 and older use DRM-Free version***

***For OSX 10.14 and later use either App Store or DRM-Free versions. But don't forget to give Flycut access in System Preferences -> Security & Privacy -> Privacy -> Accessibility. If you had previous version of Flycut installed, you might need to remove it from Accessibility first and add it again.***

**Mac App Store:**
Download from the App Store [here](http://itunes.apple.com/us/app/flycut-clipboard-manager/id442160987?mt=12)

**DRM-Free:**
Download latest DRM-Free version [here](https://github.com/TermiT/Flycut/releases)

**iOS App Store:**
Download from the App Store [here](https://itunes.apple.com/us/app/flycut/id1273639655?mt=8)

## Use
**Documentation:**
[Mac Help File](help.md) / [iOS Help File](help.iOS.md)

## Develop
**Contributors:**
Check the list of contributors [here](https://github.com/TermiT/Flycut/graphs/contributors)

**License:**
MIT
