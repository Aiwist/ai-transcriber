-- The engine's own Vulkan list, queried off the UI thread without a model.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local Hidden=dofile(root..'/hidden_runner.lua')
local M={};M.__index=M
local function integer(n)return type(n)=='number'and n==math.floor(n)and n>=0 and n<64 end
local function selector(s)
  return type(s)=='table'and integer(s.index)and s.backend=='Vulkan'and type(s.name)=='string'and #s.name>0 and #s.name<=256 and not s.name:find('[%z\1-\31]')
end
local function clean(data)
  if type(data)~='table'or type(data.devices)~='table'or #data.devices<1 or #data.devices>64 then return end
  local out={devices={},automatic_index=data.automatic_index};local ids={};local cpu=false
  for _,d in ipairs(data.devices)do
    if type(d)~='table'or not integer(d.index)or ids[d.index]or type(d.name)~='string'or #d.name<1 or #d.name>256 or d.name:find('[%z\1-\31]')or(d.backend~='Vulkan'and d.backend~='CPU')then return end
    ids[d.index]=true;cpu=cpu or d.backend=='CPU'
    out.devices[#out.devices+1]={index=d.index,name=d.name,backend=d.backend,integrated=d.integrated==true}
  end
  if not cpu or not integer(out.automatic_index)or not ids[out.automatic_index]then return end
  return out
end
local function read(J,path)
  local f=io.open(path,'rb');if not f then return end
  local bytes=f:seek('end');f:close();if not bytes or bytes>65536 then return end
  return J.load_json(path)
end
local function pathkey(path)return tostring(path or''):gsub('/','\\'):lower()end
function M.new(r,J,dir,state,engine,section)
  local self=setmetatable({r=r,J=J,dir=dir,root=state,engine=engine,section=section,mode='auto',requested=true},M)
  local raw=r.GetExtState and r.GetExtState(section,'native_device_choice_v1')or''
  if #raw<=2048 then
    local ok,saved=pcall(J.decode,raw)
    if ok and type(saved)=='table'then
      if saved.device=='cpu'then self.mode='cpu'
      elseif saved.device=='vulkan'and selector(saved.native_device)then self.mode='vulkan';self.selected=saved.native_device end
    end
  end
  local cache=read(J,state..'/native_device_catalog.json')
  if cache and cache.schema==1 and pathkey(cache.engine)==pathkey(engine)and type(cache.checked)=='number'and os.time()-cache.checked>=0 and os.time()-cache.checked<86400 then
    self.catalog=clean(cache);self.requested=not self.catalog
    if self.catalog then self:reconcile()end
  end
  return self
end
function M:snapshot()
  local out={device=self.mode}
  if self.mode=='vulkan'and self.selected then out.native_device={index=self.selected.index,name=self.selected.name,backend=self.selected.backend}end
  return out
end
function M:select(row)
  if row.device~='auto'and row.device~='cpu'and not(row.device=='vulkan'and selector(row.native_device))then return false end
  self.mode=row.device;self.selected=row.native_device and{index=row.native_device.index,name=row.native_device.name,backend=row.native_device.backend}or nil
  local ok=pcall(self.r.SetExtState,self.section,'native_device_choice_v1',self.J.encode(self:snapshot()),true)
  self.save_error=not ok
  return true
end
function M:choices(language)
  local en=language=='en';local primary='GPU / CPU';local gpu={};local selected_found=self.mode~='vulkan'
  if self.catalog then
    for _,d in ipairs(self.catalog.devices)do
      if d.index==self.catalog.automatic_index then primary=d.backend=='CPU'and'CPU'or d.name end
      if d.backend=='Vulkan'then
        local selected=self.mode=='vulkan'and self.selected and self.selected.name==d.name and self.selected.backend==d.backend and self.selected.index==d.index
        selected_found=selected_found or selected
        gpu[#gpu+1]={label=d.name,device='vulkan',native_device={index=d.index,name=d.name,backend=d.backend},selected=selected}
      end
    end
    -- Different physical adapters can have identical names; make their rows distinct.
    for _,g in ipairs(gpu)do
      local count=0;for _,other in ipairs(gpu)do if other.label==g.native_device.name then count=count+1 end end
      if count>1 then g.label=g.native_device.name..' · GPU '..(g.native_device.index+1)end
    end
  end
  local rows={{label=(en and'Auto ('or'Авто (')..primary..')',device='auto',selected=self.mode=='auto'}}
  for _,g in ipairs(gpu)do rows[#rows+1]=g end
  rows[#rows+1]={label='CPU',device='cpu',selected=self.mode=='cpu'}
  if not selected_found then rows[#rows+1]={label=(en and'Unavailable: 'or'Не найдена: ')..(self.selected and self.selected.name or'GPU'),selected=true,missing=true}end
  return rows
end
function M:reconcile()
  if self.selected then
    local exact,unique,count=nil,nil,0
    for _,d in ipairs(self.catalog.devices)do if d.backend==self.selected.backend and d.name==self.selected.name then
      unique=d;count=count+1;if d.index==self.selected.index then exact=d end
    end end
    if not exact and count==1 then self.selected={index=unique.index,name=unique.name,backend=unique.backend}end
  end
end
function M:accept(data)
  local catalog=clean(data);if not catalog then return false end
  self.catalog=catalog;self.error=nil;self:reconcile()
  local cache={schema=1,checked=os.time(),engine=self.engine,devices=catalog.devices,automatic_index=catalog.automatic_index}
  local ok,written=pcall(self.J.save_json,self.root..'/native_device_catalog.json',cache)
  self.cache_error=not ok or not written
  return true
end
function M:launch()
  local id=self.r.genGuid():gsub('[^%x]','');local directory=self.root..'/jobs/'..id
  self.r.RecursiveCreateDirectory(directory,0)
  assert(self.J.save_json(directory..'/job.json',{schema=1,id=id,action='native_devices',resource_root=self.dir}),'Не удалось сохранить запрос устройств.')
  self.job={id=id,directory=directory,started=self.r.time_precise()}
  Hidden.setup(self.r,self.dir,self.root,directory..'/job.json')
end
function M:poll(blocked)
  if self.job then
    local result=read(self.J,self.job.directory..'/result.json')
    if result and result.job_id==self.job.id then
      local good=result.ok and self:accept(result.native_devices)
      self.job=nil
      if not good then self.error='Не удалось определить устройства. Можно выбрать Авто или CPU и обновить список.'end
    elseif self.r.time_precise()-self.job.started>35 then
      pcall(self.J.write,self.job.directory..'/cancel.request','device detection timeout\n')
      self.job=nil;self.error='Определение устройств заняло слишком много времени. Можно выбрать Авто или CPU.'
    end
  elseif self.requested and self.seen and self.r.time_precise()-self.seen>0.5 and not blocked then
    self.requested=false;self.error=nil
    local ok=pcall(self.launch,self)
    if not ok then
      if self.job then pcall(self.J.write,self.job.directory..'/cancel.request','launch unconfirmed\n')end
      self.job=nil;self.error='Не удалось запустить определение устройств. Можно выбрать Авто или CPU.'
    end
  end
end
function M:draw(c,language,colors)
  self.seen=self.seen or self.r.time_precise();local r=self.r;local en=language=='en';local rows=self:choices(language);local preview
  for _,row in ipairs(rows)do if row.selected then preview=row.label end end
  if r.ImGui_BeginCombo(c,'##device',preview or rows[1].label)then
    for i,row in ipairs(rows)do
      r.ImGui_BeginDisabled(c,row.missing==true)
      if r.ImGui_Selectable(c,row.label..'##native_device_'..i,row.selected)and not row.missing then self:select(row)end
      r.ImGui_EndDisabled(c)
    end
    r.ImGui_Separator(c)
    r.ImGui_BeginDisabled(c,self.job~=nil)
    if r.ImGui_Selectable(c,(en and'Refresh devices'or'Обновить список устройств')..'##native_device_refresh',false)then self.requested=true end
    r.ImGui_EndDisabled(c);r.ImGui_EndCombo(c)
  end
  if r.ImGui_IsItemHovered(c)then r.ImGui_SetTooltip(c,en and'Auto prefers a compatible GPU and can fall back to CPU. A specific GPU is used only when explicitly available.'or'Авто предпочитает совместимую видеокарту и может перейти на CPU. При выборе конкретной карты используется только она.')end
  if self.job or self.requested then r.ImGui_TextColored(c,(colors or{}).text_muted or 0xAAAAAAFF,en and'Detecting devices…'or'Определение устройств…')
  elseif self.error then r.ImGui_TextWrapped(c,self.error)end
  if self.save_error then r.ImGui_TextWrapped(c,en and'Device choice is kept for this run only.'or'Выбор устройства сохранён только до закрытия скрипта.')end
end
function M:close()
  if self.job then pcall(self.J.write,self.job.directory..'/cancel.request','window closed\n')end
end
return M
