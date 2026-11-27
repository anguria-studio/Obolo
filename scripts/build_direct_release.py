#!/usr/bin/env python3
"""Build and verify local Developer ID release assets for Obolo."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'OboloDirect.xcodeproj'
SCHEME = 'Obolo Direct'
BUNDLE_ID = 'studio.anguria.obolo'
APP_GROUP = 'group.studio.anguria.obolo'
CLOUD_CONTAINER = 'iCloud.studio.anguria.obolo'
REPOSITORY = 'https://github.com/anguria-studio/Obolo'
FEED = f'{REPOSITORY}/releases/latest/download/appcast.xml'
SPARKLE = 'https://github.com/sparkle-project/Sparkle'
SPARKLE_VERSION = '2.10.1'
SPARKLE_REVISION = 'ab7d71291238df6e0492143b120c9b696a35f603'
SPARKLE_NAMESPACE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
SPARKLE_SERVICES = 'com.apple.security.temporary-exception.mach-lookup.global-name'
SPARKLE_TOOL_HASHES = {
    'generate_appcast': 'cdc53c1da293c5f89648929678df2072f72a9f18d91744a06fcb8cc0e12a3219',
    'generate_keys': 'c37679f98d9121981cf7b2d18592fdc8b44931bffa604acf10c9e11791b6222e',
    'sign_update': '43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b',
}
UPDATE_SETTINGS = {
    'SUFeedURL': FEED,
    'SUEnableInstallerLauncherService': True,
    'SUVerifyUpdateBeforeExtraction': True,
    'SURequireSignedFeed': True,
    'SUSignedFeedFailureExpirationInterval': 0,
    'SUEnableAutomaticChecks': True,
    'SUAutomaticallyUpdate': False,
    'SUAllowsAutomaticUpdates': False,
    'SUEnableSystemProfiling': False,
    'SUSendProfileInfo': False,
}
VERSION_PATTERN = r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}'


def run(*args, cwd=ROOT, capture=False):
    return subprocess.run([str(arg) for arg in args], cwd=cwd, text=True, check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def require_values(actual, expected, label):
    for key, value in expected.items():
        found = actual.get(key)
        if type(found) is not type(value) or found != value:
            raise ValueError(f'{label}: expected {key} to be {value!r}, got {found!r}')


def read_plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)


def read_spec(path):
    return json.loads(run('xcodegen', 'dump', '--spec', path, '--type', 'json',
                          '--no-env', capture=True))


def release_version(spec):
    settings = spec['targets']['Obolo']['settings']['base']
    version = settings['MARKETING_VERSION']
    build = settings['CURRENT_PROJECT_VERSION']
    if not re.fullmatch(VERSION_PATTERN, version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('project.yml needs a three-part marketing version and a positive integer build')
    return version, build


def check_project(source):
    base = read_spec(source / 'project.yml')
    direct = read_spec(source / 'project-direct.yml')
    store = read_spec(source / 'project-store.yml')
    version, build = release_version(base)
    minimum_os = base['options']['deploymentTarget']['macOS']
    target = direct['targets']['Obolo']
    settings = target['settings']['base']
    require_values(settings, {
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
        'PRODUCT_NAME': 'Obolo',
        'ENABLE_APP_SANDBOX': True,
        'ENABLE_HARDENED_RUNTIME': True,
        'CODE_SIGN_ENTITLEMENTS': 'Configuration/Direct.entitlements',
        'MARKETING_VERSION': version,
        'CURRENT_PROJECT_VERSION': build,
    }, 'Direct project')
    require_values(direct['packages']['Sparkle'], {'url': SPARKLE, 'exactVersion': SPARKLE_VERSION},
                   'Sparkle package')
    info = target['info']['properties']
    require_values(info, UPDATE_SETTINGS, 'Direct Info.plist')
    if {'SUEnableDownloaderService', 'SUEnableInstallerConnectionService'} & info.keys():
        raise ValueError('Unexpected Sparkle XPC service configuration')
    public_key = info['SUPublicEDKey']
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('SUPublicEDKey must encode an Ed25519 public key')
    for edition in (base, store):
        if 'Sparkle' in edition['packages'] or any(
            key.startswith('SU') for key in edition['targets']['Obolo']['info']['properties']
        ):
            raise ValueError('Sparkle must be exclusive to the direct distribution')
    direct_ents = read_plist(source / settings['CODE_SIGN_ENTITLEMENTS'])
    expected_ents = read_plist(source / 'Obolo.entitlements')
    expected_ents[SPARKLE_SERVICES] = ['$(PRODUCT_BUNDLE_IDENTIFIER)-spks',
                                      '$(PRODUCT_BUNDLE_IDENTIFIER)-spki']
    if direct_ents != expected_ents:
        raise ValueError('Direct entitlements must extend Obolo.entitlements with Sparkle installer access')
    require_values(read_plist(source / 'Configuration/ExportOptionsDirect.plist'), {
        'destination': 'export', 'method': 'developer-id', 'iCloudContainerEnvironment': 'Production',
    }, 'Developer ID export options')
    return version, build, minimum_os, settings['DEVELOPMENT_TEAM'], public_key


def git(*args):
    return run('git', *args, capture=True).strip()


def archive_source(revision, destination):
    destination.mkdir()
    snapshot = destination.with_suffix('.tar')
    run('git', 'archive', '--output', snapshot, revision)
    run('tar', '-xf', snapshot, '-C', destination)
    snapshot.unlink()


def check_release_commit(version, build, work):
    commit = git('rev-parse', 'HEAD')
    tag = f'v{version}'
    tags = git('tag', '--list', 'v*').splitlines()
    if tag in tags and git('rev-parse', f'refs/tags/{tag}^{{commit}}') != commit:
        raise ValueError(f'{tag} already identifies another commit')
    previous_tags = git('tag', '--merged', commit, '--sort=-version:refname', '--list', 'v*')
    previous = next((name for name in previous_tags.splitlines()
                     if name != tag and re.fullmatch(VERSION_PATTERN, name[1:])), None)
    if previous:
        previous_source = work / 'previous-source'
        archive_source(f'refs/tags/{previous}', previous_source)
        previous_version, previous_build = release_version(read_spec(previous_source / 'project.yml'))
        if previous != f'v{previous_version}':
            raise ValueError(f'{previous} disagrees with its tagged project.yml version')
        if int(build) <= int(previous_build):
            raise ValueError(f'Build {build} must be higher than build {previous_build} from {previous}')
    return commit


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def sparkle_tools(packages):
    # SwiftPM authenticates the binary artifact against the checksum in Package.swift.
    # Check the exact source revision and bundled executables before running any tools.
    checkout = packages / 'checkouts/Sparkle'
    revision = run('git', '-C', checkout, 'rev-parse', 'HEAD', capture=True).strip()
    if revision != SPARKLE_REVISION:
        raise ValueError(f'Expected the official Sparkle {SPARKLE_VERSION} checkout')
    tools = packages / 'artifacts/sparkle/Sparkle/bin'
    for name, expected_hash in SPARKLE_TOOL_HASHES.items():
        if sha256(tools / name) != expected_hash:
            raise ValueError(f'Unexpected checksum for the Sparkle tool {name}')
    return tools


def release_assets(assets, names):
    files = sorted(assets.iterdir())
    if {file.name for file in files} != set(names) or any(
        file.is_symlink() or not file.is_file() for file in files
    ):
        raise ValueError(f'Expected exactly {", ".join(names)} in {assets}')


def checksums(assets, dmg_name):
    return ''.join(f'{sha256(assets / name)}  {name}\n' for name in (dmg_name, 'appcast.xml'))


def verify_release_assets(assets, dmg_name, version, build, minimum_os, download_url_prefix,
                          tools, signing_args):
    release_assets(assets, (dmg_name, 'appcast.xml', 'SHA256SUMS'))
    dmg = assets / dmg_name
    appcast = assets / 'appcast.xml'
    run(tools / 'sign_update', *signing_args, '--verify', appcast)
    feed = ET.parse(appcast).getroot()
    items = feed.findall('channel/item')
    if feed.tag != 'rss' or len(items) != 1:
        raise ValueError('Appcast must contain exactly one release item')
    item = items[0]
    require_values({key: item.findtext(f'{SPARKLE_NAMESPACE}{key}') for key in (
        'shortVersionString', 'version', 'minimumSystemVersion',
    )}, {'shortVersionString': version, 'version': build, 'minimumSystemVersion': minimum_os},
       'Appcast item')
    enclosures = item.findall('enclosure')
    if len(enclosures) != 1 or item.find(f'{SPARKLE_NAMESPACE}deltas') is not None:
        raise ValueError('Appcast must contain one full update enclosure')
    enclosure = enclosures[0]
    require_values(enclosure.attrib, {
        'url': download_url_prefix + dmg_name,
        'length': str(dmg.stat().st_size),
    }, 'Appcast enclosure')
    signature = enclosure.get(f'{SPARKLE_NAMESPACE}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Appcast enclosure has no valid Ed25519 signature field')
    run(tools / 'sign_update', *signing_args, '--verify', dmg, signature)
    if (assets / 'SHA256SUMS').read_text() != checksums(assets, dmg_name):
        raise ValueError('SHA256SUMS does not match the release assets')


def generate_release_assets(assets, dmg_name, version, build, minimum_os, download_url_prefix,
                            tools, signing_args):
    release_assets(assets, (dmg_name,))
    digest = sha256(assets / dmg_name)
    run(tools / 'generate_appcast', *signing_args, '--maximum-deltas', '0',
        '--download-url-prefix', download_url_prefix, assets)
    if sha256(assets / dmg_name) != digest:
        raise ValueError('The disk image changed during appcast generation')
    (assets / 'SHA256SUMS').write_text(checksums(assets, dmg_name))
    verify_release_assets(assets, dmg_name, version, build, minimum_os, download_url_prefix,
                          tools, signing_args)


def developer_identity(team):
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
    match = re.search(r'([A-F0-9]{40}) "Developer ID Application: [^"\n]+ \('
                      + re.escape(team) + r'\)"', identities)
    if not match:
        raise ValueError(f'An installed Developer ID Application identity for team {team} is required')
    return match[1]


def verify_developer_signature(path, team):
    requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{team}" and '
                   'certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    run('codesign', '--verify', '--strict', '-R', '=' + requirement, path)


def verify_app(app, version, build, minimum_os, team, public_key):
    contents = app / 'Contents'
    require_values(read_plist(contents / 'Info.plist'), {
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'Obolo',
        'CFBundleShortVersionString': version, 'CFBundleVersion': build,
        'LSMinimumSystemVersion': minimum_os, 'SUPublicEDKey': public_key, **UPDATE_SETTINGS,
    }, 'Exported app')
    verify_developer_signature(app, team)
    run('codesign', '--verify', '--deep', '--strict', app)
    signature = subprocess.check_output(['codesign', '--display', '--verbose=4', str(app)],
                                        stderr=subprocess.STDOUT, text=True)
    if not re.search(r'flags=[^\n]*\bruntime\b', signature) or '\nTimestamp=' not in signature:
        raise ValueError('Exported app requires the hardened runtime and a secure timestamp')
    entitlements = plistlib.loads(run('codesign', '--display', '--entitlements', '-', '--xml',
                                      app, capture=True).encode())
    require_values(entitlements, {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.application-groups': [APP_GROUP],
        'com.apple.developer.icloud-container-identifiers': [CLOUD_CONTAINER],
        'com.apple.developer.icloud-services': ['CloudKit'],
        'com.apple.developer.icloud-container-environment': 'Production',
        'com.apple.developer.aps-environment': 'production',
        SPARKLE_SERVICES: [f'{BUNDLE_ID}-spks', f'{BUNDLE_ID}-spki'],
    }, 'Exported entitlements')
    if any(entitlements.get(key) for key in (
        'com.apple.security.get-task-allow', 'com.apple.developer.get-task-allow',
        'com.apple.security.cs.disable-library-validation',
    )):
        raise ValueError('Exported app contains a debug or weakened runtime entitlement')
    framework = contents / 'Frameworks/Sparkle.framework/Versions/Current'
    require_values(read_plist(framework / 'Resources/Info.plist'), {
        'CFBundleShortVersionString': SPARKLE_VERSION,
    }, 'Embedded Sparkle framework')
    if not (contents / 'Resources/Sparkle.txt').is_file():
        raise ValueError('Exported app is missing the Sparkle license')
    for executable in (contents / 'MacOS/Obolo', framework / 'Sparkle', framework / 'Autoupdate',
                       framework / 'Updater.app/Contents/MacOS/Updater',
                       framework / 'XPCServices/Installer.xpc/Contents/MacOS/Installer'):
        architectures = run('xcrun', 'lipo', '-archs', executable, capture=True).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise ValueError(f'{executable.name} must contain arm64 and x86_64 slices')


def notarize(path, ticket_target, profile):
    result = json.loads(run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                            '--wait', '--output-format', 'json', capture=True))
    if result.get('status') != 'Accepted':
        raise ValueError(f'Notarization rejected {path.name} (submission {result.get("id")})')
    print(f'Apple accepted {path.name} (submission {result["id"]})', flush=True)
    run('xcrun', 'stapler', 'staple', ticket_target)
    run('xcrun', 'stapler', 'validate', ticket_target)


def verify_signing_key(tools, public_key):
    local_key = run(tools / 'generate_keys', '--account', BUNDLE_ID, '-p', capture=True).strip()
    if local_key != public_key:
        raise ValueError('The Obolo Sparkle key in Keychain differs from SUPublicEDKey')


def build_release(output, profile, version, build, minimum_os, team, public_key, dmg_name, url):
    if git('status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('Commit the release candidate before building distribution assets')
    if output.exists() or output.is_symlink():
        raise ValueError(f'Release output already exists at {output}')
    identity = developer_identity(team)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.candidate-', dir=output.parent) as scratch:
        work = Path(scratch)
        commit = check_release_commit(version, build, work)
        source = work / 'source'
        archive_source(commit, source)
        if check_project(source) != (version, build, minimum_os, team, public_key):
            raise ValueError('Working-tree release settings differ from the archived commit')
        run('xcodegen', 'generate', '--spec', 'project-direct.yml', '--no-env', cwd=source)
        packages = work / 'packages'
        archive = work / 'OboloDirect.xcarchive'
        exported = work / 'export'
        xcode = ('xcodebuild', '-project', PROJECT, '-scheme', SCHEME,
                 '-clonedSourcePackagesDirPath', packages)
        run(*xcode, '-resolvePackageDependencies', cwd=source)
        tools = sparkle_tools(packages)
        verify_signing_key(tools, public_key)
        run('xcrun', 'notarytool', 'history', '--keychain-profile', profile, capture=True)
        run(*xcode, '-configuration', 'Release', '-destination', 'generic/platform=macOS',
            '-onlyUsePackageVersionsFromResolvedFile', '-derivedDataPath', work / 'DerivedData',
            '-archivePath', archive, 'archive', cwd=source)
        run('xcodebuild', '-exportArchive', '-allowProvisioningUpdates', '-archivePath', archive,
            '-exportPath', exported, '-exportOptionsPlist', 'Configuration/ExportOptionsDirect.plist',
            cwd=source)
        app = exported / 'Obolo.app'
        verify_app(app, version, build, minimum_os, team, public_key)
        app_zip = work / 'Obolo.zip'
        run('ditto', '-c', '-k', '--keepParent', app, app_zip)
        notarize(app_zip, app, profile)
        run('syspolicy_check', 'distribution', app)
        stage = work / 'stage'
        stage.mkdir()
        run('ditto', app, stage / 'Obolo.app')
        (stage / 'Applications').symlink_to('/Applications')
        assets = work / 'assets'
        assets.mkdir()
        dmg = assets / dmg_name
        run('hdiutil', 'create', '-volname', 'Obolo', '-srcfolder', stage, '-format', 'UDZO', dmg)
        run('codesign', '--sign', identity, '--timestamp', dmg)
        notarize(dmg, dmg, profile)
        verify_developer_signature(dmg, team)
        run('hdiutil', 'verify', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
        generate_release_assets(assets, dmg_name, version, build, minimum_os, url, tools,
                                ('--account', BUNDLE_ID))
        # Reserve the name with mkdir so concurrent candidates cannot replace each other.
        output.mkdir()
        try:
            assets.rename(output)
        except OSError:
            output.rmdir()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true', help='Check project configuration offline')
    mode.add_argument('--verify-assets', type=Path, metavar='DIR',
                      help='Verify local release assets with the Obolo Keychain signing key')
    mode.add_argument('--notary-profile', metavar='PROFILE',
                      help='Build a release and submit it to Apple with this notarytool profile')
    parser.add_argument('--sparkle-packages', type=Path, metavar='DIR',
                        help='Resolved direct project package directory for --verify-assets')
    args = parser.parse_args()
    if bool(args.verify_assets) != bool(args.sparkle_packages):
        parser.error('--verify-assets and --sparkle-packages must be used together')
    if args.notary_profile is not None and not args.notary_profile.strip():
        parser.error('Provide a nonempty notarization profile')
    try:
        version, build, minimum_os, team, public_key = check_project(ROOT)
        dmg_name = f'Obolo-{version}-{build}.dmg'
        url = f'{REPOSITORY}/releases/download/v{version}/'
        if args.check:
            print(f'Checked direct release configuration for {version} ({build}).')
        elif args.verify_assets:
            tools = sparkle_tools(args.sparkle_packages.resolve())
            verify_signing_key(tools, public_key)
            verify_release_assets(args.verify_assets.resolve(), dmg_name, version, build,
                                  minimum_os, url, tools, ('--account', BUNDLE_ID))
            print(f'Verified local assets for {version} ({build}).')
        else:
            output = ROOT / 'dist/direct' / f'v{version}-{build}'
            build_release(output, args.notary_profile, version, build, minimum_os, team,
                          public_key, dmg_name, url)
            print(f'Verified local release assets in {output}.')
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
