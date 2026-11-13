-- Generic setup IPC retained from the full edition; Native MuScriptor only.
local M={};M.__index=M
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local SupportZip=dofile(root..'/support_zip.lua')
local HiddenRunner=dofile(root..'/hidden_runner.lua')
local function text(r,c,v)r.ImGui_TextWrapped(c,tostring(v))end
local function colored(r,c,color,v)r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),color);text(r,c,v);r.ImGui_PopStyleColor(c)end
local function size_label(bytes,fallback)if not bytes then return fallback end;if bytes<1073741824 then return string.format('%.1f MiB',bytes/1048576)end;return string.format('%.2f GiB',bytes/1073741824)end
local function maintenance(a)return a=='support_report'or a=='storage_scan'or a=='storage_clean'end
local allowed={native_download=true,native_neuralnote=true,native_devices=true,storage_scan=true,storage_clean=true}
function M.new(r,dir,state,J,on_change,data)
 r.RecursiveCreateDirectory(state..'\\jobs',0)
 local self=setmetatable({r=r,dir=dir,root=state,json=J,on_change=on_change,data_root=data,active={},open=false,page=0,last_poll=-math.huge},M)
 self.active=J.load_json(state..'\\active.json',{})
 self.intro_seen=J.load_json(state..'\\onboarding.json',{}).intro_seen==true
 for _,name in ipairs({'active_job.json','running_job.json'})do
  local job=J.load_json(state..'\\'..name,{})
  if type(job.id)=='string'and #job.id==32 and job.id:match('^%x+$')and job.directory==state..'\\jobs\\'..job.id and not r.file_exists(job.directory..'\\result.json')then
   if allowed[job.action]then self.job=job else self.foreign_job=job;self.notice='Дождитесь завершения прежнего установщика Ai Transcriber перед установкой GGUF.'end
   self.open=true;break
  end
 end
 return self
end
function M:busy()return self.job~=nil or self.foreign_job~=nil end
function M:launch(action,extra)
 assert(allowed[action],'Неизвестное действие Ai Transcriber.')
 if self:busy()then return end
 local J,r=self.json,self.r
 local previous=J.load_json(self.root..'\\active_job.json',{})
 if type(previous.id)=='string'and #previous.id==32 and previous.id:match('^%x+$')and previous.directory==self.root..'\\jobs\\'..previous.id and not r.file_exists(previous.directory..'\\result.json')then
  if allowed[previous.action]then self.job=previous else self.foreign_job=previous end;return
 end
 local id=r.genGuid():gsub('[^%x]','');local directory=self.root..'\\jobs\\'..id
 r.RecursiveCreateDirectory(directory,0)
 local config={schema=1,id=id,action=action,resource_root=r.GetResourcePath(),data_root=self.data_root}
 for k,v in pairs(extra or{})do config[k]=v end
 assert(J.save_json(directory..'\\job.json',config),'Не удалось сохранить запрос установки.')
 local job={id=id,directory=directory,action=action,started=os.time()};self.launching_job=job
 assert(J.save_json(self.root..'\\active_job.json',job),'Не удалось сохранить состояние установки.')
 self.last_request=config;self.result=nil;self.progress=nil
 HiddenRunner.setup(r,self.dir,self.root,directory..'\\job.json')
 self.job=job;self.launching_job=nil;self.page=4
end
function M:start(action,extra)
 local ok,problem=pcall(self.launch,self,action,extra)
 if ok then return true end
 local job=self.launching_job
 self.result={ok=false,error={code='AIT2-201',title='Не удалось запустить помощник',stage='Запуск помощника',detail=tostring(problem),help={'Проверьте файлы установочного архива и доступность Windows PowerShell.'}}}
 if job then self.result.job_id=job.id;self.last_job=job;pcall(self.json.write,job.directory..'\\cancel.request','launch unconfirmed\n');pcall(self.json.save_json,job.directory..'\\result.json',self.result)end
 self.launching_job=nil;self.job=nil;self.open=true;self.page=5;return false
end
function M:cancel()local job=self.job or self.foreign_job;if job then self.json.write(job.directory..'\\cancel.request','cancel\n')end end
function M:poll()
 if self.foreign_job then
  local job=self.foreign_job
  if self.r.file_exists(job.directory..'\\result.json')then self.foreign_job=nil;self.notice=nil
  elseif os.time()-(tonumber(job.started)or os.time())>90 and
   (not job.recovered or self.r.time_precise()-job.recovered>15)then
   -- Recovery checks the recorded owner PID; it never restarts the old installer.
   job.recovered=self.r.time_precise()
   pcall(HiddenRunner.setup,self.r,self.dir,self.root,job.directory..'\\job.json',true)
  end
  return
 end
 if not self.job or self.r.time_precise()-self.last_poll<.25 then return end
 self.last_poll=self.r.time_precise();local job=self.job;local J=self.json
 local progress=J.load_json(job.directory..'\\status.json',nil)
 if type(progress)=='table'and progress.job_id==job.id then self.progress=progress end
 local result=J.load_json(job.directory..'\\result.json',nil)
 if not result or result.job_id~=job.id then result=self:timeout_result(job)end
 local age=os.time()-(tonumber((self.progress or{}).updated)or tonumber(job.started)or os.time())
 if not result and age>90 and(not job.recovered or self.r.time_precise()-job.recovered>15)then
  job.recovered=self.r.time_precise();pcall(HiddenRunner.setup,self.r,self.dir,self.root,job.directory..'\\job.json',true)
 end
 if result and result.job_id==job.id then
  self.job=nil;self.last_job=job
  if job.action=='storage_scan'or job.action=='storage_clean'then
   local previous=self.maintenance_return or{};self.maintenance_return=nil
   self.result=previous.result;self.message=previous.message;self.last_job=previous.last_job;self.last_request=previous.last_request;self.page=8
   if result.ok then
    if result.storage then self.storage=result.storage;self.storage_selected={};self.storage_confirm=false end
    if result.cleanup then self.storage=nil;self.storage_confirm=false;self.maintenance_notice='Удалено файлов: '..tostring(result.cleanup.deleted)..'. Обновите список.'end
   else self.result=result;self.last_job=job;self.page=5;self.open=true end
  else self.result=result;self.page=5 end
 end
end
function M.center_first_open(r,c)
  local viewport=r.ImGui_GetMainViewport(c)
  if not viewport then return end
  local x,y=r.ImGui_Viewport_GetWorkPos(viewport)
  local width,height=r.ImGui_Viewport_GetWorkSize(viewport)
  if width>0 and height>0 then
    r.ImGui_SetNextWindowPos(c,x+width/2,y+height/2,r.ImGui_Cond_FirstUseEver(),0.5,0.5)
  end
end


function M:report_title()
  local ok,manifest=pcall(self.json.load_json,self.dir..'\\manifest.json')
  local version=self.version or(ok and type(manifest)=='table' and type(manifest.version)=='string' and manifest.version)
  if version and not (version:match('^%d+%.%d+$') or version:match('^%d+%.%d+%.%d+$')) then version=nil end
  return 'Ai Transcriber '..(version or '(версия неизвестна)')
end


function M:link(url)
  if self.r.CF_ShellExecute then self.r.CF_ShellExecute(url)
  else self.r.ExecProcess('explorer.exe "'..url..'"',-1) end
end

function M:timeout_result(job)
  local elapsed=os.time()-(tonumber(job.started) or os.time())
  local started=self.progress and self.progress.job_id==job.id
  local local_timeout=job.action=='connect_model' and elapsed>=60
  if not local_timeout and (started or elapsed<30) then return nil end
  local issue={code=local_timeout and 'MUS-282' or 'AIT2-201',
    title=local_timeout and 'Проверка папки модели не завершилась за 60 секунд' or 'Помощник не ответил за 30 секунд',
    stage=local_timeout and 'Проверка локальной модели' or 'Запуск помощника',
    retry_page=job.action=='connect_model' and 9 or 1,
    help={local_timeout and 'Проверьте доступ к папке и цели ссылки. Сетевой диск или внешний накопитель могут быть недоступны.' or
      'Проверьте, что архив распакован полностью и Windows PowerShell разрешён защитным ПО.',
      job.action=='connect_model' and 'Если у вас ещё нет весов MuScriptor, нажмите «Установить с нуля».' or 'Повторите запуск после устранения причины.'},
    detail='Задание: '..job.id..'; ожидание: '..elapsed..' сек.'}
  local result={schema=1,job_id=job.id,ok=false,action=job.action,error=issue,message=issue.code..': '..issue.title}
  -- Persist cancellation before releasing the UI. A late worker must not commit
  -- an attachment after the user has already received a timeout.
  pcall(self.json.save_json,job.directory..'\\timeout.json',result)
  local ok,written=pcall(self.json.write,job.directory..'\\cancel.request','timeout\n')
  if not ok or not written then return nil end
  pcall(self.json.save_json,job.directory..'\\result.json',result)
  return result
end

function M:save_support_report(context,reason)
  local previous=self.maintenance_return
  local original=previous and previous.result or self.result
  local job=previous and previous.last_job or self.job or self.last_job
  local issue=type(original)=='table'and type(original.error)=='table'and original.error or{}
  local active=self.active or{};local components={}
  for _,key in ipairs({'data_root'})do
    if type(active[key])=='string'then components[key]=active[key]end
  end
  if self.native then components.engine='muscriptor.cpp';components.executable=self:engine();components.data_root=self.native.data_root end
  local report_weights=self.native and self.native.weights or active.weights
  local model_states={}
  for _,model in ipairs({'small','medium','large'})do
    local weight=type(report_weights)=='table'and report_weights[model]
    model_states[#model_states+1]={model=model,connected=type(weight)=='string',present=type(weight)=='string'and self.r.file_exists(weight)or false}
  end
  local summary={app=self:report_title(),created=os.date('!%Y-%m-%dT%H:%M:%SZ'),
    reaper=context and context.reaper_version,ui_status=context and context.ui_status,
    error={code=issue.code,title=issue.title,stage=issue.stage,detail=issue.detail,help=issue.help},
    job=job and{id=job.id,action=job.action,started=job.started,
      bootstrap_record=type(job.directory)=='string'and self.r.file_exists(job.directory..'\\bootstrap.json')or false,
      worker_record=type(job.directory)=='string'and self.r.file_exists(job.directory..'\\worker.json')or false},components=components,models=model_states,
    helper_failure=type(reason)=='table'and(reason.message or(reason.error or{}).title)or tostring(reason or''),
    platform=self.r.GetOS and self.r.GetOS(),report_mode='Lua support report'}
  local local_data=self.root:match('^(.*)\\Aiwist\\Ai Transcriber')
  local prefixes={{path=local_data,label='%LOCALAPPDATA%'}}
  local profile=local_data and local_data:match('^(.*)\\AppData\\Local$')
  if profile then prefixes[#prefixes+1]={path=profile,label='%USERPROFILE%'}end
  local ids={}
  for _,candidate in pairs({current=self.job,last=job})do if candidate and candidate.id then ids[#ids+1]=candidate.id end end
  self.support_report=nil
  local ok,report=pcall(SupportZip.create,self.r,self.json,self.root..'\\reports',summary,prefixes,
    {root=self.root,job_ids=ids,instance=context and context.runtime_instance})
  if previous then
    self.result=previous.result;self.message=previous.message;self.last_job=previous.last_job;self.last_request=previous.last_request;self.page=previous.page
  end
  self.maintenance_return=nil
  if not ok then self.maintenance_notice='Не удалось записать ZIP-отчёт: '..tostring(report);return false end
  self.support_report=report;self.maintenance_notice='Отчёт сохранён. '..((report.logs or 0)>0 and('Журналов: '..report.logs..'.')or'Доступных журналов нет; сведения из интерфейса сохранены.')
  pcall(SupportZip.reveal,self.r,report.path)
  return true
end
-- Compatibility for a report job started by 2.3.5 before this script was reopened.

function M:emergency_report(context,reason)return self:save_support_report(context,reason)end

function M:request_maintenance(action,extra)
  if not maintenance(action) or self:busy() or self.transcription_active then return false end
  self.inspect_pending=false;self.open=true
  if action=='support_report' then
    local status=self.get_support_status and tostring(self.get_support_status()) or ''
    status=status:gsub('hf_[%w_]+','[TOKEN REDACTED]'):gsub('[Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s"<>]+','Bearer [REDACTED]'):gsub('(https?://[^%s?"<>]+)%?[^%s"<>]+','%1?[QUERY REDACTED]')
    extra={runtime_instance=self.support_instance,ui_status=status:sub(1,4096),reaper_version=self.r.GetAppVersion and self.r.GetAppVersion() or nil}
    return self:save_support_report(extra)
  elseif action=='storage_scan' or action=='storage_clean' then
    extra=extra or {};extra.runtime_instance=self.support_instance
  end
  self.maintenance_return={page=self.page,result=self.result,message=self.message,last_job=self.last_job,last_request=self.last_request}
  local ok=self:start(action,extra)
  if not ok then self.maintenance_return=nil end
  return ok
end

function M:show_storage()
  if self:busy() or self.transcription_active then return false end
  self.guide=false;self.recovery=nil;self.page=8;self.open=true;self.maintenance_notice=nil
  return self:request_maintenance('storage_scan')
end

function M:draw_storage(c)
  local r=self.r;local storage=self.storage
  text(r,c,'Временные WAV и MIDI')
  text(r,c,'Рабочие копии аудио для нейросети и временные MIDI. Исходное аудио, MIDI в папке проекта и последний результат не удаляются.')
  if r.ImGui_Button(c,'Обновить список##storage_refresh') then self:request_maintenance('storage_scan') end
  if not storage then return end
  for _,row in ipairs(storage.categories or {})do
    if row.kind=='wav' or row.kind=='midi' then text(r,c,row.label..': '..tostring(row.files or 0)..' · '..size_label(row.bytes,'0 MiB')) end
  end
  r.ImGui_Separator(c)
  local candidates=storage.candidates or {};self.storage_selected=self.storage_selected or {}
  if #candidates==0 then
    text(r,c,(storage.blocked_files or 0)>0 and 'Файлы пока недоступны для безопасной очистки. Завершите обработку и обновите список.' or
      'Временных WAV и MIDI нет. После успешной обработки WAV удаляются автоматически.')
    return
  end
  text(r,c,'Выберите файлы для удаления. Файлы активной транскрибации в список не попадают.')
  if r.ImGui_Button(c,'Выбрать все##storage_all') then for _,row in ipairs(candidates)do self.storage_selected[row.id]=true end;self.storage_confirm=false end
  r.ImGui_SameLine(c)
  if r.ImGui_Button(c,'Снять выделение##storage_none') then self.storage_selected={};self.storage_confirm=false end
  local shown=r.ImGui_BeginChild(c,'##storage_files',-1,180)
  if shown then
    for _,row in ipairs(candidates)do
      local name=row.path:match('([^/\\]+)$') or row.path
      local changed,value=r.ImGui_Checkbox(c,name..' · '..size_label(row.bytes,'0 MiB')..'##'..row.id,self.storage_selected[row.id]==true)
      if r.ImGui_IsItemHovered(c) then r.ImGui_SetTooltip(c,self.root..'\\'..row.path) end
      if changed then self.storage_selected[row.id]=value;self.storage_confirm=false end
    end
    r.ImGui_EndChild(c)
  end
  local selected,bytes={},0
  for _,row in ipairs(candidates)do if self.storage_selected[row.id] then selected[#selected+1]=row.id;bytes=bytes+row.bytes end end
  text(r,c,'Выбрано файлов: '..#selected..' · '..size_label(bytes,'0 MiB'))
  r.ImGui_BeginDisabled(c,#selected==0)
  if not self.storage_confirm then
    if r.ImGui_Button(c,'Очистить выбранное…') then self.storage_confirm=true end
  else
    colored(r,c,(self.colors or {}).red or 0xED7777FF,'Удалить выбранные файлы без возможности отмены? Перед удалением список и активность запусков проверяются повторно.')
    if r.ImGui_Button(c,'Да, удалить##storage_confirm') then self:request_maintenance('storage_clean',{plan_id=storage.plan_id,selected=self.json.array(selected)}) end
    r.ImGui_SameLine(c);if r.ImGui_Button(c,'Отмена##storage_cancel') then self.storage_confirm=false end
  end
  r.ImGui_EndDisabled(c)
end

function M.format_bytes(value)
  for _,unit in ipairs({{1073741824,'GiB'},{1048576,'MiB'},{1024,'KiB'}}) do
    if value>=unit[1] then return string.format('%.1f %s',value/unit[1],unit[2]) end
  end
  return string.format('%.0f B',math.max(0,value))
end


function M:draw_progress(c)
  local r=self.r
  if self.foreign_job then text(r,c,self.notice);return end
  local p=self.progress or {}
  text(r,c,p.message or (self.job and self.job.action=='connect_model' and 'Запускаю проверку папки модели…' or 'Запуск помощника…'))
  if not p.job_id and not p.message then text(r,c,'Ожидание запуска — до 30 секунд.')
  elseif self.job and self.job.action=='connect_model' then text(r,c,'Проверка локальных файлов — до 60 секунд. Скачивание не выполняется.') end
  local bytes,total=tonumber(p.bytes),tonumber(p.total)
  if total and total>0 and bytes and bytes>=0 then
    local ratio=math.max(0,math.min(1,bytes/total))
    local label=string.format('%d%% · %s / %s',math.floor(ratio*100),M.format_bytes(bytes),M.format_bytes(total))
    r.ImGui_ProgressBar(c,ratio,-1,24,label)
    if tonumber(p.rate) and p.rate>0 and (not p.updated or os.time()-p.updated<=5) then text(r,c,M.format_bytes(p.rate)..'/с') end
  else
    -- Negative fraction is Dear ImGui's native indeterminate animation. It
    -- signals work, not an invented download percentage or completion time.
    local label=bytes and bytes>=0 and ('Скачано: '..M.format_bytes(bytes)) or 'В работе…'
    r.ImGui_ProgressBar(c,-r.time_precise(),-1,24,label)
  end
  text(r,c,'В работе · '..math.max(0,os.time()-(tonumber((self.job or {}).started) or os.time()))..' сек.')
end


function M:button(c,label,width,height,accent)
  local r,palette=self.r,self.colors or {}
  local themed=accent and palette.accent_ui
  if themed then
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),palette.accent_ui)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),palette.accent or palette.accent_ui)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),palette.accent_ui)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),palette.accent_text or 0xFFFFFFFF)
  end
  local clicked=r.ImGui_Button(c,label,width,height)
  if themed then r.ImGui_PopStyleColor(c,4) end
  return clicked
end


function M:draw(c,blocked)
 if not self.open then return end
 local r=self.r;r.ImGui_SetNextWindowSize(c,610,500,r.ImGui_Cond_FirstUseEver());M.center_first_open(r,c)
 local visible,opened=r.ImGui_Begin(c,'Ai Transcriber — временные WAV и MIDI##lite_storage',self.open);self.open=opened
 if visible then
  if self:busy()then self:draw_progress(c);if r.ImGui_Button(c,'Остановить')then self:cancel()end
  else r.ImGui_BeginDisabled(c,blocked or false);self:draw_storage(c);r.ImGui_EndDisabled(c)end
  if self.maintenance_notice then text(r,c,self.maintenance_notice)end
  if r.ImGui_Button(c,'Назад')then self.page=0;self.open=true end
  r.ImGui_SameLine(c);if r.ImGui_Button(c,'Закрыть')then self.open=false end
  r.ImGui_End(c)
 end
end
return M
