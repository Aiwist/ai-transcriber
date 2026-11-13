-- os.getenv uses the Windows ANSI environment in some Lua builds. Native
-- REAPER paths and child command lines use UTF-8. Resolve before any writes.
local M={}
local function hex(value)return(value:gsub('.',function(c)return string.format('%02X',c:byte())end))end
local function path(value)
  return type(value)=='string'and #value>2 and #value<32768 and utf8.len(value)~=nil and
    not value:find('[%z\1-\31"<>|?*]')and(value:match('^%a:[/\\]')or value:match('^\\\\[^\\]+\\[^\\]+'))
end
local function environment_path(r,J,section,variable,key)
  local raw=os.getenv(variable)
  if not raw or raw==''then return nil,'Windows did not provide '..variable..'.'end
  -- Normal ASCII profiles need no subprocess or extra startup check.
  if not raw:find('[\128-\255?]')and path(raw)then return raw end
  local resource=r.GetResourcePath()
  local identity=hex(raw)..':'..hex(resource)
  local ok,cache=pcall(J.decode,r.GetExtState(section,key))
  if ok and type(cache)=='table'and cache.identity==identity and path(cache.path)then return cache.path end
  local system=os.getenv('SystemRoot')or'C:\\Windows'
  if not path(system)then return nil,'SystemRoot is not a valid UTF-8 path.'end
  -- Fixed ASCII command: no user paths, tokens or shell interpolation. Return
  -- ASCII hex so neither the console code page nor ExecProcess can alter it.
  local code="$p=[Environment]::GetEnvironmentVariable('"..variable.."');if(-not $p){throw '"..variable.." is empty'};[Console]::WriteLine('AIT2PATH:'+([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($p))).Replace('-',''))"
  local cmd='"'..system..'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "'..code..'"'
  local ran,response=pcall(r.ExecProcess,cmd,5000)
  local status,encoded
  if ran and type(response)=='string'then status,encoded=response:match('^(%-?%d+)[\r\n]+AIT2PATH:([%x]+)%s*$')end
  if status~='0'or not encoded or #encoded%2~=0 or #encoded>65534 then
    return nil,'Could not obtain the Unicode '..variable..' path. PowerShell query failed or timed out (5 seconds).'
  end
  local value=encoded:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end)
  if not path(value)then return nil,'Windows returned an invalid Unicode LOCALAPPDATA path.'end
  -- Cache only a system path, never credentials. Reopening the script does not
  -- launch PowerShell again; changed profile/resource paths invalidate it.
  pcall(r.SetExtState,section,key,J.encode({schema=1,identity=identity,path=value}),true)
  return value
end
function M.local_app_data(r,J,section)return environment_path(r,J,section,'LOCALAPPDATA','windows_local_app_data_v1')end
function M.roaming_app_data(r,J,section)return environment_path(r,J,section,'APPDATA','windows_roaming_app_data_v1')end
M.valid=path
return M
