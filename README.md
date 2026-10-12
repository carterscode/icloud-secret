# icloud-secret

A tiny macOS CLI to **store a secret in the iCloud-synced Keychain and read it
back from a script** — something the built-in `security` tool cannot do.

```sh
printf '%s' "$MY_TOKEN" | icloud-secret set github-token
icloud-secret get github-token            # on any Mac on the same iCloud account
icloud-secret delete github-token
```

Items are written to the **data-protection (iCloud-synced) Keychain** with
`kSecAttrSynchronizable = true`, so they replicate to your other Macs and
survive a wipe (after you sign back into iCloud and sync completes).

## Why this exists

`security add-generic-password` writes the **local login keychain**, which does
not sync and is gone after a wipe. The synced keychain requires a
`keychain-access-groups` entitlement, which only a **code-signed, provisioned**
binary can carry. An unsigned build — `security`, `swift`, `python`, anything —
returns `errSecMissingEntitlement` (`-34018`). See Apple
[TN3137: On Mac Keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

So this tool must be signed once with an Apple **Developer ID** and notarized.
**Users just download and run the notarized binary — they need no Apple
Developer account.** Only the person building a release does.

## Install

Download the notarized universal build from [Releases](../../releases). **Keep
the `.app` bundle intact and run the binary from *inside* it** — the bundle
carries the provisioning profile that authorizes Keychain access, so a bare
copy of the binary extracted out of the bundle gets killed by the OS
(`zsh: killed`). Symlink the inner binary onto your `PATH`:

```sh
curl -fsSL https://github.com/carterscode/icloud-secret/releases/latest/download/icloud-secret-macos-universal.zip -o /tmp/ics.zip
mkdir -p ~/.local/share/icloud-secret ~/.local/bin
ditto -xk /tmp/ics.zip /tmp/ics
ditto /tmp/ics/iCloudSecret.app ~/.local/share/icloud-secret/iCloudSecret.app
ln -sfn ~/.local/share/icloud-secret/iCloudSecret.app/Contents/MacOS/icloud-secret ~/.local/bin/icloud-secret
```

## How it works / trust model

- Each user's items live in **their own** Keychain under the access group
  `<TeamID>.com.carterscode.icloudsecret`. Running the published binary lets you
  read/write **your** secrets only; it can't see anyone else's, and publishing
  it doesn't expose the author's.
- Only a binary signed by the **same Team ID** can read those items. A fork
  rebuilt under a different Team ID gets its own separate namespace — so items
  written by this release are readable only by this release.
- It's a credential tool running in your login session; the source here is what
  makes that auditable.

## Build a signed release yourself

Requires: an Apple Developer account (Developer ID distribution), a *Developer
ID Application* certificate, an explicit App ID `com.carterscode.icloudsecret`
with **Keychain Sharing**, and a Developer ID **provisioning profile** for it.

Local:

```sh
TEAM_ID=XXXXXXXXXX \
SIGN_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)" \
PROFILE=./icloud-secret.provisionprofile \
NOTARY_PROFILE=icloud-secret-notary \
scripts/build-sign.sh
```

(`NOTARY_PROFILE` from `xcrun notarytool store-credentials`.) The script prints
the zip's SHA-256 and Team ID.

### CI releases

`.github/workflows/release.yml` builds, signs, and notarizes on a `v*` tag.
Set these repository secrets:

| Secret | What |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of your exported Developer ID cert (`.p12`) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any throwaway password for the CI keychain |
| `PROVISIONING_PROFILE_BASE64` | base64 of the `.provisionprofile` |
| `TEAM_ID` | 10-char Apple Team ID |
| `SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`, `NOTARY_API_KEY_P8_BASE64` | App Store Connect API key for notarization |

Push a tag (`git tag v1.0.0 && git push --tags`) → the signed, notarized
universal zip is attached to the release.

## Caveat

iCloud Keychain sync is eventually-consistent — there's no API to force a
specific item to finish syncing, and a freshly-signed-in Mac may need a trusted
device or passcode before synced items appear. So this is *unattended after
sync*, not instantaneously guaranteed.

## License

MIT — see [LICENSE](LICENSE).
