-- REAPER's async ExecProcess path can create a visible console before
-- PowerShell handles -WindowStyle. Wait only for a short hidden launcher;
-- the supervised runner stays detached for the duration of transcription.
local M={}
local function quote(value)
  assert(type(value)=='string'and value~=''and not value:find('[%z\r\n"]'),'Некорректный путь запуска помощника.')
  return '"'..value:gsub('(\\+)$','%1%1')..'"'
end
local function launch(r,directory,arguments)
  local ps=(os.getenv('SystemRoot')or'C:\\Windows')..'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
  local cmd=quote(ps)..' -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '..
    quote(directory..'\\setup\\launch_process.ps1')..arguments
  -- This is not the neural process timeout. The launcher only starts the real
  -- runner with CreateNoWindow, acknowledges creation and exits immediately.
  local response=r.ExecProcess(cmd,5000)
  local code=type(response)=='string'and tonumber(response:match('^(%-?%d+)'))or type(response)=='number'and response
  assert(code==0,'Не удалось подтвердить фоновый запуск помощника. Проверьте журнал задания и разрешения Windows PowerShell. '..tostring(response or'Нет ответа.'):sub(1,1200))
  return response
end
function M.launch(r,directory,root,work,mode)
  assert(mode=='Run'or mode=='Check','Неизвестный режим помощника.')
  return launch(r,directory,' -WorkDir '..quote(work)..' -StateRoot '..quote(root)..' -Mode '..mode)
end
function M.setup(r,directory,root,config,recover)
  assert(recover==nil or type(recover)=='boolean','Неизвестный режим проверки компонентов.')
  return launch(r,directory,' -Config '..quote(config)..' -StateRoot '..quote(root)..(recover and' -Recover'or''))
end
return M
