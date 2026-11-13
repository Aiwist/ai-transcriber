local module = dofile(project_root .. '/Transcriber/lib/first_run.lua')
local terms_dir = project_root .. '/Transcriber'
local function setup(options)
  options = options or {}
  local events = {pending={}, saved={}, messages={}, begins=0, ends=0, child_begins=0, child_ends=0, created=0}
  local r = {
    GetExtState=function(_, key) return options.accepted and key=='license_revision' and '2026-11-10' or 'ru' end,
    SetExtState=function(_,key,value) events.saved[key]=value end,
    GetOS=function() return options.os or 'Win64' end,
    MB=function(message) events.messages[#events.messages+1]=message; return 6 end,
    ReaPack_BrowsePackages=function(filter) events.browser=filter end,
    file_exists=function(path) return not options.missing_runtime and not(options.missing_cpu and path:match('cpu%.exe$')) end,
    defer=function(fn) events.pending[#events.pending+1]=fn end,
    ImGui_CreateContext=function() events.created=events.created+1; return {} end,
    ImGui_GetVersion=function() return '1.92',19200,options.old_imgui and '0.9.3' or '0.10.0.5' end,
    ImGui_ValidatePtr=function() return not options.expired end,
    ImGui_Cond_FirstUseEver=function() return 1 end,
    ImGui_StyleVar_WindowPadding=function() return 0 end,
    ImGui_SetNextWindowSize=function() end,
    ImGui_SetNextWindowSizeConstraints=function() end,
    ImGui_PushStyleVar=function() end,
    ImGui_PopStyleVar=function() end,
    ImGui_Begin=function() if options.collapsed then return false,true end;events.begins=events.begins+1;return true,true end,
    ImGui_End=function() events.ends=events.ends+1 end,
    ImGui_GetContentRegionAvail=function() return 600,480 end,
    ImGui_TextWrapped=function() end,
    ImGui_BeginChild=function() if options.hidden_child then return false end;events.child_begins=events.child_begins+1;return true end,
    ImGui_EndChild=function() events.child_ends=events.child_ends+1 end,
    ImGui_Checkbox=function() return true,options.agreed==true end,
    ImGui_BeginDisabled=function() end,
    ImGui_EndDisabled=function() end,
    ImGui_Button=function(_,label) return label=='Принять и продолжить' and options.accept or label=='Отмена' and options.cancel or false end,
  }
  if options.no_imgui then r.ImGui_CreateContext=nil end
  local J={load_json=function() return {runtime={file='runtime/test.exe'},cpu_runtime={file='runtime/cpu.exe'}} end}
  events.ready=module.ensure(r,terms_dir,project_root..'/tests/first_run.lua',J)
  function events:frame() local fn=table.remove(self.pending,1);assert(fn);fn() end
  return events
end
local a=setup({accepted=true});assert(a.ready and #a.pending==0)
local b=setup({no_imgui=true});assert(not b.ready and b.browser=='ReaImGui' and #b.pending==0 and not next(b.saved))
local old=setup({old_imgui=true});assert(not old.ready and old.browser=='ReaImGui' and #old.pending==0)
local c=setup({missing_runtime=true});assert(not c.ready and c.messages[1]:find('AITN%-101') and #c.pending==0)
local cpu=setup({accepted=true,missing_cpu=true});assert(not cpu.ready and cpu.messages[1]:find('AITN%-101') and #cpu.pending==0)
local d=setup({os='OSX64'});assert(not d.ready and #d.pending==0)
local e=setup({agreed=true,accept=true});e:frame();assert(e.saved.license_revision=='2026-11-10' and #e.pending==1)
local f=setup({accept=true});f:frame();assert(not next(f.saved)) -- a click cannot bypass the checkbox
local g=setup({cancel=true});g:frame();assert(#g.pending==0 and not next(g.saved))
local h=setup({collapsed=true,expired=true});h:frame();h:frame();assert(h.created==2 and h.ends==0 and not next(h.saved))
local i=setup({hidden_child=true,cancel=true});i:frame();assert(i.child_begins==i.child_ends and i.begins==i.ends)

-- Verify the actual runtime selector without creating user state or jobs.
local Components=dofile(project_root..'/Transcriber/lib/native_components.lua')
local paths={['install/runtime/gpu.exe']=true,['install/runtime/cpu.exe']=true}
local r={RecursiveCreateDirectory=function() end,file_exists=function(path)return paths[path]==true end}
local spec={runtime={file='runtime/gpu.exe'},cpu_runtime={file='runtime/cpu.exe'}}
local J={load_json=function(path,default)if path:match('native_release%.json$')then return spec else return default end end}
local components=Components.new(r,'install','state',J,nil,'components')
assert(components:engine('cpu')=='install/runtime/cpu.exe')
assert(components:engine('auto')=='install/runtime/gpu.exe')
assert(components:engine('vulkan')=='install/runtime/gpu.exe')
paths['install/runtime/cpu.exe']=nil
assert(components:engine('cpu')==nil)
