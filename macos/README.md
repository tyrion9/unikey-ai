# UnikeyAI

A macOS menu-bar Vietnamese input method built on top of the original,
unmodified x-unikey engine (`src/ukengine`, `src/ukinterface`, `src/vnconv`,
`src/byteio`). The only new platform-specific code is in this `macos/`
folder.

## Layout

- `main.mm` — the app: a `CGEventTap` intercepts key-down events system-wide,
  feeds printable keys into `UnikeyFilter()` (the same function the Linux
  XIM/GTK front-ends call), and replays the engine's answer (backspaces +
  replacement UTF-8 text) as synthetic keystrokes. Also implements the
  menu-bar status item and control panel (Vietnamese on/off switch,
  Telex/VNI picker, launch-at-login switch, hide button).
- `gen_icon.mm` — a tiny build-time-only tool that draws the app icon
  (red rounded square, gold star) and saves it as a PNG.
- `build.sh` — builds everything into `UnikeyAI.app`. No Xcode project,
  no autotools; just clang++ and the command-line tools.
- `make_dmg.sh` — packages the already-built `UnikeyAI.app` into a
  drag-to-Applications `UnikeyAI.dmg` installer.
- `Info.plist` — the app bundle's metadata (`LSUIElement` = menu-bar only,
  no Dock icon; `CFBundleIconFile` = the generated icon).

## Build & run

```
cd macos
./build.sh
open UnikeyAI.app
```

On first launch macOS will ask for **Accessibility** and **Input
Monitoring** permission (System Settings > Privacy & Security). Both are
required for the key event tap to work; grant them, quit the app, and
reopen it. The app also registers itself as a login item on its very first
launch (toggle it off in the control panel if you don't want that).

## Package a .dmg for distribution

```
./make_dmg.sh
```

Produces `UnikeyAI.dmg` (app + an `Applications` shortcut to drag it into).
Not notarized (see limitations below), so on any other Mac Gatekeeper will
still warn "unidentified developer" - right-click the app once and choose
Open to get past that.

## Why a local code-signing certificate

`codesign -s -` (ad-hoc signing) gives the executable a brand new identity
on every single build. macOS ties the Accessibility/Input Monitoring grant
to that identity, so every rebuild silently revokes the permission you just
granted — you'd have to re-approve it after every code change.

`build.sh` looks for a certificate named `VietTypeMacLocalDev` in your
keychain and signs with it instead when present, falling back to ad-hoc
signing otherwise. Because the certificate (not the binary's hash) stays
the same across rebuilds, macOS keeps recognizing it as "the same app" and
the permission survives rebuilds. (The certificate's name is a leftover
from this project's earlier name and doesn't need to match the app's
current name - renaming the app does NOT require making a new certificate.)

**One-time setup** (only needed once per machine; skip if
`security find-identity -v -p codesigning` already lists
`VietTypeMacLocalDev`):

```bash
mkdir -p /tmp/unikeyai-cert && cd /tmp/unikeyai-cert
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=VietTypeMacLocalDev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# macOS's `security import` chokes on OpenSSL 3's default PKCS#12 cipher;
# force the legacy one it understands (first form for OpenSSL 3.x with the
# legacy provider, falls back to explicit legacy PBE algorithms otherwise).
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:viettype -legacy \
  || openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:viettype \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P viettype -T /usr/bin/codesign
rm -rf /tmp/unikeyai-cert
```

Then, in **Keychain Access.app** (`security import -T` only grants
`codesign` access to the key - it does not mark the certificate trusted,
and that step requires the GUI + your login password, it can't be
scripted):

1. Keychain: **login** > category **My Certificates** > find
   **VietTypeMacLocalDev** > double-click it.
2. Expand **Trust**, set **Code Signing** to **Always Trust**.
3. Close the panel and enter your login password when prompted.

Verify with `security find-identity -v -p codesigning` — it should list
`VietTypeMacLocalDev` as a *valid* identity. From then on, every
`./build.sh` signs with it automatically, and Accessibility/Input
Monitoring permission survives rebuilds.

## Note on renaming / re-identifying the app

Changing `CFBundleIdentifier` (as happened when this project was renamed
from VietTypeMac to UnikeyAI) makes macOS treat it as a brand new app for
permission purposes, even with the same signing certificate - Accessibility
and Input Monitoring need to be re-granted **once** after such a rename.
Ordinary rebuilds after that keep working without re-granting anything.

## Known limitations

- Not notarized / no Apple Developer ID — Gatekeeper will warn on first
  launch ("Open Anyway" in System Settings > Privacy & Security).
