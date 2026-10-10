# Cutting a Flycut release

Releases are produced by `.github/workflows/release.yml`, which runs when a
`v*` tag is pushed. It builds the macOS app, packages it in a DMG, optionally
signs + notarizes it, and publishes a GitHub Release with the DMG attached.

## One-time setup: GitHub secrets

Add these under **Settings → Secrets and variables → Actions**. The workflow
adapts to whichever are present, so you can start with none (test build) and
add them as you go.

| Secret | Purpose |
| --- | --- |
| `CERTIFICATES_P12` | base64 of your **Developer ID Application** certificate exported as `.p12` |
| `CERTIFICATES_PASSWORD` | the password you set when exporting the `.p12` |
| `NOTARY_TEAM_ID` | your Apple Developer Team ID (`S8JLSG5ES7`); used as the signing `DEVELOPMENT_TEAM` |
| `NOTARY_KEY` | base64 of your App Store Connect API key (`.p8`) |
| `NOTARY_KEY_ID` | the API key's **Key ID** |
| `NOTARY_ISSUER_ID` | the API key's **Issuer ID** |

Notarization uses an **App Store Connect API key** (not an Apple-ID app-specific
password): it's a team credential, independent of any personal account, and cleanly
revocable. Create it at **App Store Connect → Users and Access → Integrations → App
Store Connect API**, generate a **Team Key** (role: Developer), and **download the
`.p8` once** (it can't be re-downloaded). Note the Key ID and Issuer ID shown there.

Export the signing `.p12` and base64-encode the credentials:

```
# In Keychain Access: export your "Developer ID Application" identity as Certificates.p12
base64 -i Certificates.p12 | gh secret set CERTIFICATES_P12 -R TermiT/Flycut
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY -R TermiT/Flycut
gh secret set CERTIFICATES_PASSWORD -R TermiT/Flycut   # prompts for the .p12 passphrase
gh secret set NOTARY_KEY_ID -R TermiT/Flycut --body "XXXXXXXXXX"
gh secret set NOTARY_ISSUER_ID -R TermiT/Flycut --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
gh secret set NOTARY_TEAM_ID -R TermiT/Flycut --body "S8JLSG5ES7"
```

Behaviour by secrets configured:

- **none** → ad-hoc signed app in the DMG. Gatekeeper will warn; use only for testing.
- **signing only** → Developer ID signed with hardened runtime (still warned until notarized).
- **signing + notary** → signed, notarized, and stapled — installs cleanly with no warning.

## Cutting a release

```
# 1. Make sure master is green and the version is bumped (MARKETING_VERSION).
# 2. Tag and push:
git tag v1.9.7
git push origin v1.9.7
```

The workflow stamps `MARKETING_VERSION` from the tag, builds, packages, (signs +
notarizes if secrets are set), and creates the GitHub Release. Release notes are
taken from the matching `## 1.9.7` section of `CHANGELOG.md`, falling back to the
commit log if that section is absent.

## Fork build settings

Project-level build settings, overridable on the `xcodebuild` command line:

| Setting | Default | Effect |
| --- | --- | --- |
| `FLYCUT_BUNDLE_ID` | `net.nowaker.flycut.claude` | App bundle id; the helper gets `<id>.helper`, the iCloud container `iCloud.<id>` |
| `FLYCUT_CLOUDKIT` | `NO` | `YES` compiles in iCloud sync, signs with `FlycutDeveloperIDCloudKit.entitlements` and switches to automatic signing, which needs a paid Apple Developer team with the container registered |

Local signed build:

```
DEVELOPER_DIR=~/Applications/Xcode-26.3.app/Contents/Developer \
  xcodebuild -project Flycut.xcodeproj -scheme Flycut -configuration Release build
```

## Two channels: entitlements

1.9.7 ships on **both** channels, which need different entitlements:

- **`Flycut.entitlements`** — Mac App Store build. App Sandbox on, iCloud
  (CloudKit) container, `aps-environment`. Unchanged; used by the normal Release
  config and the MAS submission.
- **`FlycutDeveloperID.entitlements`** — Developer ID direct-download build. Not
  sandboxed, no MAS-only iCloud/`aps` keys (invalid without a provisioning profile
  under Developer ID). The workflow passes this via `CODE_SIGN_ENTITLEMENTS` in the
  archive step. The CloudKit guard added in 1.9.7 means the app runs safely without
  the iCloud entitlement (sync just no-ops); iCloud sync is unavailable in the
  direct-download build unless you register a Developer-ID iCloud container.

### Channel A — Developer ID DMG (this workflow)

Configure the secrets above, then push a `v*` tag (see below). The workflow builds
with `FlycutDeveloperID.entitlements`, notarizes, staples, and publishes the DMG.

> First-run caveat: this app bundles a login-item helper and an embedded
> framework. Notarization requires every nested binary to be Developer ID-signed
> with the hardened runtime. That can only be fully validated once
> `CERTIFICATES_P12` is set and the first tagged build runs — expect to iterate
> once on nested-code signing if notarization reports an unsigned/instrumented
> nested binary. (The command-line `CODE_SIGN_ENTITLEMENTS` override also applies
> to the helper, which is harmless — it only launches the main app.)

### Channel B — Mac App Store update

Don't use this workflow. In Xcode: select the **Flycut** scheme, Product → Archive,
then Organizer → **Distribute App → App Store Connect**. This uses
`Flycut.entitlements` (sandbox + iCloud) unchanged and goes through App Review.
Bump `MARKETING_VERSION` (already 1.9.7) and submit the same source as the DMG.
