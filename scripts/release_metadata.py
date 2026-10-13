#!/usr/bin/env python3
"""Generate checksums and distribution manifests from actual release artifacts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from ios_archive import read_ipa


def digest_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--repository', default='haneoka-gakuen/haneoka-app')
    args = parser.parse_args()
    folder = args.dist
    files = {p.name: p for p in folder.iterdir() if p.is_file()}
    generated = {'release-version.json', 'SHA256SUMS', 'altstore-source.json', 'scoop-haneoka.json', 'Haneoka.Haneoka.installer.yaml', 'Haneoka.Haneoka.locale.en-US.yaml', 'Haneoka.Haneoka.yaml', 'haneoka.rb', 'haneoka-windows-x64.appinstaller', 'haneoka-windows-arm64.appinstaller'}
    files = {name.replace(f'haneoka-{args.version}-', 'haneoka-', 1): path
             for name, path in files.items() if name not in generated}
    # Keep logical package keys for manifest generation; public package filenames
    # include the release version. Feed and package-manager manifest names stay
    # stable so installed clients can continue checking for updates.
    for name, path in list(files.items()):
        if name.startswith('haneoka-') and not path.name.startswith(f'haneoka-{args.version}-'):
            destination = folder / name.replace('haneoka-', f'haneoka-{args.version}-', 1)
            path.rename(destination)
            files[name] = destination
    hashes = {name: digest_file(path) for name, path in files.items()}
    for name in generated:
        (folder / name).unlink(missing_ok=True)
    base = f'https://github.com/{args.repository}/releases/download/v{args.version}/'
    ipa = files.get('haneoka-ios-unsigned.ipa')
    if ipa:
        info, permissions = read_ipa(ipa)
        if info.get('CFBundleShortVersionString') != args.version or info.get('CFBundleVersion') != args.build_number:
            raise SystemExit('IPA version/build do not match the release arguments')
        if any(key.startswith('com.apple.private.') for key in permissions['entitlements']):
            raise SystemExit('The AltStore source must use the standard IPA, without privileged entitlements')
        source = {'name': 'Haneoka', 'identifier': 'org.haneoka.source', 'website': 'https://haneoka.org',
                  'apps': [{'name': 'Haneoka', 'bundleIdentifier': info['CFBundleIdentifier'],
                            'developerName': 'Haneoka contributors', 'category': 'utilities',
                            'appPermissions': permissions,
                            'localizedDescription': 'Our Notes catalogue, community and local save reader. Standard iOS installs import saves or backups exported on a computer. Private game containers require the separate privileged build.',
                            'iconURL': f'https://raw.githubusercontent.com/{args.repository}/v{args.version}/assets/brand/android-chrome-512x512.png',
                            'versions': [{'version': args.version, 'buildVersion': args.build_number,
                                          'date': datetime.now(timezone.utc).isoformat(),
                                          'downloadURL': base + ipa.name, 'size': ipa.stat().st_size,
                                          'minOSVersion': info.get('MinimumOSVersion', '15.0')}]}], 'news': []}
        (folder / 'altstore-source.json').write_text(json.dumps(source, indent=2) + '\n')
    architectures = {}
    installers = []
    for arch in ['x64', 'arm64']:
        name = f'haneoka-windows-{arch}.zip'
        if name in files:
            architectures['64bit' if arch == 'x64' else 'arm64'] = {'url': base + files[name].name, 'hash': hashes[name]}
        for extension, installer_type in [('msi', 'wix'), ('exe', 'inno')]:
            name = f'haneoka-windows-{arch}' + ('-setup.exe' if extension == 'exe' else '.msi')
            if name in files:
                installers.append({'Architecture': arch, 'InstallerType': installer_type,
                                   'Scope': 'user', 'InstallerUrl': base + files[name].name,
                                   'InstallerSha256': hashes[name].upper()})
    if architectures:
        scoop = {'version': args.version, 'description': 'Our Notes catalogue and save reader',
                 'homepage': 'https://haneoka.org', 'license': 'MPL-2.0', 'architecture': architectures,
                 'shortcuts': [['haneoka.exe', 'Haneoka']],
                 'checkver': {'github': f'https://github.com/{args.repository}'}}
        (folder / 'scoop-haneoka.json').write_text(json.dumps(scoop, indent=2) + '\n')
    if installers:
        manifest = {'PackageIdentifier': 'Haneoka.Haneoka', 'PackageVersion': args.version,
                    'InstallerLocale': 'en-US', 'Installers': installers,
                    'ManifestType': 'installer', 'ManifestVersion': '1.10.0'}
        # JSON is valid YAML and avoids hand-escaped installer URLs.
        (folder / 'Haneoka.Haneoka.installer.yaml').write_text(json.dumps(manifest, indent=2) + '\n')
        locale = {'PackageIdentifier': 'Haneoka.Haneoka', 'PackageVersion': args.version,
                  'PackageLocale': 'en-US', 'Publisher': 'Haneoka contributors', 'PackageName': 'Haneoka',
                  'License': 'MPL-2.0', 'ShortDescription': 'Our Notes catalogue and save reader',
                  'ManifestType': 'defaultLocale', 'ManifestVersion': '1.10.0'}
        (folder / 'Haneoka.Haneoka.locale.en-US.yaml').write_text(json.dumps(locale, indent=2) + '\n')
        (folder / 'Haneoka.Haneoka.yaml').write_text(json.dumps({'PackageIdentifier': 'Haneoka.Haneoka',
            'PackageVersion': args.version, 'DefaultLocale': 'en-US', 'ManifestType': 'version',
            'ManifestVersion': '1.10.0'}, indent=2) + '\n')
    for arch in ['x64', 'arm64']:
        name = f'haneoka-windows-{arch}.msix'
        if name not in files:
            continue
        with zipfile.ZipFile(files[name]) as archive:
            manifest = ET.fromstring(archive.read('AppxManifest.xml'))
        identity = manifest.find('{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Identity')
        if identity is None or identity.get('Version') != f'{args.version}.{args.build_number}' or identity.get('ProcessorArchitecture') != arch:
            raise SystemExit('MSIX identity does not match the release version/architecture')
        namespace = 'http://schemas.microsoft.com/appx/appinstaller/2018'
        ET.register_namespace('', namespace)
        stable = f'https://github.com/{args.repository}/releases/latest/download/'
        installer = ET.Element(f'{{{namespace}}}AppInstaller', Uri=stable + f'haneoka-windows-{arch}.appinstaller', Version=identity.get('Version'))
        ET.SubElement(installer, f'{{{namespace}}}MainPackage', Name=identity.get('Name'), Publisher=identity.get('Publisher'), Version=identity.get('Version'), ProcessorArchitecture=arch, Uri=base + files[name].name)
        settings = ET.SubElement(installer, f'{{{namespace}}}UpdateSettings')
        ET.SubElement(settings, f'{{{namespace}}}OnLaunch', HoursBetweenUpdateChecks='24', ShowPrompt='true', UpdateBlocksActivation='false')
        ET.SubElement(settings, f'{{{namespace}}}AutomaticBackgroundTask')
        ET.ElementTree(installer).write(folder / f'haneoka-windows-{arch}.appinstaller', encoding='utf-8', xml_declaration=True)
    mac_arm = 'haneoka-macos-arm64.dmg'
    mac_intel = 'haneoka-macos-x64.dmg'
    if mac_arm in files and mac_intel in files:
        (folder / 'haneoka.rb').write_text(f'''cask "haneoka" do
  arch arm: "arm64", intel: "x64"
  version "{args.version}"
  sha256 arm: "{hashes[mac_arm]}", intel: "{hashes[mac_intel]}"
  url "{base}haneoka-{args.version}-macos-#{{arch}}.dmg"
  name "Haneoka"
  desc "Our Notes catalogue and save reader"
  homepage "https://haneoka.org"
  depends_on macos: ">= :monterey"
  app "haneoka.app"
end
''')
    (folder / 'release-version.json').write_text(json.dumps({'version': args.version, 'buildNumber': args.build_number}) + '\n')
    checksums = {}
    for path in sorted(folder.iterdir()):
        if path.is_file() and path.name != 'SHA256SUMS':
            with path.open('rb') as stream:
                checksums[path.name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    (folder / 'SHA256SUMS').write_text('\n'.join(f'{digest}  {name}' for name, digest in checksums.items()) + '\n')
    print('Generated release checksums and available-platform manifests')


if __name__ == '__main__':
    main()
