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
        # Execute the actual single-transcription entry point, including its
        # config.json writer. Testing JSON.encode alone missed the old encoder.
        start = source.index('local function start_transcription(prepared_sources)')
        stop = source.index('\npoll_transcription = function()', start)
        writer = source[start:stop]
        legacy = ''
        if 'local function json_encode(val)' in source:
            legacy = source[source.index('local function json_encode(val)'):source.index('\nlocal function copy_file')]
        (ROOT / '.work').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='Single_Transcription_', dir=ROOT / '.work')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.state = self.lua.table_from({'instruments': self.lua.table(), 'model_idx': 1,
                                         'item_len': 0.1, 'item_name': 'audio.wav'})
        factory = self.lua.execute('''return function(JSON, state, work)
local INSTRUMENTS = ''' + instruments + '''
local MODELS = {'small'}
local TEMP = work .. '/'
local SINGLE_RECORD = work .. '/single_job.json'
local SCRIPT_VERSION = 'test'
local SESSION_ID = '0123456789ABCDEF0123456789ABCDEF'
local STATE_ROOT, script_dir, ENGINE = work, work, nil
local COMPONENTS = {engine=function() return 'engine.exe' end,busy=function() return false end}
local DEVICE_PICKER = {mode='auto',snapshot=function() return {} end}
local configured_model_weights = function() return 'small.gguf' end
local cleanup_audio_preparation = function() end
local tr = function(key) return key end
local reaper = {GetProjectPath=function() return work end,RecursiveCreateDirectory=function() end,
    time_precise=function() return 0 end,defer=function() end}
local launched = 0
local HiddenRunner = {launch=function() launched=launched+1 end}
''' + getter + '\n' + legacy + '\n' + writer + '''
return function(sources)
    launched=0
    start_transcription(sources)
    assert(launched==1, state.status)
    return state.pending_cfg
end
end''')
        self.start = factory(self.json, self.state, self.work.as_posix())

    def config(self, keys, wav=None):
        self.state.instruments = self.lua.table_from({key: True for key in keys})
        record = self.lua.table_from({'source_path': str(wav or self.work / 'audio.wav'),
                                      'start_offset': 0, 'playrate': 1, 'timeline_position': 0,
                                      'temporary_reaper_render': True, 'rendered_frames': 4410})
        self.config_path = Path(self.start(self.lua.table_from([record])))
        return json.loads(self.config_path.read_text(encoding='utf-8-sig'))

    def test_no_selection_uses_automatic_detection(self):
        self.assertEqual(self.config([])['instruments'], [])

    def test_explicit_selection_and_clearing(self):
        self.assertEqual(self.config(['acoustic_guitar'])['instruments'], ['acoustic_guitar'])
        self.assertEqual(self.config(['electric_bass', 'acoustic_guitar'])['instruments'],
                         ['acoustic_guitar', 'electric_bass'])
        self.assertEqual(self.config([])['instruments'], [])

    def test_written_config_preserves_source_paths(self):
        wav = self.work / 'Аудио с пробелами.wav'
        cfg = self.config([], wav)
        self.assertEqual(cfg['wav_path'], str(wav))
        self.assertEqual(cfg['sources'][0]['source_path'], str(wav))
        self.assertEqual(cfg['sources'][0]['rendered_frames'], 4410)
        self.assertEqual(cfg['instruments'], [])

    def test_engine_accepts_auto_and_selected_instruments(self):
        release = json.loads((PAYLOAD / 'native_release.json').read_text(encoding='utf-8-sig'))
        engines = [PAYLOAD / release[key]['file'] for key in ('cpu_runtime', 'runtime')]
        if not all(engine.exists() for engine in engines):
            self.skipTest('Engines are separate release assets')
        with tempfile.TemporaryDirectory(prefix='Engine_', dir=self.work) as temporary:
            work = Path(temporary)
            wav = work / 'input.wav'
            with wave.open(str(wav), 'wb') as stream:
                stream.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
                stream.writeframes(b'\0\0' * 4410)
            for engine in engines:
                for keys in ([], ['acoustic_guitar'], ['acoustic_guitar', 'electric_bass']):
                    with self.subTest(engine=engine.parent.name, instruments=keys):
                        self.config(keys, wav)
                        # Pass the exact Lua-written file to the engine, without
                        # parsing and reserializing it through Python.
                        result = subprocess.run([str(engine), '--config', str(self.config_path), '--out',
                                                 str(self.work / 'result.mid'), '--prepare-only'],
                                                capture_output=True, timeout=20,
                                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                        info = json.loads((self.work / 'audio_info.json').read_text(encoding='utf-8-sig'))
                        self.assertEqual(info['sample_rate'], 16000)
                        self.assertGreater((self.work / 'prepared_16000.wav').stat().st_size, 44)


if __name__ == '__main__':
    unittest.main()
