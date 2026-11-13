-- Available model IDs, independent of the filtered combo's numeric indices.
local M={}
function M.available(components,order)
  local result={}
  for _,name in ipairs(order) do if components:weights(name) then result[#result+1]=name end end
  return result
end
function M.resolve(available,preferred)
  for _,name in ipairs(available) do if name==preferred then return name end end
  return available[1]
end
function M.index_of(order,name)
  for index,value in ipairs(order) do if name==value then return index end end
  return 0
end
function M.can_transcribe(available,selected,has_audio,has_python,busy)
  return not not (has_audio and has_python and not busy and M.index_of(available,selected)>0)
end
function M.draw(r,c,available,selected,label,placeholder)
  if #available==0 then return nil,r.ImGui_Button(c,placeholder..'##install_models',-1,0) end
  local items={}
  for _,name in ipairs(available) do items[#items+1]=label(name) end
  local index=M.index_of(available,selected)
  local changed,new_index=r.ImGui_Combo(c,'##model',math.max(0,index-1),table.concat(items,'\0')..'\0')
  if changed and available[new_index+1] then return available[new_index+1],false end
  return nil,false
end
return M
