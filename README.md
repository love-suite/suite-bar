# Bar

A Dock for macOS in place of the system one, part of Love Suite: Explorer where Finder was,
your pinned apps, running apps, a Downloads stack, other apps' minimized windows and the Trash; it stays
on screen with maximized windows shortened above it, or hides and slides in at the bottom edge, as you
choose per app and for full screen. The system Dock is hidden with its own public settings and always put
back (by Suite Guard should the Dock vanish).

Install: `brew install --cask love-suite/tap/bar` (once the first release is out).

Development: `swift build`, `swift test`, `scripts/make-app.sh` (Swift 6.4.2, macOS 13 or later).
