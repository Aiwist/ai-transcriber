-- Registers the installed script through REAPER's API. Never edits a project.
local _, context_path, context_section, context_command = reaper.get_action_context()
local source = (debug.getinfo(1, 'S').source or ''):gsub('^@', '')
local helper = source:match('[\\/]Register_Ai_Transcriber%.lua$') and source or context_path
local directory = (helper or ''):match('^(.*)[\\/]') or ''
local function read(path)
  local file = io.open(path, 'rb'); if not file then return '' end
  local text = file:read('*a') or ''; file:close()
  return text:gsub('^\239\187\191', '')
end
local function key(path) return (path or ''):gsub('/', '\\'):gsub('\\+$', ''):lower() end
local request = read(directory .. '\\reaper_registration.request')
local expected = request:match('^resource=([^\r\n]+)')
local id = request:match('[\r\n]request_id=([a-f0-9]+)')
local result_path = id and #id == 32 and (directory .. '\\setup\\registration\\reaper_registration_' .. id .. '.txt')
local target = directory .. '\\Aiwist_Transcriber.lua'
local function register()
  assert(result_path and expected, 'Повреждён запрос регистрации установщика.')
  assert(key(directory) == key(expected .. '\\Scripts\\Aiwist\\Transcriber'), 'Запущен регистратор не из установленной папки Transcriber.')
  assert(key(reaper.GetResourcePath()) == key(expected), 'Открыт другой REAPER: ресурсная папка не совпадает. Ожидалась: ' .. expected)
  for _,name in ipairs({'Aiwist_Transcriber.lua','lib/json.lua','lib/setup_ui.lua','lib/profile_identity.lua','lib/state_paths.lua','lib/hidden_runner.lua','lib/native_components.lua','lib/native_downloads.lua','lib/native_devices.lua','lib/gguf_health.lua','lib/last_result.lua','lib/support_zip.lua','setup/worker.ps1','setup/native_runner.ps1','setup/native_setup.ps1','manifest.json'})do
    assert(reaper.file_exists(directory..'/'..name),'Неполная установка: отсутствует '..name)
  end
  -- Repeated registration of the SAME installed path keeps its existing action.
  local command = reaper.AddRemoveReaScript(true, 0, target, true)
  assert(command and command > 0, 'REAPER не смог добавить Ai Transcriber в Actions.')
  return 'status=ok\r\nrequest_id=' .. id .. '\r\nscript=' .. target ..
    '\r\nresource=' .. reaper.GetResourcePath() .. '\r\ncommand_id=' .. command .. '\r\n'
end
local ok, result = pcall(register)
if not ok then
  result = 'status=error\r\nrequest_id=' .. (id or '') .. '\r\nerror=' .. tostring(result):gsub('[\r\n]', ' ') .. '\r\n'
end
if result_path then
  local file = io.open(result_path .. '.tmp', 'wb')
  if file then
    local written = file:write(result); local closed = file:close()
    if written and closed then os.rename(result_path .. '.tmp', result_path) end
  end
end
if context_command and context_command > 0 and key(context_path) == key(helper) then
  reaper.AddRemoveReaScript(false, context_section or 0, helper, true)
end
reaper.SetExtState('reaper_mcp_script_result', 'last_result', result, false)
reaper.defer(function() end) -- No undo point, no modal window, no transcription.
