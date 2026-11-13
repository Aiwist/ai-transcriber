#!/usr/bin/env python3
"""Prepare and verify a ReaPack package. Does not compile, upload or publish."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / 'Transcriber'


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    data = value.encode('utf-8') if isinstance(value, str) else value
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def notice_bounds(sheet):
    headings = list(re.finditer(r'THIRD_PARTY_NOTICES_RU\.txt\r?\n={64}', sheet))
    assert len(headings) == 1, 'Missing or duplicate third-party notice section'
    start = headings[0].end()
    separator = re.search(r'\r?\n={64}\r?\n', sheet[start:])
    assert separator is not None, 'Missing next license section'
    end = start + separator.start()
    return start, end


def check_notice_sheet(sheet, notices, version):
    start, end = notice_bounds(sheet)
    assert sheet[start:end].replace('\r\n', '\n').strip() == notices.replace('\r\n', '\n').strip(), 'Bundled third-party notices are stale'
    versions = re.findall(r'^Версия:\s*(\d+\.\d+\.\d+)\s*$', sheet, re.M)
    assert versions == [version], 'Wrong application version in the license sheet'


def prepare_notice_sheet(version):
    path = PAYLOAD / 'THIRD_PARTY_NOTICES_RU.txt'
    notices = path.read_text(encoding='utf-8-sig')
    notices, count = re.subn(r'^Версия: [^\n]+$', 'Версия: ' + version, notices, flags=re.M)
    assert count == 1, 'Missing application version in the third-party notice'
    write(path, notices)
    path = PAYLOAD / 'INSTALL_LICENSES_RU.txt'
    sheet = path.read_bytes().decode('utf-8')
    start, end = notice_bounds(sheet)
    section = sheet[start:end]
    newline = '\r\n' if '\r\n' in section else '\n'
    prefix = re.match(r'\s*', section).group()
    suffix = re.search(r'\s*$', section).group()
    sheet = sheet[:start] + prefix + notices.strip().replace('\n', newline) + suffix + sheet[end:]
    check_notice_sheet(sheet, notices, version)
    write(path, sheet)


def settings():
    config = read_json(ROOT / 'reapack.json')
    release = read_json(PAYLOAD / 'native_release.json')
    assert config['schema'] == release['schema'] == 1
    assert re.fullmatch(r'\d+\.\d+\.\d+', release['version'])
    assert re.fullmatch(r'[\w.-]+/[\w.-]+', config['repository'])
    for runtime in runtimes(release):
        assert re.fullmatch(r'[0-9a-f]{64}', runtime['sha256'])
    assert release['runtime']['backends'] == ['Vulkan', 'CPU']
    assert release['runtime']['asset'] == 'ai_transcriber_native_vulkan.exe'
    assert release['cpu_runtime']['backends'] == ['CPU']
    assert release['cpu_runtime']['asset'] == 'ai_transcriber_native_cpu.exe'
    return config, release


def runtimes(release):
    return [release['runtime'], release['cpu_runtime']]


def safe_relative(name):
    path = PurePosixPath(name)
    assert name and not path.is_absolute() and '\\' not in name and ':' not in name
    assert all(part not in ('.', '..') for part in path.parts), name
    assert path.as_posix() == name, name
    return name


def inventory(release):
    """Only application files are eligible; no jobs, settings, weights or SDKs."""
    files = set()
    for pattern in ('Aiwist_Transcriber.lua', 'Register_Ai_Transcriber.lua',
                    'capabilities.json', 'native_models.json', 'native_release.json',
                    'INSTALL_LICENSES_RU.txt', 'NOTICE.txt', 'README_RU.txt',
                    'THIRD_PARTY_NOTICES_RU.txt', 'lib/*.lua', 'setup/*.ps1',
                    'fonts/*.ttf', 'licenses/*.txt'):
        for path in PAYLOAD.glob(pattern):
            files.add(path.relative_to(PAYLOAD).as_posix())
    files.discard('manifest.json')
    files.discard('manifest.tsv')
    files.update(safe_relative(runtime['file']) for runtime in runtimes(release))
    assert len(files) == len({name.lower() for name in files})
    return sorted(files)


def hashes(release, require_runtime=False):
    result = {}
    builds = {runtime['file']:runtime for runtime in runtimes(release)}
    for name in inventory(release):
        path = PAYLOAD / name
        if name in builds:
            runtime = builds[name]
            if require_runtime or path.exists():
                assert path.is_file(), f'Missing engine: {path}'
                assert path.stat().st_size == runtime['bytes'], 'Wrong engine size'
                assert sha256(path) == runtime['sha256'], 'Wrong engine SHA-256'
                with path.open('rb') as stream:
                    assert stream.read(2) == b'MZ', 'Not a Windows executable'
            result[name] = runtime['sha256']
        else:
            assert path.is_file(), name
            result[name] = sha256(path)
    return result


def package_files(release):
    return sorted(inventory(release) + ['manifest.json', 'manifest.tsv'])


def asset_url(config, release, runtime):
    return (f"https://github.com/{config['repository']}/releases/download/"
            f"v{release['version']}/{runtime['asset']}")


def source_url(config, release, name):
    runtime = next((build for build in runtimes(release) if build['file'] == name), None)
    return (asset_url(config, release, runtime) if runtime else
            f"https://raw.githubusercontent.com/{config['repository']}/"
            f"v{release['version']}/Transcriber/{name}")


def header(config, release):
    lines = [f"-- @version {release['version']}", '-- @description Ai Transcriber',
             '-- @author Aiwist', '-- @license Apache-2.0',
             '-- Copyright (c) 2026 Aiwist.',
             '-- AI-assisted development: OpenAI Codex.',
             '-- Attribution/scope: NOTICE.txt; full license: licenses/AiTranscriber-Lua-APACHE-2.0.txt',
             '-- @changelog']
    lines += ['--   ' + change for change in config['changes']]
    lines += ['-- @about', '--   Audio to MIDI in REAPER. Windows x64; requires ReaImGui (cfillion).',
              '--   The native engine supports Vulkan GPU and CPU. No Python environment.',
              '--   Accept the bundled licenses on first launch, then install models in Settings.',
              '--   MuScriptor weights retain their CC BY-NC 4.0 and author-specific terms.',
              '-- @link', f"--   GitHub https://github.com/{config['repository']}",
              '--   Boosty https://boosty.to/aiwist', '-- @screenshot',
              f"--   https://raw.githubusercontent.com/{config['repository']}/main/assets/screenshots/screen-1.png",
              f"--   https://raw.githubusercontent.com/{config['repository']}/main/assets/screenshots/screen-2.png",
              '-- @provides']
    for name in package_files(release):
        if name == config['package']:
            lines.append('--   [win64 main] .')
        elif name in [runtime['file'] for runtime in runtimes(release)]:
            lines.append(f'--   [win64 nomain] {name} {source_url(config, release, name)}')
        else:
            lines.append(f'--   [win64 nomain] {name}')
    return '\n'.join(lines) + '\n'


def index_bytes(config, release):
    # Keep published version definitions unchanged; append the current package.
    previous = ET.parse(ROOT / 'index.xml').getroot() if (ROOT / 'index.xml').exists() else None
    root = ET.Element('index', {'version': '1', 'name': config['name']})
    category = ET.SubElement(root, 'category', {'name': config['category']})
    package = ET.SubElement(category, 'reapack', {'name': config['package'], 'type': 'script', 'desc': 'Ai Transcriber'})
    metadata = ET.SubElement(package, 'metadata')
    ET.SubElement(metadata, 'description').text = (
        r'{\rtf1\ansi Ai Transcriber: audio to MIDI in REAPER. Windows x64. '
        r'Requires ReaImGui (cfillion) from ReaTeam Extensions. '
        r'Includes the native Vulkan/CPU engine; models download separately in Settings. '
        r'First launch displays bundled licenses.}')
    ET.SubElement(metadata, 'link', {'rel': 'website', 'href': f"https://github.com/{config['repository']}"}).text = 'GitHub'
    ET.SubElement(metadata, 'link', {'rel': 'website', 'href': 'https://boosty.to/aiwist'}).text = 'Boosty'
    for number in (1, 2):
        ET.SubElement(metadata, 'link', {'rel': 'screenshot'}).text = (
            f"https://raw.githubusercontent.com/{config['repository']}/main/assets/screenshots/screen-{number}.png")
    if previous is not None:
        old = previous.find(f"./category[@name='{config['category']}']/reapack[@name='{config['package']}']")
        if old is not None:
            for version in old.findall('version'):
                if version.get('name') != release['version']:
                    package.append(copy.deepcopy(version))
    version = ET.SubElement(package, 'version', {'name': release['version'], 'author': 'Aiwist', 'time': config['time']})
    ET.SubElement(version, 'changelog').text = '\n'.join(config['changes'])
    for name in package_files(release):
        attrs = {'platform': 'win64', 'file': name}
        if name == config['package']:
            attrs['main'] = 'main'
        ET.SubElement(version, 'source', attrs).text = source_url(config, release, name)
    ET.indent(root, space='  ')
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'


def prepare():
    config, release = settings()
    prepare_notice_sheet(release['version'])
    script = PAYLOAD / config['package']
    body = script.read_text(encoding='utf-8-sig').split('--[[', 1)[1]
    write(script, (header(config, release) + '--[[' + body).replace('\n', '\r\n'))
    payload_hashes = hashes(release, require_runtime=True)
    manifest = {'schema': 1, 'version': release['version'], 'channel': 'native',
                'files': payload_hashes}
    write(PAYLOAD / 'manifest.json', json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    installer_files = sorted(list(payload_hashes) + ['manifest.json'])
    installer = ROOT / 'Install.ps1'
    text = installer.read_text(encoding='utf-8-sig')
    text = re.sub(r"\$script:SetupVersion='[^']+'", f"$script:SetupVersion='{release['version']}'", text)
    helper_hash = sha256(ROOT / 'reaimgui_install.ps1').upper()
    text, helper_count = re.subn(r"(\(Get-FileHash -LiteralPath \$script:ReaImGuiInstaller\)\.Hash -ne ')[A-F0-9]{64}",
                               lambda match: match[1] + helper_hash, text)
    assert helper_count == 1
    listing = '$script:SetupFiles=@(\n' + ',\n'.join("    '" + n + "'" for n in installer_files) + '\n)'
    text, count = re.subn(r'\$script:SetupFiles=@\(.*?\n\)', lambda _: listing, text, count=1, flags=re.S)
    assert count == 1
    write(installer, b'\xef\xbb\xbf' + text.replace('\n', '\r\n').encode('utf-8'))
    write(PAYLOAD / 'manifest.tsv', ''.join(f'{name}\t{sha256(PAYLOAD / name)}\n' for name in installer_files))
    write(ROOT / 'index.xml', index_bytes(config, release))
    check(require_runtime=True)


def check(require_runtime=False):
    config, release = settings()
    check_notice_sheet((PAYLOAD / 'INSTALL_LICENSES_RU.txt').read_text(encoding='utf-8-sig'),
                       (PAYLOAD / 'THIRD_PARTY_NOTICES_RU.txt').read_text(encoding='utf-8-sig'),
                       release['version'])
    assert read_json(PAYLOAD / 'manifest.json')['files'] == hashes(release, require_runtime)
    assert read_json(PAYLOAD / 'manifest.json')['version'] == release['version']
    assert (PAYLOAD / config['package']).read_text(encoding='utf-8').startswith(header(config, release))
    for name in ('Install.ps1', 'Установка.txt', 'Transcriber/README_RU.txt', 'Transcriber/THIRD_PARTY_NOTICES_RU.txt'):
        assert release['version'] in (ROOT / name).read_text(encoding='utf-8-sig'), f'Version mismatch: {name}'
    assert f'local SCRIPT_VERSION = "{release["version"]}"' in (PAYLOAD / config['package']).read_text(encoding='utf-8')
    assert f"$manifest.version -ne '{release['version']}'" in (PAYLOAD / 'setup/common.ps1').read_text(encoding='utf-8-sig')
    installer_files = sorted(inventory(release) + ['manifest.json'])
    installer = (ROOT / 'Install.ps1').read_text(encoding='utf-8-sig')
    assert sha256(ROOT / 'reaimgui_install.ps1').upper() in installer
    listed = re.search(r'\$script:SetupFiles=@\((.*?)\n\)', installer, re.S)
    assert sorted(re.findall(r"'([^']+)'", listed[1])) == installer_files
    rows = dict(line.split('\t') for line in (PAYLOAD / 'manifest.tsv').read_text().splitlines())
    assert sorted(rows) == installer_files
    for name, checksum in rows.items():
        build = next((runtime for runtime in runtimes(release) if runtime['file'] == name), None)
        actual = build['sha256'] if build else sha256(PAYLOAD / name)
        assert checksum == actual, f'Stale installer checksum: {name}'
    root = ET.parse(ROOT / 'index.xml').getroot()
    assert root.get('name') == config['name'] == 'Aiwist'
    assert config['category'] == 'Transcriber'  # preserve existing action/hotkeys
    versions = root.findall(f"./category[@name='{config['category']}']/reapack[@name='{config['package']}']/version")
    assert len({v.get('name') for v in versions}) == len(versions)
    current = next(v for v in versions if v.get('name') == release['version'])
    sources = current.findall('source')
    assert len(sources) == len(package_files(release))
    assert sorted(s.get('file') for s in sources) == package_files(release)
    assert [s.get('file') for s in sources if s.get('main')] == [config['package']]
    for source in sources:
        name = safe_relative(source.get('file'))
        assert source.get('platform') == 'win64'
        assert source.text == source_url(config, release, name), name
    for path in (PAYLOAD / 'runtime').glob('**/*'):
        if path.is_file():
            assert path.relative_to(PAYLOAD).as_posix() in [runtime['file'] for runtime in runtimes(release)], f'Unexpected runtime: {path}'
    print(f"OK: Ai Transcriber {release['version']}, {len(sources)} files, CPU and Vulkan executables")


def stage_assets():
    check(require_runtime=True)
    config, release = settings()
    destination = ROOT / '.work' / 'reapack' / ('v' + release['version'])
    destination.mkdir(parents=True, exist_ok=True)
    checksums = []
    for runtime in runtimes(release):
        source = PAYLOAD / runtime['file']
        target = destination / runtime['asset']
        if target.exists():
            assert sha256(target) == runtime['sha256'], 'Refusing to replace different staged asset'
        else:
            # Save disk space on the same volume; copy where hard links are unavailable.
            try:
                os.link(source, target)
            except OSError:
                shutil.copyfile(source, target)
        checksums.append(f"{sha256(target)}  {target.name}\n")
    write(destination / 'SHA256SUMS.txt', ''.join(checksums))
    write(destination / 'RELEASE_NOTES.md', f"Ai Transcriber {release['version']} — Windows x64\n\n" +
          '\n'.join('- ' + c for c in config['changes']) +
          '\n\nInstall via ReaPack; accept licenses on first launch and download models in Settings.\n')
    print(f'Release assets prepared locally: {destination}')


def verify_remote():
    """Read-only final check, explicitly run by the publisher after publication."""
    check()
    config, release = settings()
    checksums = read_json(PAYLOAD / 'manifest.json')['files']
    checksums['manifest.json'] = sha256(PAYLOAD / 'manifest.json')
    checksums['manifest.tsv'] = sha256(PAYLOAD / 'manifest.tsv')
    for name in package_files(release):
        req = urllib.request.Request(source_url(config, release, name), headers={'User-Agent': 'AiTranscriber-release-check'})
        digest = hashlib.sha256()
        with urllib.request.urlopen(req, timeout=60) as response:
            while block := response.read(1024 * 1024):
                digest.update(block)
        assert digest.hexdigest() == checksums[name], f'Remote SHA-256 mismatch: {name}'
    print('All public package URLs and SHA-256 checksums verified.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'check', 'stage-assets', 'verify-remote'))
    parser.add_argument('--require-runtime', action='store_true')
    args = parser.parse_args()
    if args.command == 'prepare': prepare()
    elif args.command == 'check': check(args.require_runtime)
    elif args.command == 'stage-assets': stage_assets()
    else: verify_remote()


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, ValueError, ET.ParseError) as error:
        sys.exit(f'Package check failed: {error}')
