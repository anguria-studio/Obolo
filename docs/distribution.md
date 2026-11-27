# macOS distribution builds

Both editions build the same `Obolo.app` for Apple silicon and Intel. They use the app ID `studio.anguria.obolo`, the App Group `group.studio.anguria.obolo`, and the CloudKit container `iCloud.studio.anguria.obolo`.

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in [project.yml](../project.yml). Start with version `1.0.0`, build `1`, and increment the build number for each subsequent release candidate. Use the same version and build for both editions of a candidate. Bump the patch version for fixes and the minor version for backward-compatible features.

Keep user-visible changes under **Unreleased** in the [changelog](../CHANGELOG.md). At publication, move those changes into a dated version section and tag the release commit as `vX.Y.Z`.

Run the commands below from the repository root. Archiving uses the team's Apple Development identity. Export uses the distribution identity and matching provisioning profile for the App Group, CloudKit, and push notifications. The export options select production CloudKit, and Xcode takes the APNs environment from the distribution profile. Deploy the CloudKit schema to production before distributing either edition.

## Direct download

The direct edition checks GitHub for a signed Sparkle feed. Automatic checks start enabled and users confirm each installation. **Settings → Updates** has the switch and a **Check Now** button. The feed address is `https://github.com/anguria-studio/Obolo/releases/latest/download/appcast.xml`. Each feed points to the versioned DMG in its release.

The release Mac needs the app's development and Developer ID signing identities and profiles, a `notarytool` Keychain profile, and the existing Sparkle signing key under the Keychain account `studio.anguria.obolo`. Keep an encrypted backup of that signing key before the first public release. The public half is in [the direct project](../project-direct.yml).

Check the candidate configuration, then build the release from the commit you intend to tag. Supply the name of your own notarization profile.

```sh
python3 scripts/build_direct_release.py --check
python3 scripts/build_direct_release.py --notary-profile YOUR_NOTARY_PROFILE
```

The second command submits the app and disk image to Apple's notary service and staples each ticket. It signs the finished DMG and the Sparkle feed and produces `Obolo-X.Y.Z-BUILD.dmg`, `appcast.xml`, and `SHA256SUMS` under `dist/direct/vX.Y.Z-BUILD/`. When the candidate passes the upgrade rehearsal, attach all three files to the corresponding GitHub release and mark it as the latest stable release. Homebrew can use the same versioned DMG and its checksum.

CI builds the universal direct app and uses a disposable app and signing key to exercise feed generation and verification. For the first installation rehearsal, use a separate checkout and a disposable macOS account signed out of iCloud. Set a test HTTPS feed URL and a dedicated test public key in that checkout’s direct project. Export two Developer ID builds with increasing build numbers and use Sparkle’s `generate_appcast` with the matching test key to serve the newer DMG at the test feed. Install the older build, add a sample subscription, and use **Check Now**. After installation and relaunch, verify the new build number and the saved subscription.

## Mac App Store

```sh
xcodegen generate --spec project-store.yml
xcodebuild -project OboloStore.xcodeproj -scheme 'Obolo App Store' \
  -destination 'generic/platform=macOS' -archivePath build/OboloStore.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/OboloStore.xcarchive \
  -exportPath build/store -exportOptionsPlist Configuration/ExportOptionsStore.plist \
  -allowProvisioningUpdates
```

The export writes a local package for App Store Connect and keeps the build number from `project.yml`.

Use the [Mac App Store privacy guide](app-store-privacy.md) to verify the build's data flows and fill out App Privacy.

For an unsigned archive, generate the appropriate project with XcodeGen and run `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`. The [CI workflow](../.github/workflows/ci.yml) shows both commands.
