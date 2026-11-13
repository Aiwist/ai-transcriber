-- Support ZIP writer and bounded, fixed-name diagnostic collector. Pure Lua:
-- no PowerShell, Python, downloads, recursive scans or credential-file access.
local M={}
local function replace(text,from,to)
  if type(from)~='string'or from==''or utf8.len(from)==nil then return text end
  return text:gsub(from:gsub('(%W)','%%%1'),function()return to end)
end
function M.redact(value,prefixes)
  local text=tostring(value or '')
  text=text:gsub('hf_[%w_]+','[TOKEN REDACTED]'):gsub('[Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s"<>]+','Bearer [REDACTED]')
  text=text:gsub('(["\']?)([%w_]+)%1(%s*[:=]%s*)(["\'])(.-)%4',function(keyquote,key,sep,quote,body)
    if key:lower():find('token',1,true)or key:lower():find('password',1,true)or key:lower():find('authorization',1,true)or key:lower():find('api_key',1,true)then body='[REDACTED]'end
    return keyquote..key..keyquote..sep..quote..body..quote
  end)
  text=text:gsub('([%w_]+)(%s*[:=]%s*)([^%s,;}]+)',function(key,sep,body)
    if key:lower():find('token',1,true)or key:lower():find('password',1,true)or key:lower():find('authorization',1,true)or key:lower():find('api_key',1,true)then body='[REDACTED]'end
    return key..sep..body
  end)
  text=text:gsub('(https?://[^%s?"<>]+)%?[^%s"<>]+','%1?[QUERY REDACTED]')
  for _,prefix in ipairs(prefixes or {})do
    text=replace(text,prefix.path,prefix.label)
    text=replace(text,prefix.path and prefix.path:gsub('\\','\\\\'),prefix.label)
  end
  -- Preserve valid Unicode. Render invalid bytes as ASCII diagnostics, rather
  -- than publishing a broken UTF-8 report or guessing the user's code page.
  if not utf8.len(text)then text=text:gsub('[\128-\255]',function(c)return string.format('\\x%02X',c:byte())end)end
  text=text:sub(1,131072)
  while not utf8.len(text)do text=text:sub(1,-2)end
  return text
end
local crc_table={}
for value=0,255 do
  local crc=value
  for _=1,8 do crc=(crc>>1)~((crc&1)==1 and 0xEDB88320 or 0)end
  crc_table[value]=crc
end
local function crc32(text)
  local crc=0xFFFFFFFF
  for i=1,#text do crc=(crc>>8)~crc_table[(crc~text:byte(i))&0xFF]end
  return (~crc)&0xFFFFFFFF
end
local function clean(value,prefixes,depth)
  if type(value)=='string'then return M.redact(value,prefixes)end
  if type(value)~='table'then return value end
  if depth>8 then return '[DETAIL OMITTED]'end
  local copy={}
  for key,item in pairs(value)do
    local name=tostring(key):lower()
    if name:find('token',1,true)or name:find('password',1,true)or name:find('authorization',1,true)or name:find('api_key',1,true)then copy[key]='[REDACTED]'
    else copy[key]=clean(item,prefixes,depth+1)end
  end
  return copy
end
local function utf16(text,big_endian)
  local out={};local index=1
  local function unit(at)
    local a,b=text:byte(at,at+1);if not b then return nil end
    return big_endian and a*256+b or a+b*256
  end
  while index<#text do
    local point=unit(index);index=index+2
    if point>=0xD800 and point<=0xDBFF then
      local low=unit(index)
      if low and low>=0xDC00 and low<=0xDFFF then point=0x10000+(point-0xD800)*1024+low-0xDC00;index=index+2
      else point=0xFFFD end
    elseif point>=0xDC00 and point<=0xDFFF then point=0xFFFD end
    out[#out+1]=utf8.char(point)
  end
  return table.concat(out)
end
local function tail(J,path,prefixes)
  local f=io.open(path,'rb');if not f then return nil,'unavailable'end
  local first=f:read(3)or'';local length=f:seek('end')
  if not length then f:close();return nil,'unreadable'end
  local start=math.max(0,length-131072);local is16=first:sub(1,2)=='\255\254'or first:sub(1,2)=='\254\255'
  if is16 then start=start-start%2 end
  f:seek('set',start);local text=f:read(math.min(131072,length-start))or'';f:close()
  if is16 then
    if start==0 then text=text:sub(3)end
    text=utf16(text,first:sub(1,2)=='\254\255')
  elseif start==0 and first=='\239\187\191'then text=text:sub(4)end
  if start>0 then text=text:match('\n(.*)')or''end
  if text:find('%z')then return nil,'not a text log'end
  -- Parse complete JSON before masking so secrets in escaped detail strings
  -- are cleaned before they are serialized again. Raw requests are never read.
  if path:sub(-5)=='.json'and start==0 then
    local ok,value=pcall(J.decode,text)
    if ok then return M.redact(J.encode(clean(value,prefixes,0)),prefixes)end
  end
  return M.redact(text,prefixes)
end
local function identifier(value)return type(value)=='string'and #value==32 and value:match('^%x+$')end
function M.collect(r,J,root,job_ids,instance,prefixes)
  local entries,skipped,seen={}, {}, {};local bytes=0
  local function add(relative)
    local text,why=tail(J,root..'\\'..relative:gsub('/','\\'),prefixes)
    if not text then
      if r.file_exists(root..'\\'..relative:gsub('/','\\'))then skipped[#skipped+1]=relative..': '..why end
      return
    end
    if bytes+#text>3800000 or #entries>=56 then skipped[#skipped+1]=relative..': report size limit';return end
    entries[#entries+1]={name=relative,text=text};bytes=bytes+#text
  end
  local ids={}
  for _,id in ipairs(job_ids or{})do if identifier(id)and not seen[id]and #ids<4 then ids[#ids+1]=id;seen[id]=true end end
  -- Recovery pointers contain only job identity. Derive the directory locally;
  -- never use a path supplied by a pointer or include pointer/request contents.
  for _,name in ipairs({'active_job.json','running_job.json'})do
    local value=tail(J,root..'\\'..name)
    if value and #value<=8192 then
      local ok,pointer=pcall(J.decode,value)
      if ok and type(pointer)=='table'and identifier(pointer.id)and not seen[pointer.id]and #ids<4 then ids[#ids+1]=pointer.id;seen[pointer.id]=true end
    end
  end
  for _,id in ipairs(ids)do
    for _,name in ipairs({'result.json','status.json','bootstrap.json','bootstrap_error.json','launch_error.log','console.log','runtime.log','probe_mu.log','probe_bp.log','model_validation.log','download.log'})do add('jobs/'..id..'/'..name)end
  end
  if identifier(instance)then
    for _,name in ipairs({'muscriptor_helper_log.txt','muscriptor_helper_log.txt.err','launch_error.log','diagnostic.json','exit.json','process.json','native_result.json','native_progress.json'})do add('runtime_temp/'..instance..'/'..name)end
  end
  return entries,skipped
end
function M.pack(entries)
  local body,central,seen={},{},{};local offset,count,total=0,0,0
  for _,entry in ipairs(entries)do
    local name,data=entry.name,entry.text
    assert(name:match('^[a-zA-Z0-9_./-]+$')and name:sub(1,1)~='/'and not name:find('..',1,true)and #name<160 and #data<=131072 and not seen[name],'Invalid support ZIP entry')
    seen[name]=true;total=total+#data;assert(total<=4194304,'Support ZIP is too large')
    local crc=crc32(data);local size=#data
    local record=string.pack('<I4I2I2I2I2I2I4I4I4I2I2',0x04034B50,20,0x800,0,0,33,crc,size,size,#name,0)..name..data
    body[#body+1]=record
    central[#central+1]=string.pack('<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4',0x02014B50,20,20,0x800,0,0,33,crc,size,size,#name,0,0,0,0,0,offset)..name
    offset=offset+#record;count=count+1
  end
  assert(count>0 and count<=64,'Invalid support ZIP inventory')
  local directory=table.concat(central)
  return table.concat(body)..directory..string.pack('<I4I2I2I2I2I4I4I2',0x06054B50,0,0,count,count,#directory,offset,0)
end
function M.reveal(r,file)
  if r.CF_LocateInExplorer then return r.CF_LocateInExplorer(file)end
  return r.ExecProcess('explorer.exe /select,"'..file..'"',-1)
end
function M.create(r,J,folder,summary,prefixes,options)
  assert(type(folder)=='string'and utf8.len(folder)and not folder:find('[%z\1-\31"<>|?*]'),'Invalid report folder')
  if options then assert(folder==options.root..'\\reports','Report logs must belong to the application state root')end
  r.RecursiveCreateDirectory(folder,0)
  local name='Ai_Transcriber_Support_'..os.date('%Y-%m-%d_%H-%M-%S')..'_'..r.genGuid():gsub('[^%x]','')..'.zip'
  local destination=folder..'\\'..name
  local part=destination..'.part'
  assert(not r.file_exists(destination)and not r.file_exists(part),'Support ZIP already exists')
  -- The caller explicitly selects fields. Never serialize the manager/request,
  -- active config wholesale, draft token, saved credentials or arbitrary logs.
  local text=M.redact(J.encode(clean(summary,prefixes,0)),prefixes)
  local entries={{name='README.txt',text='Support report created directly by Ai Transcriber in Lua. Includes selected UI/component/launch diagnostics and available fixed-name text logs (128 KiB per file, 4 MiB total). No token, audio, MIDI, weights, raw requests or environment dump. No automatic upload.'},
    {name='diagnostics.txt',text=text}}
  local logs,skipped={},{}
  if options then logs,skipped=M.collect(r,J,options.root,options.job_ids,options.instance,prefixes)end
  for _,entry in ipairs(logs)do entries[#entries+1]=entry end
  if options then entries[#entries+1]={name='logs_status.txt',text=M.redact('Included logs: '..#logs..'\n'..(#logs==0 and'No readable logs were available. UI diagnostics are included.\n'or'')..table.concat(skipped,'\n'),prefixes)}end
  local bytes=M.pack(entries)
  local written,problem=J.write(part,bytes)
  if not written then os.remove(part)end
  assert(written,'Не удалось записать ZIP-отчёт: '..tostring(problem))
  local moved,move_error=os.rename(part,destination)
  assert(moved,'Не удалось завершить ZIP-отчёт: '..tostring(move_error))
  return {path=destination,bytes=#bytes,files=#entries,logs=#logs,emergency=options==nil}
end
function M.startup_error(r,J,message,version,app)
  local question='Не удалось прочитать путь профиля Windows. Данные и компоненты не изменены.\n\n'..message..'\n\nСохранить аварийный ZIP-отчёт?'
  if r.ShowMessageBox(question,app,4)~=6 then return end
  local ok,result=pcall(M.create,r,J,r.GetResourcePath()..'\\Reports\\'..app,
    {app=app,version=version,stage='Windows profile path',error=message,reaper=r.GetAppVersion and r.GetAppVersion(),
      local_app_data_utf8=utf8.len(os.getenv('LOCALAPPDATA')or'')~=nil})
  if ok then pcall(M.reveal,r,result.path)else r.ShowMessageBox(tostring(result),app,0)end
end
return M
