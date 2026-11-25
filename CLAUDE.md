# Bar: project brief

Bar (`local.suite.bar`, executable `Bar`, `LSUIElement`) is the suite's Dock in place of the system one,
an app of its own since 2026-11-22 (it was part of Explorer, then called Dock; renamed Bar the same day,
its identifiers from `local.explorer.Dock`). Everything of its own says Bar: the app, its libraries, types and files (`BarController`, `BarView`,
`BarStore`), its preference keys (`BarSettings`, `BarPinnedApps`).
What concerns the system Dock keeps the word: `DockManager`, `DockReader`, `DockSpan`, `DockMeasure`. It shows while it is
turned on (Settings › Bar) and Explorer manages files (Explorer's Explorer/Finder switch, read from
Explorer's defaults, `UseExplorer`); turned off, it puts the system Dock back and quits. While turned on it
starts at login by itself (its own login item, `SMAppService`); Suite Settings starts it when it is turned
on. While it runs, Suite Settings' agent covers the Dock's settings in System Settings.

## Architecture

```
BarSettings (library, no UI; the only product other repositories see)
    BarSettings (what was DockOptions and the class keeping it, one value now, `BarSettings.current`),
    in Bar.app's defaults; BarMessage, the distributed notifications with Suite Settings
BarCore     (library, no UI, unit-tested) pinned apps (first read from the system Dock), layout,
    geometry, minimized windows, stacks, the system Dock's size
Bar    (Bar.app) the panel, its icons, the Downloads stack, other apps' minimized windows,
    fitting windows above it, the edge guard, Mission Control
```

Its executable is `Bar`, never `Dock`: the system Dock's process is "Dock", which `killall Dock`
restarts and Suite Guard tells apart by path.

From the other repositories: `SuiteCore` (`suite-core`) for opening Explorer and its windows
(`ExplorerLink.activate`, `open`, `reveal`; folders open in Explorer, files as the system opens them),
Suite Settings (`SuiteSettingsApp.show(tab:)`) and updates; `SuiteFilesCore` and `SuiteFilesUI`
(`suite-files`) for the Trash (`TrashLocations`, `SuiteTrash`, Finder's sounds), `DirectoryWatcher` and the
Downloads stack's files; `DockGuard` (`suite-guard`) for hiding the system Dock (`DockManager`) and loading
Suite Guard (`GuardAgent.update()`), which puts it back should the Dock vanish. Bar never imports
Explorer's code. Apps of the suite that are ordinary apps only for macOS's sake (Desktop) are never shown
in it, their windows neither fitted nor watched (`BarHiddenApps`).

Bar's settings, pinned apps and the system Dock's settings from before hiding
(`DockSettingsBeforeHiding`, which Suite Guard reads) are in Bar's defaults (`local.suite.bar`).

## What the Dock does today

- **Dock** (Settings › Bar: System Dock | Bar, the system one by default): a non-activating panel
  at the Dock level, at the bottom of the main screen, shown while Explorer manages files. Explorer first (in Finder's place; Finder never
  shows), pinned apps (`BarStore`, first taken read-only from `com.apple.dock` `persistent-apps`,
  reordered by dragging, removed by dragging up), running apps after a separator, Downloads as a grid
  stack, other apps' minimized windows (`MinimizedWindows`, Accessibility; a click brings one back),
  the Trash. Click launches or activates; right-click: Keep in Dock / Remove from Dock, Show in
  Explorer, Quit, then Force Quit for an app still running after it was asked (or with Option held, `QuitRequests`); files dropped on an app open with it, on the Trash go to the Trash. It stays on
  screen, other apps' maximized windows shortened to end above it through the Accessibility API
  (`WindowFitter`, `WindowFit`; needs the user's permission), or hides automatically and slides in at
  the bottom edge. The New Dock hides the system one: `autohide` on, 1000 s `autohide-delay` and
  `autohide-time-modifier`, `tilesize` 1 (below System Settings' 16, honoured: a sliver even in
  Mission Control, which always shows the Dock), at the bottom (`orientation`, so minimizing animates
  towards our Dock; the user tried the left edge and preferred this), running apps only
  (`static-only`), Dock restarted (`DockManager`). macOS 27 ignores the delay, so the pointer is
  kept off the bottom row of pixels, only along the short stretch the hidden system Dock covers (`EdgeGuard`, `CGWarpMouseCursorPosition` from a mouse monitor; a window above the Dock
  doesn't stop it), measured through Accessibility (`DockMeasure`) or estimated
  (`DockSpan`); the rest of the edge and the corners stay free. Mission Control always shows
  the system Dock (a sliver at size 1). A strip of wallpaper over it was tried and removed: it showed
  over every app and not during Mission Control's animation. Instead our Dock (a level above the
  system Dock, 2 points from the bottom) covers it: it slides in for Mission Control, which is noticed
  from WindowManager's Spaces bar among the windows on screen (`MissionControl`, polled five times a
  second while our Dock hides itself; no notification exists). Whether it hides is chosen in Settings › Bar: a default (hides or stays),
  apps with which it does otherwise while in front (one list per default: `BarSettings.hidingApps`,
  `stayingApps`), and full screen apart (hides, as the system Dock does, by default; stays; or as for the
  app; `BarSettings.hides`, `FullScreenSpace`: the app in front has a window covering the whole screen). The previous values are kept in our
  preferences and put back on going back to the System Dock, on switching to Finder, by `--restore-bar`
  (which Explorer's `--restore-finder` runs) and when Bar quits, so the Mac is never left without a Dock;
  not when Bar reopens itself (updates, `--relaunch`) nor at logout or shutdown, as each Dock restart leaves
  Spaces, ⌘Tab and Mission Control unusable for a minute or two. Should Bar vanish (a crash, a forced
  quit, not started at login), Suite Guard (repository `suite-guard`) puts the system Dock back after 15
  seconds (90 after login), from the copy Bar keeps in its defaults.
  Never touch the real Dock in tests, and restart it as rarely as possible.

Since the Dock is an app of its own: quitting Explorer no longer puts the system Dock back (quitting the
Dock or turning it off does); `--restore-bar` replaces `--restore-finder` for the Dock
(`~/Applications/Bar.app/Contents/MacOS/Bar --restore-bar`); a copy started with `--relaunch`
takes over from the running one without restarting the system Dock (`make-app.sh` does it). Files in the
Downloads stack open as Explorer opens them while it runs (`ExplorerLink.openFiles`: pictures and PDFs to
Viewer), as the system does otherwise; files dropped on it are moved or copied as Explorer does, asking
whether to replace (the old item goes to the Trash), skip or keep both (`BarDrop`).

## Work to do

- `feat/dock-parity` (moved here with its history; a session was working on it at the split, in the
  monorepo): folders and files in the Dock, stack views and options, recents, badges, app menus,
  magnification. Rebase it on this `main`: its files moved from `Sources/Explorer`, `Sources/ExplorerCore`
  and `Sources/ExplorerSettings` to `Sources/Bar`, `Sources/BarCore` and `Sources/BarSettings`,
  and `DockOptions` became `BarSettings`.
- `feat/launcher/core`: the Launcher tile.
- `BarEdgeProbe` is a temporary diagnostic, asked on 2026-11-22: keep it until the cause is found; read it
  with `log show --predicate 'category == "BarEdge"' --last 1d`.

## Building and running

- `swift build` and `swift test` for development.
- `scripts/make-app.sh` builds `build/Bar.app` (release), signs it with the "Suite Local Signing"
  certificate from the login keychain, so macOS permissions survive rebuilds (ad-hoc signing, the
  fallback, re-asks every build), and installs it as `~/Applications/Bar.app`, the only copy Launch
  Services knows. It records the branch and commit in the Info.plist (`SuiteBuildBranch`,
  `SuiteBuildCommit`) and refuses to replace an installed copy built from another branch, or from an unknown
  one, unless `--force`: another session may be testing it. `INSTALL_DIR=` builds without installing. A
  running copy is relaunched from the new one.
- Never ask the user to open `build/Bar.app` from a worktree.
- UI can't be checked by unit tests and screenshots of the user's screen are not available: check UI by
  rendering views offscreen (`cacheDisplay`) from a scratch package that compiles the sources.
- Releases: change `VERSION` (only `Z` is this repository's own), commit, push, then `scripts/publish.sh`
  pushes the tag; `.github/workflows/release.yml` builds, signs the app with "Suite Release Signing",
  signs `update.json` with the update key (both from the repository's `release` environment secrets),
  publishes the release and updates the cask in `love-suite/homebrew-tap`. The feed is
  `https://github.com/love-suite/suite-bar/releases/latest/download/update.json`
  (the GitHub repository it is built from). A change of `AA.Y` comes from the suite repository through
  `.github/workflows/sync-version.yml`. Until `Support/release-certificate.cer` and
  `Support/update-public-key.txt` exist, nothing can be released.

## The suite

This repository is part of Love Suite, one repository per app under `github.com/love-suite`:
`suite-core` (the shared library), `suite-files` (the file layer of the apps handling files),
`suite-guard`, `suite-desktop` (the desktop), `suite-explorer`, `suite-bar` (the Dock), `suite-viewer`,
`suite-clipboard`, `suite-settings` (the settings), `suite-awake` (keeping the Mac awake), `suite-launcher`, `suite-bindings`,
`suite-ai-organizer`; `homebrew-tap` (the tap `love-suite/tap`, one cask per app) and `suite` (the
front page, the suite's version, the scripts that act on every repository). Locally they sit side by side
in `~/GitHub/paul-amour/suite/`.

## Conventions (the same in every repository of the suite)

- The user writes in French and expects answers in French; everything in the code stays in English: code,
  comments, tests, docs, commit messages. Do not add co-author trailers.
- No "…" in menu items, buttons or messages: the user wants none, anywhere.
- Behaviour follows Windows unless Apple's design is asked for.
- Swift Package Manager, `swift-tools-version:5.9`, macOS 13+. Tests use Swift Testing (`import Testing`).
- Toolchain: swiftly, Swift 6.4.2 (`.swift-version`, git-ignored). If `swift test` complains about a
  missing toolchain: `swiftly use 6.4.2`.
- AppKit for windows that need fine control; SwiftUI is allowed for small panels (settings, pickers).
- No private APIs and no system modifications (SIP stays on).
- Git: one worktree per feature under `.worktrees/` (git-ignored), one branch per change
  (`feat/<feature>`, `fix/<area>/<what>`), merged into `main` one by one; `main` stays stable.
- Versions are `AA.Y`, then `AA.Y.Z` for a fix (`VERSION`, tag `vVERSION`: 27.1, then 27.1.1; SwiftPM reads
  `v27.1` as 27.1.0): `AA` is the latest macOS in production (27), `AA.Y` is the same in every repository of
  the suite so the apps work together, `Z` is this repository's own. A change of `AA.Y` is made in `suite`
  and reaches every repository. While a version is being prepared, `VERSION` doesn't move (27.1 now):
  development builds are `VERSION-dev.N`, N the commits since `VERSION` was set, merges aside, from 1 (`make-app.sh`),
  and a change another repository needs gets a development tag, `vVERSION-dev.N`, which releases nothing.
  Dependencies on other repositories of the suite (`suite-core`, `suite-files`, `suite-guard`, settings
  libraries) use
  `.upToNextMinor(from: "27.1.0-dev.1")` (the latest development tag, then the release);
  `Package.resolved` is committed. Tags are never moved once pushed. The build number (`CFBundleVersion`,
  which the updater compares) stays the number of commits.
- Changing two repositories at once: `swift package edit <Package> --path ../<repository>` points at the
  neighbour's working copy until its tag exists, `swift package unedit` goes back. Never committed.
- What two apps need lives in `suite-core` (file code in `suite-files`); an app's own code never goes into another app's repository, and
  an app exposes only its settings, as `<App>Settings`, for Suite Settings.
- Do not run commands that delete user data. Trash instead of delete.
- No code converting saved settings at launch. Before the first release nothing needs converting (the
  developer's own settings don't count): rename freely. Between released versions, a change to saved
  settings is a `SettingsMigration` (suite-core) for the version that brought it, given to the app's
  `SuiteUpdater`, which runs it once after the update.
