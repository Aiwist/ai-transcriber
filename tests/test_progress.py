"""Test the actual single-job polling status, including native percentages."""
from pathlib import Path
import unittest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


class ProgressTests(unittest.TestCase):
    def status(self, message, fraction):
        lua = LuaRuntime(unpack_returned_tuples=True)
        source = (ROOT / 'Transcriber/Aiwist_Transcriber.lua').read_text(encoding='utf-8-sig')
        start = source.index('poll_transcription = function()')
        end = source.index('\nfinish_transcription = function(', start)
        factory = lua.execute('''return function(heartbeat)
local state={transcribing=true,transcription_started_at=0}
local TEMP,SESSION_ID='test/','id'
local JSON={load_json=function(path) if path:find('process.json',1,true) then return heartbeat end end}
local reaper={time_precise=function()return 3 end,defer=function()end}
local tr=function()return 'Transcribing' end
local poll_transcription
''' + source[start:end] + '\npoll_transcription();return state.status end')
        return factory(lua.table_from({'message': message, 'fraction': fraction, 'updated': 0}))

    def test_percentage_is_not_duplicated(self):
        for message in ('Загрузка модели в память · 18%', 'Транскрибация · 18%'):
            with self.subTest(message=message):
                status = self.status(message, 0.18)
                self.assertEqual(status.count('%'), 1)
                self.assertTrue(status.endswith('18% · 3 s'))

    def test_percentage_is_added_when_missing(self):
        self.assertEqual(self.status('Подготовка аудио', .5), 'Подготовка аудио · 50% · 3 s')
        self.assertEqual(self.status('Подготовка аудио', None), 'Подготовка аудио · 3 s')
