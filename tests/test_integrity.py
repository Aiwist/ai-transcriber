"""A ReaPack-style install must repair inherited Low labels before engine use."""
import json
import ctypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def integrity_label(path):
    from ctypes import wintypes as W
    api = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    get = api.GetNamedSecurityInfoW
    get.argtypes = [W.LPWSTR, W.DWORD, W.DWORD, ctypes.c_void_p, ctypes.c_void_p,
                   ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    get.restype = W.DWORD
    convert = api.ConvertSecurityDescriptorToStringSecurityDescriptorW
    convert.argtypes = [ctypes.c_void_p, W.DWORD, W.DWORD, ctypes.POINTER(W.LPWSTR), ctypes.POINTER(W.DWORD)]
    convert.restype = W.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    descriptor, text, size = ctypes.c_void_p(), W.LPWSTR(), W.DWORD()
    error = get(str(path), 1, 16, None, None, None, None, ctypes.byref(descriptor))
    if error:
        raise ctypes.WinError(error)
    try:
        if not convert(descriptor, 1, 16, ctypes.byref(text), ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        return text.value
    finally:
        if text:
            kernel.LocalFree(text)
        if descriptor:
            kernel.LocalFree(descriptor)


@unittest.skipUnless(os.name == 'nt' and shutil.which('powershell'), 'Windows required')
class IntegrityTests(unittest.TestCase):
    def test_reapack_launcher_repairs_low_integrity(self):
        release = json.loads((ROOT / 'Transcriber/native_release.json').read_text(encoding='utf-8-sig'))
        if not (ROOT / 'Transcriber' / release['runtime']['file']).exists():
            self.skipTest('Engines are separate release assets')
        (ROOT / '.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='ReaPack_Integrity_', dir=ROOT / '.work') as directory:
            base = Path(directory)
            app = base / 'Scripts/Aiwist/Transcriber'
            shutil.copytree(ROOT / 'Transcriber', app)
            state = base / 'state'
            job_id = '0123456789ABCDEF0123456789ABCDEF'
            work = state / 'runtime_temp' / job_id
            work.mkdir(parents=True)
            (work / 'request.json').write_text(json.dumps({'schema': 1, 'id': job_id,
                'engine': 'native', 'output': 'muscriptor_result_1.mid'}), encoding='utf-8')
            cpu = app / release['cpu_runtime']['file']
            env = {k:v for k,v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
            medium = subprocess.run(['icacls', str(base), '/setintegritylevel', '(OI)(CI)M'], capture_output=True)
            self.assertEqual(medium.returncode, 0)
            low = subprocess.run(['icacls', str(app), '/setintegritylevel', '(OI)(CI)L', '/T'], capture_output=True)
            self.assertEqual(low.returncode, 0, low.stdout.decode(errors='replace'))
            for key in ('cpu_runtime', 'runtime'):
                low = subprocess.run(['icacls', str(app / release[key]['file']), '/setintegritylevel', 'L'], capture_output=True)
                self.assertEqual(low.returncode, 0)
            self.assertIn(';;;LW)', integrity_label(cpu))
            # Use the actual ReaPack launcher. Check mode never starts inference.
            run = subprocess.run(['powershell', '-NoLogo', '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass', '-File', str(app / 'setup/launch_process.ps1'),
                '-WorkDir', str(work), '-StateRoot', str(state), '-Mode', 'Check'],
                env=env, capture_output=True, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(run.returncode, 0, run.stdout.decode(errors='replace'))
            pid = re.search(rb'AIT2LAUNCH:[A-Fa-f0-9]+:(\d+)', run.stdout)
            self.assertIsNotNone(pid)
            wait = subprocess.run(['powershell', '-NoLogo', '-NoProfile', '-NonInteractive',
                '-Command', '$p=Get-Process -Id '+pid[1].decode()+
                ' -ErrorAction SilentlyContinue;if($p){[void]$p.WaitForExit(15000)}'],
                env=env, capture_output=True, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(wait.returncode, 0)
            self.assertIn(';;;ME)', integrity_label(cpu))
            self.assertNotIn(';;;LW)', integrity_label(cpu))
            after = subprocess.run([str(cpu), '--devices', '--out', str(base / 'after.json')],
                                   capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=15)
            self.assertEqual(after.returncode, 0, after.stderr.decode(errors='replace'))
            self.assertTrue((base / 'after.json').is_file())
