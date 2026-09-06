# Releasing the clients

The Windows bundle and the Android APK are built and published by
[`.github/workflows/release-clients.yml`](../.github/workflows/release-clients.yml).
Nobody builds them on a laptop any more, and nothing gets committed to
`Restaurant_Dashboard_UI/public/downloads/`.

Read the **one-time setup** below before the first run. After that, releasing is
three commands and a manifest bump.

---

## What the workflow actually asserts

Three things about a client build fail *silently* — the artifact compiles,
installs, and is only wrong once it is on a restaurant's counter. Each one has an
explicit assertion in the job rather than a line in a checklist.

| Failure | What it looks like in the field | The guard |
| --- | --- | --- |
| The `--dart-define`s get dropped | App installs fine, opens to the login screen, reaches nothing. `lib/config.dart` defaults to `http://localhost:3001`. | Greps the compiled Dart snapshot (`data/app.so`, `lib/*/libapp.so`) for the production hosts, and for the localhost defaults. Must find the first, must not find the second. |
| The Windows zip gains a wrapping folder | The updater's robocopy lands a nested dead copy beside the real exe. The app never updates again; every counter needs a manual reinstall. | Asserts the exe is at the zip **root**, that the zip's top level equals the build output's top level, and that `data/flutter_assets/` is at the root. |
| The APK is signed with a different key | Android refuses the update ("App not installed"). Every owner must uninstall first, losing local state. | Compares the signer certificate SHA-256 against the build already in the field. |

### Why the URL guard checks the full URLs, not the word "localhost"

Because "fail if the artifact contains `localhost`" fails *every correct build*.
The Dart runtime ships the bare string `localhost` inside the AOT snapshot — it
is in the shipped 1.8.4 production build right now. The guard therefore looks for
`http://localhost:3001` and `http://localhost:9002`, which are exactly
`config.dart`'s defaults and appear only when the dart-defines were missed.

---

## One-time setup

### 1. Create four repository secrets

**Settings → Secrets and variables → Actions → New repository secret**, on
`Dial-Dost/restaurant_owner_app`.

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `android/app/upload-keystore.jks`, base64-encoded (see below) |
| `ANDROID_KEYSTORE_PASSWORD` | the `storePassword` line from your local `android/key.properties` |
| `ANDROID_KEY_PASSWORD` | the `keyPassword` line from the same file |
| `ANDROID_KEY_ALIAS` | the `keyAlias` line from the same file (`upload`, unless you changed it) |

Both source files are gitignored and must stay that way. Nothing in this repo,
this document, or the workflow reads their contents; the workflow writes them
back at job time from these secrets, and deletes them in an `always()` step.

If any of the four is missing the job **fails before building**. That is
deliberate: without `android/key.properties`, `android/app/build.gradle.kts`
falls back to the *debug* keystore and produces a release APK that no existing
installation will accept.

### 2. Produce the base64

One line, no wrapping. Run it yourself — this is the only step that touches the
keystore.

**Windows (PowerShell), from the repo root:**

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\upload-keystore.jks")) | Set-Clipboard
```

Then paste into the secret field. (Drop `| Set-Clipboard` to print it instead,
but clipboard is safer — it keeps the blob out of your terminal scrollback.)

**Linux:**

```bash
base64 -w0 android/app/upload-keystore.jks
```

**macOS:**

```bash
base64 -i android/app/upload-keystore.jks
```

Sanity check without revealing anything: the base64 should be roughly 4/3 the
size of the `.jks` file. The workflow independently rejects a decode under 512
bytes, which catches a truncated paste.

### 3. Confirm the pinned signing fingerprint

`release-clients.yml` pins `EXPECTED_SIGNER_SHA256` to the signer certificate of
the build currently in the field. Verify it matches what you actually ship:

```bash
# any build-tools ≥30 has apksigner
apksigner verify --print-certs RestaurantDash-Android.apk
```

Against the shipped 1.8.4 APK this prints:

```
Signer #1 certificate DN: CN=Restaurant Dash, O=Restaurant Dash
Signer #1 certificate SHA-256 digest: 0e7fe2a45c1c0ff77157a8629a5b54291ffb9d3d6fbf7064bb009c34ae2ebbf3
```

That digest is the certificate, not the key — it is public, it is already inside
every installed copy of the app, and pinning it is safe.

**Do not edit that constant to make a red build go green.** A mismatch means the
APK would force every owner to uninstall and reinstall. The only legitimate
reason to change it is a deliberate key rotation, which *is* a reinstall for
everyone and needs its own plan.

---

## Releasing

1. **Bump the version** in `pubspec.yaml`:

   ```yaml
   version: 1.8.5+50
   ```

   Bump both halves. The name (`1.8.5`) is what `/app/version` compares and what
   the update dialog shows; the code (`+50`) is what Android uses to decide an
   install is an upgrade. The workflow refuses a tag that disagrees with this
   line — a mismatch ships an APK whose `versionName` never changed, so every
   client is offered the same update on every launch, forever.

2. **Tag and push:**

   ```bash
   git tag v1.8.5
   git push origin main --tags
   ```

   The workflow runs analyze, the full test suite, both builds, all three guards,
   and publishes:

   ```
   https://github.com/Dial-Dost/restaurant_owner_app/releases/download/v1.8.5/RestaurantDash-Windows.zip
   https://github.com/Dial-Dost/restaurant_owner_app/releases/download/v1.8.5/RestaurantDash-Android.apk
   ```

3. **Only then bump the manifest.** In `Restaurant_Backend/app_release.ts`:

   ```ts
   const LATEST = "1.8.5";
   ```

   ...rewrite `notes` for the owner reading it, and push. The download URLs are
   derived from `LATEST`, so that one edit repoints both. The backend deploy
   pipeline ships it.

   **The order matters.** Bumping the manifest before the release assets exist
   points every client at a 404.

### Dry runs

**Actions → Release clients → Run workflow**, leaving *Publish* unchecked. That
builds both clients and runs all three guards without creating a release. Use it
after touching the workflow, the signing secrets, or `config.dart`.

---

## Verifying the first CI-built APK — the real proof

Building a signed APK proves nothing on its own. The thing worth proving is that
it installs **over** an existing install without uninstalling, because that is
the failure the signing guard exists to prevent.

Do this once, before you trust the pipeline with a real release:

1. Get a device (or emulator) with the **current shipped 1.8.4** installed — the
   one from the existing download, *not* a local debug build. Debug builds carry
   the debug certificate and will fail this test for the wrong reason.

2. Sign in and leave some local state behind: log in, set a server override, open
   a screen or two. That state is what a signature mismatch destroys.

3. Trigger the workflow from the current `main` (dispatch with *Publish* checked,
   or tag `v1.8.4` if no release exists yet) and download the resulting
   `RestaurantDash-Android.apk`.

4. Install it **over** the existing app, without uninstalling:

   ```bash
   adb install -r RestaurantDash-Android.apk
   ```

   - `Success` → the signing is right. Open the app and confirm you are **still
     logged in** and the override survived: that is the local state proving the
     data directory was kept, not recreated.
   - `INSTALL_FAILED_UPDATE_INCOMPATIBLE` or `signatures do not match` → CI used a
     different key. Do not ship it. Re-check `ANDROID_KEYSTORE_BASE64` and
     `ANDROID_KEY_ALIAS`. (In practice the workflow's signature assertion fails
     first and you never get an artifact — this step confirms the assertion is
     actually testing the right thing.)

5. Repeat once through the **in-app updater** rather than adb, since that is the
   path owners take: it downloads the APK from the release URL and hands it to
   the OS installer. This also exercises the GitHub redirect (release assets 302
   to `release-assets.githubusercontent.com`; the updater's HTTP client follows
   it transparently — verified, but worth seeing once).

### Verifying the Windows zip

Cheaper, and the workflow already asserts it, but to see it yourself: download the
zip and confirm `restaurant_owner_app.exe` is at the **root**, not inside a
folder. Then run the in-app update from an older install and confirm the app
relaunches on the new version — if a wrapping folder ever slipped through, the app
would relaunch unchanged and never update again.

---

## What happened to the old dashboard download URLs

The previous URLs were:

```
https://experiosolutions.dialdost.com/downloads/RestaurantDash-Windows.zip
https://experiosolutions.dialdost.com/downloads/RestaurantDash-Android.apk
```

**Nothing breaks mid-flight**, for two independent reasons:

1. **Clients do not store a download URL.** `lib/services/update_checker.dart`
   fetches `GET /app/version` on every launch and reads `downloads[platform]`
   from that response. The URL is never persisted. So every client — 1.8.4 and
   older alike — picks up the new release-asset URLs on its next launch, without
   any client-side change.

2. **The old files are still served.** They remain committed in
   `Restaurant_Dashboard_UI/public/downloads/` and Next.js serves `public/`
   statically, so the old URLs keep returning the 1.8.4 artifacts. The only
   client that can still *use* one is a session that fetched the manifest before
   the backend deploy and is sitting on the update dialog when it lands — that
   URL is held in memory in `UpdateInfo.downloadUrl`, and it still resolves.

Those two files are the last ~115MB of binaries in the dashboard repo. Deleting
them is safe once no manifest points at them and you accept that a directly
shared old link stops working — but it will not shrink the repo, since the blobs
stay in git history. Leaving them costs nothing and closes the in-memory window
above, so the default is to leave them and simply stop adding more.

### Why release assets rather than committing to the dashboard repo

Committing the artifacts would have needed a **write token for a second
repository** stored in this one's secrets, and would keep adding ~115MB of
undeltifiable binary per release to a history that every clone and every deploy
pays for, permanently. Release assets live outside the git object store, need
only this repo's built-in `GITHUB_TOKEN`, and give a stable public URL per tag.

Tag-pinned URLs, not `/releases/latest/download/...`: a "latest" alias can hand a
client an artifact whose version does not match what the manifest advertised.
`app_release.ts` derives both URLs from `LATEST`, and a test asserts the pinning,
so the version and the artifact cannot drift apart.

---

## If a release goes wrong

The manifest has an escape hatch that does not need CI or a deploy. Set
`APP_RELEASE_PIN_VERSION` (and `APP_RELEASE_PIN_WINDOWS` /
`APP_RELEASE_PIN_ANDROID` if you also need to repoint the downloads) in the
backend's environment to pull clients back to the previous release. See the
header of `Restaurant_Backend/app_release.ts`. The legacy `APP_LATEST_VERSION`
family is **inert** — setting it does nothing.
