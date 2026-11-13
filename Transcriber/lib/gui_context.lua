-- ReaImGui can collect contexts that miss deferred frames. Rebuild only the
-- presentation resources; callers retain their jobs, settings and results.
local M={};M.__index=M
function M.new(r,label,initialize)
  return setmetatable({r=r,label=label,initialize=initialize,generation=0},M)
end
function M:valid()
  if not self.ctx then return false end
  if type(self.r.ImGui_ValidatePtr)~='function'then return true end
  local ok,valid=pcall(self.r.ImGui_ValidatePtr,self.ctx,'ImGui_Context*')
  return ok and valid==true
end
function M:ensure()
  if self:valid()then return self.ctx,false end
  local recovered=self.generation>0
  self.ctx=nil
  local ok,context=pcall(self.r.ImGui_CreateContext,self.label)
  if not ok or not context then return nil,false,ok and'Не удалось создать контекст ReaImGui.'or tostring(context)end
  if self.initialize then
    local ready,problem=pcall(self.initialize,context)
    if not ready then return nil,false,tostring(problem)end
  end
  self.ctx=context;self.generation=self.generation+1
  return context,recovered
end
return M
