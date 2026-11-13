-- Aiwist shared dependency-free JSON/file helpers. Lua 5.3+.
local M = {}
M.null = setmetatable({}, { __tostring = function() return 'null' end })
local array_mt = { __json_array = true }
function M.array(t) return setmetatable(t or {}, array_mt) end
local escape_map = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function quote(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c) return escape_map[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end
function M.encode(value)
  local seen = {}
  local function enc(v)
    if v == M.null or v == nil then return 'null' end
    local kind = type(v)
    if kind == 'string' then return quote(v) end
    if kind == 'boolean' then return v and 'true' or 'false' end
    if kind == 'number' then
      assert(v == v and v ~= math.huge and v ~= -math.huge, 'Non-finite JSON number')
      return string.format('%.17g', v):gsub(',', '.')
    end
    assert(kind == 'table', 'Unsupported JSON type: ' .. kind)
    assert(not seen[v], 'Cyclic JSON table'); seen[v] = true
    local parts, is_array, count = {}, getmetatable(v) == array_mt, 0
    for k in pairs(v) do count = count + 1 end
    if not is_array and count > 0 and #v == count then
      is_array = true
      for k in pairs(v) do if type(k) ~= 'number' or k < 1 or k > count or k % 1 ~= 0 then is_array = false end end
    end
    if is_array then
      for i=1,#v do parts[#parts+1] = enc(v[i]) end
      seen[v]=nil; return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys={}; for k in pairs(v) do assert(type(k)=='string','JSON object keys must be strings'); keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do parts[#parts+1]=quote(k)..':'..enc(v[k]) end
    seen[v]=nil; return '{' .. table.concat(parts, ',') .. '}'
  end
  return enc(value)
end
function M.decode(text)
  assert(type(text)=='string','JSON input must be a string')
  text=text:gsub('^\239\187\191','')
  local pos, len = 1, #text
  local function fail(msg) error('JSON at byte '..pos..': '..msg,0) end
  local function ws() local _,last=text:find('^[ \n\r\t]*',pos); pos=(last or pos-1)+1 end
  local function hex4()
    local h=text:sub(pos,pos+3); if #h~=4 or not h:match('^%x%x%x%x$') then fail('Invalid Unicode escape') end
    pos=pos+4; return tonumber(h,16)
  end
  local function str()
    pos=pos+1; local out={}; local start=pos
    while pos<=len do
      local c=text:sub(pos,pos)
      if c=='"' then out[#out+1]=text:sub(start,pos-1); pos=pos+1; return table.concat(out) end
      if c=='\\' then
        out[#out+1]=text:sub(start,pos-1); pos=pos+1; local e=text:sub(pos,pos); pos=pos+1
        local simple={ ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
        if e=='u' then
          local cp=hex4()
          if cp>=0xD800 and cp<=0xDBFF then
            if text:sub(pos,pos+1)~='\\u' then fail('Missing low surrogate') end
            pos=pos+2; local lo=hex4(); if lo<0xDC00 or lo>0xDFFF then fail('Invalid low surrogate') end
            cp=0x10000+(cp-0xD800)*1024+lo-0xDC00
          elseif cp>=0xDC00 and cp<=0xDFFF then fail('Unexpected low surrogate') end
          out[#out+1]=utf8.char(cp)
        elseif simple[e] then out[#out+1]=simple[e] else fail('Invalid escape') end
        start=pos
      elseif c:byte()<32 then fail('Control character in string') else pos=pos+1 end
    end
    fail('Unterminated string')
  end
  local parse
  parse=function(depth)
    if depth>128 then fail('Too much nesting') end
    ws(); local c=text:sub(pos,pos)
    if c=='"' then return str() end
    if c=='{' or c=='[' then
      local arr=c=='['; local result=arr and M.array() or {}; pos=pos+1; ws()
      local closing=arr and ']' or '}'
      if text:sub(pos,pos)==closing then pos=pos+1; return result end
      while true do
        local key
        if not arr then
          if text:sub(pos,pos)~='"' then fail('Expected object key') end
          key=str(); ws(); if text:sub(pos,pos)~=':' then fail('Expected colon') end; pos=pos+1
        end
        local value=parse(depth+1)
        if arr then result[#result+1]=value else result[key]=value end
        ws(); local sep=text:sub(pos,pos); pos=pos+1
        if sep==closing then return result end
        if sep~=',' then fail('Expected comma or closing bracket') end
        ws()
      end
    end
    for token,value in pairs({ ['true']=true, ['false']=false, ['null']=M.null }) do
      if text:sub(pos,pos+#token-1)==token then pos=pos+#token; return value end
    end
    local number=text:sub(pos):match('^-?%d+%.?%d*[eE]?[+-]?%d*')
    if number and #number>0 then
      if not (number:match('^-?%d+$') or number:match('^-?%d+%.%d+$') or number:match('^-?%d+[eE][+-]?%d+$') or number:match('^-?%d+%.%d+[eE][+-]?%d+$')) then fail('Invalid number') end
      if number:match('^-?0%d') then fail('Leading zero') end
      local n=tonumber(number); if not n or n==math.huge or n==-math.huge then fail('Invalid number') end
      pos=pos+#number; return n
    end
    fail('Unexpected token')
  end
  local result=parse(0); ws(); if pos<=len then fail('Trailing content') end; return result
end
function M.read(path)
  local f=io.open(path,'rb'); if not f then return nil end
  local data=f:read('*a'); f:close(); return data
end
function M.write(path,data)
  local f,err=io.open(path,'wb'); if not f then return nil,err end
  local ok,e=f:write(data); local closed,ce=f:close(); if not ok or not closed then return nil,e or ce end; return true
end
function M.load_json(path, fallback)
  local raw=M.read(path); if not raw then return fallback end
  local ok,value=pcall(M.decode,raw); return ok and value or fallback
end
function M.save_json(path,value)
  local tmp=path..'.tmp'; local ok,err=M.write(tmp,M.encode(value)); if not ok then return nil,err end
  -- Windows rename cannot replace an existing file. Keep a backup during replacement.
  os.remove(path..'.bak'); os.rename(path,path..'.bak')
  local moved,e=os.rename(tmp,path)
  if not moved then os.rename(path..'.bak',path); return nil,e end
  return true
end
function M.copy(source,target)
  if source:lower()==target:lower() then return true end
  local input,err=io.open(source,'rb'); if not input then return nil,err end
  local output,e=io.open(target,'wb'); if not output then input:close(); return nil,e end
  local ok,problem=true,nil
  while true do local block=input:read(1024*1024); if not block then break end; if not output:write(block) then ok=false; problem='Write failed'; break end end
  input:close(); local done,ce=output:close(); if not done then ok=false; problem=ce end
  return ok,problem
end
function M.ps_quote(s) return "'"..tostring(s):gsub("'","''").."'" end
function M.clean_name(s)
  s=tostring(s or 'ElevenLabs'):gsub('[%z\1-\31<>:"/\\|?*]','_'):gsub('^%s+',''):gsub('[%s%.]+$','')
  local n=utf8.offset(s,65); if n then s=s:sub(1,n-1) end
  if s=='' then s='ElevenLabs' end
  if s:upper():match('^(CON)$') or s:upper():match('^(PRN)$') or s:upper():match('^(AUX)$') or s:upper():match('^(NUL)$') or s:upper():match('^COM[1-9]$') or s:upper():match('^LPT[1-9]$') then s='_'..s end
  return s
end
function M.wav_header(frames,rate,channels)
  local bytes=frames*channels*2; assert(bytes<=0xffffffff-36,'WAV too large')
  return string.pack('<c4I4c4c4I4I2I2I4I4I2I2c4I4','RIFF',bytes+36,'WAVE','fmt ',16,1,channels,rate,rate*channels*2,channels*2,16,'data',bytes)
end
function M.pcm16(sample)
  if sample~=sample then sample=0 end
  sample=math.max(-1,math.min(1,sample)); local v=sample<0 and math.ceil(sample*32768) or math.floor(sample*32767)
  return string.pack('<i2',v)
end
function M.utf8_count(s) return utf8.len(s) or #s end
function M.format_time(seconds)
  return string.format('%02d:%05.2f',math.floor(seconds/60),seconds%60)
end
return M
