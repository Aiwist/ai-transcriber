-- Isolated first-run UI smoke test: no project edits, downloads or saved consent.
local source=(debug.getinfo(1,'S').source or''):gsub('^@','')
local root=source:match('^(.*)[/\\]tests[/\\]')
assert(root,'Run the test from the project tests directory.')
local output=root..'/.work/reapack_ui_test.json'
local J=dofile(root..'/Transcriber/lib/json.lua')
local First=dofile(root..'/Transcriber/lib/first_run.lua')
local r=setmetatable({}, {__index=reaper})
local frames,visible,collapsed=0,0,0
local saved=false
r.GetExtState=function(_,key) return key=='language'and'ru'or'' end
r.SetExtState=function() saved=true;error('The test must not save consent.') end
r.MB=function(text) error(text) end
r.ImGui_Begin=function(c,label,open,...)
  frames=frames+1
  reaper.ImGui_SetNextWindowCollapsed(c,frames==2,reaper.ImGui_Cond_Always())
  local shown,keep=reaper.ImGui_Begin(c,label..'##reapack_ui_test',open,...)
  if shown then visible=visible+1 else collapsed=collapsed+1 end
  return shown,keep
end
r.ImGui_Button=function(c,label,...)
  local clicked=reaper.ImGui_Button(c,label,...)
  if label=='Отмена'and frames>=4 then
    local result={ok=visible>=2 and collapsed>=1 and not saved,frames=frames,visible=visible,collapsed=collapsed,saved_consent=saved}
    assert(J.save_json(output,result))
    reaper.SetExtState('reaper_mcp_script_result','last_result',J.encode(result),false)
    return true
  end
  return label=='Отмена'and clicked or false
end
reaper.RecursiveCreateDirectory(root..'/.work',0)
assert(not First.ensure(r,root..'/Transcriber',source,J))
