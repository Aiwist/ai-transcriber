-- Shared application identity. Import only known public preferences/control data;
-- never move models, project media, credentials or active worker directories.
local M={}
M.section='AiwistTranscriber2'
local keys={'language','theme','ui_scale','model','force_channel_one','model_section_open','instruments_section_open','native_device_choice_v1','windows_local_app_data_v1','windows_roaming_app_data_v1'}
function M.preferences(r,section)
  if section~=M.section or r.GetExtState(section,'identity_preferences_v1')=='1'then return end
  local ok=true
  for _,key in ipairs(keys)do
    if r.GetExtState(section,key)==''then
      local value=r.GetExtState('AiwistTranscriberLite',key)
      if type(value)=='string'and #value>0 and #value<=65536 then ok=pcall(r.SetExtState,section,key,value,true)and ok end
    end
  end
  if ok then pcall(r.SetExtState,section,'identity_preferences_v1','1',true)end
end
local function read(J,path,limit)
  local f=io.open(path,'rb');if not f then return end
  local n=f:seek('end');f:close();if not n or n<1 or n>(limit or 1048576)then return end
  local ok,data=pcall(J.load_json,path);if ok and type(data)=='table'then return data end
end
local function pending(r,J,root)
  for _,name in ipairs({'active_job.json','running_job.json'})do
    local job=read(J,root..'\\'..name)
    if job and type(job.id)=='string'and #job.id==32 and job.id:match('^%x+$')and job.directory==root..'\\jobs\\'..job.id and not r.file_exists(job.directory..'\\result.json')then return true end
  end
  local downloads=read(J,root..'\\native_download_jobs.json')
  for _,name in ipairs({'small','medium','large'})do
    local job=downloads and type(downloads.jobs)=='table'and downloads.jobs[name]
    if type(job)=='table'and type(job.id)=='string'and #job.id==32 and job.id:match('^%x+$')and job.directory==root..'\\jobs\\'..job.id and not r.file_exists(job.directory..'\\result.json')then return true end
  end
end
function M.prepare(r,J,local_data)
  local root=local_data..'\\Aiwist\\Ai Transcriber'
  if r.GetExtState and r.GetExtState(M.section,'identity_data_root_v1')==root then
    r.RecursiveCreateDirectory(root..'\\jobs',0)
    return root,local_data..'\\Ai Transcriber'
  end
  local legacy={local_data..'\\Aiwist\\Ai Transcriber Lite',root..' 2.0'}
  -- An already launched old worker keeps its address until it terminates.
  if not pending(r,J,root)then
    for _,old in ipairs(legacy)do if pending(r,J,old)then return old,local_data..'\\Ai Transcriber','Дождитесь завершения прежней установки. Следующий запуск использует общие настройки.'end end
  end
  r.RecursiveCreateDirectory(root..'\\jobs',0)
  local changed=false;local failed=false
  local active=read(J,root..'\\native_active.json')or{schema=1,weights={},sources={}}
  if type(active.weights)~='table'then active.weights={}end
  if type(active.sources)~='table'then active.sources={}end
  for _,old in ipairs(legacy)do
    local previous=read(J,old..'\\native_active.json')
    if previous and type(previous.weights)=='table'then
      for _,name in ipairs({'small','medium','large','basic_pitch'})do
        local path=previous.weights[name];local current=active.weights[name]
        if type(path)=='string'and #path<32768 and r.file_exists(path)and(type(current)~='string'or not r.file_exists(current))then
          active.weights[name]=path;active.sources[name]=type(previous.sources)=='table'and previous.sources[name]or'external';changed=true
        end
      end
      for _,key in ipairs({'components_root','data_root','basic_pitch_data_root'})do
        if not active[key]and type(previous[key])=='string'then active[key]=previous[key];changed=true end
      end
    end
    for _,name in ipairs({'active.json','last_result.json','last_result.json.bak'})do
      if not r.file_exists(root..'\\'..name)then
        local data=read(J,old..'\\'..name,33554432)
        if data then local ok,saved=pcall(J.save_json,root..'\\'..name,data);failed=not(ok and saved)or failed end
      end
    end
    if type(r.EnumerateFiles)=='function'then
      for i=0,1023 do
        local name=r.EnumerateFiles(old..'\\instrument_selections',i);if not name then break end
        if #name<=520 and name:match('^%x+%.json$')then
          local value=read(J,old..'\\instrument_selections\\'..name,262144)
          if value and value.schema==1 and type(value.tracks)=='table'and type(value.project)=='string'then
            local path=root..'\\instrument_selections\\'..name
            local target=read(J,path,262144);local merged=false
            if not target then target=value;merged=true
            elseif target.schema==1 and target.project==value.project and type(target.tracks)=='table'then
              for track,settings in pairs(value.tracks)do if target.tracks[track]==nil then target.tracks[track]=settings;merged=true end end
            end
            if merged then
              local ok,saved=pcall(function()assert(#J.encode(target)<=262144);r.RecursiveCreateDirectory(root..'\\instrument_selections',0);return J.save_json(path,target)end)
              failed=not(ok and saved)or failed
            end
          end
        end
      end
    end
  end
  if changed then local ok,saved=pcall(J.save_json,root..'\\native_active.json',active);failed=not(ok and saved)or failed end
  if not failed and r.SetExtState then
    local ok=pcall(r.SetExtState,M.section,'identity_data_root_v1',root,true);failed=not ok
  end
  return root,local_data..'\\Ai Transcriber',failed and'Часть прежних настроек не удалось перенести. Исходные данные сохранены; перенос повторится при следующем запуске.'or nil
end
return M
