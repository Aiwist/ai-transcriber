-- ReaPack installs files without running an installer. Show the bundled terms
-- before creating jobs or downloading models; retain consent across updates.
local M = {}
local SECTION = 'AiwistTranscriber2'
local REVISION = '2026-11-10'
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return end
  local value = f:read('*a'); f:close()
  return value and value:gsub('^\239\187\191', '')
end
function M.accepted(r)
  return r.GetExtState(SECTION, 'license_revision') == REVISION
end
function M.ensure(r, directory, script, J)
  local en = r.GetExtState(SECTION, 'language') == 'en'
  if r.GetOS() ~= 'Win64' then
    r.MB(en and 'This package supports Windows x64 only.' or
      'Эта версия Ai Transcriber работает только в Windows x64.', 'Ai Transcriber', 0)
    return false
  end
  local compatible = false
  if r.ImGui_CreateContext and r.ImGui_GetVersion then
    local ok, _, _, version = pcall(r.ImGui_GetVersion)
    local major, minor = tostring(version):match('^(%d+)%.(%d+)')
    compatible = ok and major and (tonumber(major) > 0 or tonumber(minor) >= 10)
  end
  if not compatible then
    local text = en and
      'ReaImGui 0.10 or newer is required (author: cfillion). Install or update it in Extensions → ReaPack → Browse packages, then restart REAPER.\n\nOpen the package browser now?' or
      'Требуется ReaImGui 0.10 или новее (автор cfillion). Установите или обновите его через Extensions → ReaPack → Browse packages, затем перезапустите REAPER.\n\nОткрыть список пакетов?'
    if r.MB(text, 'Ai Transcriber — ReaImGui', 4) == 6 then
      if r.ReaPack_BrowsePackages then r.ReaPack_BrowsePackages('ReaImGui')
      else r.MB(en and 'ReaPack is not installed. Install it from reapack.com, then install ReaImGui.' or
        'ReaPack не установлен. Установите его с reapack.com, затем установите ReaImGui.', 'Ai Transcriber', 0) end
    end
    return false
  end
  local release = J.load_json(directory .. '/native_release.json', {})
  local runtime = release.runtime and release.runtime.file
  local cpu_runtime = release.cpu_runtime and release.cpu_runtime.file
  if type(runtime) ~= 'string' or not r.file_exists(directory .. '/' .. runtime) or
      type(cpu_runtime) ~= 'string' or not r.file_exists(directory .. '/' .. cpu_runtime) then
    r.MB(en and 'AITN-101: The native engine is missing. Reinstall Ai Transcriber in ReaPack (right-click the package → Reinstall), then apply changes.' or
      'AITN-101: Не установлен нативный движок. В ReaPack нажмите правой кнопкой на Ai Transcriber → Reinstall и примените изменения.', 'Ai Transcriber', 0)
    return false
  end
  if M.accepted(r) then return true end
  local terms = read(directory .. '/INSTALL_LICENSES_RU.txt')
  if not terms or terms == '' then
    r.MB(en and 'The license sheet is missing. Reinstall Ai Transcriber in ReaPack.' or
      'Не найден лицензионный лист. Переустановите Ai Transcriber через ReaPack.', 'Ai Transcriber', 0)
    return false
  end
  local Gui = dofile(directory .. '/lib/gui_context.lua')
  local context = Gui.new(r, 'Ai Transcriber — ' .. (en and 'License' or 'Условия использования'))
  local agreed = false
  local function frame()
    local c, _, problem = context:ensure()
    if not c then r.MB(tostring(problem), 'Ai Transcriber', 0); return end
    r.ImGui_SetNextWindowSize(c, 720, 560, r.ImGui_Cond_FirstUseEver())
    r.ImGui_SetNextWindowSizeConstraints(c, 420, 320, 1200, 1000)
    r.ImGui_PushStyleVar(c, r.ImGui_StyleVar_WindowPadding(), 16, 14)
    local visible, open = r.ImGui_Begin(c, context.label, true)
    local accepted, cancelled = false, false
    if visible then
      r.ImGui_TextWrapped(c, en and 'Read the licenses before using Ai Transcriber and downloading models.' or
        'Перед использованием Ai Transcriber и скачиванием моделей ознакомьтесь с лицензиями.')
      local _, height = r.ImGui_GetContentRegionAvail(c)
      local child = r.ImGui_BeginChild(c, '##terms', 0, math.max(100, height - 100), 0)
      if child then r.ImGui_TextWrapped(c, terms); r.ImGui_EndChild(c) end
      local changed, value = r.ImGui_Checkbox(c, en and 'I have read and accept these terms' or 'Я ознакомился с условиями и принимаю их', agreed)
      if changed then agreed = value end
      r.ImGui_BeginDisabled(c, not agreed)
      accepted = r.ImGui_Button(c, en and 'Accept and continue' or 'Принять и продолжить', -1, 30)
      r.ImGui_EndDisabled(c)
      cancelled = r.ImGui_Button(c, en and 'Cancel' or 'Отмена', -1, 26)
      r.ImGui_End(c)
    end
    r.ImGui_PopStyleVar(c)
    if accepted and agreed then
      r.SetExtState(SECTION, 'license_revision', REVISION, true)
      r.defer(function() dofile(script) end)
    elseif open and not cancelled then r.defer(frame) end
  end
  r.defer(frame)
  return false
end
return M
