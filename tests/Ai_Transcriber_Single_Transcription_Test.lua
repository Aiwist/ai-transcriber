-- @description Ai Transcriber: single transcription protocol and write test
-- Reads the current project only. Writes to its own runtime_temp test directory.
local r=reaper
local app=r.GetResourcePath()..'/Scripts/Aiwist/Transcriber'
local J=dofile(app..'/lib/json.lua')
local source=assert(J.read(app..'/Aiwist_Transcriber.lua')):gsub('\r\n','\n')
local real_project=r.EnumProjects(-1,'')
local before={tracks=r.CountTracks(real_project),items=r.CountMediaItems(real_project),changes=r.GetProjectStateChangeCount(real_project)}
local paths=dofile(app..'/lib/windows_paths.lua')
local local_data=assert(paths.local_app_data(r,J,'AiwistTranscriber2'))
local root=local_data..'/Aiwist/Ai Transcriber'
local id=r.genGuid():gsub('[^%x]','')
local work=root..'/runtime_temp/'..id
r.RecursiveCreateDirectory(work,0)
local report={test='single_transcription',work=work,version=source:match('%-%- @version ([^\n]+)'),cases={}}
local function finish(ok,problem)
  report.ok=ok;report.error=problem and tostring(problem)or nil
  report.project_unchanged=r.EnumProjects(-1,'')==real_project and r.CountTracks(real_project)==before.tracks and r.CountMediaItems(real_project)==before.items and r.GetProjectStateChangeCount(real_project)==before.changes
  J.save_json(work..'/test_report.json',report)
  r.SetExtState('reaper_mcp_script_result','last_result',J.encode(report),false)
end
local ok,err=xpcall(function()
  local a=assert(source:find('local function start_transcription(prepared_sources)',1,true))
  local b=assert(source:find('\npoll_transcription = function()',a,true))
  local getter=assert(source:match('(local function get_selected_instruments%(%)\n.-\nend)'))
  local instrument_list=assert(source:match('local INSTRUMENTS = (%{.-\n%})'))
  local legacy=''
  local la=source:find('local function json_encode(val)',1,true)
  if la then legacy=source:sub(la,assert(source:find('\nlocal function copy_file',la,true))-1)end
  local code='return function(JSON,state,work,app)\n'..
    'local INSTRUMENTS='..instrument_list..'\n'..
    [[local MODELS={'small'}
local SCRIPT_VERSION='test'
local TEMP=work..'/'
local SINGLE_RECORD=work..'/single_job.json'
local SESSION_ID=']]..id..[['
local STATE_ROOT,script_dir,ENGINE=work,app,nil
local COMPONENTS={engine=function()return app..'/engine.exe'end,busy=function()return false end}
local DEVICE_PICKER={mode='auto',snapshot=function()return {}end}
local configured_model_weights=function()return 'small.gguf'end
local cleanup_audio_preparation=function()end
local tr=function(k)return k end
local reaper={GetProjectPath=function()return work end,RecursiveCreateDirectory=function()end,time_precise=function()return 0 end,defer=function()end}
local launches=0
local HiddenRunner={launch=function()launches=launches+1 end}
]]..getter..'\n'..legacy..'\n'..source:sub(a,b-1)..[[
return function(sources)
 launches=0;start_transcription(sources);assert(launches==1,state.status)
 return state.pending_cfg
end
end]]
  local state={instruments={},model_idx=1,item_len=.1,item_name='test.wav'}
  local start=assert(load(code,'single_transcription_test'))()(J,state,work,app)
  local wav=work..'/input.wav'
  local pcm=string.rep(string.pack('<i2',0),4410)
  local header='RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,1,44100,88200,2,16)..'data'..string.pack('<I4',#pcm)
  assert(J.write(wav,header..pcm))
  local sources={{source_path=wav,start_offset=0,playrate=1,timeline_position=0,temporary_reaper_render=true,rendered_frames=4410}}
  local pa=assert(source:find('poll_transcription = function()',1,true))
  local pb=assert(source:find('\nfinish_transcription = function(',pa,true))
  local progress_code=[[return function()
local state={transcribing=true,transcription_started_at=0}
local TEMP,SESSION_ID='test/','id'
local JSON={load_json=function(path)if path:find('process.json',1,true)then return {message='Загрузка модели в память · 18%',fraction=.18,updated=0}end end}
local reaper={time_precise=function()return 3 end,defer=function()end}
local tr=function()return 'Transcribing'end
local poll_transcription
]]..source:sub(pa,pb-1)..'\npoll_transcription();return state.status end'
  report.progress_status=assert(load(progress_code,'single_progress_test'))()()
  local _,percents=report.progress_status:gsub('%%','')
  assert(percents==1,'Duplicate progress percentage: '..report.progress_status)
  local release=assert(J.load_json(app..'/native_release.json'))
  local function quote(s)assert(not s:find('"',1,true));return '"'..s..'"'end
  for _,keys in ipairs({{}, {'acoustic_guitar'}})do
    state.instruments={};for _,key in ipairs(keys)do state.instruments[key]=true end
    local cfg_path=start(sources)
    local raw=assert(J.read(cfg_path));local cfg=J.decode(raw)
    assert(J.encode(cfg.instruments):sub(1,1)=='[','Instrument list was written as an object: '..raw)
    for _,build in ipairs({release.cpu_runtime,release.runtime})do
      local command=quote(app..'/'..build.file)..' --config '..quote(cfg_path)..' --out '..quote(work..'/result.mid')..' --prepare-only'
      local result=r.ExecProcess(command,15000)
      local exit=tonumber(tostring(result):match('^(%-?%d+)'))
      report.cases[#report.cases+1]={instruments=J.array(keys),engine=build.asset,exit_code=exit,output=tostring(result):sub(1,1200)}
      assert(exit==0,'Engine write/prepare failed: '..tostring(result))
      assert(J.read(work..'/native_progress.json'),'Engine did not create progress file')
      assert(J.read(work..'/prepared_16000.wav'),'Engine did not create prepared audio')
    end
  end
end,debug.traceback)
finish(ok,ok and nil or err)
