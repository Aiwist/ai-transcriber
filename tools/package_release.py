#!/usr/bin/env python3
"""Build a verified standalone ZIP from the exact ReaPack application payload."""
import argparse
import os
from pathlib import Path
import sys
import uuid
import zipfile

import reapack as package


FORBIDDEN_LIST = Path('.work/forbidden-names.txt')


def forbidden_names():
    """Личные имена, которых не должно быть в поставляемых файлах.

    Список лежит вне Git (`.work/` игнорируется): в публичном репозитории
    хранить сами имена нельзя. Нет файла — проверка пропускается.
    """
    if not FORBIDDEN_LIST.is_file():
        return ()
    names = (line.strip() for line in FORBIDDEN_LIST.read_text(encoding='utf-8').splitlines())
    return tuple(name for name in names if name and not name.startswith('#'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    package.check(require_runtime=True)
    _, release = package.settings()
    directory = args.output_dir.resolve()
    if not directory.is_dir():
        raise ValueError('Release directory must already exist')
    archive = directory / f"Ai_Transcriber_Setup_{release['version']}_Windows.zip"
    checksum_file = directory / (archive.name + '.sha256')
    if archive.exists() or checksum_file.exists():
        raise FileExistsError('Published release files are never overwritten')
    files = {f'Transcriber/{name}':package.PAYLOAD / name for name in package.package_files(release)}
    for name in ('Install.ps1','Установить.bat','reaimgui_install.ps1','reaper_actions.ps1',
                 'Установка.txt','LICENSE','CHANGELOG.md'):
        files[name] = package.ROOT / name
    checksums = {name:package.sha256(path) for name,path in files.items()}
    temporary = directory / ('.' + archive.name + '.' + uuid.uuid4().hex + '.part')
    try:
        with zipfile.ZipFile(temporary, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for name in sorted(files):
                z.write(files[name], name)
        with zipfile.ZipFile(temporary) as z:
            if sorted(z.namelist()) != sorted(files):
                raise ValueError('Incorrect archive inventory')
            engines = [name for name in z.namelist() if name.endswith('.exe')]
            expected = sorted('Transcriber/' + build['file'] for build in package.runtimes(release))
            if sorted(engines) != expected:
                raise ValueError('Archive engine set differs from ReaPack')
            for name in sorted(files):
                with z.open(name) as stream:
                    import hashlib
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                if digest != checksums[name]:
                    raise ValueError('Archive SHA-256 mismatch: ' + name)
                if name.endswith(('.txt','.lua','.md','.py','.ps1')):
                    text = z.read(name).decode('utf-8-sig')
                    for personal in forbidden_names():
                        if personal.casefold() in text.casefold():
                            raise ValueError('Unexpected personal name in ' + name)
        # Hard-link publication is atomic and refuses to replace an existing file.
        os.link(temporary, archive)
        temporary.unlink()
        digest = package.sha256(archive)
        with checksum_file.open('x', encoding='utf-8', newline='\n') as stream:
            stream.write(f'{digest}  {archive.name}\n')
        print(f'ZIP verified: {archive}')
        print(f'Files: {len(files)}; installed payload identical to ReaPack')
        print(f'Bytes: {archive.stat().st_size}; SHA-256: {digest}')
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, ValueError, zipfile.BadZipFile) as error:
        sys.exit(f'Release build failed: {error}')
