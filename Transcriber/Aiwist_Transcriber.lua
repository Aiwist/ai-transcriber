-- @version 1.0.2
-- @description Ai Transcriber
-- @author Aiwist
-- @license Apache-2.0
-- Copyright (c) 2026 Aiwist.
-- AI-assisted development: OpenAI Codex.
-- Attribution/scope: NOTICE.txt; full license: licenses/AiTranscriber-Lua-APACHE-2.0.txt
-- @changelog
--   Audio to MIDI in REAPER: local transcription on CPU or Vulkan GPU.
--   Install through ReaPack or with the standalone ZIP installer; both deliver the same files.
--   Models Small, Medium and Large are installed in Settings; licenses are shown on first launch.
-- @about
--   Audio to MIDI in REAPER. Windows x64; requires ReaImGui (cfillion).
--   The native engine supports Vulkan GPU and CPU. No Python environment.
--   Accept the bundled licenses on first launch, then install models in Settings.
--   MuScriptor weights retain their CC BY-NC 4.0 and author-specific terms.
-- @link
--   GitHub https://github.com/Aiwist/ai-transcriber
--   Boosty https://boosty.to/aiwist
-- @screenshot
--   https://raw.githubusercontent.com/Aiwist/ai-transcriber/main/assets/screenshots/screen-1.png
--   https://raw.githubusercontent.com/Aiwist/ai-transcriber/main/assets/screenshots/screen-2.png
-- @provides
--   [win64 main] .
--   [win64 nomain] INSTALL_LICENSES_RU.txt
--   [win64 nomain] NOTICE.txt
--   [win64 nomain] README_RU.txt
--   [win64 nomain] Register_Ai_Transcriber.lua
--   [win64 nomain] THIRD_PARTY_NOTICES_RU.txt
--   [win64 nomain] capabilities.json
--   [win64 nomain] fonts/Inter_18pt-Bold.ttf
--   [win64 nomain] fonts/Inter_18pt-Light.ttf
--   [win64 nomain] fonts/Inter_18pt-Regular.ttf
--   [win64 nomain] fonts/Inter_18pt-SemiBold.ttf
--   [win64 nomain] fonts/JetBrainsMono-Medium.ttf
--   [win64 nomain] fonts/JetBrainsMono-Regular.ttf
--   [win64 nomain] fonts/lucide.ttf
--   [win64 nomain] lib/first_run.lua
--   [win64 nomain] lib/gguf_health.lua
--   [win64 nomain] lib/gui_context.lua
--   [win64 nomain] lib/hidden_runner.lua
--   [win64 nomain] lib/instrument_memory.lua
--   [win64 nomain] lib/json.lua
--   [win64 nomain] lib/last_result.lua
--   [win64 nomain] lib/model_picker.lua
--   [win64 nomain] lib/native_components.lua
--   [win64 nomain] lib/native_devices.lua
--   [win64 nomain] lib/native_downloads.lua
--   [win64 nomain] lib/profile_identity.lua
--   [win64 nomain] lib/setup_ui.lua
--   [win64 nomain] lib/state_paths.lua
--   [win64 nomain] lib/support_zip.lua
--   [win64 nomain] lib/windows_paths.lua
--   [win64 nomain] licenses/AiTranscriber-Lua-APACHE-2.0.txt
--   [win64 nomain] licenses/Inter-OFL-1.1.txt
--   [win64 nomain] licenses/JetBrainsMono-OFL-1.1.txt
--   [win64 nomain] licenses/Lucide-LICENSE.txt
--   [win64 nomain] licenses/MuScriptor-Code-MIT.txt
--   [win64 nomain] licenses/MuScriptor-Specific-Conditions.txt
--   [win64 nomain] licenses/MuScriptor-Weights-CC-BY-NC-4.0.txt
--   [win64 nomain] licenses/PFFFT-FFTPACK-LICENSE.txt
--   [win64 nomain] licenses/dr-wav-LICENSE.txt
--   [win64 nomain] licenses/ggml-MIT.txt
--   [win64 nomain] licenses/libsamplerate-BSD.txt
--   [win64 nomain] licenses/muscriptor-cpp-MIT.txt
--   [win64 nomain] licenses/nlohmann-json-MIT.txt
--   [win64 nomain] manifest.json
--   [win64 nomain] manifest.tsv
--   [win64 nomain] native_models.json
--   [win64 nomain] native_release.json
--   [win64 nomain] runtime/muscriptor-34a01513-cpu/ai_transcriber_native.exe https://github.com/Aiwist/ai-transcriber/releases/download/v1.0.2/ai_transcriber_native_cpu.exe
--   [win64 nomain] runtime/muscriptor-34a01513-vulkan/ai_transcriber_native.exe https://github.com/Aiwist/ai-transcriber/releases/download/v1.0.2/ai_transcriber_native_vulkan.exe
--   [win64 nomain] setup/bootstrap.ps1
--   [win64 nomain] setup/common.ps1
--   [win64 nomain] setup/download_progress.ps1
--   [win64 nomain] setup/launch_process.ps1
--   [win64 nomain] setup/maintenance.ps1
--   [win64 nomain] setup/native_process.ps1
--   [win64 nomain] setup/native_runner.ps1
--   [win64 nomain] setup/native_setup.ps1
--   [win64 nomain] setup/single_runner.ps1
--   [win64 nomain] setup/worker.ps1
--[[
  Ai Transcriber — аудио в MIDI через локально установленный MuScriptor
  =============================================================================
  Выделите аудио-айтем, настройте модель/устройство/инструменты, нажмите Transcribe.
  MIDI импортируется на новый трек, выровнен по началу аудио, темп проекта сохраняется.

  Требования:
    - reaper_imgui (ReaPack) — даёт функции reaper.ImGui_*
    - Движок muscriptor.cpp входит в Native; модели GGUF подключаются отдельно
    - Python и TensorFlow не требуются

  Установка: положить в папку Scripts, запустить через Actions > Reascript: Load
]]

-- ============================================================
-- РџРЈРўР
-- ============================================================
local SCRIPT_VERSION = "1.0.2"
-- Путь к текущему скрипту: get_action_context возвращает
-- (is_new_value, filename, sectionID, cmdID, mode, resolution)
local _, action_full = reaper.get_action_context()
local source_full = (debug.getinfo(1,'S').source or ''):gsub('^@','')
local script_full = source_full:match('Aiwist_Transcriber%.lua$') and source_full or action_full
local script_dir = ""
if script_full and script_full ~= "" then
  script_dir = script_full:match("(.*)[\\/]") or ""
end
local PREVIEW = reaper.file_exists(script_dir .. "\\native_preview.json") and not reaper.file_exists(script_dir .. "\\native_release.json")
local PREF_SECTION = PREVIEW and "AiwistTranscriberNativePreview" or "AiwistTranscriber2"
local JSON = dofile(script_dir .. "\\lib\\json.lua")
local FirstRun = dofile(script_dir .. "\\lib\\first_run.lua")
if not FirstRun.ensure(reaper, script_dir, script_full, JSON) then return end
local RELEASE = JSON.load_json(script_dir .. '/native_release.json', {})
local HELPER = script_dir .. '/' .. RELEASE.runtime.file
local ProfileIdentity=dofile(script_dir..'\\lib\\profile_identity.lua')
ProfileIdentity.preferences(reaper,PREF_SECTION)
local WindowsPaths=dofile(script_dir..'\\lib\\windows_paths.lua')
local SupportZip=dofile(script_dir..'\\lib\\support_zip.lua')
local LOCAL_APP_DATA,path_error=WindowsPaths.local_app_data(reaper,JSON,PREF_SECTION)
if not LOCAL_APP_DATA then SupportZip.startup_error(reaper,JSON,path_error,SCRIPT_VERSION,'Ai Transcriber');return end
local LastResult = dofile(script_dir .. "\\lib\\last_result.lua")
local HiddenRunner=dofile(script_dir..'\\lib\\hidden_runner.lua')
local ModelPicker = dofile(script_dir .. "\\lib\\model_picker.lua")
local StatePaths = dofile(script_dir .. "\\lib\\state_paths.lua")
local STATE_ROOT, DEFAULT_COMPONENTS, STATE_NOTICE
if PREVIEW then
  STATE_ROOT=LOCAL_APP_DATA.."\\Aiwist\\Ai Transcriber Preview";DEFAULT_COMPONENTS=STATE_ROOT.."\\components"
  reaper.RecursiveCreateDirectory(STATE_ROOT,0)
else STATE_ROOT,DEFAULT_COMPONENTS,STATE_NOTICE=StatePaths.prepare(reaper,JSON,LOCAL_APP_DATA)end
local InstrumentMemory=dofile(script_dir..'\\lib\\instrument_memory.lua')
local INSTRUMENT_MEMORY
local SetupUI = dofile(script_dir .. "\\lib\\native_components.lua")
local GuiContext=dofile(script_dir..'\\lib\\gui_context.lua')
local COMPONENTS
local ENGINE
local state
local NATIVE_COMPONENTS = PREVIEW and DEFAULT_COMPONENTS or (LOCAL_APP_DATA .. "\\Ai Transcriber")
COMPONENTS = SetupUI.new(reaper, script_dir, STATE_ROOT, JSON, nil, NATIVE_COMPONENTS)
COMPONENTS.version=SCRIPT_VERSION
local NativeDevices=dofile(script_dir..'\\lib\\native_devices.lua')
local DEVICE_PICKER=NativeDevices.new(reaper,JSON,script_dir,STATE_ROOT,COMPONENTS:engine(),PREF_SECTION)
if STATE_NOTICE then COMPONENTS.notice=STATE_NOTICE; COMPONENTS.open=true end
ENGINE = COMPONENTS:engine()
-- Separate per-instance files: running 1.x and 2.0 together cannot mix jobs/logs.
local SINGLE_RECORD=STATE_ROOT..'\\single_job.json'
local RESUME=JSON.load_json(SINGLE_RECORD,nil)
if type(RESUME)~='table'or RESUME.schema~=1 or RESUME.phase~='running'or
  type(RESUME.id)~='string'or #RESUME.id~=32 or not RESUME.id:match('^%x+$')or
  type(RESUME.output)~='string'or not RESUME.output:match('^muscriptor_result_%d+%.mid$')or
  type(RESUME.context)~='table'then RESUME=nil end
local SESSION_ID = RESUME and RESUME.id or reaper.genGuid():gsub("[^%x]", "")
local TEMP = STATE_ROOT .. "\\runtime_temp\\" .. SESSION_ID .. "\\"
reaper.RecursiveCreateDirectory(TEMP, 0)
local session_updated=0
local session_busy=nil
local function update_session(closed)
  local busy=state and state.transcribing==true or false
  if closed or busy~=session_busy or os.time()-session_updated>=30 then
    session_updated=os.time()
    session_busy=busy
    pcall(JSON.save_json,TEMP..'session.json',{schema=1,owner='AiTranscriber2',id=SESSION_ID,updated=session_updated,closed=closed==true,busy=busy})
  end
end
update_session(false)

-- Список инструментов (ключ = для API, метка = для GUI)
local INSTRUMENTS = {
  { key = "acoustic_piano", label = "Acoustic Piano", cat = "Keys" },
  { key = "electric_piano", label = "Electric Piano", cat = "Keys" },
  { key = "chromatic_percussion", label = "Chromatic Perc", cat = "Keys" },
  { key = "organ", label = "Organ", cat = "Keys" },
  { key = "acoustic_guitar", label = "Acoustic Guitar", cat = "Guitars" },
  { key = "clean_electric_guitar", label = "Clean E-Guitar", cat = "Guitars" },
  { key = "distorted_electric_guitar", label = "Distorted E-Guitar", cat = "Guitars" },
  { key = "acoustic_bass", label = "Acoustic Bass", cat = "Bass" },
  { key = "electric_bass", label = "Electric Bass", cat = "Bass" },
  { key = "violin", label = "Violin", cat = "Strings" },
  { key = "viola", label = "Viola", cat = "Strings" },
  { key = "cello", label = "Cello", cat = "Strings" },
  { key = "contrabass", label = "Contrabass", cat = "Strings" },
  { key = "orchestral_harp", label = "Orchestral Harp", cat = "Strings" },
  { key = "string_ensemble", label = "String Ensemble", cat = "Strings" },
  { key = "synth_strings", label = "Synth Strings", cat = "Strings" },
  { key = "voice", label = "Voice", cat = "Voice" },
  { key = "orchestra_hit", label = "Orchestra Hit", cat = "Synths" },
  { key = "trumpet", label = "Trumpet", cat = "Brass" },
  { key = "trombone", label = "Trombone", cat = "Brass" },
  { key = "tuba", label = "Tuba", cat = "Brass" },
  { key = "french_horn", label = "French Horn", cat = "Brass" },
  { key = "brass_section", label = "Brass Section", cat = "Brass" },
  { key = "soprano_and_alto_sax", label = "Soprano & Alto Sax", cat = "Sax" },
  { key = "tenor_sax", label = "Tenor Sax", cat = "Sax" },
  { key = "baritone_sax", label = "Baritone Sax", cat = "Sax" },
  { key = "oboe", label = "Oboe", cat = "Woodwinds" },
  { key = "english_horn", label = "English Horn", cat = "Woodwinds" },
  { key = "bassoon", label = "Bassoon", cat = "Woodwinds" },
  { key = "clarinet", label = "Clarinet", cat = "Woodwinds" },
  { key = "flutes", label = "Flutes", cat = "Woodwinds" },
  { key = "synth_lead", label = "Synth Lead", cat = "Synths" },
  { key = "synth_pad", label = "Synth Pad", cat = "Synths" },
  { key = "drums", label = "Drums", cat = "Drums" },
  { key = "timpani", label = "Timpani", cat = "Drums" },
}

-- Модели и устройства
local MODELS = { "large", "medium", "small" }
-- Minimum vertical area kept below the Transcribe button. The status/progress
-- card uses this space, so it never has to fight the bottom window edge.
local STATUS_PANEL_RESERVE_HEIGHT = 92

-- ============================================================
-- РЎРћРЎРўРћРЇРќРР•
-- ============================================================

local I18N = {
  en = {
    settings = "Settings", language = "Language", english = "English", russian = "Русский",
    
    ui_theme = "UI theme", dark = "Amber", light = "Light", cyan = "Cyan", about = "About the author",
    source = "1. Selected Audio Source", selected_item = "Selected item", no_item = "(no item selected)",
    source_track = "Source track", position = "Position", duration = "Duration", project_bpm = "Project BPM",
    selection_auto = "Selection follows REAPER automatically",
    selection_locked = "Source selection is locked while transcribing", model_hardware = "2. AI Model & Hardware",
    model_size = "MuScriptor model size", device = "Accelerator device (GPU/CPU)",
    instruments = "Instruments (click to select tags)", auto_detect = "Leave empty = automatic detection",
    selected_instruments = "Selected instruments (tags)", output = "3. MIDI Output & Track Options",
    placement = "Track placement",
    below = "Insert on a new track below the selected audio item", bottom = "Insert on a new track at the bottom",
    align = "Align MIDI with the audio item start", keep_tempo = "Fit MIDI duration to the audio item",
    transcribe = "TRANSCRIBE", transcribing = "Transcribing", force_channel_one = "Put all imported MIDI notes on channel 1",
    ready = "Ready. Select an audio item, configure the options, and press Transcribe.",
    select_audio = "Select an audio item first.", multi_track = "Select audio items on one track only.", helper_missing = "Helper not found: ",
    render_failed = "Audio render failed.", config_failed = "Could not write the configuration file.",
    weights_missing = "Local MuScriptor model files are missing: ",
    install_models = "Install models", install_models_hint = "Install MuScriptor models in Settings.",
    preparing_audio = "PREPARING WARPED AUDIO FROM REAPER...",
    midi_import_failed = "MIDI import failed.", done = "Done! MIDI imported to",
    copy_log = "Copy log file (TXT)", log_copied = "Log file copied. Paste it into a message with Ctrl+V.",
    log_copy_failed = "Could not copy the log file.",
    copy_log_hint = "Creates a diagnostic TXT file and places it on the Windows clipboard as a file.",
    bpm_preserved = "Project BPM preserved", best = "best quality", standard = "standard", fast = "fast",
    auto_device = "Auto (GPU / CPU)", cpu_only = "CPU only", gpu_cuda = "GPU (Vulkan)",
  },
  ru = {
    settings = "Настройки", language = "Язык", english = "English", russian = "Русский",
    
    ui_theme = "Тема интерфейса", dark = "Янтарь", light = "Светлая", cyan = "Циан", about = "Об авторе",
    source = "1. Выбранный источник аудио", selected_item = "Выбранный объект", no_item = "(объект не выбран)",
    source_track = "Исходная дорожка", position = "Позиция", duration = "Длительность", project_bpm = "Темп проекта",
    selection_auto = "Выбор обновляется автоматически из REAPER",
    selection_locked = "Источник зафиксирован на время транскрипции", model_hardware = "2. Модель ИИ и оборудование",
    model_size = "Размер модели MuScriptor", device = "Устройство вычисления (GPU/CPU)",
    instruments = "Инструменты (нажмите для выбора)", auto_detect = "Пустой список = автоматическое определение",
    selected_instruments = "Выбранные инструменты (теги)", output = "3. Вывод MIDI и параметры дорожки",
    placement = "Расположение дорожки",
    below = "Создать дорожку под выбранным аудиообъектом", bottom = "Создать дорожку внизу списка",
    align = "Совместить начало MIDI с аудиообъектом", keep_tempo = "Подогнать длительность MIDI под аудиообъект",
    transcribe = "ТРАНСКРИБИРОВАТЬ", transcribing = "Транскрибация", force_channel_one = "Свести все MIDI-ноты на канал 1",
    ready = "Готово. Выберите аудиообъект, настройте параметры и запустите транскрипцию.",
    select_audio = "Сначала выберите аудиообъект.", multi_track = "Выберите аудио-айтемы только на одной дорожке.", helper_missing = "Не найден вспомогательный скрипт: ",
    render_failed = "Не удалось подготовить аудио.", config_failed = "Не удалось записать файл настроек.",
    weights_missing = "Локальные файлы модели MuScriptor недоступны: ",
    install_models = "Установите модели", install_models_hint = "Установите модели MuScriptor в настройках.",
    preparing_audio = "Подготовка аудио с учётом stretch-маркеров...",
    midi_import_failed = "Не удалось импортировать MIDI.", done = "Готово! MIDI импортирован на дорожку",
    copy_log = "Скопировать журнал (TXT)", log_copied = "TXT-файл скопирован. Вставьте его в сообщение через Ctrl+V.",
    log_copy_failed = "Не удалось скопировать журнал.",
    copy_log_hint = "Копирует TXT-файл. Его можно вставить в сообщение через Ctrl+V.",
    bpm_preserved = "Темп проекта сохранён", best = "лучшее качество", standard = "стандарт", fast = "быстро",
    auto_device = "Авто (GPU / CPU)", cpu_only = "Только CPU", gpu_cuda = "GPU (Vulkan)",
  },
}

local EXTSTATE_SECTION = PREF_SECTION
local saved_language = reaper.GetExtState(EXTSTATE_SECTION, "language")
if saved_language ~= "ru" and saved_language ~= "en" then saved_language = "ru" end

-- Масштаб интерфейса для крупных мониторов.
-- Общей ручки масштаба шрифта в ReaImGui нет — в привязке она намеренно закрыта
-- (строки про FontGlobalScale в api/context.cpp закомментированы). Поэтому размеры
-- умножаем сами. Размер задаётся не при загрузке шрифта, а при каждом использовании,
-- и весь текст проходит через push_font и dl_text — этих двух мест достаточно.
-- Четыре ступени масштаба интерфейса: 75 / 100 / 125 / 150 %.
local saved_ui_scale = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "ui_scale")) or 1.0
if saved_ui_scale ~= 0.75 and saved_ui_scale ~= 1.0 and
   saved_ui_scale ~= 1.25 and saved_ui_scale ~= 1.5 then
  saved_ui_scale = 1.0
end
local UI_SCALE = saved_ui_scale
local function ui_size(size)
  if UI_SCALE == 1.0 then return size end
  return math.max(1, math.floor(size * UI_SCALE + 0.5))
end
-- WAV is now the only intermediate format; old MP3 preferences are ignored.
local saved_theme = reaper.GetExtState(EXTSTATE_SECTION, "theme")
if saved_theme == "classic" then
  saved_theme = "dark"
  reaper.SetExtState(EXTSTATE_SECTION, "theme", saved_theme, true)
elseif saved_theme ~= "light" and saved_theme ~= "dark" and saved_theme ~= "cyan" then
  saved_theme = "dark"
end
local saved_force_channel_one = reaper.GetExtState(EXTSTATE_SECTION, "force_channel_one") ~= "0"
local saved_model_section_open = reaper.GetExtState(EXTSTATE_SECTION, "model_section_open") ~= "0"
local saved_instruments_section_open = reaper.GetExtState(EXTSTATE_SECTION, "instruments_section_open") ~= "0"
local saved_model = reaper.GetExtState(EXTSTATE_SECTION, "model")
local model_idx = 1
for i, model in ipairs(MODELS) do
  if model == saved_model then
    model_idx = i
    break
  end
end
local function tr(key)
  local lang = (state and state.language) or saved_language
  return (I18N[lang] and I18N[lang][key]) or I18N.en[key] or key
end

local function read_path_pointer(pointer)
  local file = io.open(pointer, "r")
  if not file then return nil end
  local path = file:read("*a") or ""
  file:close()
  path = path:gsub("^%s*\"?", ""):gsub("\"?%s*$", "")
  if path ~= "" then return path end
  return nil
end

local function read_existing_path_pointer(pointer)
  local path = read_path_pointer(pointer)
  if path and reaper.file_exists(path) then return path end
  return nil
end

local function configured_model_weights(model_name)
  return COMPONENTS:weights(tostring(model_name))
end
state = {
  language = saved_language,
  theme = saved_theme,
  settings_open = false,
  model_section_open = saved_model_section_open,
  instruments_section_open = saved_instruments_section_open,
  model_section_height = nil,
  instruments_section_height = nil,
  instrument_category_open = {},
  instrument_category_heights = {},
  status_panel_visible = false,
  status_panel_extra_height = nil,
  status_panel_hidden_height = STATUS_PANEL_RESERVE_HEIGHT,
  layout_resize_requested = true,
  layout_resize_settle_frames = 0,
  requested_window_height = nil,
  last_window_w = nil,
  last_window_h = nil,
  selected_items = {},
  selection_signature = nil,
  selection_error = "",
  -- Выбранный айтем
  item = nil,
  item_name = "",
  track_name = "",
  track_idx = -1,
  item_pos = 0,
  item_len = 0,
  bpm = 120,
  -- Настройки
  model_idx = model_idx, -- canonical MODELS index; 0 when no model is installed
  available_models = {},
  last_model_check = -math.huge,
  force_channel_one = saved_force_channel_one,
  instruments = {},    -- key -> true
  place_below = true,  -- true = ниже выбранного, false = внизу списка
  align_start = true,  -- выравнивать по началу айтема
  keep_tempo = true,   -- сохранять темп проекта (галочка из требования)
  instrument_tags = "", -- строка с выбранными тегами инструментов
  -- Статус
  status = I18N[saved_language].ready,
  transcribing = false,
  transcription_started_at = 0,
  pending_out = "",
  audio_prepare_job = nil,
  audio_temp_sources = {},
  current_audio_accessor = nil,
  current_audio_file = nil,
  current_audio_path = nil,
  log_ready = false,
  log_feedback = "",
  last_log_snapshot = "",
}
INSTRUMENT_MEMORY=InstrumentMemory.new(reaper,JSON,STATE_ROOT,INSTRUMENTS)

local function refresh_installed_models(force)
  -- Refresh the available local MuScriptor models between operations.
  if state.transcribing then return end
  local now=reaper.time_precise()
  if not force and now-state.last_model_check<1 then return end
  state.last_model_check=now
  ENGINE=COMPONENTS:engine()
  local previous=MODELS[state.model_idx]
  state.available_models=ModelPicker.available(COMPONENTS,MODELS)
  local selected=ModelPicker.resolve(state.available_models,previous or saved_model)
  state.model_idx=ModelPicker.index_of(MODELS,selected)
  if selected and selected~=saved_model then
    saved_model=selected
    reaper.SetExtState(EXTSTATE_SECTION,"model",selected,true)
  end
  local missing_message=state.status==I18N.ru.install_models_hint or state.status==I18N.en.install_models_hint
  if not selected and (previous or force or missing_message or state.status==I18N.ru.ready or state.status==I18N.en.ready) then
    state.status=tr("install_models_hint")
  elseif selected and missing_message then
    state.status=tr("ready")
  end
  local hint=COMPONENTS:recovery_hint()
  if hint and hint~=state.last_health_hint then state.status=hint end
  if not hint and state.last_health_hint and state.status==state.last_health_hint then
    state.status=selected and ENGINE and tr("ready") or tr("install_models_hint")
  end
  state.last_health_hint=hint
end
COMPONENTS.on_change=function()
  ENGINE=COMPONENTS:engine()
  refresh_installed_models(true)
  if not state.transcribing then
    state.status=#state.available_models==0 and tr("install_models_hint") or
      (ENGINE and tr("ready") or "Откройте настройки.")
    state.status=COMPONENTS:recovery_hint() or state.status
  end
end
refresh_installed_models(true)

local function select_installed_model(name)
  if (state.transcribing) or COMPONENTS:busy() or ModelPicker.index_of(MODELS,name)==0 or not COMPONENTS:weights(name) then return false end
  state.model_idx=ModelPicker.index_of(MODELS,name)
  saved_model=name
  reaper.SetExtState(EXTSTATE_SECTION,"model",name,true)
  if not state.transcribing then state.status=tr("ready")end
  return true
end
COMPONENTS.get_selected_model=function() return MODELS[state.model_idx] end
COMPONENTS.on_select_model=select_installed_model
COMPONENTS.get_support_status=function()return state.status end
COMPONENTS.support_instance=SESSION_ID

-- ============================================================
-- РЈРўРР›РРўР«
-- ============================================================
-- Простой JSON-энкодер (REAPER Lua не имеет встроенного json)
local function json_encode(val)
  local function enc(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
      if v ~= v then return "null" end  -- NaN
      return string.format("%.14g", v)
    elseif t == "string" then
      return '"' .. v:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        else return string.format("\\u%04x", c:byte())
        end
      end) .. '"'
    elseif t == "table" then
      local is_arr = #v > 0
      local parts = {}
      if is_arr then
        for i = 1, #v do
          parts[i] = enc(v[i])
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        for k, vv in pairs(v) do
          parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(vv)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    else
      return "null"
    end
  end
  return enc(val)
end

local function copy_file(source, destination)
  local input = io.open(source, "rb")
  if not input then return false end
  local data = input:read("*a")
  input:close()
  local output = io.open(destination, "wb")
  if not output then return false end
  output:write(data)
  output:close()
  local verify = io.open(destination, "rb")
  if not verify then return false end
  local size = verify:seek("end") or 0
  verify:close()
  return size > 0
end

local function project_midi_path(source_midi)
  local project_dir = reaper.GetProjectPath("")
  if not project_dir or project_dir == "" then return nil end
  local midi_dir = project_dir .. "\\Muscriptor"
  reaper.RecursiveCreateDirectory(midi_dir,0)
  local stem = (state.item_name or "transcription"):gsub("%.[^%.]+$", "")
  stem = stem:gsub('[%c\\/:*?"<>|]', "_")
  if stem == "" then stem = "transcription" end
  local destination = midi_dir .. "\\" .. stem .. "_transcription.mid"
  local suffix = 1
  while reaper.file_exists(destination) do
    destination = midi_dir .. "\\" .. stem .. "_transcription_" .. suffix .. ".mid"
    suffix = suffix + 1
  end
  return destination
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  f:seek("end")
  local size = f:seek("end")
  f:close()
  return size or 0
end

local function fmt_time(sec)
  if not sec or sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = sec - m * 60
  return string.format("%d:%05.2f", m, s)
end

local function selected_items_signature()
  local selected_count = reaper.CountSelectedMediaItems(0)
  local parts = { tostring(LastResult.project_guid(reaper)),tostring(selected_count) }
  for i = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item)
    parts[#parts + 1] = tostring(item) .. ":" .. tostring(take)..":"..tostring(item and reaper.GetMediaItem_Track(item))
  end
  return table.concat(parts, "|")
end

local function read_text_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local limit=262144
  local bytes=f:seek('end')or 0
  f:seek('set',math.max(0,bytes-limit))
  local content = f:read(limit) or ""
  f:close()
  if bytes>limit then content=content:match('\n(.*)')or''end
  return (bytes>limit and '[Earlier log entries omitted]\r\n'or'')..content
end

local function powershell_quote(value)
  return tostring(value or ""):gsub("'", "''")
end

local function copy_diagnostic_log_to_clipboard()
  local local_app_data = LOCAL_APP_DATA
  local log_dir = local_app_data and local_app_data ~= ""
    and (local_app_data .. "\\Aiwist Transcriber\\Logs")
    or (TEMP .. "Aiwist Transcriber Logs")
  reaper.RecursiveCreateDirectory(log_dir, 0)

  local timestamp = os.date("%Y-%m-%d_%H-%M-%S")
  local snapshot = log_dir .. "\\Ai_Transcriber_Log_" .. timestamp .. '_'..reaper.genGuid():gsub('[^%x]','')..".txt"
  local log_root=TEMP
  local stdout_path = log_root and(log_root .. "muscriptor_helper_log.txt")
  local stderr_path = stdout_path and(stdout_path .. ".err")
  local stdout = log_root and read_text_file(stdout_path)or''
  local stderr = log_root and read_text_file(stderr_path)or''
  if stdout == "" then stdout = "(stdout log was not created or is empty)" end
  if stderr == "" then stderr = "(stderr log was not created or is empty)" end

  local report = table.concat({
    "Ai Transcriber "..SCRIPT_VERSION.." diagnostic log",
    "Created: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "Status: " .. tostring(state.status or ""),
    "Native engine: " .. tostring(ENGINE or ""),
    "Helper: " .. tostring(HELPER or ""),
    "",
    "===== STDOUT: muscriptor_helper_log.txt =====",
    stdout,
    "",
    "===== STDERR: muscriptor_helper_log.txt.err =====",
    stderr,
    ""
  }, "\r\n")

  local output = io.open(snapshot, "wb")
  if not output then
    state.log_feedback = tr("log_copy_failed")
    return false
  end
  output:write("\239\187\191")
  report=report:gsub('hf_[%w_]+','[TOKEN REDACTED]'):gsub('[Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s"<>]+','Bearer [REDACTED]')
  output:write(report)
  output:close()

  local clipboard_script = TEMP .. "ai_transcriber_copy_log.ps1"
  local ps = table.concat({
    "$ErrorActionPreference = 'Stop'",
    "Add-Type -AssemblyName System.Windows.Forms",
    "$files = New-Object System.Collections.Specialized.StringCollection",
    "[void]$files.Add('" .. powershell_quote(snapshot) .. "')",
    "$data = New-Object System.Windows.Forms.DataObject",
    "$data.SetFileDropList($files)",
    "for ($i = 0; $i -lt 5; $i++) {",
    "  try { [System.Windows.Forms.Clipboard]::SetDataObject($data, $true); exit 0 }",
    "  catch { Start-Sleep -Milliseconds 150 }",
    "}",
    "exit 1"
  }, "\r\n")
  local pf = io.open(clipboard_script, "wb")
  if not pf then
    state.log_feedback = tr("log_copy_failed") .. " " .. snapshot
    return false
  end
  pf:write("\239\187\191")
  pf:write(ps)
  pf:close()

  local ps_exe=(os.getenv('SystemRoot')or'C:\\Windows')..'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
  local command = '"'..ps_exe..'" -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. clipboard_script .. '"'
  local ran,response=pcall(reaper.ExecProcess,command,5000)
  os.remove(clipboard_script)
  local success=ran and(type(response)=='number'and response==0 or type(response)=='string'and tonumber(response:match('^(%-?%d+)'))==0)
  state.last_log_snapshot = snapshot
  state.log_feedback = success and tr("log_copied") or (tr("log_copy_failed") .. " " .. snapshot)
  return success
end

local function project_bpm_at_time(time_position)
  local ok, bpm = pcall(reaper.TimeMap_GetDividedBpmAtTime, 0,
    tonumber(time_position) or 0)
  if ok and type(bpm) == "number" and bpm > 0 then return bpm end
  local fallback = reaper.Master_GetTempo()
  return type(fallback) == "number" and fallback > 0 and fallback or 120
end

local function refresh_selected_item(selection_signature)
  state.selection_signature = selection_signature or selected_items_signature()
  state.selected_items = {}
  state.selection_error = ""
  local selected_count = reaper.CountSelectedMediaItems(0)
  local common_track = nil
  local different_track = false
  for i = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item)
    if item and take and not reaper.TakeIsMIDI(take) then
      local track = reaper.GetMediaItem_Track(item)
      if not common_track then common_track = track end
      if track ~= common_track then different_track = true end
      state.selected_items[#state.selected_items + 1] = item
    end
  end
  state.multiple_tracks=different_track
  INSTRUMENT_MEMORY:select(LastResult.project_guid(reaper),not different_track and common_track and reaper.GetTrackGUID(common_track)or nil,state,different_track)
  table.sort(state.selected_items, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION") < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)
  state.item = state.selected_items[1]
  if not state.item then
    state.item_name = state.selection_error ~= "" and state.selection_error or tr("no_item")
    state.track_name, state.track_idx, state.item_pos, state.item_len = "", -1, 0, 0
    state.bpm = project_bpm_at_time(reaper.GetCursorPosition())
    return
  end
  state.item_pos = reaper.GetMediaItemInfo_Value(state.item, "D_POSITION")
  state.bpm = project_bpm_at_time(state.item_pos)
  local selection_end = state.item_pos
  for _, item in ipairs(state.selected_items) do
    local item_end = reaper.GetMediaItemInfo_Value(item, "D_POSITION") + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_end > selection_end then selection_end = item_end end
  end
  state.item_len = selection_end - state.item_pos
  state.item_name = #state.selected_items > 1 and
    ((state.language == "ru" and "Выбрано айтемов: " or "Selected items: ") .. #state.selected_items) or ""
  if #state.selected_items == 1 then
    local take = reaper.GetActiveTake(state.item)
    local src = take and reaper.GetMediaItemTake_Source(take)
    local path = src and reaper.GetMediaSourceFileName(src, "") or ""
    state.item_name = reaper.GetTakeName(take)
    if not state.item_name or state.item_name==''then state.item_name=path:match("[^\\/]+$")or path end
  end
  local track = reaper.GetMediaItem_Track(state.item)
  state.track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  state.track_name = select(2, reaper.GetTrackName(track, ""))
  if state.track_name == "" then state.track_name = "Track " .. state.track_idx end
end

local function refresh_selection_if_changed()
  local signature = selected_items_signature()
  if signature ~= state.selection_signature then
    refresh_selected_item(signature)
  else
    state.bpm = project_bpm_at_time(state.item and state.item_pos or reaper.GetCursorPosition())
  end
end

local function get_selected_instruments()
  local keys = {}
  for _, inst in ipairs(INSTRUMENTS) do
    if state.instruments[inst.key] then
      keys[#keys + 1] = inst.key
    end
  end
  return keys
end

local function get_item_render_info(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local source_path = reaper.GetMediaSourceFileName(src, "")
  if source_path == "" or not reaper.file_exists(source_path) then return nil end
  return {
    source_path = source_path,
    start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    timeline_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
  }
end

-- Export the take exactly on the REAPER timeline. Unlike reading the media
-- source directly, a take audio accessor follows stretch markers, reverse,
-- looping, pitch/playrate processing and edits already represented by the take.
-- Samples are read pre-FX so transcription does not inherit reverb/mastering.
local ACCESSOR_SAMPLE_RATE = 44100
local ACCESSOR_CHANNELS = 2
local ACCESSOR_CHUNK_FRAMES = 32768
local ACCESSOR_BYTES_PER_SAMPLE = 4 -- IEEE float WAV
local ACCESSOR_PACK_SAMPLES = 1024

local function float_wav_header(frame_count)
  local data_size = frame_count * ACCESSOR_CHANNELS * ACCESSOR_BYTES_PER_SAMPLE
  local block_align = ACCESSOR_CHANNELS * ACCESSOR_BYTES_PER_SAMPLE
  local byte_rate = ACCESSOR_SAMPLE_RATE * block_align
  return "RIFF" .. string.pack("<I4", 36 + data_size) .. "WAVE" ..
    "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 3, ACCESSOR_CHANNELS,
      ACCESSOR_SAMPLE_RATE, byte_rate, block_align, 32) ..
    "data" .. string.pack("<I4", data_size)
end

local function pack_float_samples(values, count)
  local blocks = {}
  local first = 1
  while first <= count do
    local last = math.min(count, first + ACCESSOR_PACK_SAMPLES - 1)
    local format = "<" .. string.rep("f", last - first + 1)
    blocks[#blocks + 1] = string.pack(format, table.unpack(values, first, last))
    first = last + 1
  end
  return table.concat(blocks)
end

local function close_current_audio_export()
  if state.current_audio_file then
    pcall(function() state.current_audio_file:close() end)
    state.current_audio_file = nil
  end
  if state.current_audio_accessor then
    pcall(reaper.DestroyAudioAccessor, state.current_audio_accessor)
    state.current_audio_accessor = nil
  end
  state.current_audio_path = nil
end

local function cleanup_audio_preparation(preserve_sources)
  close_current_audio_export()
  state.audio_prepare_job = nil
  if not preserve_sources then
    for _, path in ipairs(state.audio_temp_sources or {}) do os.remove(path)end
  end
  state.audio_temp_sources = {}
end

local function begin_take_audio_export(item, output_path)
  if not reaper.ValidatePtr2(0, item, "MediaItem*") then
    error("The selected audio item is no longer available.")
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    error("The selected item no longer has an active audio take.")
  end
  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then error("REAPER could not create an audio accessor for the selected take.") end
  local accessor_start = reaper.GetAudioAccessorStartTime(accessor)
  local accessor_end = reaper.GetAudioAccessorEndTime(accessor)
  local accessor_length = math.max(0, accessor_end - accessor_start)
  local render_length = math.min(length, accessor_length)
  local frame_count = math.max(1, math.floor(render_length * ACCESSOR_SAMPLE_RATE))
  if frame_count * ACCESSOR_CHANNELS * ACCESSOR_BYTES_PER_SAMPLE > 0xffffffff - 36 then
    reaper.DestroyAudioAccessor(accessor)
    error("The selected item is too long for a WAV export. Transcribe smaller sections.")
  end

  local file, open_error = io.open(output_path, "wb")
  if not file then
    reaper.DestroyAudioAccessor(accessor)
    error("Could not create temporary REAPER audio: " .. tostring(open_error or output_path))
  end
  state.current_audio_accessor = accessor
  state.current_audio_file = file
  state.current_audio_path = output_path
  local wrote, write_error = file:write(float_wav_header(frame_count))
  if not wrote then
    close_current_audio_export()
    os.remove(output_path)
    error("Could not write the temporary WAV header: " .. tostring(write_error or output_path))
  end

  return {
    accessor = accessor,
    file = file,
    output_path = output_path,
    accessor_start = accessor_start,
    frame_count = frame_count,
    frame_offset = 0,
    source = {
      source_path = output_path,
      start_offset = 0,
      playrate = 1,
      item_length = render_length,
      timeline_position = position,
      temporary_reaper_render = true,
      rendered_frames = frame_count,
    },
  }
end

local function create_audio_preparation_job(items, temp_dir)
  local run_id = tostring(os.time()) .. "_" ..
    tostring(math.floor((reaper.time_precise() % 1) * 1000000))
  local all_frames = 0
  for _, item in ipairs(items) do
    all_frames = all_frames + math.max(1, math.floor(
      reaper.GetMediaItemInfo_Value(item, "D_LENGTH") * ACCESSOR_SAMPLE_RATE + 0.5))
  end

  return {
    items = items,
    temp_dir = temp_dir,
    run_id = run_id,
    all_frames = all_frames,
    completed_frames = 0,
    index = 1,
    current = nil,
    prepared = {},
  }
end

-- ============================================================
-- Р—РђРџРЈРЎРљ РўР РђРќРЎРљР РРџР¦РР (С‡РµСЂРµР· helper, Р°СЃРёРЅС…СЂРѕРЅРЅРѕ)
-- ============================================================
-- Forward declarations: poll_transcription/finish_transcription
-- определяются ниже, но вызываются из start_transcription.
local poll_transcription
local finish_transcription

local function start_transcription(prepared_sources)
  if prepared_sources==nil then
    if state.transcribing then return end
    refresh_installed_models(true)
  end
  ENGINE=COMPONENTS:engine(DEVICE_PICKER.mode)
  if not ENGINE or COMPONENTS:busy() then
    COMPONENTS.open = true
    state.status = "Подключите MuScriptor и дождитесь завершения проверки компонентов."
    return
  end
  local temp_dir = TEMP .. "muscriptor_transcribe"
  local selected_model = MODELS[state.model_idx]
  local model_weights_path = configured_model_weights(selected_model)
  if not model_weights_path then
    if prepared_sources~=nil then cleanup_audio_preparation();state.transcribing=false end
    COMPONENTS.open=true
    state.status=selected_model and (tr("weights_missing")..selected_model..". "..tr("install_models_hint")) or tr("install_models_hint")
    return
  end
  if prepared_sources == nil then
    if state.transcribing then return end
    if reaper.file_exists(TEMP..'runner.json')and not reaper.file_exists(TEMP..'exit.json')then
      state.status='ERROR: Предыдущий процесс ещё не подтвердил завершение. Повторный запуск заблокирован.';return
    end
    for _,name in ipairs({'runner.json','exit.json','process.json','cancel.request','request.json'})do
      if reaper.file_exists(TEMP..name)then
        local removed=os.remove(TEMP..name)
        if not removed then state.status='ERROR: Не удалось обновить служебный файл: '..name;return end
      end
    end
    state.log_ready = true
    state.log_feedback = ""
    state.last_log_snapshot = ""
    os.remove(TEMP .. "muscriptor_helper_log.txt")
    os.remove(TEMP .. "muscriptor_helper_log.txt.err")
    refresh_selected_item()
    if state.selection_error ~= "" then
      state.status = "ERROR: " .. state.selection_error
      return
    end
    if not state.item or #state.selected_items == 0 then
      state.status = "ERROR: " .. tr("select_audio")
      return
    end
    if not reaper.file_exists(HELPER) then
      state.status = "ERROR: " .. tr("helper_missing") .. HELPER
      return
    end
    if not string.pack then
      state.status = "ERROR: REAPER Lua does not support binary WAV export."
      return
    end

    reaper.RecursiveCreateDirectory(temp_dir,0)
    local selected_snapshot = {}
    for _, selected_item in ipairs(state.selected_items) do
      if not get_item_render_info(selected_item) then
        state.status = "ERROR: " .. tr("render_failed")
        return
      end
      selected_snapshot[#selected_snapshot + 1] = selected_item
    end

    local project_guid,project_error=LastResult.project_guid(reaper)
    if not project_guid then state.status="ERROR: "..project_error;return end
    state.pending_context={project_guid=project_guid,project_identity='master_track_guid_v1',track_guid=reaper.GetTrackGUID(reaper.GetMediaItem_Track(state.item)),
      position=state.item_pos,duration=state.item_len,force_channel_one=state.force_channel_one,model=selected_model}
    cleanup_audio_preparation()
    state.transcribing = true
    state.status = tr("preparing_audio")
    state.audio_prepare_job = create_audio_preparation_job(selected_snapshot, temp_dir)
    return
  end

  local sources = prepared_sources
  if #sources == 0 then
    cleanup_audio_preparation()
    state.status = "ERROR: " .. tr("render_failed")
    state.transcribing = false
    return
  end
  local render_info = sources[1]
  local rendered_audio = temp_dir .. "\\input_" .. os.time() .. ".wav"

  local cfg = {
    wav_path = render_info.source_path,
    sources = sources,
    rendered_audio = rendered_audio,
    render_format = "wav",
    audio_preparation = "reaper-float-wav-v1",
    bridge_version = SCRIPT_VERSION,
    padding_seconds = 1.0,
    start_offset = render_info.start_offset,
    playrate = render_info.playrate,
    item_length = state.item_len,
    instruments = get_selected_instruments(),
    model = selected_model,
    model_weights_path = model_weights_path,
    device = DEVICE_PICKER.mode,
    native_device = DEVICE_PICKER:snapshot().native_device,
    use_sampling = false,
    temperature = 1.0,
  }

  local cfg_json = TEMP .. "config.json"
  local f = io.open(cfg_json, "w")
  if f then
    f:write(json_encode(cfg))
    f:close()
  else
    cleanup_audio_preparation()
    state.status = "ERROR: " .. tr("config_failed")
    state.transcribing = false
    return
  end

  -- Сохраняем MIDI в ПАПКУ ПРОЕКТА (подпапка "Muscriptor"), чтобы результат
  -- Р»РµР¶Р°Р» СЂСЏРґРѕРј СЃ .rpp Рё Р±С‹Р» Р»РµРіРєРѕ РґРѕСЃС‚СѓРїРµРЅ. РРјСЏ вЂ” РїРѕ РёРјРµРЅРё Р°СѓРґРёРѕ-Р°Р№С‚РµРјР°.
  local proj_dir = reaper.GetProjectPath("")
  local midi_dir = proj_dir .. "\\Muscriptor"
  reaper.RecursiveCreateDirectory(midi_dir,0)
  local base = (state.item_name:match("(.+)%.[%w]+$")) or state.item_name or "transcription"
  base = base:gsub('[%c\\/:*?"<>|]', "_")  -- убираем недопустимые символы из имени файла
  if base == "" then base = "transcription" end
  local out_midi = TEMP .. "muscriptor_result_" .. os.time() .. ".mid"

  -- The single job uses the supervised hidden runner.
  if not JSON.save_json(TEMP.."request.json",{schema=1,id=SESSION_ID,engine="native",executable=ENGINE,
    output=out_midi:match("[^\\/]+$")})then
    cleanup_audio_preparation();state.transcribing=false;state.status='ERROR: Не удалось сохранить запрос транскрибации.';return
  end
  state.pending_out=out_midi
  state.pending_cfg=cfg_json
  if not JSON.save_json(SINGLE_RECORD,{schema=1,phase='running',id=SESSION_ID,
      output=out_midi:match('[^\\/]+$'),context=state.pending_context,name=state.item_name,started=os.time()})then
    cleanup_audio_preparation();state.transcribing=false;state.status='ERROR: Не удалось сохранить состояние транскрибации.';return
  end
  state.status=tr("transcribing");state.transcribing=true
  state.transcription_started_at=reaper.time_precise()
  local launched,launch_error=pcall(HiddenRunner.launch,reaper,script_dir,STATE_ROOT,TEMP:gsub('[/\\]+$',''),'Run')
  if not launched then state.status='Запуск помощника не подтверждён. Проверяем состояние задания.\n'..tostring(launch_error)end

  -- The helper now owns these temporary take WAVs and deletes them after
  -- combining them into the single analysis input.
  state.audio_temp_sources = {}

  -- Поллинг через defer
  reaper.defer(function() poll_transcription() end)
end

poll_transcription = function()
  if not state.transcribing then return end
  local terminal=JSON.load_json(TEMP..'exit.json',nil)
  if type(terminal)=='table'and terminal.id==SESSION_ID and terminal.code~=0 then
    JSON.save_json(SINGLE_RECORD,{schema=1,phase='finished',id=SESSION_ID})
    state.status='ERROR: '..tostring(terminal.message);state.transcribing=false;return
  end

  local out=state.pending_out
  if terminal and terminal.id==SESSION_ID and terminal.code==0 then
    if out and reaper.file_exists(out..'.ready')and file_size(out)>0 and file_size(out..'.notes.tsv')>0 then
      finish_transcription(out)
    else
      JSON.save_json(SINGLE_RECORD,{schema=1,phase='finished',id=SESSION_ID})
      state.transcribing=false
      state.status='ERROR: MuScriptor не создал MIDI с нотами. Попробуйте другой фрагмент или набор инструментов.'
    end
    return
  end
  local elapsed = math.max(0, reaper.time_precise() - (state.transcription_started_at or 0))
  local heartbeat=JSON.load_json(TEMP..'process.json',{})
  local fraction=tonumber(heartbeat.fraction)
  state.status=tostring(heartbeat.message or tr('transcribing'))
  if fraction and fraction>=0 and fraction<=1 then state.status=state.status..string.format(' · %d%%',math.floor(fraction*100))end
  state.status=state.status..string.format(' · %.0f s',elapsed)
  -- The supervisor enforces the same 25-minute limit and confirms termination.
  if elapsed > 1500 then
    JSON.write(TEMP..'cancel.request','timeout\n')
    state.status='Ожидание превысило 25 минут. Останавливаю обработку…'
  end
  if (not heartbeat.updated or os.time()-heartbeat.updated>10)and elapsed>10 and
    (not state.process_checked or reaper.time_precise()-state.process_checked>10)then
    state.process_checked=reaper.time_precise()
    local checked,check_error=pcall(HiddenRunner.launch,reaper,script_dir,STATE_ROOT,TEMP:gsub('[/\\]+$',''),'Check')
    if not checked then state.status=state.status..'\n'..tostring(check_error)end
  end

  reaper.defer(function() poll_transcription() end)
end

finish_transcription = function(midi_path)
  state.transcribing = false
  local ok,data=pcall(LastResult.capture,midi_path,state.pending_context)
  if not ok then JSON.save_json(SINGLE_RECORD,{schema=1,phase='finished',id=SESSION_ID});state.status="ERROR: "..tostring(data);return end
  -- Save BEFORE importing: an interrupted/undone import must remain replayable.
  local saved,save_error=pcall(LastResult.save,JSON,STATE_ROOT,data)
  -- Commit the automatic-import attempt before touching the project. If REAPER
  -- closes during import, the saved result remains available via explicit replay.
  if not JSON.save_json(SINGLE_RECORD,{schema=1,phase='importing',id=SESSION_ID})then
    state.status='ERROR: Не удалось сохранить состояние импорта. MIDI доступен для повторной вставки.';return
  end
  local imported,count=LastResult.import(reaper,data)
  JSON.save_json(SINGLE_RECORD,{schema=1,phase='finished',id=SESSION_ID})
  if not imported then state.status="ERROR: "..tostring(count);return end
  local destination=project_midi_path(midi_path)
  if destination and copy_file(midi_path,destination) then os.remove(midi_path) end
  os.remove(midi_path..".notes.tsv")
  os.remove(midi_path..".notes.tsv.pitch.tsv")
  os.remove(midi_path..".ready")
  state.status=tr("done").." ("..tostring(count)..")"
  if not saved then state.status=state.status.."\nНе удалось сохранить повторную вставку: "..tostring(save_error) end
end

local FONT = {}
local function utf8_cp(cp)
  return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end
local ICON = {
  SETTINGS = utf8_cp(0xE154),
  FILE = utf8_cp(0xE0C0),
  CHECK = utf8_cp(0xE06C),
  CHEVRON = utf8_cp(0xE06D),
  ZAP = utf8_cp(0xE1B4),
}

local TK_LIGHT = {
  bg = 0xE6EAF1FF, bg_elev = 0xF3F6FBFF, card = 0xFFFFFFFF,
  title_bg = 0xE6EAF1FF,
  card_hover = 0xF3F6FAFF, prompt_bg = 0xFFFFFFFF,
  border = 0x465F8C42, border_str = 0x465F8C5C,
  text = 0x0F1824FF, text_muted = 0x475467FF, text_faint = 0x5E6A7CFF,
  accent = 0x3F63A8FF, accent_ui = 0x89A4E4FF, accent_soft = 0xBDD1EEFF,
  accent_text = 0xFFFFFFFF, input_bg = 0xECEFF5FF,
  green = 0x217548FF, red = 0xC14747FF, amber = 0x8A5A12FF,
  footer_bg = 0x00000005,
}
local TK_DARK = {
  bg = 0x1C1F21FF, bg_elev = 0x202326FF, card = 0x292C2FFF,
  title_bg = 0x090A0BFF,
  card_hover = 0x35383BFF, prompt_bg = 0x24272AFF,
  border = 0xFFFFFF18, border_str = 0xFFFFFF2A,
  text = 0xE6E8EAFF, text_muted = 0xA0A4A8FF, text_faint = 0x7A7E82FF,
  accent = 0xF0B84FFF, accent_ui = 0x8C682DFF, accent_soft = 0x3B3020FF,
  accent_text = 0xFFFFFFFF, input_bg = 0x17191BFF,
  green = 0x66CC66FF, red = 0xD46F6FFF, amber = 0xF0B84FFF,
  footer_bg = 0x00000026,
}
local TK_CYAN = {
  bg = 0x1C1F21FF, bg_elev = 0x202326FF, card = 0x292C2FFF,
  title_bg = 0x090A0BFF,
  card_hover = 0x35383BFF, prompt_bg = 0x24272AFF,
  border = 0x7BA7AE28, border_str = 0x7BA7AE48,
  text = 0xE6E8EAFF, text_muted = 0xA0A4A8FF, text_faint = 0x7A7E82FF,
  accent = 0x6DC9DAFF, accent_ui = 0x2B778CFF, accent_soft = 0x1C343AFF,
  accent_text = 0xFFFFFFFF, input_bg = 0x17191BFF,
  green = 0x66CC66FF, red = 0xD46F6FFF, amber = 0x6DC9DAFF,
  footer_bg = 0x00000026,
}
local TK = TK_DARK

local function ui_text(ru, en)
  return state.language == "ru" and ru or en
end

local function push_font(c, font, size)
  if not font then return false end
  reaper.ImGui_PushFont(c, font, ui_size(size))
  return true
end

local function pop_font(c, pushed)
  if pushed then reaper.ImGui_PopFont(c) end
end

local function calc_text(c, font, size, text)
  local pushed = push_font(c, font, size)
  local w, h = reaper.ImGui_CalcTextSize(c, text)
  pop_font(c, pushed)
  return w or 0, h or size
end

local function dl_text(dl, font, size, x, y, color, text)
  if font then
    reaper.ImGui_DrawList_AddTextEx(dl, font, ui_size(size), x, y, color, text)
  else
    reaper.ImGui_DrawList_AddText(dl, x, y, color, text)
  end
end

local function lerp_u32(a, b, t)
  local ar, ag, ab, aa = (a >> 24) & 0xFF, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF
  local br, bg, bb, ba = (b >> 24) & 0xFF, (b >> 16) & 0xFF, (b >> 8) & 0xFF, b & 0xFF
  local it = 1 - t
  return ((math.floor(ar * it + br * t) & 0xFF) << 24)
       | ((math.floor(ag * it + bg * t) & 0xFF) << 16)
       | ((math.floor(ab * it + bb * t) & 0xFF) << 8)
       |  (math.floor(aa * it + ba * t) & 0xFF)
end

local function select_palette()
  TK = state.theme == "light" and TK_LIGHT
    or state.theme == "cyan" and TK_CYAN
    or TK_DARK
end

local function push_theme(c)
  select_palette()
  local colors = {
    { reaper.ImGui_Col_WindowBg(), TK.bg },
    { reaper.ImGui_Col_ChildBg(), TK.bg },
    { reaper.ImGui_Col_PopupBg(), TK.bg_elev },
    { reaper.ImGui_Col_TitleBg(), TK.title_bg },
    { reaper.ImGui_Col_TitleBgActive(), TK.title_bg },
    { reaper.ImGui_Col_TitleBgCollapsed(), TK.title_bg },
    { reaper.ImGui_Col_Text(), TK.text },
    { reaper.ImGui_Col_TextDisabled(), TK.text_faint },
    { reaper.ImGui_Col_Border(), TK.border },
    { reaper.ImGui_Col_Separator(), TK.border },
    { reaper.ImGui_Col_FrameBg(), TK.input_bg },
    { reaper.ImGui_Col_FrameBgHovered(), TK.prompt_bg },
    { reaper.ImGui_Col_FrameBgActive(), TK.prompt_bg },
    { reaper.ImGui_Col_Button(), TK.card },
    { reaper.ImGui_Col_ButtonHovered(), TK.card_hover },
    { reaper.ImGui_Col_ButtonActive(), lerp_u32(TK.card_hover, TK.accent_ui, 0.35) },
    { reaper.ImGui_Col_Header(), TK.card },
    { reaper.ImGui_Col_HeaderHovered(), TK.card_hover },
    { reaper.ImGui_Col_HeaderActive(), lerp_u32(TK.card_hover, TK.accent_ui, 0.30) },
    { reaper.ImGui_Col_PlotHistogram(), TK.accent },
    { reaper.ImGui_Col_PlotHistogramHovered(), TK.accent },
    { reaper.ImGui_Col_TableHeaderBg(), TK.card },
    { reaper.ImGui_Col_TableBorderStrong(), TK.border_str },
    { reaper.ImGui_Col_TableBorderLight(), TK.border },
    { reaper.ImGui_Col_TableRowBg(), 0x00000000 },
    { reaper.ImGui_Col_TableRowBgAlt(), TK.footer_bg },
    { reaper.ImGui_Col_CheckMark(), TK.accent },
    { reaper.ImGui_Col_ScrollbarBg(), 0x00000000 },
    { reaper.ImGui_Col_ScrollbarGrab(), TK.border_str },
    { reaper.ImGui_Col_ScrollbarGrabHovered(), TK.accent_ui },
    { reaper.ImGui_Col_ScrollbarGrabActive(), TK.accent },
  }
  for _, pair in ipairs(colors) do
    reaper.ImGui_PushStyleColor(c, pair[1], pair[2])
  end
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FramePadding(), 8, 5)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_ItemSpacing(), 7, 4)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FrameRounding(), 5)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_GrabRounding(), 5)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_ChildRounding(), 6)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_PopupRounding(), 7)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_ScrollbarSize(), 10)
  return #colors, 9
end

local function tooltip_v5(c, text, allow_when_disabled)
  if not text or text == "" then return end
  local hovered = false
  if allow_when_disabled and reaper.ImGui_HoveredFlags_AllowWhenDisabled then
    hovered = reaper.ImGui_IsItemHovered(c, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
  else
    hovered = reaper.ImGui_IsItemHovered(c)
  end
  if not hovered then return end
  -- The global popup palette already gives native tooltips the same elevated
  -- card surface. SetTooltip is supported by older ReaImGui builds too.
  reaper.ImGui_SetTooltip(c, text)
end

local function section_label(c, label, is_open, id)
  local base_x = reaper.ImGui_GetCursorPosX(c)
  local inset = 7
  reaper.ImGui_SetCursorPosX(c, base_x + inset)

  if is_open ~= nil then
    local dl = reaper.ImGui_GetWindowDrawList(c)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(c)
    local avail_w = reaper.ImGui_GetContentRegionAvail(c)
    local row_h = 16
    local clicked = reaper.ImGui_InvisibleButton(c, "##section_" .. tostring(id or label), avail_w, row_h)
    local hovered = reaper.ImGui_IsItemHovered(c)
    if hovered then reaper.ImGui_SetMouseCursor(c, reaper.ImGui_MouseCursor_Hand()) end
    local new_open = is_open
    if clicked then new_open = not is_open end
    local bar_w, bar_h = 12, 2
    local bar_y = sy + math.floor((row_h - bar_h) * 0.5)
    local bar_color = hovered and TK.accent or lerp_u32(TK.accent, TK.bg, 0.35)
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, bar_y, sx + bar_w, bar_y + bar_h, bar_color, 1)
    if not new_open then
      local bar_x = sx + math.floor((bar_w - bar_h) * 0.5)
      reaper.ImGui_DrawList_AddRectFilled(dl, bar_x, bar_y - 5, bar_x + bar_h, bar_y + 7, bar_color, 1)
    end
    dl_text(dl, FONT.mono_med, 10, sx + bar_w + 8, sy + 2,
      hovered and TK.text_muted or TK.text_faint, label)
    reaper.ImGui_SetCursorPosX(c, base_x)
    reaper.ImGui_Dummy(c, 1, 1)
    return new_open
  end

  local pushed = push_font(c, FONT.mono_med, 10)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.text_faint)
  reaper.ImGui_Text(c, label)
  reaper.ImGui_PopStyleColor(c)
  pop_font(c, pushed)
  local x2, y2 = reaper.ImGui_GetItemRectMax(c)
  local _, y1 = reaper.ImGui_GetItemRectMin(c)
  local cursor_x = reaper.ImGui_GetCursorScreenPos(c)
  local avail_w = reaper.ImGui_GetContentRegionAvail(c)
  local line_y = math.floor((y1 + y2) * 0.5)
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(c),
    x2 + 8, line_y, cursor_x + avail_w, line_y, TK.border, 1)
  reaper.ImGui_SetCursorPosX(c, base_x)
  reaper.ImGui_Dummy(c, 1, 1)
end

local function begin_card(c, id)
  local base_x = reaper.ImGui_GetCursorPosX(c)
  local avail_w = reaper.ImGui_GetContentRegionAvail(c)
  local inset = 7
  reaper.ImGui_SetCursorPosX(c, base_x + inset)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ChildBg(), TK.card)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Border(), TK.border)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_ChildBorderSize(), 1)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_ChildRounding(), 6)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowPadding(), 14, 10)
  local child_open = reaper.ImGui_BeginChild(c, id,
    math.max(1, avail_w - inset * 2), 0,
    reaper.ImGui_ChildFlags_AutoResizeY() | reaper.ImGui_ChildFlags_Borders())
  return child_open, base_x
end

local function end_card(c, child_open, base_x)
  reaper.ImGui_PopStyleVar(c, 3)
  reaper.ImGui_PopStyleColor(c, 2)
  if child_open then reaper.ImGui_EndChild(c) end
  if base_x then reaper.ImGui_SetCursorPosX(c, base_x) end
end

local function card_title(c, title, dot_color, wrap)
  local dl = reaper.ImGui_GetWindowDrawList(c)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(c)
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy + 5, sx + 4, sy + 9,
    dot_color or TK.accent_ui)
  reaper.ImGui_SetCursorPosX(c, reaper.ImGui_GetCursorPosX(c) + 10)
  local pushed = push_font(c, FONT.inter_semi, 12)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.text)
  if wrap then reaper.ImGui_TextWrapped(c, title) else reaper.ImGui_Text(c, title) end
  reaper.ImGui_PopStyleColor(c)
  pop_font(c, pushed)
end

local function muted_text(c, text, wrap)
  local pushed = push_font(c, FONT.inter_reg, 11)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.text_muted)
  if wrap then reaper.ImGui_TextWrapped(c, text) else reaper.ImGui_Text(c, text) end
  reaper.ImGui_PopStyleColor(c)
  pop_font(c, pushed)
end

local function mono_text(c, color, text)
  local pushed = push_font(c, FONT.mono_reg, 10)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_Text(c, text)
  reaper.ImGui_PopStyleColor(c)
  pop_font(c, pushed)
end

local function open_url(url)
  COMPONENTS:link(url)
end

local CAT_ORDER = { "Keys", "Guitars", "Bass", "Strings", "Voice", "Brass", "Sax", "Woodwinds", "Synths", "Drums" }
local INSTRUMENTS_BY_CAT = {}
for _, instrument in ipairs(INSTRUMENTS) do
  INSTRUMENTS_BY_CAT[instrument.cat] = INSTRUMENTS_BY_CAT[instrument.cat] or {}
  INSTRUMENTS_BY_CAT[instrument.cat][#INSTRUMENTS_BY_CAT[instrument.cat] + 1] = instrument
end

local function draw_instrument_tags(c)
  local changed = false
  local pushed = push_font(c, FONT.mono_reg, 10)
  for _, cat in ipairs(CAT_ORDER) do
    local list = INSTRUMENTS_BY_CAT[cat]
    if list and #list > 0 then
      local was_open = state.instrument_category_open[cat] == true
      local is_open = reaper.ImGui_CollapsingHeader(c, cat)
      state.instrument_category_open[cat] = is_open
      if is_open ~= was_open then state.layout_resize_requested = true end

      if is_open then
        local _, category_start_y = reaper.ImGui_GetCursorScreenPos(c)
        local row_start = reaper.ImGui_GetCursorPosX(c)
        local avail = reaper.ImGui_GetContentRegionAvail(c)
        local used = 0
        for i, inst in ipairs(list) do
          local selected = state.instruments[inst.key] == true
          local tw = reaper.ImGui_CalcTextSize(c, inst.label)
          local bw = tw + 14
          if used > 0 and used + bw > avail then
            used = 0
          elseif used > 0 then
            reaper.ImGui_SameLine(c, nil, 4)
          end
          if selected then
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Button(), TK.accent_ui)
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonHovered(), lerp_u32(TK.accent_ui, 0xFFFFFFFF, 0.10))
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.accent_text)
          else
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Button(), TK.input_bg)
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonHovered(), TK.card_hover)
            reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.text_muted)
          end
          reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FramePadding(), 7, 3)
          reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FrameRounding(), 4)
          if reaper.ImGui_Button(c, inst.label .. "##instrument_" .. inst.key) then
            if selected then
              state.instruments[inst.key] = nil
            else
              state.instruments[inst.key] = true
            end
            state.instrument_tags = table.concat(get_selected_instruments(), ", ")
            INSTRUMENT_MEMORY:remember(state)
            changed = true
          end
          reaper.ImGui_PopStyleVar(c, 2)
          reaper.ImGui_PopStyleColor(c, 3)
          used = used + bw + 4
        end
        reaper.ImGui_SetCursorPosX(c, row_start)
        reaper.ImGui_Dummy(c, 1, 1)
        local _, category_end_y = reaper.ImGui_GetCursorScreenPos(c)
        state.instrument_category_heights[cat] = math.max(1, category_end_y - category_start_y)
      end
    end
  end
  pop_font(c, pushed)
  return changed
end

local function settings_choices(c, id, options, current, on_change)
  local avail = reaper.ImGui_GetContentRegionAvail(c)
  local gap = 5
  local width = math.floor((avail - gap * (#options - 1)) / #options)
  local pushed = push_font(c, FONT.mono_med, 10)
  for i, option in ipairs(options) do
    if i > 1 then reaper.ImGui_SameLine(c, nil, gap) end
    local selected = current == option.value
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Button(), selected and TK.accent_ui or TK.card)
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonHovered(), selected and lerp_u32(TK.accent_ui, 0xFFFFFFFF, 0.10) or TK.card_hover)
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), selected and TK.accent_text or TK.text_muted)
    if reaper.ImGui_Button(c, option.label .. "##" .. id .. tostring(i), width, 27) then
      on_change(option.value)
    end
    reaper.ImGui_PopStyleColor(c, 3)
  end
  pop_font(c, pushed)
end

local get_window_size_limit
local function draw_settings(c)
  if COMPONENTS.open and COMPONENTS.page~=8 and(not COMPONENTS.job or tostring(COMPONENTS.job.action):match('^native_'))then
    reaper.ImGui_OpenPopup(c,"settings_popup")
    COMPONENTS.open=false
  end
  if state.settings_anchor_x and state.settings_anchor_y then
    reaper.ImGui_SetNextWindowPos(c, state.settings_anchor_x, state.settings_anchor_y + 6,
      reaper.ImGui_Cond_Appearing(), 1, 0)
  end
  reaper.ImGui_SetNextWindowSize(c, 570, 0, reaper.ImGui_Cond_Appearing())
  local _,limit_h=get_window_size_limit(c)
  reaper.ImGui_SetNextWindowSizeConstraints(c,480,200,10000,limit_h)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_PopupBg(), TK.bg_elev)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Border(), TK.border_str)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowPadding(), 14, 12)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowRounding(), 7)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  if reaper.ImGui_BeginPopup(c, "settings_popup") then
    local pushed = push_font(c, FONT.inter_semi, 14)
    reaper.ImGui_TextColored(c, TK.text, tr("settings"))
    pop_font(c, pushed)
    muted_text(c, ui_text("Модели, компоненты и внешний вид", "Models, components and appearance"), false)
    reaper.ImGui_Dummy(c, 1, 5)
    mono_text(c, TK.text_faint, string.upper(ui_text("Модели", "Models")))
    COMPONENTS:draw_settings(c,state.transcribing,state.language,TK)
    reaper.ImGui_Dummy(c, 1, 5)

    reaper.ImGui_BeginDisabled(c,state.transcribing or COMPONENTS:busy())
    if reaper.ImGui_Button(c,ui_text('Временные WAV и MIDI…','Temporary WAV and MIDI…'),-1,30) then
      COMPONENTS:show_storage();reaper.ImGui_CloseCurrentPopup(c)
    end
    if reaper.ImGui_Button(c,ui_text('Сохранить отчёт для поддержки (ZIP)','Save support report (ZIP)'),-1,30) then
      COMPONENTS:request_install();COMPONENTS:request_maintenance('support_report')
    end
    reaper.ImGui_EndDisabled(c)
    reaper.ImGui_Dummy(c, 1, 5)
    mono_text(c, TK.text_faint, string.upper(tr("language")))
    settings_choices(c, "lang", {
      { label = "EN", value = "en" }, { label = "RU", value = "ru" },
    }, state.language, function(value)
      state.language = value
      reaper.SetExtState(EXTSTATE_SECTION, "language", value, true)
    end)
    reaper.ImGui_Dummy(c, 1, 5)

    mono_text(c, TK.text_faint, string.upper(tr("ui_theme")))
    local theme_options = {
      { label = tr("light"), value = "light" },
      { label = tr("dark"), value = "dark" },
      { label = tr("cyan"), value = "cyan" },
    }
    local theme_index = 1
    local theme_labels = {}
    for i, option in ipairs(theme_options) do
      theme_labels[#theme_labels + 1] = option.label
      if option.value == state.theme then theme_index = i end
    end
    reaper.ImGui_SetNextItemWidth(c, -1)
    local theme_changed, selected_theme_index = reaper.ImGui_Combo(c, "##ui_theme",
      theme_index - 1, table.concat(theme_labels, "\0") .. "\0\0")
    if theme_changed then
      local selected_theme = theme_options[selected_theme_index + 1]
      if selected_theme then
        state.theme = selected_theme.value
        reaper.SetExtState(EXTSTATE_SECTION, "theme", state.theme, true)
      end
    end
    reaper.ImGui_Dummy(c, 1, 5)

    mono_text(c, TK.text_faint, string.upper(ui_text("Масштаб", "Scale")))
    settings_choices(c, "zoom", {
      { label = "75%", value = 0.75 }, { label = "100%", value = 1.0 },
      { label = "125%", value = 1.25 }, { label = "150%", value = 1.5 },
    }, UI_SCALE, function(value)
      UI_SCALE = value
      reaper.SetExtState(EXTSTATE_SECTION, "ui_scale", tostring(value), true)
      -- Сохранённая геометрия окна рассчитана на прежний масштаб и при увеличении
      -- обрежет содержимое, поэтому просим пересчитать размер по содержимому.
      state.layout_resize_requested = true
      state.requested_window_height = nil
      state.last_window_w = nil
      state.last_window_h = nil
    end)
    reaper.ImGui_Dummy(c, 1, 7)

    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Button(), TK.card)
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonHovered(), TK.card_hover)
    local about_clicked = reaper.ImGui_Button(c, tr("about") .. "  ↗##about", -1, 30)
    reaper.ImGui_PopStyleColor(c, 2)
    if about_clicked then open_url("https://boosty.to/aiwist") end
    reaper.ImGui_EndPopup(c)
  end
  reaper.ImGui_PopStyleVar(c, 3)
  reaper.ImGui_PopStyleColor(c, 2)
end

local function draw_hero(c)
  local dl = reaper.ImGui_GetWindowDrawList(c)
  local base_x = reaper.ImGui_GetCursorPosX(c)
  local base_y = reaper.ImGui_GetCursorPosY(c)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(c)
  local win_x = reaper.ImGui_GetWindowPos(c)
  local win_w = reaper.ImGui_GetWindowWidth(c)
  local hero_h = 72
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl,
    win_x, sy, win_x + win_w, sy + hero_h,
    TK.accent_soft, TK.accent_soft, TK.bg, TK.bg)
  reaper.ImGui_DrawList_AddLine(dl, win_x, sy + hero_h - 1,
    win_x + win_w, sy + hero_h - 1, TK.border, 1)

  local pad_x = 20
  local title_y = sy + 10
  local brand_w = calc_text(c, FONT.inter_light or FONT.inter_reg, 24, "Ai ")
  dl_text(dl, FONT.inter_light or FONT.inter_reg, 24, sx + pad_x, title_y,
    lerp_u32(TK.accent, 0x18264FFF, 0.25), "Ai ")
  dl_text(dl, FONT.inter_bold or FONT.inter_semi, 24, sx + pad_x + brand_w - 1,
    title_y, TK.accent, "Transcriber")
  dl_text(dl, FONT.mono_med, 9, sx + pad_x, sy + 43, TK.text_muted,
    ui_text("АУДИО → MIDI", "AUDIO → MIDI"))

  -- Compact ReaAssist-style gear in the former status slot. It has no
  -- permanent button chrome: only a generous hit target and a muted-to-bright
  -- hover transition.
  local icon_size = 14
  local icon_font = FONT.lucide
  local icon_text = icon_font and ICON.SETTINGS or "..."
  local iw = calc_text(c, icon_font, icon_size, icon_text)
  local version_label = "v" .. SCRIPT_VERSION
  local version_font = FONT.mono_reg or FONT.inter_reg
  local version_w = calc_text(c, version_font, 9, version_label)
  local tap_w, tap_h = math.max(iw + 10, version_w, 24), 24
  local x1 = sx + win_w - 20 - tap_w
  local y1 = sy + math.floor((hero_h - tap_h) * 0.5)
  reaper.ImGui_SetCursorScreenPos(c, x1, y1)
  local clicked = reaper.ImGui_InvisibleButton(c, "##settings_gear", tap_w, tap_h)
  local hovered = reaper.ImGui_IsItemHovered(c)
  if hovered then reaper.ImGui_SetMouseCursor(c, reaper.ImGui_MouseCursor_Hand()) end
  tooltip_v5(c, ui_text("Настройки интерфейса и формата аудио", "Interface and audio format settings"))
  dl_text(dl, icon_font, icon_size,
    x1 + math.floor((tap_w - iw) * 0.5), y1 + math.floor((tap_h - icon_size) * 0.5),
    hovered and TK.text or TK.text_muted, icon_text)
  dl_text(dl, version_font, 9, x1 + (tap_w - version_w) * 0.5,
    y1 + tap_h + 1, TK.text_muted, version_label)
  state.settings_anchor_x = x1 + tap_w
  state.settings_anchor_y = y1 + tap_h
  if clicked then reaper.ImGui_OpenPopup(c, "settings_popup") end

  reaper.ImGui_SetCursorPos(c, base_x, base_y)
  reaper.ImGui_Dummy(c, 1, hero_h)
end

local function draw_source_card(c)
  section_label(c, ui_text("ИСТОЧНИК АУДИО", "AUDIO SOURCE"))
  local show, card_x = begin_card(c, "##source_card")
  if show then
    card_title(c, state.item_name ~= "" and state.item_name or tr("no_item"),
      state.item and TK.accent_ui or TK.amber, true)
    if state.selection_error ~= "" then
      mono_text(c, TK.red, state.selection_error)
    elseif state.multiple_tracks then
      muted_text(c,ui_text('Фрагменты на нескольких дорожках','Items on multiple tracks'),false)
    elseif state.track_idx >= 0 then
      muted_text(c, string.format("%s  ·  #%d", state.track_name, state.track_idx), false)
    else
      muted_text(c, tr("select_audio"), false)
    end
    local details = string.format("%s  %s     %s  %s     %s  %.2f",
      string.upper(tr("position")), fmt_time(state.item_pos),
      string.upper(tr("duration")), fmt_time(state.item_len),
      string.upper(tr("project_bpm")), state.bpm or 120)
    mono_text(c, TK.text_muted, details)
    if state.transcribing then
      mono_text(c, TK.amber, "●  " .. tr("selection_locked"))
    end
  end
  end_card(c, show, card_x)
end

local function draw_model_card(c)
  local was_open = state.model_section_open
  state.model_section_open = section_label(c,
    ui_text("МОДЕЛЬ И ОБОРУДОВАНИЕ", "MODEL & HARDWARE"),
    state.model_section_open, "model")
  if state.model_section_open ~= was_open then
    reaper.SetExtState(EXTSTATE_SECTION, "model_section_open", state.model_section_open and "1" or "0", true)
    state.layout_resize_requested = true
  end
  if not state.model_section_open then
    return
  end

  local _, content_start_y = reaper.ImGui_GetCursorScreenPos(c)
  local show, card_x = begin_card(c, "##model_card")
  if show then
    reaper.ImGui_BeginDisabled(c, state.transcribing)
    local avail = reaper.ImGui_GetContentRegionAvail(c)
    muted_text(c, tr("model_size"), false)
    reaper.ImGui_SetNextItemWidth(c, avail)
    local pushed = push_font(c, FONT.mono_reg, 11)
    local descriptions={large=tr("best"),medium=tr("standard"),small=tr("fast")}
    local selected_model,install_requested=ModelPicker.draw(reaper,c,state.available_models,MODELS[state.model_idx],
      function(name) return name.." ("..descriptions[name]..")" end,tr("install_models"))
    pop_font(c, pushed)
    if install_requested then
      if COMPONENTS:can_recover() then COMPONENTS:show_overview() else COMPONENTS:request_install() end
    end
    if selected_model then select_installed_model(selected_model) end
    muted_text(c, tr("device"), false)
    reaper.ImGui_SetNextItemWidth(c, avail)
    pushed = push_font(c, FONT.mono_reg, 11)
    DEVICE_PICKER:draw(c,state.language,TK)
    pop_font(c, pushed)

    reaper.ImGui_EndDisabled(c)
  end
  end_card(c, show, card_x)
  local _, content_end_y = reaper.ImGui_GetCursorScreenPos(c)
  state.model_section_height = math.max(1, content_end_y - content_start_y)
end

local function draw_instruments_card(c)
  local was_open = state.instruments_section_open
  state.instruments_section_open = section_label(c,
    ui_text("ИНСТРУМЕНТЫ", "INSTRUMENTS"),
    state.instruments_section_open, "instruments")
  if state.instruments_section_open ~= was_open then
    reaper.SetExtState(EXTSTATE_SECTION, "instruments_section_open", state.instruments_section_open and "1" or "0", true)
    state.layout_resize_requested = true
  end
  if not state.instruments_section_open then
    return
  end

  local _, content_start_y = reaper.ImGui_GetCursorScreenPos(c)
  local show, card_x = begin_card(c, "##instruments_card")
  if show then
    reaper.ImGui_BeginDisabled(c, state.transcribing)
    muted_text(c, tr("auto_detect"), false)
    reaper.ImGui_Dummy(c, 1, 1)
    draw_instrument_tags(c)
    reaper.ImGui_Dummy(c, 1, 1)
    muted_text(c, tr("selected_instruments"), false)
    reaper.ImGui_SetNextItemWidth(c, -1)
    local pushed = push_font(c, FONT.mono_reg, 11)
    local ch_tags, new_tags = reaper.ImGui_InputText(c, "##instruments", state.instrument_tags, 512)
    pop_font(c, pushed)
    if ch_tags and new_tags then state.instrument_tags = new_tags;INSTRUMENT_MEMORY:remember(state) end
    if INSTRUMENT_MEMORY.error then muted_text(c,ui_text('Выбор сохранён только до закрытия скрипта: не удалось записать настройки.','The choice is kept for this run only: settings could not be saved.'),true)end
    reaper.ImGui_EndDisabled(c)
  end
  end_card(c, show, card_x)
  local _, content_end_y = reaper.ImGui_GetCursorScreenPos(c)
  state.instruments_section_height = math.max(1, content_end_y - content_start_y)
end

local function draw_output_card(c)
  section_label(c, ui_text("ВЫВОД MIDI", "MIDI OUTPUT"))
  local show, card_x = begin_card(c, "##output_card")
  if show then
    reaper.ImGui_BeginDisabled(c, state.transcribing)
    muted_text(c, ui_text(
      "Дорожки появятся под исходным аудио, будут выровнены по его началу и получат названия инструментов MuScriptor.",
      "Tracks are created below the source audio, aligned to its start, and named after MuScriptor instruments."), true)
    reaper.ImGui_Dummy(c, 1, 1)
    local channel_changed, channel_one = reaper.ImGui_Checkbox(c, tr("force_channel_one"), state.force_channel_one)
    if channel_changed then
      state.force_channel_one = channel_one
      reaper.SetExtState(EXTSTATE_SECTION, "force_channel_one", channel_one and "1" or "0", true)
    end
    tooltip_v5(c, ui_text(
      "Все импортированные ноты попадут на MIDI-канал 1. Исходный MIDI-файл не изменяется.",
      "All imported notes use MIDI channel 1. The source MIDI file is unchanged."))

    reaper.ImGui_EndDisabled(c)
  end
  end_card(c, show, card_x)
end

local function draw_action_and_status(c)
  reaper.ImGui_Dummy(c, 1, 2)
  local action_base_x = reaper.ImGui_GetCursorPosX(c)
  local action_avail_w = reaper.ImGui_GetContentRegionAvail(c)
  local action_inset = 7
  reaper.ImGui_SetCursorPosX(c, action_base_x + action_inset)
  local can_start=ModelPicker.can_transcribe(state.available_models,MODELS[state.model_idx],state.item~=nil,ENGINE~=nil,COMPONENTS:busy())
  reaper.ImGui_BeginDisabled(c, (state.transcribing) or not can_start)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Button(), TK.accent_ui)
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonHovered(), lerp_u32(TK.accent_ui, 0xFFFFFFFF, 0.10))
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ButtonActive(), lerp_u32(TK.accent_ui, 0x000000FF, 0.12))
  reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.accent_text)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FrameRounding(), 8)
  reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_FramePadding(), 10, 8)
  local pushed = push_font(c, FONT.inter_semi, 12)
  local action_label = tr("transcribe")
  local clicked = reaper.ImGui_Button(c, action_label .. "##transcribe",
    math.max(1, action_avail_w - action_inset * 2), 38)
  pop_font(c, pushed)
  reaper.ImGui_PopStyleVar(c, 2)
  reaper.ImGui_PopStyleColor(c, 4)
  reaper.ImGui_EndDisabled(c)
  reaper.ImGui_SetCursorPosX(c, action_base_x)
  if clicked then start_transcription() end
  if reaper.file_exists(STATE_ROOT..'\\last_result.json') or reaper.file_exists(STATE_ROOT..'\\last_result.json.bak') then
    reaper.ImGui_BeginDisabled(c,state.transcribing or COMPONENTS:busy())
    if reaper.ImGui_Button(c,ui_text('Повторно вставить последний MIDI','Insert last MIDI again'),-1,28) then
      local data,problem=LastResult.load(JSON,STATE_ROOT)
      if data then
        local ok,count=LastResult.import(reaper,data)
        state.status=ok and (tr('done')..' ('..tostring(count)..')') or ('ERROR: '..tostring(count))
      else state.status='ERROR: '..tostring(problem) end
    end
    reaper.ImGui_EndDisabled(c)
  end

  local initial_ready = state.status == I18N.en.ready or state.status == I18N.ru.ready
  if initial_ready and not state.transcribing then
    local _, hidden_start_y = reaper.ImGui_GetCursorScreenPos(c)
    reaper.ImGui_Dummy(c, 1, STATUS_PANEL_RESERVE_HEIGHT)
    local _, hidden_end_y = reaper.ImGui_GetCursorScreenPos(c)
    state.status_panel_hidden_height = math.max(1, hidden_end_y - hidden_start_y)
    if state.status_panel_visible then
      state.status_panel_visible = false
      state.layout_resize_requested = true
    end
    return
  end

  local was_status_visible = state.status_panel_visible
  local _, status_region_start_y = reaper.ImGui_GetCursorScreenPos(c)
  reaper.ImGui_Dummy(c, 1, 2)
  local show, card_x = begin_card(c, "##status_card")
  if show then
    local status_color = TK.text_muted
    if state.transcribing then
      status_color = TK.accent
    elseif state.status:sub(1, 5) == "ERROR" then
      status_color = TK.red
    elseif state.status:sub(1, 4) == "DONE" or state.status:find("Готово!", 1, true) then
      status_color = TK.green
    end
    local pulse = 0xFF
    if state.transcribing then
      pulse = math.floor(110 + 145 * (0.5 + 0.5 * math.sin(reaper.time_precise() * 5)))
    end
    local dl = reaper.ImGui_GetWindowDrawList(c)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(c)
    reaper.ImGui_DrawList_AddCircleFilled(dl, sx + 3, sy + 7, 3,
      (status_color & 0xFFFFFF00) | pulse)
    reaper.ImGui_SetCursorPosX(c, reaper.ImGui_GetCursorPosX(c) + 13)
    local status_font = push_font(c, FONT.inter_reg, 11)
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), status_color)
    reaper.ImGui_TextWrapped(c, state.status)
    reaper.ImGui_PopStyleColor(c)
    pop_font(c, status_font)
    if state.log_ready and not state.transcribing then
      if reaper.ImGui_Button(c,ui_text("Отчёт для поддержки (ZIP)","Support report (ZIP)"))then COMPONENTS:request_maintenance("support_report")end
      reaper.ImGui_Dummy(c, 1, 3)
      local log_font = push_font(c, FONT.inter_med or FONT.inter_reg, 10)
      reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.accent)
      local copy_clicked = reaper.ImGui_Selectable(c, tr("copy_log") .. "##copy_log", false)
      reaper.ImGui_PopStyleColor(c)
      pop_font(c, log_font)
      if reaper.ImGui_IsItemHovered(c) then reaper.ImGui_SetTooltip(c, tr("copy_log_hint")) end
      if copy_clicked then copy_diagnostic_log_to_clipboard() end
      if state.log_feedback ~= "" then
        local feedback_font = push_font(c, FONT.inter_reg, 9)
        reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_Text(), TK.text_muted)
        reaper.ImGui_TextWrapped(c, state.log_feedback)
        reaper.ImGui_PopStyleColor(c)
        pop_font(c, feedback_font)
      end
    end
  end
  end_card(c, show, card_x)
  reaper.ImGui_Dummy(c, 1, 5)
  local _, status_content_end_y = reaper.ImGui_GetCursorScreenPos(c)
  local used_status_height = math.max(0, status_content_end_y - status_region_start_y)
  if used_status_height < STATUS_PANEL_RESERVE_HEIGHT then
    reaper.ImGui_Dummy(c, 1, STATUS_PANEL_RESERVE_HEIGHT - used_status_height)
  end
  local _, status_region_end_y = reaper.ImGui_GetCursorScreenPos(c)
  local status_region_height = math.max(1, status_region_end_y - status_region_start_y)
  local measured_extra_height = math.max(1,
    status_region_height - (state.status_panel_hidden_height or STATUS_PANEL_RESERVE_HEIGHT))
  state.status_panel_visible = true
  if not was_status_visible then
    state.status_panel_extra_height = measured_extra_height
    state.layout_resize_requested = true
  end
end

-- Пределы размера окна берём из рабочей области главного окна REAPER:
-- ReaImGui отдаёт её как main viewport, уже за вычетом панелей задач и меню.
-- Нужны они вот почему. Положение и размер окна ReaImGui хранит в своём ini
-- в ресурсной папке REAPER, и переустановка скрипта этот файл не трогает.
-- После смены мониторов на больший масштаб логических точек становится меньше,
-- сохранённое окно перестаёт помещаться, нижняя часть с кнопками уезжает за
-- край экрана — и выглядит это так, будто окно перестало отвечать на нажатия.
get_window_size_limit=function(c)
  local limit_w, limit_h = 1000, 1400
  local viewport = reaper.ImGui_GetMainViewport and reaper.ImGui_GetMainViewport(c)
  if viewport and reaper.ImGui_Viewport_GetWorkSize then
    local work_w, work_h = reaper.ImGui_Viewport_GetWorkSize(viewport)
    if work_w and work_w > 0 then limit_w = math.max(440, math.min(1000, work_w - 40)) end
    if work_h and work_h > 0 then limit_h = math.max(650, math.min(1400, work_h - 40)) end
  end
  return limit_w, limit_h
end

local function draw_gui(c)
  if not state.transcribing then refresh_selection_if_changed() end
  local theme_colors, theme_vars = push_theme(c)
  local base_font = push_font(c, FONT.inter_reg, 13)
  local limit_w, limit_h = get_window_size_limit(c)
  if state.requested_window_height and state.last_window_w then
    reaper.ImGui_SetNextWindowSize(c, math.min(limit_w, state.last_window_w),
      math.max(650, math.min(limit_h, state.requested_window_height)))
    state.requested_window_height = nil
  else
    reaper.ImGui_SetNextWindowSize(c, 540, 650, reaper.ImGui_Cond_FirstUseEver())
  end
  reaper.ImGui_SetNextWindowSizeConstraints(c, 440, 650, limit_w, limit_h)
  SetupUI.center_first_open(reaper,c)
  reaper.ImGui_SetNextWindowBgAlpha(c, 1.0)
  local visible, open = reaper.ImGui_Begin(c, "Ai Transcriber", true,
    reaper.ImGui_WindowFlags_NoNavInputs())

  if visible then
    state.last_window_w, state.last_window_h = reaper.ImGui_GetWindowSize(c)
    -- Восстановленный размер мог остаться от прежней конфигурации мониторов.
    -- Подрезаем его каждый кадр, но только вниз: вырасти окно может в пределах
    -- ограничения, заданного выше.
    if state.last_window_h > limit_h or state.last_window_w > limit_w then
      reaper.ImGui_SetWindowSize(c, math.min(state.last_window_w, limit_w),
        math.min(state.last_window_h, limit_h))
    end
    draw_hero(c)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(c)
    local body_h = math.max(1, avail_h)
    reaper.ImGui_PushStyleVar(c, reaper.ImGui_StyleVar_WindowPadding(), 14, 10)
    reaper.ImGui_PushStyleColor(c, reaper.ImGui_Col_ChildBg(), 0x00000000)
    local body_visible = reaper.ImGui_BeginChild(c, "##main_body", avail_w, body_h, 0)
    if body_visible then
      draw_source_card(c)
      reaper.ImGui_Dummy(c, 1, 5)
      draw_model_card(c)
      reaper.ImGui_Dummy(c, 1, 5)
      draw_instruments_card(c)
      reaper.ImGui_Dummy(c, 1, 5)
      draw_output_card(c)
      draw_action_and_status(c)
      local content_height = reaper.ImGui_GetCursorPosY(c) + 10
      -- A section opened in this frame may not have a stable measured height
      -- until ImGui completes another layout pass. Recalculate on two
      -- consecutive frames so the very first expansion also resizes the
      -- window, rather than only working after a collapse/reopen cycle.
      if state.layout_resize_requested then
        state.layout_resize_settle_frames = 2
        state.layout_resize_requested = false
      end
      if (state.layout_resize_settle_frames or 0) > 0 then
        local window_chrome_height = math.max(0, state.last_window_h - body_h)
        state.requested_window_height = math.max(650,
          math.min(limit_h, window_chrome_height + content_height))
        state.layout_resize_settle_frames = state.layout_resize_settle_frames - 1
      end
    end
    reaper.ImGui_PopStyleColor(c)
    reaper.ImGui_PopStyleVar(c)
    if body_visible then reaper.ImGui_EndChild(c) end

    draw_settings(c)
  end

  if visible then reaper.ImGui_End(c) end
  pop_font(c, base_font)
  reaper.ImGui_PopStyleVar(c, theme_vars)
  reaper.ImGui_PopStyleColor(c, theme_colors)
  return open
end

-- Create the context only in a deferred drawing frame. A paused script can
-- outlive its ReaImGui resources, while its queue/result state remains valid.
local GUI_CONTEXT=GuiContext.new(reaper,"Ai Transcriber",function(ctx)
  for key in pairs(FONT)do FONT[key]=nil end
  local clean_script_dir = script_dir:gsub("[\\/]+$", "")
  local aiwist_dir = clean_script_dir:match("^(.*)[\\/][^\\/]+$") or clean_script_dir
  local font_dirs = {
    clean_script_dir .. "\\fonts\\",
    aiwist_dir .. "\\ReaAssist (mod)\\App\\Resources\\fonts\\",
  }
  local files = {
    inter_reg = "Inter_18pt-Regular.ttf",
    inter_light = "Inter_18pt-Light.ttf",
    inter_semi = "Inter_18pt-SemiBold.ttf",
    inter_bold = "Inter_18pt-Bold.ttf",
    mono_reg = "JetBrainsMono-Regular.ttf",
    mono_med = "JetBrainsMono-Medium.ttf",
    lucide = "lucide.ttf",
  }
  for key, filename in pairs(files) do
    for _, fonts_dir in ipairs(font_dirs) do
      local path = fonts_dir .. filename
      if reaper.file_exists(path) then
        local ok, font = pcall(reaper.ImGui_CreateFontFromFile, path, 0, 0)
        if ok and font then
          local attached = pcall(reaper.ImGui_Attach, ctx, font)
          if attached then FONT[key] = font break end
        end
      end
    end
  end
end)
local ctx

local function advance_audio_preparation_step()
  local job = state.audio_prepare_job
  if not job then return end

  if not job.current then
    if job.index > #job.items then
      local prepared = job.prepared
      state.audio_prepare_job = nil
      start_transcription(prepared)
      return
    end
    local path = job.temp_dir .. "\\reaper_take_" .. job.run_id .. "_" ..
      string.format("%04d.wav", job.index)
    state.audio_temp_sources[#state.audio_temp_sources + 1] = path
    job.current = begin_take_audio_export(job.items[job.index], path)
  end

  local current = job.current
  local frames = math.min(ACCESSOR_CHUNK_FRAMES,
    current.frame_count - current.frame_offset)
  local buffer = reaper.new_array(frames * ACCESSOR_CHANNELS)
  buffer.clear()
  local result = reaper.GetAudioAccessorSamples(current.accessor,
    ACCESSOR_SAMPLE_RATE, ACCESSOR_CHANNELS,
    current.accessor_start + current.frame_offset / ACCESSOR_SAMPLE_RATE,
    frames, buffer)
  if result == nil or result < 0 then
    error("REAPER failed while reading warped take audio: result=" .. tostring(result))
  end

  local packed = pack_float_samples(buffer.table(), frames * ACCESSOR_CHANNELS)
  local wrote, write_error = current.file:write(packed)
  if not wrote then
    error("Could not write temporary take audio: " ..
      tostring(write_error or current.output_path))
  end

  current.frame_offset = current.frame_offset + frames
  local total_done = job.completed_frames + current.frame_offset
  local percent = math.floor(math.min(100,
    total_done / math.max(1, job.all_frames) * 100) + 0.5)
  state.status = tr("preparing_audio") .. string.format("\n%d/%d  ·  %d%%",
    job.index, #job.items, percent)

  if current.frame_offset >= current.frame_count then
    job.prepared[#job.prepared + 1] = current.source
    job.completed_frames = job.completed_frames + current.frame_count
    close_current_audio_export()
    job.current = nil
    job.index = job.index + 1
  end
end

local function advance_audio_preparation()
  if not state.audio_prepare_job then return end
  local ok, failure = pcall(advance_audio_preparation_step)
  if not ok then
    cleanup_audio_preparation()
    state.transcribing = false
    state.status = "ERROR: " .. tr("render_failed") .. "\n" .. tostring(failure)
  end
end

local function loop()
  local setup_ok, setup_error = pcall(function() COMPONENTS:poll() end)
  if not setup_ok then state.status = "SETUP ERROR: " .. tostring(setup_error) end
  refresh_installed_models(false)
  update_session(false)
  advance_audio_preparation()
  DEVICE_PICKER:poll(state.transcribing or COMPONENTS:busy())
  local current,recovered,problem=GUI_CONTEXT:ensure()
  if not current then
    reaper.MB("Не удалось открыть окно Ai Transcriber.\n\n"..tostring(problem),"Ai Transcriber",0)
    return
  end
  ctx=current
  if recovered then state.ui_context_recoveries=(state.ui_context_recoveries or 0)+1 end
  local open = draw_gui(ctx)
  local setup_colors, setup_vars = push_theme(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16, 14)
  local setup_font = push_font(ctx, FONT.inter_reg, 13)
  COMPONENTS.language=state.language; COMPONENTS.colors=TK
  COMPONENTS.transcription_active=state.transcribing;COMPONENTS.support_instance=SESSION_ID
  COMPONENTS:draw(ctx, state.transcribing)
  pop_font(ctx, setup_font)
  reaper.ImGui_PopStyleVar(ctx, setup_vars + 1)
  reaper.ImGui_PopStyleColor(ctx, setup_colors)
  if not COMPONENTS.last_ui_heartbeat or reaper.time_precise() - COMPONENTS.last_ui_heartbeat > 1 then
    COMPONENTS.last_ui_heartbeat = reaper.time_precise()
    reaper.SetExtState(PREF_SECTION, "ui_status", JSON.encode({version=SCRIPT_VERSION,
      page=COMPONENTS.page, manager_open=COMPONENTS.open, busy=COMPONENTS:busy(), updated=os.time()}), false)
  end
  if open then
    reaper.defer(loop)
  end
  -- При закрытии окна просто выходим; REAPER сам освободит контекст
end

-- Старт
refresh_selected_item()
if RESUME then
  state.pending_out=TEMP..RESUME.output;state.pending_cfg=TEMP..'config.json';state.pending_context=RESUME.context
  state.item_name=RESUME.name or'transcription';state.item_pos=RESUME.context.position;state.item_len=RESUME.context.duration
  state.transcribing=true;state.log_ready=true
  state.transcription_started_at=reaper.time_precise()-math.max(0,os.time()-(tonumber(RESUME.started)or os.time()))
  state.status='Продолжается транскрибация…';reaper.defer(poll_transcription)
end
reaper.atexit(function()pcall(DEVICE_PICKER.close,DEVICE_PICKER);pcall(INSTRUMENT_MEMORY.remember,INSTRUMENT_MEMORY,state);cleanup_audio_preparation();update_session(true)end)
reaper.defer(loop)
