# Fast Browser Releases

Public stable releases and update metadata for Fast Browser.

## Update security

The updater accepts only HTTPS assets from this repository, verifies the installer SHA-256 from `update.json`, and verifies the Sigstore bundle against the exact GitHub Actions workflow identity from `mustad450-pixel/fast-browser-automation` before installation.

## Fresh installation

1. Install the latest `Fast-Browser-...-Setup.exe` release asset.
2. Run `Install-FastBrowserUpdater.ps1` once.
3. Fast Browser then checks the stable manifest automatically and also exposes **Check for Fast Browser updates** from its About page.

The Windows updater performs a lightweight hourly check. A new installer is applied only after both SHA-256 and Sigstore verification succeed.