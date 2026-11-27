# macOS distribution builds

Both editions build the same `Obolo.app` for Apple silicon and Intel. They use the app ID `studio.anguria.obolo`, the App Group `group.studio.anguria.obolo`, and the CloudKit container `iCloud.studio.anguria.obolo`.

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in [project.yml](../project.yml). Start with version `1.0.0`, build `1`, and increment the build number for each subsequent release candidate. Use the same version and build for both editions of a candidate. Bump the patch version for fixes and the minor version for backward-compatible features.

Keep user-visible changes under **Unreleased** in the [changelog](../CHANGELOG.md). At publication, move those changes into a dated version section and tag the release commit as `vX.Y.Z`.

Run these commands from the repository root. The archive step uses the app team's Apple Development signing. The export step uses the matching distribution identity and provisioning profile for CloudKit and push notifications. Sign in to the app's Apple Developer team in Xcode to let it manage provisioning. The export options use the production CloudKit environment, and Xcode takes the APNs environment from the distribution profile. Deploy the CloudKit schema to production before distributing either edition.

## Direct download

```sh
xcodegen generate --spec project-direct.yml
xcodebuild -project OboloDirect.xcodeproj -scheme 'Obolo Direct' \
  -destination 'generic/platform=macOS' -archivePath build/OboloDirect.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/OboloDirect.xcarchive \
  -exportPath build/direct -exportOptionsPlist Configuration/ExportOptionsDirect.plist \
  -allowProvisioningUpdates
```

The export produces a Developer ID-signed app for notarization and packaging.

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

To compile either edition without signing credentials, replace `-allowProvisioningUpdates archive` with `CODE_SIGNING_ALLOWED=NO archive` and stop after the archive step.
