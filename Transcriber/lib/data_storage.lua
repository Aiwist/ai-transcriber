-- One storage preference shared by both editions and carried by the REAPER profile.
local M={};M.__index=M
local KEY='data_storage_v1'
local function norm(p)return type(p)=='string'and p:gsub('/','\\'):gsub('\\+$','')or''end
local function within(p,root)
  p,root=norm(p),norm(root)
  if p:lower()==root:lower()then return ''end
  if p:sub(1,#root+1):lower()==root:lower()..'\\'then return p:sub(#root+2)end
end
local function valid(p)
  p=norm(p)
  return p:match('^%a:\\.+')and not p:find('[%z\1-\31<>|?*"]')and not p:sub(3):find(':',1,true)
    and not p:match('\\%.%.?\\')and not p:match('\\%.%.?$')
end
local function join(root,tail)
  tail=norm(tail)
  assert(not tail:match('^\\')and not tail:find(':',1,true)and not tail:match('^%.%.?\\')
    and not tail:match('\\%.%.?\\')and not tail:match('\\%.%.?$')and tail~='..','Invalid relative storage path')
  return norm(root)..(tail~=''and'\\'..tail or'')
end
local function map(value,fn,J)
  if type(value)=='string'then return fn(value)end
  if type(value)~='table'or value==J.null then return value end
  local result=setmetatable({},getmetatable(value))
  for k,v in pairs(value)do result[k]=map(v,fn,J)end
  return result
end
function M:expand(s)
  if s:sub(1,6)=='@data/'then return join(self.root,s:sub(7))end
  if s:sub(1,8)=='@reaper/'then return join(self.resource,s:sub(9))end
  return s
end
function M:pack(s)
  if self.mode=='system'then return s end
  local tail=within(s,self.root)
  if tail~=nil then return '@data/'..tail:gsub('\\','/')end
  tail=within(s,self.resource)
  if tail~=nil then return '@reaper/'..tail:gsub('\\','/')end
  return s
end
function M:install_codec()
  local J=self.J;local load,save=J.load_json,J.save_json
  J.load_json=function(path,fallback)
    local v=load(path,fallback)
    if within(path,self.root)~=nil then return map(v,function(s)return self:expand(s)end,J)end
    return v
  end
  J.save_json=function(path,value)
    -- Engine configuration is consumed directly by C++; always give it absolute paths.
    local name=norm(path):match('[^\\]+$')
    if within(path,self.root)~=nil and name~='config.json'and name~='.storage_context.json'then
      value=map(value,function(s)return self:pack(s)end,J)
    end
    return save(path,value)
  end
end
function M.selection(r,J,section,local_data)
  local resource=norm(r.GetResourcePath())
  local raw=r.GetExtState(section,KEY);local ok,pref=pcall(J.decode,raw)
  if raw~=''and(not ok or type(pref)~='table'or pref.schema~=1)then error('AITN-710: Повреждена настройка папки данных. Восстановите data_storage_v1 в профиле REAPER.')end
  local portable=r.file_exists(resource..'\\reaper.exe')and r.file_exists(resource..'\\reaper.ini')
  local mode=ok and pref.mode or(portable and'portable'or'system')
  local root
  if mode=='system'then root=local_data..'\\Aiwist\\Ai Transcriber'
  elseif mode=='portable'then root=resource..'\\Data\\Ai Transcriber'
  elseif mode=='custom'and type(pref.path)=='string'then root=pref.relative and join(resource,pref.path)or norm(pref.path)
  else error('AITN-710: Неизвестная настройка папки данных.')end
  assert(valid(root),'AITN-710: Недопустимая папка данных: '..tostring(root))
  return root,mode,resource
end
function M.new(r,J,section,local_data,state_paths)
  local root,mode,resource=M.selection(r,J,section,local_data)
  local notice
  if mode=='system'then local ignored;root,ignored,notice=state_paths.prepare(r,J,local_data)end
  r.RecursiveCreateDirectory(root..'\\jobs',0)
  local self=setmetatable({r=r,J=J,section=section,root=root,mode=mode,resource=resource,local_data=local_data},M)
  assert(J.save_json(root..'\\.storage_context.json',{schema=1,mode=mode,resource_root=resource,data_root=root}),
    'AITN-711: Не удалось записать в папку данных: '..root)
  self:install_codec()
  return self,root,mode=='system'and(local_data..'\\Ai Transcriber')or(root..'\\components'),notice
end
function M:preference(target,mode)
  local pref={schema=1,mode=mode}
  if mode=='custom'then
    local relative=within(target,self.resource)
    pref.path=relative or norm(target);pref.relative=relative~=nil
  end
  return pref
end
function M:target(mode)
  return mode=='system'and self.local_data..'\\Aiwist\\Ai Transcriber'or self.resource..'\\Data\\Ai Transcriber'
end
function M.recover(r,J,section,problem)
  local en=r.GetExtState(section,'language')=='en'
  local question=(en and'Cannot open the script data folder.\n\n'or'Не удалось открыть папку данных скрипта.\n\n')..tostring(problem)..'\n\n'..
    (en and'Choose another folder? Existing data stays in place; nothing will be copied from the unavailable folder.'or'Выбрать другую папку? Прежние данные останутся на месте; из недоступной папки ничего не копируется.')
  if r.MB(question,'Ai Transcriber',4)~=6 then return false end
  local ok,path
  if r.JS_Dialog_BrowseForFolder then
    local answer;answer,path=r.JS_Dialog_BrowseForFolder(en and'Ai Transcriber data folder'or'Папка данных Ai Transcriber',r.GetResourcePath());ok=answer==1
  else ok,path=r.GetUserInputs(en and'Ai Transcriber data folder'or'Папка данных Ai Transcriber',1,en and'Folder path,extrawidth=300'or'Путь к папке,extrawidth=300',r.GetResourcePath()..'\\Data\\Ai Transcriber')end
  if not ok then return false end
  path=norm(path)
  if not valid(path)or path:lower()==norm(r.GetResourcePath()):lower()then r.MB(en and'Choose a separate local folder.'or'Выберите отдельную папку на локальном диске.','Ai Transcriber',0);return false end
  r.RecursiveCreateDirectory(path,0)
  local probe=path..'\\.write-test-'..r.genGuid():gsub('[^%x]','')..'.tmp'
  local written,err=J.write(probe,'Ai Transcriber storage check');os.remove(probe)
  if not written then r.MB(tostring(err),'Ai Transcriber',0);return false end
  local self=setmetatable({resource=norm(r.GetResourcePath())},M)
  r.SetExtState(section,KEY,J.encode(self:preference(path,'custom')),true)
  return true
end
function M:request(owner,target,mode,blocked)
  if blocked or owner:busy()or owner.downloads:busy()then return false end
  target=norm(target)
  if not valid(target)or target:lower()==self.resource:lower()then self.notice='Выберите отдельную папку на локальном диске.';return false end
  if target:lower()==self.root:lower()then self.notice='Эта папка уже используется.';return false end
  local en=owner.language=='en'
  local reuse=false
  if self.r.file_exists(target..'\\.storage_context.json')then
    local answer=self.r.MB((en and'This folder already contains Ai Transcriber data. Use it without copying?\n\nYes: open the existing data. No: copy the current data (differing files will stop the operation).'or
      'В этой папке уже есть данные Ai Transcriber. Использовать их без копирования?\n\nДа — открыть имеющиеся данные. Нет — скопировать текущие данные (при различии файлов операция остановится).')..'\n\n'..target,'Ai Transcriber',3)
    if answer==2 then return false end
    reuse=answer==6
  end
  local message=(en and'Copy script data to:\n'or'Скопировать данные скрипта в папку:\n')..target..'\n\n'..
    (en and'Existing files will be verified. Source data stays in place. Model folders outside the data folder keep their locations. Close other Ai Transcriber windows before continuing. Reopen the script after completion.'or
    'Файлы будут проверены. Исходные данные останутся на месте. Папки моделей вне папки данных сохранят своё расположение. Перед продолжением закройте другие окна Ai Transcriber. После завершения потребуется заново открыть скрипт.')
  if not reuse and self.r.MB(message,'Ai Transcriber',1)~=1 then return false end
  self.pending=self:preference(target,mode)
  return owner:start('native_storage_migrate',{target_root=target,storage_mode=mode,reuse_existing=reuse,runtime_instance=owner.support_instance})
end
function M:completed(owner,result)
  if not result or not result.ok or not result.storage_target then self.pending=nil;return end
  -- Only adopt the fully verified destination returned by our worker.
  local pref=self:preference(result.storage_target,result.storage_mode)
  self.r.SetExtState(self.section,KEY,self.J.encode(pref),true)
  owner.restart_required=true;self.pending=nil
  self.notice=owner.language=='en'and'Data folder changed. Close and reopen Ai Transcriber.'or'Папка данных изменена. Закройте и снова откройте Ai Transcriber.'
end
function M:draw(owner,c,blocked,language)
  local r=self.r;local en=language=='en'
  if not r.ImGui_CollapsingHeader(c,en and'Script data folder##data_storage'or'Папка данных скрипта##data_storage')then return end
  r.ImGui_TextWrapped(c,self.root)
  r.ImGui_TextWrapped(c,en and'Logs, temporary files, settings and module data. Model download folders are configured separately.'or'Журналы, временные файлы, настройки и данные модулей. Папки загрузки моделей настраиваются отдельно.')
  r.ImGui_BeginDisabled(c,blocked or owner:busy()or owner.downloads:busy())
  if r.ImGui_Button(c,en and'Choose data folder…##data_choose'or'Выбрать папку данных…##data_choose',-1,28)then
    local chosen=owner:choose_folder(en and'Ai Transcriber data folder'or'Папка данных Ai Transcriber',self.root)
    if chosen then self:request(owner,chosen,'custom',blocked)end
  end
  if self.mode~='portable'and r.ImGui_Button(c,en and'Store with this REAPER##data_portable'or'Хранить рядом с этим REAPER##data_portable',-1,28)then self:request(owner,self:target('portable'),'portable',blocked)end
  if self.mode~='system'and r.ImGui_Button(c,en and'Use Windows user folder##data_system'or'Использовать папку пользователя Windows##data_system',-1,28)then self:request(owner,self:target('system'),'system',blocked)end
  r.ImGui_EndDisabled(c)
  if self.notice then r.ImGui_TextWrapped(c,self.notice)end
end
M.within=within
return M
