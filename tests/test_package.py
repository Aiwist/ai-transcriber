"""Offline checks: fresh ReaPack layout, integrity failure and Lua first launch."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package', ROOT / 'tools/reapack.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_manifest_and_reapack_inventory(self):
        package.check()

    def test_stale_license_version_is_rejected(self):
        _, release = package.settings()
        sheet = (package.PAYLOAD / 'INSTALL_LICENSES_RU.txt').read_text(encoding='utf-8-sig')
        notices = (package.PAYLOAD / 'THIRD_PARTY_NOTICES_RU.txt').read_text(encoding='utf-8-sig')
        package.check_notice_sheet(sheet, notices, release['version'])
        stale = sheet.replace('Версия: ' + release['version'], 'Версия: 0.0.0', 1)
        self.assertNotEqual(stale, sheet)
        with self.assertRaisesRegex(AssertionError, 'stale'):
            package.check_notice_sheet(stale, notices, release['version'])
        with self.assertRaisesRegex(AssertionError, 'version'):
            package.check_notice_sheet(stale, notices.replace('Версия: ' + release['version'], 'Версия: 0.0.0'), release['version'])

    def test_all_lua_syntax(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        load = lua.eval('function(code, name) local f,e=load(code,name); assert(f,e) end')
        for path in (ROOT / 'Transcriber').rglob('*.lua'):
            load(path.read_text(encoding='utf-8-sig'), str(path))

    def test_first_run_and_minimized_window(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().project_root = ROOT.as_posix()
        lua.execute((ROOT / 'tests/first_run.lua').read_text(encoding='utf-8'))

    @unittest.skipUnless(shutil.which('powershell'), 'Windows PowerShell required')
    def test_bat_installer_source_integrity(self):
        _, release = package.settings()
        if not (package.PAYLOAD / release['runtime']['file']).exists():
            self.skipTest('Engine is a separate release asset')
        environment = {k:v for k,v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
        code = ". './Install.ps1' -LibraryOnly; $files=Get-SetupPayload (Join-Path (Get-Location) 'Transcriber'); Write-Output ('INSTALLER_PAYLOAD_OK '+$files.Count)"
        result = subprocess.run(['powershell', '-NoLogo', '-NoProfile', '-NonInteractive',
                                 '-ExecutionPolicy', 'Bypass', '-Command', code],
                                cwd=ROOT, env=environment, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        expected = len(package.package_files(release))
        self.assertIn(f'INSTALLER_PAYLOAD_OK {expected}'.encode(), result.stdout)

    @unittest.skipUnless(shutil.which('powershell'), 'Windows PowerShell required')
    def test_bat_and_reapack_install_identical_files(self):
        _, release = package.settings()
        if not all((package.PAYLOAD / build['file']).exists() for build in package.runtimes(release)):
            self.skipTest('Engines are separate release assets')
        (ROOT / '.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='Installer_Сверка_', dir=ROOT / '.work') as temporary:
            resource = Path(temporary)
            (resource / 'reaper.ini').write_text('[REAPER]\n')
            code = r'''param([string]$Resource)
$ErrorActionPreference='Stop'
. './Install.ps1' -LibraryOnly
function Assert-SetupIdle {}
function Ensure-SetupReaImGui {
  param($Path,$OnProgress)
  $script:DependencyCalled=$true
  return [pscustomobject]@{Changed=$false;RestartRequired=$false}
}
$result=Install-AiTranscriber -ResourcePath $Resource
if(-not $script:DependencyCalled){throw 'Dependency installation was skipped'}
Write-Output ('INSTALLED '+$result.Files)
'''
            script = resource / 'install-test.ps1'
            script.write_text(code, encoding='utf-8-sig')
            environment = {k:v for k,v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
            result = subprocess.run(['powershell','-NoLogo','-NoProfile','-NonInteractive',
                                     '-ExecutionPolicy','Bypass','-File',str(script),str(resource)],
                                    cwd=ROOT, env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            installed = resource / 'Scripts/Aiwist/Transcriber'
            actual = sorted(p.relative_to(installed).as_posix() for p in installed.rglob('*') if p.is_file())
            self.assertEqual(actual, package.package_files(release))
            for name in actual:
                self.assertEqual(package.sha256(installed / name), package.sha256(package.PAYLOAD / name), name)

    @unittest.skipUnless(shutil.which('powershell'), 'Windows PowerShell required')
    def test_clean_install_and_corrupt_file(self):
        config, release = package.settings()
        engine = package.PAYLOAD / release['runtime']['file']
        if not engine.exists():
            self.skipTest('Engine is a separate release asset; local strict check required')
        (ROOT / '.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='AiTranscriber_Кириллица_', dir=ROOT / '.work') as temporary:
            # ReaPack constructs exactly this path from index name/category.
            destination = Path(temporary) / 'Scripts/Aiwist/Transcriber'
            for name in package.package_files(release):
                source, target = package.PAYLOAD / name, destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            script = Path(temporary) / 'check.ps1'
            script.write_text("param([string]$Root)\n$ErrorActionPreference='Stop'\n. (Join-Path $Root 'setup/common.ps1')\nTest-AitPayload $Root\n'PAYLOAD_OK'\n", encoding='utf-8-sig')
            command = ['powershell', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(destination)]
            # Windows PowerShell must use its own module path, not one inherited
            # from the PowerShell 7 development terminal.
            environment = {k:v for k,v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
            good = subprocess.run(command, capture_output=True, env=environment)
            self.assertEqual(good.returncode, 0, good.stderr.decode(errors='replace'))
            self.assertIn(b'PAYLOAD_OK', good.stdout)
            target = destination / 'lib/first_run.lua'
            target.write_bytes(target.read_bytes() + b'\n-- damaged after download\n')
            bad = subprocess.run(command, capture_output=True, env=environment)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn(b'AIT2-120', bad.stderr)


if __name__ == '__main__':
    unittest.main()
