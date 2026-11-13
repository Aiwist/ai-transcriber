-- Instrument choices belong to stable project/track GUIDs.
-- Sidecars keep preferences across script restarts without writing the RPP.
local M={};M.__index=M
local LIMIT=262144
local function identifier(value)
  return type(value)=='string'and #value>0 and #value<=128 and not value:find('[%z\1-\31]')
end
function M.new(r,J,root,instruments)
  return setmetatable({r=r,J=J,root=root..'\\instrument_selections',instruments=instruments,projects={}},M)
end
function M:clean(value)
  value=type(value)=='table'and value or{}
  local chosen={};local keys={}
  for _,entry in ipairs(self.instruments)do
    if type(value.instruments)=='table'and value.instruments[entry.key]==true then chosen[entry.key]=true;keys[#keys+1]=entry.key end
  end
  local tags=value.instrument_tags
  if type(tags)~='string'or #tags>512 or tags:find('[%z\1-\31]')or not utf8.len(tags)then tags=table.concat(keys,', ')end
  return{instruments=chosen,instrument_tags=tags}
end
function M:path(project)
  return self.root..'\\'..project:gsub('.',function(c)return string.format('%02x',c:byte())end)..'.json'
end
function M:load(project)
  if self.projects[project]then return self.projects[project]end
  local result={schema=1,project=project,tracks={}}
  for _,suffix in ipairs({'','.bak'})do
    local file=io.open(self:path(project)..suffix,'rb');local raw
    if file then local size=file:seek('end');if size and size>0 and size<=LIMIT then file:seek('set',0);raw=file:read('*a')end;file:close()end
    local ok,data=pcall(self.J.decode,raw or'')
    if ok and type(data)=='table'and data.schema==1 and data.project==project and type(data.tracks)=='table'then
      local count=0
      for track,value in pairs(data.tracks)do if identifier(track)then
        count=count+1;if count>1024 then break end
        result.tracks[track]=self:clean(value)
      end end
      break
    end
  end
  self.projects[project]=result;return result
end
function M:remember(state)
  if not self.project or not self.track then return end
  local data=self:load(self.project);local entry=self:clean(state)
  if self.J.encode(data.tracks[self.track])~=self.J.encode(entry)then data.tracks[self.track]=entry;data.dirty=true end
  if not data.dirty then return end
  local payload={schema=1,project=self.project,tracks=data.tracks}
  local ok,saved=pcall(function()
    local count=0;for _ in pairs(data.tracks)do count=count+1 end;assert(count<=1024,'Too many remembered tracks')
    assert(#self.J.encode(payload)<=LIMIT,'Instrument selection storage is full')
    self.r.RecursiveCreateDirectory(self.root,0)
    return self.J.save_json(self:path(self.project),payload)
  end)
  if ok and saved then data.dirty=nil;data.error=nil;self.error=nil
  else data.error=true;self.error=true end -- The in-memory choice remains usable if saving fails.
end
function M:select(project,track,state,mixed)
  if not identifier(project)then project=nil end
  if not identifier(track)then track=nil end
  local project_changed=project~=self.project
  if not project_changed and not track and not mixed then return end -- Temporary MIDI/no selection.
  if not project_changed and track==self.track and(mixed==true)==(self.mixed==true)then return end
  self:remember(state)
  self.project=project;self.track=track;self.mixed=mixed==true
  local data=project and track and self:load(project)
  self.error=data and data.error or nil
  local entry=data and data.tracks[track]
  local value=self:clean(entry)
  state.instruments=value.instruments;state.instrument_tags=value.instrument_tags
end
return M
