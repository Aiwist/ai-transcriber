-- Isolated profiles only. No project changes, downloads, model inference or real preferences.
local projects={'D:/!Studio/Reaper/Scripts/Ai Transcriber','D:/!Studio/Reaper/Scripts/Ai Transcriber Plus'}
local r=reaper
local work=projects[1]..'/.work/REAPER_Portable_'..r.genGuid():gsub('[^%x]','')
r.RecursiveCreateDirectory(work,0)
local J=dofile(projects[1]..'/Transcriber/lib/json.lua')
local before={project=r.EnumProjects(-1,''),changes=r.GetProjectStateChangeCount(0),tracks=r.CountTracks(0),items=r.CountMediaItems(0)}
local results={};local context;local index=0;local current;local started=r.time_precise()
local function write(path,value)
  r.RecursiveCreateDirectory(path:match('^(.*)[/\\]'),0)
  assert(J.write(path,value))
end
local function copy_tree(source,target)
  r.RecursiveCreateDirectory(target,0)
  local i=0
  while true do local name=r.EnumerateFiles(source,i);if not name then break end;assert(J.copy(source..'/'..name,target..'/'..name));i=i+1 end
  i=0
  while true do local name=r.EnumerateSubdirectories(source,i);if not name then break end;copy_tree(source..'/'..name,target..'/'..name);i=i+1 end
end
local function finish(problem)
  if context and r.ImGui_DestroyContext then pcall(r.ImGui_DestroyContext,context)end
  local unchanged=r.EnumProjects(-1,'')==before.project and r.GetProjectStateChangeCount(0)==before.changes and r.CountTracks(0)==before.tracks and r.CountMediaItems(0)==before.items
  local result={ok=not problem and unchanged,error=problem,project_unchanged=unchanged,cases=J.array(results),work=work}
  J.save_json(work..'/report.json',result)
  r.SetExtState('reaper_mcp_script_result','last_result',J.encode(result),false)
end
local function begin_case()
  index=index+1
  if not projects[index]then finish();return false end
  local app=projects[index]..'/Transcriber'
  local resource=work..'/Edition'..index..'/USB A'
  write(resource..'/reaper.exe','fixture');write(resource..'/reaper.ini','[reaper]\n')
  local prefs={};local proxy=setmetatable({}, {__index=r})
  proxy.GetResourcePath=function()return resource end
  proxy.GetExtState=function(s,k)return prefs[s..':'..k]or''end
  proxy.SetExtState=function(s,k,v,p)prefs[s..':'..k]=v end
  proxy.MB=function()return 1 end -- Approve the test's isolated copy, never real settings.
  local json=dofile(app..'/lib/json.lua')
  local Storage=dofile(app..'/lib/data_storage.lua')
  local storage,root,components=Storage.new(proxy,json,'AiwistTranscriber2',work..'/Local'..index,dofile(app..'/lib/state_paths.lua'))
  assert(storage.mode=='portable');assert(root==resource:gsub('/','\\')..'\\Data\\Ai Transcriber')
  write(root..'/components/models/test.gguf','GGUF-fixture')
  write(root..'/audio.wav',string.rep('audio',2048))
  local native={schema=1,weights={small=root..'\\components\\models\\test.gguf'},components_root=components}
  if index==2 then
    local runtime=resource:gsub('/','\\')..'\\OldModels\\runtimes\\transkun-1.0.0'
    write(runtime..'/dotnet/dotnet.exe','fixture');write(runtime..'/onnxruntime.dll','fixture')
    native.transkun={schema=1,version='1.0.0',runtime=runtime,dotnet=runtime..'\\dotnet\\dotnet.exe',models=components..'\\models\\Transkun'}
  end
  assert(json.save_json(root..'\\native_active.json',native))
  assert(json.save_json(root..'\\onboarding.json',{schema=1,intro_seen=true}))
  assert(json.save_json(root..'\\last_result.json',{schema=1,file=root..'\\audio.wav'}))
  assert(json.save_json(root..'\\config.json',{schema=1,input_wav=root..'\\audio.wav',instruments=json.array()}))
  local owner=dofile(app..'/lib/native_components.lua').new(proxy,app,root,json,nil,components,components)
  owner.data_storage=storage;owner.support_instance='TEST';owner.language='ru'
  local destination=resource..'/Мои данные'
  current={app=app,json=json,storage=storage,root=root,resource=resource,prefs=prefs,proxy=proxy,owner=owner,target=destination,started=r.time_precise(),frames=0}
  return true
end
local function frame()
  local ok,problem=xpcall(function()
    if not current and not begin_case()then return end
    local c=current
    if not context then context=r.ImGui_CreateContext('Ai Transcriber — проверка портативных данных')end
    r.ImGui_SetNextWindowSize(context,620,420,r.ImGui_Cond_FirstUseEver())
    local visible=r.ImGui_Begin(context,'Ai Transcriber — проверка портативных данных',true)
    if visible then
      r.ImGui_Text(context,index==1 and'Базовая редакция: изолированный профиль'or'Полная редакция: изолированный профиль')
      r.ImGui_SetNextItemOpen(context,true,r.ImGui_Cond_Always())
      c.storage:draw(c.owner,context,false,'ru')
      if c.owner.job then c.owner:draw_progress(context)end
      r.ImGui_TextWrapped(context,'Проект, реальные настройки и установленные модели не изменяются.')
    end
    r.ImGui_End(context)
    c.frames=c.frames+1
    if not c.requested and c.frames>=3 then
      assert(c.storage:request(c.owner,c.target,'custom',false));assert(c.owner.job);c.requested=true
    end
    c.owner:poll()
    if c.requested and not c.owner.job then
      assert(c.owner.result and c.owner.result.ok,c.json.encode(c.owner.result or{}))
      assert(c.owner.restart_required and c.owner:busy())
      local pref=c.json.decode(c.prefs['AiwistTranscriber2:data_storage_v1'])
      assert(pref.relative and pref.path=='Мои данные')
      local relocated=work..'/Edition'..index..'/USB B'
      copy_tree(c.resource,relocated)
      c.proxy.GetResourcePath=function()return relocated end
      -- Reopen with a fresh JSON module, exactly as the next script process would.
      local nextJson=dofile(c.app..'/lib/json.lua')
      local Storage=dofile(c.app..'/lib/data_storage.lua')
      local nextStorage,nextRoot=Storage.new(c.proxy,nextJson,'AiwistTranscriber2',work..'/Local'..index,dofile(c.app..'/lib/state_paths.lua'))
      local active=nextJson.load_json(nextRoot..'\\native_active.json',{})
      assert(r.file_exists(active.weights.small),'Model path did not relocate')
      assert(active.weights.small:sub(1,#nextRoot)==nextRoot)
      assert(r.file_exists(nextJson.load_json(nextRoot..'\\last_result.json',{}).file))
      local raw=assert(J.read(nextRoot..'\\config.json'))
      assert(not raw:find('@data/',1,true),'Relative path leaked into engine configuration')
      assert(J.read(c.root..'\\audio.wav')==J.read(nextRoot..'\\audio.wav'),'Copy differs')
      if index==2 then assert(r.file_exists(active.transkun.dotnet));assert(active.transkun.runtime:sub(1,#nextRoot)==nextRoot)end
      -- Prepare audio with both real executables after relocation. No model is loaded.
      local wav=nextRoot..'\\проверка звука.wav'
      assert(J.write(wav,J.wav_header(4410,44100,1)..string.rep(string.pack('<i2',0),4410)))
      local cfg={wav_path=wav,sources=nextJson.array({{source_path=wav,start_offset=0,playrate=1,timeline_position=0,temporary_reaper_render=true,rendered_frames=4410}}),
        model='small',model_weights_path=active.weights.small,device='cpu',padding_seconds=1,item_length=.1,
        audio_preparation='reaper-float-wav-v1',instruments=nextJson.array()}
      assert(nextJson.save_json(nextRoot..'\\config.json',cfg))
      local builds=index==1 and{'muscriptor-34a01513-cpu','muscriptor-34a01513-vulkan'}or{'ai-transcriber-2.11.4-msl-34a01513-cpu','ai-transcriber-2.11.4-msl-34a01513-vulkan'}
      local function quote(s)assert(not s:find('"',1,true));return '"'..s..'"'end
      for _,build in ipairs(builds)do
        local command=quote(c.app..'/runtime/'..build..'/ai_transcriber_native.exe')..' --config '..quote(nextRoot..'\\config.json')..' --out '..quote(nextRoot..'\\result.mid')..' --prepare-only'
        local output=r.ExecProcess(command,15000)
        assert(tonumber(tostring(output):match('^(%-?%d+)'))==0,'Engine prepare failed: '..tostring(output))
        assert(r.file_exists(nextRoot..'\\native_progress.json')and r.file_exists(nextRoot..'\\prepared_16000.wav'))
      end
      -- Both editions consume the same profile selection and portable JSON schema.
      local other=dofile(projects[index==1 and 2 or 1]..'/Transcriber/lib/data_storage.lua')
      local selected=other.selection(c.proxy,nextJson,'AiwistTranscriber2',work..'/Local'..index)
      assert(selected==nextRoot)
      results[#results+1]={edition=index==1 and'basic'or'plus',ok=true,ui_frames=c.frames,files=c.owner.result.files,
        portable_default=true,copy_verified=true,relative_preference=true,relocation=true,shared_profile=true,
        engine_config_absolute=true,engine_prepare_cpu_vulkan=true,transkun_environment=index==2 or nil}
      current=nil
    elseif r.time_precise()-c.started>90 then error('Storage worker timed out')end
  end,debug.traceback)
  if not ok then finish(problem);return end
  if index<=#projects then r.defer(frame)end
end
r.defer(frame)
