-- Durable, project-bound MIDI note snapshot. No Python/model is needed to replay.
local M={}
local LIMIT=32*1024*1024
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e10 end
local function integer(n,a,b) return finite(n) and n%1==0 and n>=a and n<=b end
-- REAPER has no native GetProjectGUID. The master track provides a stable
-- project identity without an extension, project writes or a saved RPP path.
function M.project_guid(r,project)
  if type(r.GetMasterTrack)=='function' and type(r.GetTrackGUID)=='function' then
    local ok,guid=pcall(function()
      local master=r.GetMasterTrack(project or 0)
      if master then return r.GetTrackGUID(master) end
    end)
    if ok and type(guid)=='string' and guid~='' and #guid<=128 and not guid:find('[%z\r\n]') and
      guid:gsub('[{}%-]',''):match('^0+$')==nil then return guid end
  end
  return nil,'Не удалось прочитать идентификатор проекта REAPER. Откройте проект и повторите попытку.'
end
local function bounded(path)
  local f=io.open(path,'rb');if not f then return nil end
  local size=f:seek('end');f:close();return size and size<=LIMIT and size>0
end
function M.validate(data)
  assert(type(data)=='table' and data.schema==1,'Неверный формат последнего результата.')
  local c=data.context
  assert(type(c)=='table' and type(c.project_guid)=='string' and c.project_guid~='','Не указан исходный проект MIDI.')
  assert(c.project_identity==nil or c.project_identity=='master_track_guid_v1','Неизвестный способ привязки MIDI к проекту.')
  assert(type(c.track_guid)=='string' and (c.force_channel_one==nil or type(c.force_channel_one)=='boolean'),'Повреждены параметры импорта MIDI.')
  assert(finite(c.position) and finite(c.duration) and c.duration>0,'Некорректное время MIDI.')
  assert(type(data.notes)=='table' and #data.notes>0 and #data.notes<=1000000,'Нет корректных MIDI-нот.')
  assert(type(data.names)=='table' and type(data.pitch)=='table' and #data.pitch<=1000000,'Повреждены события MIDI.')
  for key,name in pairs(data.names)do assert(type(key)=='string' and key:match('^%d+$') and type(name)=='string' and #name<=512,'Повреждено название MIDI-дорожки.')end
  for _,n in ipairs(data.notes) do
    assert(integer(n.track,0,65535) and integer(n.pitch,0,127) and integer(n.velocity,1,127) and
      integer(n.channel,0,15) and finite(n.start) and n.start>=0 and finite(n.finish) and n.finish>n.start,'Повреждена MIDI-нота.')
  end
  for _,e in ipairs(data.pitch) do
    assert(integer(e.track,0,65535) and integer(e.channel,0,15) and integer(e.bend,-8192,8191) and finite(e.time) and e.time>=0,'Повреждено событие pitch bend.')
  end
  return data
end
function M.capture(path,context)
  assert(bounded(path) and bounded(path..'.notes.tsv'),'Файл результата отсутствует или слишком большой.')
  local midi=assert(io.open(path,'rb'));local header=midi:read(4);midi:close();assert(header=='MThd','Повреждён MIDI-файл.')
  local data={schema=1,created=os.time(),context=context,notes={},names={},pitch={}}
  for line in io.lines(path..'.notes.tsv') do
    local ti,name,s,e,p,v,ch=line:match('^(%d+)\t([^\t]*)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)\t(%d+)$')
    assert(ti,'Повреждена таблица MIDI-нот.')
    data.names[tostring(tonumber(ti))]=name:sub(1,512)
    data.notes[#data.notes+1]={track=tonumber(ti),start=tonumber(s),finish=tonumber(e),pitch=tonumber(p),velocity=tonumber(v),channel=tonumber(ch)}
  end
  local pitch_path=path..'.notes.tsv.pitch.tsv';local f=io.open(pitch_path,'rb')
  if f then
    f:close();assert(bounded(pitch_path),'Слишком большой файл pitch bend.')
    for line in io.lines(pitch_path) do
      local ti,_,_,_,ch,t,b=line:match('^(%d+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)\t([^\t]+)\t(-?%d+)$')
      assert(ti,'Повреждена таблица pitch bend.')
      data.pitch[#data.pitch+1]={track=tonumber(ti),channel=tonumber(ch),time=tonumber(t),bend=tonumber(b)}
    end
  end
  return M.validate(data)
end
function M.save(J,root,data)
  M.validate(data)
  assert(#J.encode(data)<=LIMIT,'Последний MIDI слишком большой для сохранения.')
  assert(J.save_json(root..'\\last_result.json',data),'Не удалось сохранить последний MIDI.')
end
function M.load(J,root)
  for _,suffix in ipairs({'','.bak'}) do
    local path=root..'\\last_result.json'..suffix
    if bounded(path) then
      local ok,data=pcall(function()return M.validate(J.load_json(path))end)
      if ok then return data end
    end
  end
  return nil,'Сохранённый MIDI отсутствует или повреждён. Выполните новую транскрипцию.'
end
function M.import(r,data)
  local ok,problem=pcall(M.validate,data);if not ok then return false,problem end
  local c=data.context
  local guid,identity_error=M.project_guid(r)
  local matches=guid~=nil and guid==c.project_guid
  -- Preserve older snapshots if a host supplied its own project-GUID helper.
  -- New snapshots never depend on that non-native API or use it as a fallback.
  if not matches and c.project_identity==nil and type(r.GetProjectGUID)=='function' then
    local legacy_ok,legacy_guid=pcall(r.GetProjectGUID,0)
    matches=legacy_ok and type(legacy_guid)=='string' and legacy_guid==c.project_guid
  end
  if not matches then return false,identity_error or 'Этот MIDI относится к другому проекту. Откройте исходный проект и повторите вставку.' end
  local index=r.CountTracks(0);local source_found=false
  for i=0,r.CountTracks(0)-1 do
    if r.GetTrackGUID(r.GetTrack(0,i))==c.track_guid then index=i+1;source_found=true;break end
  end
  local sources,seen={},{}
  for _,n in ipairs(data.notes)do if not seen[n.track]then seen[n.track]=true;sources[#sources+1]=n.track end end
  table.sort(sources)
  local created,notes={},0
  r.Undo_BeginBlock2(0);r.PreventUIRefresh(1)
  local imported,err=xpcall(function()
    for _,source in ipairs(sources)do
      local before=r.CountTracks(0);r.InsertTrackAtIndex(index,true)
      assert(r.CountTracks(0)==before+1,'Не удалось создать новую дорожку.')
      local track=assert(r.GetTrack(0,index),'Не удалось создать дорожку.');created[#created+1]=track
      r.GetSetMediaTrackInfo_String(track,'P_NAME',data.names[tostring(source)] or ('Instrument '..source),true)
      local item=assert(r.CreateNewMIDIItemInProj(track,c.position,c.position+math.max(c.duration,0.01),false),'Не удалось создать MIDI-объект.')
      local take=assert(r.GetActiveTake(item),'Не удалось получить MIDI take.')
      for _,n in ipairs(data.notes)do if n.track==source then
        local first=r.MIDI_GetPPQPosFromProjTime(take,c.position+n.start)
        local last=r.MIDI_GetPPQPosFromProjTime(take,c.position+n.finish)
        assert(last>first and r.MIDI_InsertNote(take,false,false,first,last,c.force_channel_one and 0 or n.channel,n.pitch,n.velocity,true)~=false,'Не удалось вставить MIDI-ноту.')
        notes=notes+1
      end end
      for _,e in ipairs(data.pitch)do if e.track==source then
        local wheel=e.bend+8192
        assert(r.MIDI_InsertCC(take,false,false,r.MIDI_GetPPQPosFromProjTime(take,c.position+e.time),0xE0,c.force_channel_one and 0 or e.channel,wheel%128,math.floor(wheel/128),true)~=false,'Не удалось вставить pitch bend.')
      end end
      r.MIDI_Sort(take);index=index+1
    end
  end,debug.traceback)
  if not imported then for i=#created,1,-1 do pcall(r.DeleteTrack,created[i])end end
  r.PreventUIRefresh(-1);r.UpdateArrange();r.Undo_EndBlock2(0,'Ai Transcriber: вставить MIDI',-1)
  if not imported then return false,err end
  return true,#created,notes
end
return M
