# Restaurant Dash — Staff / Owner App (Flutter)

The Flutter app restaurant **owners and staff** are handed. It signs in against
the hosted Restaurant Dash backend and shows their restaurant, role, plan, and
permissions, with POS / orders / inventory / reports built on top. It ships for
**Windows desktop** and **Android**; the code is iOS-ready (building for iOS
requires a Mac — see below).

**Turnkey by design:** the backend URL is baked in at build time, so an owner is
handed the built app + a website link and just signs in — no configuration.
(For testing, a runtime server override exists — see
[Runtime server override](#runtime-server-override-no-rebuild-needed).)

## Configuration (build-time dart-defines)

Two values are provided at build/run time and baked into the binary as defaults:

| Define           | Purpose                                                        | Default (when omitted)  |
| ---------------- | -------------------------------------------------------------- | ----------------------- |
| `BACKEND_URL`    | The Restaurant Dash backend API                                | `http://localhost:3001` |
| `ORDER_BASE_URL` | The dashboard site hosting the guest QR-ordering pages (table QR points at `{ORDER_BASE_URL}/order/{slug}?table={name}`) | `http://localhost:9002` |

## Run (development)

Requires the Flutter SDK and, for Windows desktop, Visual Studio with the
"Desktop development with C++" workload.

```bash
cd restaurant_owner_app
flutter pub get
flutter run -d windows --dart-define=BACKEND_URL=http://localhost:3001 --dart-define=ORDER_BASE_URL=http://localhost:9002
```

(Start the backend on 3001 and the dashboard on 9002 first if you want live data.)

## Release builds

> **Shipping a release is CI's job, not yours.** Bump `version:` in
> `pubspec.yaml`, tag it `v<version>`, push — `.github/workflows/release-clients.yml`
> builds both clients, proves the production URLs are baked in, proves the
> Windows zip is flat, proves the APK carries the same signing key as the build
> in the field, and publishes both as GitHub release assets. See
> **[docs/RELEASE.md](docs/RELEASE.md)**.
>
> The rest of this section is what those jobs run, kept for local builds and for
> debugging a failing one. Artifacts built by hand are **not** shipped, and are
> no longer committed to `Restaurant_Dashboard_UI/public/downloads/`.

Release builds bake the dart-defines in as the app's **defaults**:

### Windows

```bash
flutter build windows --release --dart-define=BACKEND_URL=https://api.your-domain.com --dart-define=ORDER_BASE_URL=https://app.your-domain.com
```

Output: **`build/windows/x64/runner/Release/restaurant_owner_app.exe`**

> **Do not look in `windows/runner/` for the app.** That directory is the C++
> runner *source code* that Flutter compiles — the built executable only ever
> appears under `build/windows/x64/runner/Release/`.

The `.exe` is **not** standalone: the whole `Release/` folder (exe +
`flutter_windows.dll` + other DLLs + the `data/` folder) is the app. Ship the
entire folder together.

**Packaging (hand owners one artifact):**

- **Shipped format:** a **flat** zip of the *contents* of `Release/` — the exe,
  the DLLs and `data/` at the zip root. Zip the folder itself and the in-app
  updater's robocopy nests a dead copy inside the install directory, after which
  the app never updates again. CI builds this and asserts the layout; locally:
  ```powershell
  Compress-Archive -Path "build\windows\x64\runner\Release\*" -DestinationPath RestaurantDash-Windows.zip
  ```
  The `\*` is the whole point.
- **Recommended:** build an MSIX installer:
  ```bash
  dart pub global activate msix
  flutter pub add --dev msix
  dart run msix:create --release --dart-define=BACKEND_URL=https://api.your-domain.com
  ```
  Distribute the resulting `.msix`. One build is reused for every owner.

### Android

```bash
flutter build apk --release --dart-define=BACKEND_URL=https://api.your-domain.com --dart-define=ORDER_BASE_URL=https://app.your-domain.com
```

Output: **`build/app/outputs/flutter-apk/app-release.apk`** — a single APK you
can sideload or distribute directly.

Notes:

- Requires **Android SDK platform 36** and **build-tools 36**.
- **`android/app/proguard-rules.pro` is required** (already committed). It
  carries keep-rules for the ML Kit text-recognition dependency; without it the
  release build **fails at the R8 shrink step**. Don't delete it.

### iOS

The Dart code and plugins are iOS-compatible, but Apple tooling only runs on
macOS. On a Mac with Xcode:

```bash
flutter build ipa --release --dart-define=BACKEND_URL=... --dart-define=ORDER_BASE_URL=...
```

No Mac is available in this repo's dev environment, so iOS is code-ready but
unbuilt.

## Runtime server override (no rebuild needed)

The baked-in `BACKEND_URL` is only a **default**. On the **login screen**, the
**gear icon** (top corner) opens the **"Server address"** dialog:

- Paste a server URL and save — the app immediately talks to that server.
- The override is **persisted on the device** (shared preferences) and survives
  restarts; it always **wins over the baked-in default**.
- **Reset to default** clears the override and returns to the baked-in URL
  (saving an empty value does the same).
- Bare hostnames are accepted: anything not starting with `http://`/`https://`
  gets `https://` prepended (handy for pasting tunnel hostnames).

This is how a test build is repointed at an ephemeral tunnel (e.g.
`cloudflared tunnel --url http://localhost:3001` prints a fresh public URL each
run) without rebuilding the app.

## Auto-update on launch

On startup the app calls **`GET /app/version`** on its backend and compares the
manifest against its own version (`pubspec.yaml` `version:`):

- Newer version available → an update dialog offers the platform's download link.
- App below the **minimum** version → the update dialog is **mandatory**.

The manifest lives in **code**, at `Restaurant_Backend/app_release.ts`, and rides
the ordinary backend deploy. Releasing it is a push; nobody edits `.env` on the
box. Bump `LATEST` there and the download URLs follow it.

For an incident — pulling a bad release, or forcing an upgrade — these
environment variables override the shipped manifest field by field, without
waiting for a deploy:

| Backend env var             | Meaning                                |
| --------------------------- | -------------------------------------- |
| `APP_RELEASE_PIN_VERSION`   | Latest available app version           |
| `APP_RELEASE_PIN_MIN`       | Below this, updating is mandatory      |
| `APP_RELEASE_PIN_NOTES`     | Release notes shown in the dialog      |
| `APP_RELEASE_PIN_WINDOWS`   | Download URL offered to Windows builds |
| `APP_RELEASE_PIN_ANDROID`   | Download URL offered to Android builds |
| `APP_RELEASE_PIN_IOS`       | Download URL offered to iOS builds     |

> The older `APP_LATEST_VERSION` / `APP_MIN_VERSION` / `APP_UPDATE_NOTES` /
> `APP_DOWNLOAD_*` names are **inert** — they may still be set on a box
> provisioned before the manifest moved into code, where they now do nothing.
> The backend logs them by name at boot so nobody debugs one at 2am.

## App icon

- Master art: `assets/icon/app_icon.png` (1024×1024).
- Android adaptive-icon foreground: `assets/icon/app_icon_foreground.png`.
- `flutter_launcher_icons` is configured in `pubspec.yaml`; regenerate every
  platform's icons (Windows `.ico`, Android mipmaps + adaptive icon, iOS asset
  catalog) after changing the art:

```bash
dart run flutter_launcher_icons
```

## Onboarding flow

1. A platform admin creates the restaurant + the owner's login in the `/platform`
   console (see the repo root README).
2. The owner is given the installer (or link to it) and the dashboard website link.
3. The owner opens the app and signs in with **restaurant name + username +
   password**. Suspended/expired accounts are blocked at sign-in.

## Features

A permission-gated sidebar (mirrors the web dashboard, gated by the signed-in
user's permitted actions) with modules wired to the live backend:

- **Overview** — KPIs (APC, revenue, covers, ratings) + account/plan
- **Orders** (incl. POS order entry), **Menu**, **Tables**, **Inventory** (+ add),
  **Bookings**, **Customers**, **Feedback**, **Analytics**, **Valet**,
  **Employees** (+ add), **Settings**
- Thermal **bill printing** (Windows raw printer support), table **QR codes**,
  menu **OCR import** (ML Kit) and **spreadsheet import** (Excel), live updates
  via Socket.IO.

## Tests & analysis

```bash
flutter analyze   # static analysis (flutter_lints)
flutter test      # widget tests in test/
```

## Structure

```
lib/
  config.dart                     backend/order URLs (dart-defines) + runtime server override
  models/profile.dart             signed-in profile + permission gating (can())
  services/api_client.dart        auth + generic request()
  services/auth_controller.dart   session state + token persistence
  services/rest_client.dart       authed GET/POST/… helper (401 -> sign out)
  services/update_checker.dart    /app/version check + update dialog on launch
  services/printer_service.dart   bill printing (PDF + thermal)
  services/win_raw_printer.dart   Windows raw-printer FFI backend
  widgets/async_view.dart         loading / error+retry wrapper used by modules
  widgets/notifications_bell.dart live notifications bell
  screens/login_screen.dart       sign-in + server-address override dialog
  screens/home_shell.dart         permission-gated nav shell
  screens/order_entry.dart        POS order entry
  screens/modules.dart            all feature modules
  app.dart, main.dart             root app + auth routing
```
