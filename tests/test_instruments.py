"""Instrument selection must reach the engine as an array, including auto mode."""
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / 'Transcriber'


class InstrumentTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.json = self.lua.execute((PAYLOAD / 'lib/json.lua').read_text(encoding='utf-8-sig'))
        source = (PAYLOAD / 'Aiwist_Transcriber.lua').read_text(encoding='utf-8-sig')
        instruments = re.search(r'local INSTRUMENTS = (\{.*?\n\})', source, re.S).group(1)
        getter = re.search(r'local function get_selected_instruments\(\).*?\nend', source, re.S).group()
        factory = self.lua.execute('return function(JSON, state) local INSTRUMENTS = ' + instruments + '\n' + getter + '\nreturn get_selected_instruments end')
        self.state = self.lua.table_from({'instruments': self.lua.table()})
        self.selected = factory(self.json, self.state)

    def config(self, keys):
        self.state.instruments = self.lua.table_from({key: True for key in keys})
        return json.loads(self.json.encode(self.lua.table_from({'instruments': self.selected()})))

    def test_no_selection_uses_automatic_detection(self):
        self.assertEqual(self.config([]), {'instruments': []})

    def test_explicit_selection_and_clearing(self):
        self.assertEqual(self.config(['acoustic_guitar']), {'instruments': ['acoustic_guitar']})
        self.assertEqual(self.config(['electric_bass', 'acoustic_guitar']),
                         {'instruments': ['acoustic_guitar', 'electric_bass']})
        self.assertEqual(self.config([]), {'instruments': []})

    def test_engine_accepts_auto_and_selected_instruments(self):
        release = json.loads((PAYLOAD / 'native_release.json').read_text(encoding='utf-8-sig'))
        engines = [PAYLOAD / release[key]['file'] for key in ('cpu_runtime', 'runtime')]
        if not all(engine.exists() for engine in engines):
            self.skipTest('Engines are separate release assets')
        (ROOT / '.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='Instruments_', dir=ROOT / '.work') as temporary:
            work = Path(temporary)
            wav = work / 'input.wav'
            with wave.open(str(wav), 'wb') as stream:
                stream.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
                stream.writeframes(b'\0\0' * 4410)
            for engine in engines:
                for keys in ([], ['acoustic_guitar'], ['acoustic_guitar', 'electric_bass']):
                    with self.subTest(engine=engine.parent.name, instruments=keys):
                        config = self.config(keys)
                        config.update(wav_path=str(wav), item_length=0.1, padding_seconds=1)
                        path = work / 'config.json'
                        path.write_text(json.dumps(config), encoding='utf-8')
                        result = subprocess.run([str(engine), '--config', str(path), '--out',
                                                 str(work / 'result.mid'), '--prepare-only'],
                                                capture_output=True, timeout=20,
                                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                        info = json.loads((work / 'audio_info.json').read_text(encoding='utf-8-sig'))
                        self.assertEqual(info['sample_rate'], 16000)
                        self.assertGreater((work / 'prepared_16000.wav').stat().st_size, 44)


if __name__ == '__main__':
    unittest.main()
