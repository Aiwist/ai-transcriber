-- Stable data location; never rename a Python/venv with embedded absolute paths.
local M = {}

local function pending(r, json, root)
  for _,name in ipairs({'running_job.json','active_job.json'}) do
    local job=json.load_json(root..'\\'..name,json.load_json(root..'\\'..name..'.bak',{}))
    if type(job)=='table' and type(job.id)=='string' and #job.id==32 and job.id:match('^%x+$') then
      local directory=root..'\\jobs\\'..job.id
      if job.directory==directory and not r.file_exists(directory..'\\result.json') then return true end
    end
  end
  return false
end

local function forget_credentials(r, roots)
  local failed={}
  for _,root in ipairs(roots) do
    for _,name in ipairs({'credential.dpapi','credential.dpapi.tmp'}) do
      local path=root..'\\'..name
      if r.file_exists(path) then
        local removed=os.remove(path)
        if not removed then failed[#failed+1]=path end
      end
    end
  end
  if #failed>0 then
    return 'Не удалось удалить устаревший файл токена. Удалите его вручную:\n'..table.concat(failed,'\n')
  end
end

function M.prepare(r, json, local_app_data)
  local root=local_app_data..'\\Aiwist\\Ai Transcriber'
  local legacy=root..' 2.0'
  local data_root=local_app_data..'\\MuScriptor'
  -- Keep communicating with an already running worker at its original address.
  -- The next launch migrates only control state once that job has finished.
  local current_pending,legacy_pending=pending(r,json,root),pending(r,json,legacy)
  if not current_pending and legacy_pending then return legacy,data_root end
  r.RecursiveCreateDirectory(root..'\\jobs',0)
  -- Do not remove a credential that an already started OLD worker may still
  -- need. Cleanup is retried at the next launch after that job has finished.
  local notice
  if not current_pending and not legacy_pending then notice=forget_credentials(r,{root,legacy}) end
  if not current_pending then
    local active=json.load_json(root..'\\active.json',json.load_json(root..'\\active.json.bak',nil))
    if active==nil then
      active=json.load_json(legacy..'\\active.json',json.load_json(legacy..'\\active.json.bak',nil))
      if type(active)=='table' then
        -- Paths stay verbatim: existing environments and weights are reused in place.
        assert(json.save_json(root..'\\active.json',active),'Не удалось сохранить настройки компонентов в новой папке.')
      end
    end
  end
  return root,data_root,notice
end
local previous_prepare=M.prepare
function M.prepare(r,J,local_data)
  local root,data,notice=previous_prepare(r,J,local_data)
  if root==local_data..'\\Aiwist\\Ai Transcriber'then
    local here=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
    local Identity=dofile(here..'/profile_identity.lua')
    local merged,_,problem=Identity.prepare(r,J,local_data)
    return merged,data,notice or problem
  end
  return root,data,notice
end
return M
