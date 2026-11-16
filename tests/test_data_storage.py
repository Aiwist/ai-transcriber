"""Portable profiles exercise real Lua state I/O and the shipped setup worker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from lupa import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'Transcriber'

class StorageTests(unittest.TestCase):
    def setUp(self):
        (ROOT/'.work').mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='storage_',dir=ROOT/'.work')
        self.addCleanup(self.temp.cleanup)
        self.work=Path(self.temp.name)
        self.resource=self.work/'REAPER';self.resource.mkdir()
        self.local=self.work/'Local';self.local.mkdir()
        self.prefs={}

    def context(self,resource=None,prefs=None):
        lua=LuaRuntime(unpack_returned_tuples=True)
        J=lua.execute((APP/'lib/json.lua').read_text(encoding='utf-8-sig'))
        module=lua.execute((APP/'lib/data_storage.lua').read_text(encoding='utf-8-sig'))
        paths=lua.eval('dofile')((APP/'lib/state_paths.lua').as_posix())
        resource=resource or self.resource;prefs=self.prefs if prefs is None else prefs
        r=lua.table_from(dict(GetResourcePath=lambda:str(resource),
            GetExtState=lambda s,k:prefs.get((s,k),''),
            SetExtState=lambda s,k,v,p:prefs.__setitem__((s,k),v),
            file_exists=lambda p:Path(p).is_file(),
            RecursiveCreateDirectory=lambda p,f:Path(p).mkdir(parents=True,exist_ok=True)))
        storage,root,components,*_=module.new(r,J,'AiwistTranscriber2',str(self.local),paths)
        return lua,J,module,storage,Path(root),Path(components)

    def test_system_defaults_remain_unchanged(self):
        _,_,_,s,root,components=self.context()
        self.assertEqual(s.mode,'system')
        self.assertEqual(root,self.local/'Aiwist/Ai Transcriber')
        self.assertEqual(components,self.local/'Ai Transcriber')

    def test_portable_relocation_and_absolute_engine_config(self):
        for name in ('reaper.exe','reaper.ini'):(self.resource/name).touch()
        lua,J,_,s,root,components=self.context()
        self.assertEqual(components,root/'components')
        model=root/'components/models/small.gguf';model.parent.mkdir(parents=True);model.write_bytes(b'weights')
        value=lua.table_from(dict(weights=lua.table_from(dict(small=str(model))),
            engine=str(self.resource/'Scripts/Aiwist/Transcriber/engine.exe'),
            instruments=J.array(),silent=False,external=r'X:\External\large.gguf',null_value=J.null))
        self.assertTrue(J.save_json(str(root/'native_active.json'),value))
        self.assertTrue(J.save_json(str(root/'config.json'),value))
        raw=json.loads((root/'native_active.json').read_text())
        self.assertEqual(raw['weights']['small'],'@data/components/models/small.gguf')
        self.assertEqual(raw['instruments'],[])
        self.assertEqual(raw['null_value'],None)
        self.assertFalse(raw['silent'])
        self.assertEqual(json.loads((root/'config.json').read_text())['weights']['small'],str(model))
        moved=self.work/'Moved';shutil.copytree(self.resource,moved)
        _,J2,_,s2,newroot,_=self.context(moved)
        read=J2.load_json(str(newroot/'native_active.json'),None)
        self.assertEqual(read.weights.small,str(newroot/'components/models/small.gguf'))
        self.assertTrue(Path(read.weights.small).is_file())
        self.assertTrue(read.engine.startswith(str(moved)))
        self.assertEqual(read.external,r'X:\External\large.gguf')

    def test_custom_folder_uses_relative_profile_preference(self):
        lua,J,module,s,_,_=self.context()
        pref=s.preference(s,str(self.resource/'Data/Custom'),'custom')
        self.assertTrue(pref.relative)
        self.assertEqual(pref.path,r'Data\Custom')
        self.prefs[('AiwistTranscriber2','data_storage_v1')]=J.encode(pref)
        _,_,_,s2,root,_=self.context()
        self.assertEqual(s2.mode,'custom');self.assertEqual(root,self.resource/'Data/Custom')
        with self.assertRaises(Exception):s2.expand(s2,'@data/../outside')

    def test_unavailable_folder_can_be_reselected_at_startup(self):
        lua,J,module,_,_,_=self.context()
        selected=self.resource/'Recovered'
        r=lua.table_from(dict(GetResourcePath=lambda:str(self.resource),GetExtState=lambda s,k:'',
            SetExtState=lambda s,k,v,p:self.prefs.__setitem__((s,k),v),MB=lambda *a:6,
            GetUserInputs=lambda *a:(True,str(selected)),genGuid=lambda:'ABCD',
            RecursiveCreateDirectory=lambda p,f:Path(p).mkdir(parents=True,exist_ok=True)))
        self.assertTrue(module.recover(r,J,'AiwistTranscriber2','unavailable'))
        pref=json.loads(self.prefs[('AiwistTranscriber2','data_storage_v1')])
        self.assertEqual(pref['path'],'Recovered');self.assertTrue(pref['relative'])
        _,_,_,_,root,_=self.context()
        self.assertEqual(root,selected)

    def powershell(self,code):
        environment={k:v for k,v in os.environ.items() if k.upper()!='PSMODULEPATH'}
        p=subprocess.run(['powershell','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',code],
                         env=environment,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr.decode(errors='replace'))
        return p.stdout.decode(encoding='utf-8-sig',errors='replace')

    def migrate(self,source,target,mode='custom',reuse=False):
        job_id='0123456789ABCDEF0123456789ABCDEF'
        directory=source/'jobs'/job_id;directory.mkdir(parents=True,exist_ok=True)
        (directory/'job.json').write_text(json.dumps(dict(schema=1,id=job_id,action='native_storage_migrate',
            resource_root=str(self.resource),target_root=str(target),storage_mode=mode,reuse_existing=reuse,runtime_instance='TEST')))
        script=APP/'setup/worker.ps1'
        self.powershell(f"$ErrorActionPreference='Stop'; & '{script}' -Config '{directory/'job.json'}' -StateRoot '{source}'")
        return json.loads((directory/'result.json').read_text(encoding='utf-8-sig'))

    @unittest.skipUnless(shutil.which('powershell'),'Windows PowerShell required')
    def test_worker_migration_and_codec(self):
        lua,J,_,s,source,_=self.context()
        (source/'audio.wav').write_bytes(bytes(range(256))*4096)
        runtime=self.work/'Old models/runtimes/transkun-1.0.0';runtime.mkdir(parents=True)
        (runtime/'host.dll').write_bytes(b'environment')
        J.save_json(str(source/'native_active.json'),lua.table_from(dict(
            weights=lua.table_from(dict(small=str(self.work/'External/small.gguf'))),
            transkun=lua.table_from(dict(runtime=str(runtime),dotnet=str(runtime/'dotnet/dotnet.exe'))),
            instruments=J.array())))
        J.save_json(str(source/'last_result.json'),lua.table_from(dict(file=str(source/'audio.wav'))))
        J.save_json(str(source/'config.json'),lua.table_from(dict(file=str(source/'audio.wav'),instruments=J.array())))
        target=self.resource/'Data/Chosen'
        result=self.migrate(source,target)
        self.assertTrue(result['ok'],result)
        self.assertEqual((target/'audio.wav').read_bytes(),(source/'audio.wav').read_bytes())
        self.assertTrue((runtime/'host.dll').exists())
        self.assertTrue((target/'runtimes/transkun-1.0.0/host.dll').exists())
        native=json.loads((target/'native_active.json').read_text())
        self.assertEqual(native['instruments'],[])
        self.assertEqual(native['transkun']['runtime'],'@data/runtimes/transkun-1.0.0')
        self.assertEqual(json.loads((target/'config.json').read_text())['file'],str(target/'audio.wav'))
        common=APP/'setup/common.ps1'
        code=f"""$ErrorActionPreference='Stop'; . '{common}';
$v=Read-AitJson '{target/'native_active.json'}';
if($v.transkun.runtime -ne '{target/'runtimes/transkun-1.0.0'}'){{throw 'Runtime was not resolved'}};
Write-AitJson '{target/'roundtrip.json'}' $v;
Write-AitJson '{target/'config.json'}' $v;
"""
        self.powershell(code)
        self.assertEqual(json.loads((target/'roundtrip.json').read_text())['transkun']['runtime'],'@data/runtimes/transkun-1.0.0')
        self.assertEqual(json.loads((target/'config.json').read_text())['transkun']['runtime'],str(target/'runtimes/transkun-1.0.0'))

    @unittest.skipUnless(shutil.which('powershell'),'Windows PowerShell required')
    def test_migration_refuses_collisions_and_busy_sessions(self):
        _,_,_,_,source,_=self.context()
        (source/'keep.txt').write_text('source')
        target=self.work/'target';target.mkdir();(target/'keep.txt').write_text('different')
        result=self.migrate(source,target)
        self.assertFalse(result['ok']);self.assertIn('AITN-716',result['error']['detail'])
        self.assertEqual((target/'keep.txt').read_text(),'different')
        self.assertEqual((source/'keep.txt').read_text(),'source')
        import time
        session=source/'runtime_temp/another';session.mkdir(parents=True)
        (session/'session.json').write_text(json.dumps(dict(id='OTHER',updated=int(time.time()),busy=True,closed=False)))
        result=self.migrate(source,self.work/'newtarget')
        self.assertFalse(result['ok']);self.assertIn('AITN-712',result['error']['detail'])

    @unittest.skipUnless(shutil.which('powershell'),'Windows PowerShell required')
    def test_reopen_existing_store_without_overwriting(self):
        _,_,_,_,source,_=self.context()
        (source/'keep.txt').write_text('current')
        target=self.work/'Previous';target.mkdir()
        (target/'keep.txt').write_text('previous')
        (target/'.storage_context.json').write_text(json.dumps(dict(schema=1,mode='custom',resource_root=str(self.resource),data_root=str(target))))
        result=self.migrate(source,target,reuse=True)
        self.assertTrue(result['ok'],result);self.assertEqual(result['files'],0)
        self.assertEqual((target/'keep.txt').read_text(),'previous')
        self.assertEqual((source/'keep.txt').read_text(),'current')
