-- Independent, persisted component jobs. Neural inference remains sequential.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local Runner=dofile(root..'/hidden_runner.lua')
local Legacy=dofile(root..'/setup_ui.lua')
local M={};M.__index=M
local names={'small','medium','large'}
local labels={small='MuScriptor Small',medium='MuScriptor Medium',large='MuScriptor Large'}
function M:save()
  local jobs={}
  -- A smaller distribution must keep passive records of additional models.
  local saved=self.J.load_json(self.path,{})
  if type(saved)=='table'and type(saved.jobs)=='table'then
    for name,j in pairs(saved.jobs)do
      if type(name)=='string'and #name<=32 and name:match('^[a-z_]+$')and not labels[name]and type(j)=='table'and
        type(j.id)=='string'and #j.id==32 and j.id:match('^%x+$')and j.action=='native_download'and j.directory==self.owner.root..'\\jobs\\'..j.id then
        jobs[name]={id=j.id,directory=j.directory,action=j.action,model=name,started=tonumber(j.started)}
      end
    end
  end
  for _,name in ipairs(names)do
    local j=self.jobs[name]
    if j then jobs[name]={id=j.id,directory=j.directory,action='native_download',model=name,started=j.started}end
  end
  return self.J.save_json(self.path,{schema=1,jobs=jobs})
end
function M:adopt(job)
  if type(job)~='table'or type(job.id)~='string'or #job.id~=32 or not job.id:match('^%x+$')or job.directory~=self.owner.root..'\\jobs\\'..job.id then return false end
  local config=self.J.load_json(job.directory..'\\job.json',{})
  local model=config.model or(type(config.models)=='table'and #config.models==1 and config.models[1])
  if config.id~=job.id or config.action~='native_download'or not labels[model]then return false end
  if self.jobs[model]and self.jobs[model].id~=job.id then return false end
  self.jobs[model]={id=job.id,directory=job.directory,model=model,action='native_download',started=tonumber(job.started)or os.time()}
  return true
end
function M:busy(name)
  if name then local j=self.jobs[name];return j~=nil and not j.result end
  for _,j in pairs(self.jobs)do if not j.result then return true end end
  return false
end
function M:start(name,folder)
  if not labels[name]or self:busy(name)then return false end
  local owner=self.owner;local id=owner.r.genGuid():gsub('[^%x]','')
  assert(#id==32,'Не удалось создать задание загрузки')
  local dir=owner.root..'\\jobs\\'..id;owner.r.RecursiveCreateDirectory(dir,0)
  local config={schema=1,id=id,action='native_download',models=self.J.array({name}),data_root=folder,shared_root=true,resource_root=owner.r.GetResourcePath()}
  assert(self.J.save_json(dir..'\\job.json',config),'Не удалось сохранить параметры загрузки')
  local old=self.jobs[name];local job={id=id,directory=dir,model=name,action='native_download',started=os.time()}
  self.jobs[name]=job
  if not self:save()then self.jobs[name]=old;error('Не удалось сохранить список загрузок')end
  -- Persist before launch: reopening observes these exact jobs, never relaunches.
  local ok,detail=pcall(self.launch,self,job,config)
  if not ok then
    job.launch_error=tostring(detail)
    self:cancel(name)
    -- Observe the worker/recovery even if launch acknowledgement was lost.
    -- Do not start a replacement that could write the same partial file.
  end
  return true
end
function M:launch(job)
  return Runner.setup(self.owner.r,self.owner.dir,self.owner.root,job.directory..'\\job.json')
end
function M:cancel(name)
  local j=self.jobs[name]
  if not j or j.result then return false end
  if self.J.write(j.directory..'\\cancel.request','cancel\n')then j.cancelling=true;return true end
  return false
end
function M:poll()
  local now=self.owner.r.time_precise()
  if now-self.last_poll<.25 then return end
  self.last_poll=now
  local changed=false
  for _,name in ipairs(names)do
    local j=self.jobs[name]
    if j and not j.result then
      local p=self.J.load_json(j.directory..'\\status.json',nil)
      if type(p)=='table'and p.job_id==j.id then j.progress=p end
      local result=self.J.load_json(j.directory..'\\result.json',nil)
      if type(result)~='table'or result.job_id~=j.id then
        result=Legacy.timeout_result({json=self.J,progress=j.progress},j)
      end
      local age=os.time()-(tonumber((j.progress or{}).updated)or j.started)
      if not result and age>90 and(not j.last_recovery or now-j.last_recovery>15)then
        j.last_recovery=now
        pcall(Runner.setup,self.owner.r,self.owner.dir,self.owner.root,j.directory..'\\job.json',true)
      end
      if type(result)=='table'and result.job_id==j.id then
        j.result=result;changed=true
        if not result.ok then self.owner.last_job=j;self.owner.result=result
        elseif not self.owner.result or self.owner.result.ok then self.owner.last_job=j end
      end
    end
  end
  if changed then
    -- Each result contains a snapshot from its own commit. Read the current
    -- merged registry instead of replacing it with an older finishing job.
    local active=self.J.load_json(self.owner.root..'\\native_active.json',nil)
    if type(active)=='table'and type(active.weights)=='table'then self.owner.native=active;self.owner.native_health=nil end
    if self.owner.on_change then self.owner.on_change()end
  end
end
function M:status(name,en)
  local j=self.jobs[name];if not j then return end
  if j.result then
    if j.result.ok then return end
    return j.result.cancelled and(en and'Cancelled'or'Остановлена')or(en and'Installation failed'or'Ошибка установки'),false
  end
  if j.cancelling then return en and'Stopping…'or'Останавливаем…',true end
  local p=j.progress or{}
  if p.stage=='checking'then return en and'Checking…'or'Проверка…',true end
  local bytes,total=tonumber(p.bytes),tonumber(p.total)
  if bytes and total and total>0 and bytes>=0 then return (en and'Downloading · 'or'Загрузка · ')..math.floor(math.min(1,bytes/total)*100)..'%',true end
  return en and'Starting download…'or'Запуск загрузки…',true
end
function M:draw(c,en,colors)
  local r=self.owner.r
  for _,name in ipairs(names)do
    local j=self.jobs[name]
    if j and(not j.result or not j.result.ok)then
      r.ImGui_Spacing(c)
      r.ImGui_TextColored(c,not j.result and(colors.accent or 0x70C8DCFF)or(colors.red or 0xEE7777FF),labels[name])
      if not j.result then
        local p=j.progress or{};local bytes,total=tonumber(p.bytes),tonumber(p.total)
        local ratio=total and total>0 and bytes and bytes>=0 and math.max(0,math.min(1,bytes/total))or nil
        local label=ratio and string.format('%d%% · %s / %s',math.floor(ratio*100),Legacy.format_bytes(bytes),Legacy.format_bytes(total))or(self:status(name,en))
        r.ImGui_ProgressBar(c,ratio or -r.time_precise(),-1,20,label)
        if j.launch_error then r.ImGui_TextWrapped(c,en and'Launch could not be confirmed. Checking the download status…'or'Запуск не подтверждён. Проверяем состояние загрузки…')end
        r.ImGui_BeginDisabled(c,j.cancelling==true)
        if r.ImGui_Button(c,(en and'Stop'or'Остановить')..'##download_stop_'..name)then self:cancel(name)end
        r.ImGui_EndDisabled(c)
      else
        local e=j.result.error or{}
        r.ImGui_TextWrapped(c,(e.code and e.code..' — 'or'')..(e.title or j.result.message or(en and'Installation failed'or'Установка не завершена')))
        if e.help and e.help[1]then r.ImGui_TextWrapped(c,e.help[1])end
        if e.detail and r.ImGui_CollapsingHeader(c,(en and'Error details'or'Подробности ошибки')..'##download_error_'..name)then r.ImGui_TextWrapped(c,e.detail)end
      end
    end
  end
end
function M.new(owner)
  local self=setmetatable({owner=owner,J=owner.json,jobs={},path=owner.root..'\\native_download_jobs.json',last_poll=0},M)
  local saved=self.J.load_json(self.path,self.J.load_json(self.path..'.bak',{}))
  if type(saved)=='table'and saved.schema==1 and type(saved.jobs)=='table'then
    for _,name in ipairs(names)do self:adopt(saved.jobs[name])end
  end
  if owner.job and self:adopt(owner.job)then owner.job=nil end
  return self
end
return M
