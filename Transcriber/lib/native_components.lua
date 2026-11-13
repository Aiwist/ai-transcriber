-- MuScriptor-only model settings with independent persisted downloads.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local Legacy=dofile(root..'/setup_ui.lua')
local Health=dofile(root..'/gguf_health.lua')
local Downloads=dofile(root..'/native_downloads.lua')
local M={}
-- The main window uses the same first-open placement as the component window.
M.center_first_open=Legacy.center_first_open
local sizes={{id='small',size='200 МиБ'},{id='medium',size='590 МиБ'},{id='large',size='2.6 ГиБ'}}
local methods={}
function methods:engine(device)
  local release=self.json.load_json(self.dir..'/native_release.json',{})
  local build=device=='cpu'and release.cpu_runtime or release.runtime
  local relative=build and build.file
  if type(relative)~='string'then return nil end
  local p=self.dir..'/'..relative
  return self.r.file_exists(p)and p or nil
end
function methods:model_problem(name,force)
  local path=type(self.native.weights)=='table'and self.native.weights[name]
  if type(path)~='string'then return 'модель не подключена'end
  self.native_health=self.native_health or{}
  local cached=self.native_health[name];local now=self.r.time_precise()
  if force or not cached or cached.path~=path or not self.r.file_exists(path)or now-cached.at>1 then
    local problem,bytes=Health.inspect(path,name);cached={path=path,problem=problem,bytes=bytes,at=now};self.native_health[name]=cached
  end
  return cached.problem
end
function methods:weights(name)
  return not self:model_problem(name)and self.native.weights[name]or nil
end
function methods:model_rows(force)
  local out={};local selected=self.get_selected_model and self.get_selected_model()
  for _,m in ipairs(sizes)do
    local registered=type(self.native.weights)=='table'and type(self.native.weights[m.id])=='string'
    local problem=registered and self:model_problem(m.id,force)or nil
    local path=registered and not problem and self.native.weights[m.id]or nil
    out[#out+1]={id=m.id,size=m.size,path=path,installed=path~=nil,incomplete=registered and not path,problem=problem,active=path and selected==m.id}
  end;return out
end
function methods:can_recover()return self:engine()~=nil end
function methods:recovery_hint()
  if not self:engine()then return 'Нативный движок отсутствует. Повторите установку Ai Transcriber.'end
  for _,m in ipairs(sizes)do
    if type(self.native.weights)=='table'and self.native.weights[m.id]then
      local issue=self:model_problem(m.id);if issue then return m.id..': '..issue..'. Откройте настройки и подключите или загрузите модель повторно.'end
    end
  end
end
function methods:request_install()self.open=true;self.page=0;self.native_view=true;self.inspect_pending=false;self.native_probe_pending=nil;return true end
function methods:show_overview()return self:request_install()end
function methods:busy()return self.job~=nil or self.foreign_job~=nil or self.downloads and self.downloads:busy()or false end
function methods:request_model(name,blocked)
  if blocked or self.job or self.foreign_job or self.transcription_active or self.downloads:busy(name)then return false end
  if name~='small'and name~='medium'and name~='large'then return false end
  self:request_install();self.native_intro=false;self.native_legacy=nil;self.native_notice=nil
  self.result=nil;self.neuralnote_choose=nil
  self.intro_seen=true;pcall(self.json.save_json,self.root..'\\onboarding.json',{schema=1,intro_seen=true})
  local ok,result=pcall(self.downloads.start,self.downloads,name,self.components_root)
  if not ok then self.result={ok=false,error={code='AIT2-201',title='Не удалось запустить загрузку',help={'Проверьте доступ к папке компонентов и повторите установку.'},detail=tostring(result)}};return false end
  return result
end
function methods:request_all(blocked)
  if blocked or self.job or self.foreign_job or self.transcription_active then return false end
  local started=false
  for _,row in ipairs(self:component_rows())do
    if not row.installed and not self.downloads:busy(row.id)then started=self:request_model(row.id,false)or started end
  end
  return started
end
function methods:request_recovery(kind,blocked)
  if blocked or self:busy()then return false end
  self:request_install();self.native_notice=kind=='components'and'Движок входит в комплект. Для его восстановления повторно распакуйте Native.'or'Нажмите «Установить» в строке нужной модели.';return true
end
function methods:request_neuralnote(blocked,folder)
  if blocked or self:busy()or self.transcription_active then return false end
  self:request_install();self.native_intro=false;self.native_legacy=nil;self.native_notice=nil;self.neuralnote_choose=nil
  self.intro_seen=true;pcall(self.json.save_json,self.root..'\\onboarding.json',{schema=1,intro_seen=true})
  return self:start('native_neuralnote',folder and{model_directory=folder}or nil)
end
function methods:choose_folder(title,initial)
  local r=self.r
  if r.JS_Dialog_BrowseForFolder then
    local ok,folder=r.JS_Dialog_BrowseForFolder(title,initial or'')
    if ok==1 and type(folder)=='string'and folder~=''then return folder end
  elseif r.GetUserInputs then
    local ok,folder=r.GetUserInputs(title,1,'Путь к папке,extrawidth=300',initial or'')
    if ok and type(folder)=='string'and folder:match('%S')then return folder end
  end
end
function methods:choose_neuralnote(blocked)
  if blocked or self:busy()or self.transcription_active then return false end
  local folder=self:choose_folder('Папка моделей NeuralNote',self.neuralnote_folder or'')
  if not folder then return false end
  self.neuralnote_folder=folder
  return self:request_neuralnote(false,folder)
end
function methods:draw_neuralnote(c,blocked)
  local r=self.r;local en=self.language=='en'
  r.ImGui_BeginDisabled(c,blocked or self:busy())
  if r.ImGui_Button(c,(en and'Connect NeuralNote models'or'Подключить модели NeuralNote')..'##native_neuralnote',-1,30)then self:request_neuralnote(blocked)end
  if r.ImGui_IsItemHovered(c)then r.ImGui_SetTooltip(c,en and'Already have NeuralNote 2? Connect the models you have downloaded.'or'Есть установленный NeuralNote 2? Подключите уже скачанные модели.')end
  if self.neuralnote_choose then
    if r.ImGui_Button(c,(en and'Choose model folder…'or'Указать папку моделей…')..'##native_neuralnote_folder',-1,30)then self:choose_neuralnote(blocked)end
  end
  r.ImGui_EndDisabled(c)
end
function methods:component_rows(force)
  local rows=self:model_rows(force)
  local labels={small='MuScriptor Small',medium='MuScriptor Medium',large='MuScriptor Large'}
  for _,row in ipairs(rows)do row.label=labels[row.id]end
  return rows
end
function methods:draw_models(c,blocked,language,colors)
  local r=self.r;local en=language=='en';colors=colors or{}
  if r.ImGui_BeginTable(c,'##native_models',4,r.ImGui_TableFlags_Borders()|r.ImGui_TableFlags_RowBg())then
    for _,label in ipairs(en and{'Model','Size','Status',' '}or{'Модель','Размер','Состояние',' '})do r.ImGui_TableSetupColumn(c,label)end;r.ImGui_TableHeadersRow(c)
    for _,m in ipairs(self:component_rows())do
      r.ImGui_TableNextRow(c);r.ImGui_TableNextColumn(c);r.ImGui_Text(c,m.label)
      r.ImGui_TableNextColumn(c);r.ImGui_Text(c,m.size);r.ImGui_TableNextColumn(c)
      local status=m.installed and(m.active and(en and'Installed · active'or'Установлена · активна')or(en and'Installed'or'Установлена'))or(m.incomplete and(en and'Damaged'or'Повреждена')or(en and'Not installed'or'Не установлена'))
      local download_status,downloading=self.downloads:status(m.id,en)
      if m.installed and not downloading then download_status=nil end
      status=download_status or status
      r.ImGui_TextColored(c,downloading and(colors.accent or 0x70C8DCFF)or download_status and(colors.red or 0xEE7777FF)or m.incomplete and(colors.red or 0xEE7777FF)or m.installed and(colors.green or 0x80CC80FF)or(colors.muted or 0xAAAAAAFF),status)
      if m.problem and r.ImGui_IsItemHovered(c)then r.ImGui_SetTooltip(c,m.problem)end
      r.ImGui_TableNextColumn(c);r.ImGui_BeginDisabled(c,blocked or self.job~=nil or self.foreign_job~=nil or downloading==true)
      if downloading then r.ImGui_Text(c,'—')
      else
        if r.ImGui_Button(c,(m.installed and(en and'Select'or'Выбрать')or(en and'Install'or'Установить'))..'##native_'..m.id)then
          if m.installed and self.on_select_model then self.on_select_model(m.id)else self:request_model(m.id,blocked)end
        end
      end;r.ImGui_EndDisabled(c)
    end;r.ImGui_EndTable(c)
  end
  return false
end
function methods:poll()
  self.downloads:poll()
  local before=self.job
  Legacy.poll(self)
  if before and not self.job and self.result and self.result.native_active then
    self.native=self.json.load_json(self.root..'\\native_active.json',self.result.native_active);self.native_health=nil;self.native_notice=self.result.message
    self.components_root=self.native.components_root or self.components_root
    if self.on_change then self.on_change()end
  elseif before and not self.job and tostring(before.action):match('^native_')then
    self.native_notice=self.result and self.result.message or'Помощник не завершил операцию.'
  end
  if before and not self.job and before.action=='native_neuralnote'then
    local code=self.result and self.result.error and self.result.error.code
    self.neuralnote_choose=code=='AITN-231'or code=='AITN-232'or code=='AITN-230'or code=='AITN-233'
    self.open=true
  end
end
-- Draw within the main settings popup. Model operations never create a window.
function methods:draw_settings(c,blocked,language,colors)
  local r=self.r
  self.language=language;self.colors=colors
  self:draw_models(c,blocked,language,colors)
  local missing=false
  for _,row in ipairs(self:component_rows())do if not row.installed and not self.downloads:busy(row.id)then missing=true end end
  if missing then
    r.ImGui_BeginDisabled(c,blocked or self.job~=nil or self.foreign_job~=nil)
    if r.ImGui_Button(c,(language=='en'and'Install all models'or'Установить все модели')..'##native_all',-1,30)then self:request_all(blocked)end
    r.ImGui_EndDisabled(c)
  end
  r.ImGui_Spacing(c)
  self:draw_neuralnote(c,blocked)
  self.downloads:draw(c,language=='en',colors or{})
  if self.job then
    self:draw_progress(c)
    if r.ImGui_Button(c,'Остановить##native_cancel')then self:cancel()end
  end
  if self.result and self.result.action~='native_download'and not self.result.ok and self.result.error then
    local issue=self.result.error
    r.ImGui_TextColored(c,(self.colors or{}).red or 0xEE7777FF,(issue.code or'AITN-200')..' — '..(issue.title or'Операция не завершена'))
    if issue.help and issue.help[1]then r.ImGui_TextWrapped(c,issue.help[1])end
  elseif self.native_notice then r.ImGui_TextWrapped(c,self.native_notice)end
  if self.neuralnote_choose then r.ImGui_TextWrapped(c,language=='en'and'Choose the folder containing your MuScriptor GGUF models. If you have not downloaded any yet, click Install in the table.'or'Укажите папку со скачанными моделями MuScriptor GGUF. Если моделей ещё нет, нажмите «Установить» в таблице.')end
  local discovery=self.result and self.result.native_discovery
  if discovery and #(discovery.skipped or{})>0 and r.ImGui_CollapsingHeader(c,'Не подключённые файлы##native_skipped')then
    for _,file in ipairs(discovery.skipped)do r.ImGui_TextWrapped(c,file.name..' — '..file.reason)end
  end
  if self.result and self.result.action~='native_download'and not self.result.ok and self.result.error and r.ImGui_CollapsingHeader(c,'Подробности ошибки##native_error')then r.ImGui_TextWrapped(c,self.result.error.detail or self.result.message or'Ошибка')end
  if self.maintenance_notice then r.ImGui_TextWrapped(c,self.maintenance_notice)end
  if r.ImGui_CollapsingHeader(c,language=='en'and'Download folder##native_location'or'Папка для загрузки моделей##native_location')then
    r.ImGui_BeginDisabled(c,blocked or self:busy())
    r.ImGui_SetNextItemWidth(c,-1)
    local changed,folder=r.ImGui_InputText(c,'##native_root',self.components_root)
    if changed then self.components_root=folder end
    if r.ImGui_Button(c,language=='en'and'Choose folder…##native_folder'or'Выбрать папку…##native_folder')then
      local chosen=self:choose_folder('Папка компонентов Ai Transcriber',self.components_root)
      if chosen then self.components_root=chosen end
    end
    r.ImGui_EndDisabled(c)
  end
end
function methods:draw(c,blocked)
  -- Keep the temporary-file utility and compatibility with old running jobs.
  -- All current Native model controls are rendered by the main settings popup.
  if self.open and(self.page==8 or self.job and not tostring(self.job.action):match('^native_'))then Legacy.draw(self,c,blocked)end
end
function M.new(r,dir,state,J,on_change,data)
  local self=Legacy.new(r,dir,state,J,on_change,data)
  self.native=J.load_json(state..'\\native_active.json',J.load_json(state..'\\native_active.json.bak',{schema=1,weights={}}))
  if type(self.native)~='table'or type(self.native.weights)~='table'then self.native={schema=1,weights={}}end
  for name,fn in pairs(methods)do self[name]=fn end
  self.downloads=Downloads.new(self)
  self.inspect_pending=false;self.native_view=true
  -- New downloads share one folder; existing GGUF paths are never migrated.
  -- Reuse a custom saved location, but replace former default suggestions.
  data=data or self.data_root
  local function key(path)return type(path)=='string'and path:gsub('/','\\'):gsub('\\+$',''):lower()or''end
  local parent=data and data:match('^(.*)[/\\][^/\\]+$')
  local saved=self.native.components_root or self.native.data_root
  if not self.native.components_root and parent and(key(saved)==key(parent..'\\MuScriptor')or key(saved)==key(state..'\\components'))then saved=nil end
  self.components_root=type(saved)=='string'and saved~=''and saved or data
  if not(self.native.weights.small or self.native.weights.medium or self.native.weights.large)then self.open=true;self.native_intro=not self.intro_seen end
  return self
end
return M
