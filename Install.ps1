param([switch]$LibraryOnly)
$ErrorActionPreference='Stop'
$script:SetupVersion='1.0.2'
$script:SetupPayloadRoot=Join-Path $PSScriptRoot 'Transcriber'
$script:SetupFiles=@(
    'Aiwist_Transcriber.lua',
    'INSTALL_LICENSES_RU.txt',
    'NOTICE.txt',
    'README_RU.txt',
    'Register_Ai_Transcriber.lua',
    'THIRD_PARTY_NOTICES_RU.txt',
    'capabilities.json',
    'fonts/Inter_18pt-Bold.ttf',
    'fonts/Inter_18pt-Light.ttf',
    'fonts/Inter_18pt-Regular.ttf',
    'fonts/Inter_18pt-SemiBold.ttf',
    'fonts/JetBrainsMono-Medium.ttf',
    'fonts/JetBrainsMono-Regular.ttf',
    'fonts/lucide.ttf',
    'lib/first_run.lua',
    'lib/gguf_health.lua',
    'lib/gui_context.lua',
    'lib/hidden_runner.lua',
    'lib/instrument_memory.lua',
    'lib/json.lua',
    'lib/last_result.lua',
    'lib/model_picker.lua',
    'lib/native_components.lua',
    'lib/native_devices.lua',
    'lib/native_downloads.lua',
    'lib/profile_identity.lua',
    'lib/setup_ui.lua',
    'lib/state_paths.lua',
    'lib/support_zip.lua',
    'lib/windows_paths.lua',
    'licenses/AiTranscriber-Lua-APACHE-2.0.txt',
    'licenses/Inter-OFL-1.1.txt',
    'licenses/JetBrainsMono-OFL-1.1.txt',
    'licenses/Lucide-LICENSE.txt',
    'licenses/MuScriptor-Code-MIT.txt',
    'licenses/MuScriptor-Specific-Conditions.txt',
    'licenses/MuScriptor-Weights-CC-BY-NC-4.0.txt',
    'licenses/PFFFT-FFTPACK-LICENSE.txt',
    'licenses/dr-wav-LICENSE.txt',
    'licenses/ggml-MIT.txt',
    'licenses/libsamplerate-BSD.txt',
    'licenses/muscriptor-cpp-MIT.txt',
    'licenses/nlohmann-json-MIT.txt',
    'manifest.json',
    'native_models.json',
    'native_release.json',
    'runtime/muscriptor-34a01513-cpu/ai_transcriber_native.exe',
    'runtime/muscriptor-34a01513-vulkan/ai_transcriber_native.exe',
    'setup/bootstrap.ps1',
    'setup/common.ps1',
    'setup/download_progress.ps1',
    'setup/launch_process.ps1',
    'setup/maintenance.ps1',
    'setup/native_process.ps1',
    'setup/native_runner.ps1',
    'setup/native_setup.ps1',
    'setup/single_runner.ps1',
    'setup/worker.ps1'
)
function Get-SetupSafePath([string]$Root,[string]$Relative) {
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $path=[IO.Path]::GetFullPath((Join-Path $base $Relative.Replace('/','\')))
    if (-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Недопустимый путь установки.' }
    return $path
}
function Assert-SetupOrdinaryPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Выберите обычную папку без символических ссылок: '+$current) }
        }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Get-SetupHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$script:ReaImGuiInstaller=Join-Path $PSScriptRoot 'reaimgui_install.ps1'
if (-not (Test-Path -LiteralPath $script:ReaImGuiInstaller -PathType Leaf) -or
    (Get-FileHash -LiteralPath $script:ReaImGuiInstaller).Hash -ne 'D3EF122E8A94A03E61CDB86FDB83CBDD6C5F3222ECE4C4545C168EAFDBBBA21E') {
    throw 'AIT2-120: Повреждён модуль установки ReaImGui. Распакуйте исходный установочный архив заново.'
}
. $script:ReaImGuiInstaller
$script:ActionsInstaller=Join-Path $PSScriptRoot 'reaper_actions.ps1'
if(-not (Test-Path -LiteralPath $script:ActionsInstaller -PathType Leaf) -or
    (Get-FileHash -LiteralPath $script:ActionsInstaller).Hash -ne '2A6926EEB4231C4DCAF58D9E17589AE0C48DEA93778DB60C2C1B8F449AFB2A61'){
    throw 'AIT2-120: Повреждён модуль регистрации Actions. Распакуйте исходный архив заново.'
}
. $script:ActionsInstaller
function Get-SetupPayload([string]$SourceRoot) {
    Assert-SetupOrdinaryPath $SourceRoot
    $manifestPath=Get-SetupSafePath $SourceRoot 'manifest.tsv'
    $manifest=@{}
    foreach ($line in [IO.File]::ReadAllLines($manifestPath,[Text.Encoding]::UTF8)) {
        if ($line -eq '') { continue }
        $fields=$line.Split([char]9)
        if ($fields.Count -ne 2 -or $script:SetupFiles -cnotcontains $fields[0] -or $manifest.ContainsKey($fields[0])) { throw 'Некорректный список файлов установки.' }
        $manifest[$fields[0]]=$fields[1]
    }
    if ($manifest.Count -ne $script:SetupFiles.Count) { throw 'Неполный комплект установки.' }
    $data=@{}
    foreach ($name in $script:SetupFiles) {
        $path=Get-SetupSafePath $SourceRoot $name; Assert-SetupOrdinaryPath $path
        $bytes=[IO.File]::ReadAllBytes($path)
        if ((Get-SetupHash $bytes) -cne $manifest[$name]) { throw ('Контрольная сумма не совпадает: '+$name) }
        $data[$name]=$bytes
    }
    $worker=$data['setup/worker.ps1']
    if ($worker[0] -ne 239 -or $worker[1] -ne 187 -or $worker[2] -ne 191) { throw 'Некорректная кодировка PowerShell worker.' }
    $data['manifest.tsv']=[IO.File]::ReadAllBytes($manifestPath)
    return $data
}
function Assert-SetupIdle([string]$ResourcePath,[string]$LocalData=[Environment]::GetFolderPath('LocalApplicationData')) {
    foreach($process in @(Get-Process -Name ai_transcriber_native -ErrorAction SilentlyContinue)){
        $path=$null;try{$path=$process.Path}catch{}
        foreach($folder in @('Scripts/Aiwist/Transcriber','Scripts/Aiwist/Transcriber Lite')){
            $base=Get-SetupSafePath $ResourcePath $folder
            if($path -and $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Завершите транскрибацию перед обновлением Ai Transcriber.'}
        }
    }
    $local=$LocalData
    foreach($name in @('Ai Transcriber','Ai Transcriber Lite','Ai Transcriber 2.0')){
        $root=Join-Path $local ('Aiwist\'+$name)
        $records=@()
        foreach($file in @('active_job.json','running_job.json','native_download_jobs.json')){
            $path=Join-Path $root $file
            if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -le 1048576){
                try{$value=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;if($file -eq 'native_download_jobs.json'){$records+=@($value.jobs.PSObject.Properties.Value)}else{$records+=$value}}catch{}
            }
        }
        foreach($job in $records){
            if($job.id -notmatch '^[a-fA-F0-9]{32}$' -or $job.directory -ine (Join-Path $root ('jobs\'+$job.id)) -or [IO.File]::Exists((Join-Path $job.directory 'result.json'))){continue}
            $ownerPath=Join-Path $job.directory 'worker.json'
            try{
                $owner=Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop|ConvertFrom-Json
                $worker=Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue
                if($worker -and $worker.StartTime.ToUniversalTime().ToString('o') -eq $owner.started){throw [InvalidOperationException]::new('Дождитесь завершения или остановите скачивание моделей перед обновлением Ai Transcriber.')}
            }catch [InvalidOperationException]{throw}catch{}
        }
    }
}
function Install-AiTranscriber([string]$ResourcePath,[string]$SourceRoot=$script:SetupPayloadRoot,[int]$FailAfter=-1,[scriptblock]$OnProgress) {
    if(-not [Environment]::Is64BitOperatingSystem){throw 'AIT2-165: Эта сборка предназначена для Windows x64 и REAPER x64.'}
    if (-not [IO.Path]::IsPathRooted($ResourcePath)) { throw 'Выберите полный путь к папке ресурсов REAPER.' }
    if (-not (Test-Path -LiteralPath (Join-Path $ResourcePath 'reaper.ini') -PathType Leaf)) {
        throw 'AIT-500: Это не папка ресурсов REAPER: нет reaper.ini. Откройте REAPER → Options → Show REAPER resource path. Папка программы в Program Files обычно не подходит.'
    }
    $data=Get-SetupPayload $SourceRoot
    $installFiles=@($script:SetupFiles)+@('manifest.tsv')
    Assert-SetupIdle $ResourcePath
    $imgui=Ensure-SetupReaImGui $ResourcePath $OnProgress
    $target=Get-SetupSafePath $ResourcePath 'Scripts/Aiwist/Transcriber'
    Assert-SetupOrdinaryPath $target
    foreach ($name in $installFiles) { Assert-SetupOrdinaryPath (Get-SetupSafePath $target $name) }
    $backup=Get-SetupSafePath $target ('_update_backup/setup_'+$script:SetupVersion+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+([guid]::NewGuid().ToString('N').Substring(0,8)))
    $originals=@{}; $touched=New-Object 'Collections.Generic.List[string]'
    $retired=New-Object 'Collections.Generic.List[string]'
    $oldManifest=Get-SetupSafePath $target 'manifest.json';$previous=$null
    if([IO.File]::Exists($oldManifest) -and (Get-Item -LiteralPath $oldManifest).Length -le 1048576){try{$previous=Get-Content -LiteralPath $oldManifest -Raw|ConvertFrom-Json}catch{}}
    $alias=Get-SetupSafePath $ResourcePath 'Scripts/Aiwist/Transcriber Lite/Aiwist_Transcriber_Lite.lua'
    $aliasBackup=Get-SetupSafePath $backup 'legacy/Aiwist_Transcriber_Lite.lua';$aliasChanged=$false
    $changed=@($installFiles|Where-Object {
        $file=Get-SetupSafePath $target $_
        -not [IO.File]::Exists($file) -or (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -cne (Get-SetupHash $data[$_])
    })
    foreach ($name in $changed) {
        $destination=Get-SetupSafePath $target $name
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $saved=Get-SetupSafePath $backup $name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
            Copy-Item -LiteralPath $destination -Destination $saved
            $originals[$name]=$saved
        }
    }
    try {
        foreach ($name in $changed) {
            if ($touched.Count -eq $FailAfter) { throw 'Тестовая ошибка записи.' }
            $destination=Get-SetupSafePath $target $name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $touched.Add($name)
            [IO.File]::WriteAllBytes($destination,$data[$name])
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne (Get-SetupHash $data[$name])) { throw ('Ошибка проверки: '+$name) }
        }
        if($previous -and $previous.files -and @($previous.files.PSObject.Properties).Count -le 512){
            foreach($entry in $previous.files.PSObject.Properties){
                $name=$entry.Name
                if($installFiles -contains $name -or $name -like 'runtime/*' -or $entry.Value -notmatch '^[a-fA-F0-9]{64}$'){continue}
                $old=Get-SetupSafePath $target $name;Assert-SetupOrdinaryPath $old
                if([IO.File]::Exists($old) -and (Get-FileHash -LiteralPath $old).Hash -ieq $entry.Value){
                    $saved=Get-SetupSafePath $backup ('retired/'+$name)
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
                    Move-Item -LiteralPath $old -Destination $saved;$retired.Add($name)
                }
            }
        }
        if($FailAfter -eq -2){throw 'Тестовая ошибка после смены модулей.'}
        if([IO.File]::Exists($alias)){
            Assert-SetupOrdinaryPath $alias
            $bridge="-- @description Ai Transcriber`r`nlocal p=reaper.GetResourcePath()..'/Scripts/Aiwist/Transcriber/Aiwist_Transcriber.lua'`r`nif not reaper.file_exists(p)then reaper.MB('Повторите установку Ai Transcriber.','Ai Transcriber',0);return end`r`ndofile(p)`r`n"
            if([IO.File]::ReadAllText($alias) -cne $bridge){
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($aliasBackup));Copy-Item -LiteralPath $alias -Destination $aliasBackup
                $aliasChanged=$true;[IO.File]::WriteAllText($alias,$bridge,[Text.UTF8Encoding]::new($false))
            }
        }
        if($FailAfter -eq -3){throw 'Тестовая ошибка после обновления прежнего запуска.'}
    } catch {
        $failure=$_.Exception.Message; $recoveryErrors=New-Object 'Collections.Generic.List[string]'
        if($aliasChanged){try{Copy-Item -LiteralPath $aliasBackup -Destination $alias -Force}catch{$recoveryErrors.Add('Прежний запуск: '+$_.Exception.Message)}}
        foreach($name in $retired){try{Copy-Item -LiteralPath (Get-SetupSafePath $backup ('retired/'+$name)) -Destination (Get-SetupSafePath $target $name) -Force}catch{$recoveryErrors.Add($name+': '+$_.Exception.Message)}}
        for ($i=$touched.Count-1;$i -ge 0;$i--) {
            $name=$touched[$i]; $destination=Get-SetupSafePath $target $name
            try {
                if ($originals.ContainsKey($name)) { Copy-Item -LiteralPath $originals[$name] -Destination $destination -Force }
                elseif (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination }
            } catch { $recoveryErrors.Add($name+': '+$_.Exception.Message) }
        }
        if ($recoveryErrors.Count) { throw ($failure+"`r`nРезервные копии: "+$backup+"`r`n"+($recoveryErrors -join "`r`n")) }
        throw $failure
    }
    return [pscustomobject]@{Target=$target;Backup=$backup;Files=$installFiles.Count;Changed=$touched.Count;ReaImGui=$imgui}
}
function Get-SetupLicenseText([string]$SourceRoot=$script:SetupPayloadRoot) {
    $payload=Get-SetupPayload $SourceRoot
    if(-not $payload.ContainsKey('INSTALL_LICENSES_RU.txt')){throw 'В комплекте отсутствует лицензионный лист. Распакуйте ZIP заново.'}
    return [Text.Encoding]::UTF8.GetString($payload['INSTALL_LICENSES_RU.txt']).TrimStart([char]0xFEFF)
}
function New-SetupLicenseWindow([string]$Text) {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text='Ai Transcriber — лицензии и условия';$form.ClientSize=New-Object Drawing.Size(660,560)
    $form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.StartPosition='CenterScreen'
    $form.AutoScaleMode='Dpi';$form.Font=New-Object Drawing.Font('Segoe UI',10)
    $form.BackColor=[Drawing.Color]::FromArgb(28,31,33);$form.ForeColor=[Drawing.Color]::FromArgb(230,232,234)
    $title=New-Object Windows.Forms.Label;$title.Text='Лицензии и условия';$title.SetBounds(28,19,604,38)
    $title.Font=New-Object Drawing.Font('Segoe UI',21,[Drawing.FontStyle]::Bold);$title.ForeColor=[Drawing.Color]::FromArgb(109,201,218);$form.Controls.Add($title)
    $hint=New-Object Windows.Forms.Label;$hint.Text='Ознакомьтесь с условиями компонентов и моделей Ai Transcriber перед установкой.';$hint.SetBounds(28,65,604,42);$form.Controls.Add($hint)
    $document=New-Object Windows.Forms.TextBox;$document.SetBounds(28,115,604,295)
    $document.Multiline=$true;$document.MaxLength=1048576
    $document.ReadOnly=$true;$document.WordWrap=$true;$document.ScrollBars='Vertical'
    $document.BorderStyle='FixedSingle';$document.BackColor=[Drawing.Color]::FromArgb(23,25,27);$document.ForeColor=$form.ForeColor
    $document.Font=New-Object Drawing.Font('Segoe UI',9);$document.Text=$Text -replace "`r?`n","`r`n";$document.SelectionStart=0;$form.Controls.Add($document)
    $accept=New-Object Windows.Forms.RadioButton;$accept.Text='Я принимаю условия';$accept.SetBounds(28,422,604,26);$form.Controls.Add($accept)
    $decline=New-Object Windows.Forms.RadioButton;$decline.Text='Я не принимаю условия';$decline.SetBounds(28,451,604,26);$decline.Checked=$true;$form.Controls.Add($decline)
    $version=New-Object Windows.Forms.Label;$version.Text='Ai Transcriber · v'+$script:SetupVersion;$version.SetBounds(28,516,290,24);$version.ForeColor=[Drawing.Color]::FromArgb(160,164,168);$form.Controls.Add($version)
    $next=New-Object Windows.Forms.Button;$next.Text='Далее';$next.SetBounds(342,508,140,36);$next.Enabled=$false
    $next.FlatStyle='Flat';$next.FlatAppearance.BorderSize=0;$next.BackColor=[Drawing.Color]::FromArgb(41,44,47);$next.ForeColor=$form.ForeColor;$form.Controls.Add($next)
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Отмена';$cancel.SetBounds(492,508,140,36);$cancel.DialogResult='Cancel'
    $cancel.FlatStyle='Flat';$cancel.FlatAppearance.BorderSize=0;$cancel.BackColor=[Drawing.Color]::FromArgb(41,44,47);$cancel.ForeColor=$form.ForeColor;$form.Controls.Add($cancel)
    $accept.Add_CheckedChanged({
        $next.Enabled=$accept.Checked
        $next.BackColor=if($accept.Checked){[Drawing.Color]::FromArgb(43,119,140)}else{[Drawing.Color]::FromArgb(41,44,47)}
    }.GetNewClosure())
    $next.Add_Click({if($accept.Checked){$form.DialogResult='OK';$form.Close()}}.GetNewClosure())
    $form.AcceptButton=$next;$form.CancelButton=$cancel
    $form.Tag=[pscustomobject]@{Accept=$accept;Decline=$decline;Next=$next;Cancel=$cancel;Document=$document}
    return $form
}
function Show-SetupLicenseWindow([string]$Text) {
    $form=New-SetupLicenseWindow $Text
    try{return $form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK}
    finally{$form.Dispose()}
}
function Show-SetupWindow {
    param([string]$PreviewPath,[string]$ResourcePath)
    # The BAT entry point cannot reach installation or dependency buttons until
    # this dialog has been accepted. Cancelling does not create an install form.
    if(-not $PreviewPath){
        $licenseText=Get-SetupLicenseText
        if(-not (Show-SetupLicenseWindow $licenseText)){return}
    }
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:SetupForm=New-Object Windows.Forms.Form
    $form=$script:SetupForm; $form.Text='Ai Transcriber — установка'; $form.ClientSize=New-Object Drawing.Size(660,510)
    $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.StartPosition='CenterScreen'
    $form.BackColor=[Drawing.Color]::FromArgb(28,31,33); $form.ForeColor=[Drawing.Color]::FromArgb(230,232,234)
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $script:SetupBusy=$false; $script:SetupInstalledResource=$null; $script:SetupRegistered=$false
    $accent=[Drawing.Color]::FromArgb(109,201,218); $muted=[Drawing.Color]::FromArgb(160,164,168)
    function New-SetupLabel($Text,$X,$Y,$W,$H,$Color) {
        $label=New-Object Windows.Forms.Label; $label.Text=$Text; $label.SetBounds($X,$Y,$W,$H); $label.ForeColor=$Color; $form.Controls.Add($label); return $label
    }
    function New-SetupButton($Text,$X,$Y,$W,$H,$Action) {
        $button=New-Object Windows.Forms.Button; $button.Text=$Text; $button.SetBounds($X,$Y,$W,$H); $button.FlatStyle='Flat'; $button.FlatAppearance.BorderSize=0
        $button.BackColor=if($Action){[Drawing.Color]::FromArgb(43,119,140)}else{[Drawing.Color]::FromArgb(41,44,47)}
        $button.ForeColor=$form.ForeColor; $form.Controls.Add($button); return $button
    }
    $title=New-SetupLabel 'Ai Transcriber' 28 18 540 47 $accent; $title.Font=New-Object Drawing.Font('Segoe UI',23,[Drawing.FontStyle]::Bold)
    [void](New-SetupLabel ('УСТАНОВКА В REAPER · v'+$script:SetupVersion) 30 67 570 23 $muted)
    [void](New-SetupLabel 'Папка ресурсов REAPER' 28 107 550 24 $form.ForeColor)
    $script:SetupResourceBox=New-Object Windows.Forms.TextBox; $box=$script:SetupResourceBox; $box.SetBounds(28,136,507,27)
    $box.BackColor=[Drawing.Color]::FromArgb(23,25,27); $box.ForeColor=$form.ForeColor
    $box.Text=if($ResourcePath){$ResourcePath}else{Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'REAPER'}; $form.Controls.Add($box)
    $browse=New-SetupButton 'Выбрать…' 545 133 87 32 $false
    $browse.Add_Click({
        $picker=New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description='Выберите папку из REAPER: Options → Show REAPER resource path in explorer/finder'
            $picker.SelectedPath=$script:SetupResourceBox.Text
            if($picker.ShowDialog($script:SetupForm) -eq 'OK'){$script:SetupResourceBox.Text=$picker.SelectedPath}
        }finally{$picker.Dispose()}
    })
    $script:SetupDestinationLabel=New-SetupLabel '' 28 174 604 54 $muted
    $script:SetupDestinationLabel.AutoEllipsis=$true
    $script:SetupDependenciesLabel=New-SetupLabel '' 28 231 404 44 $accent
    $script:SetupImGuiButton=New-SetupButton 'Установить ReaImGui' 443 230 189 32 $false
    $script:SetupImGuiButton.Visible=$false
    $script:SetupProgress=New-Object Windows.Forms.ProgressBar; $script:SetupProgress.SetBounds(28,280,604,18)
    $script:SetupProgress.Minimum=0; $script:SetupProgress.Maximum=100; $script:SetupProgress.Visible=$false; $form.Controls.Add($script:SetupProgress)
    $script:SetupStepsBox=New-Object Windows.Forms.TextBox; $steps=$script:SetupStepsBox; $steps.SetBounds(28,309,604,103)
    $steps.Multiline=$true; $steps.ReadOnly=$true; $steps.BorderStyle='None'; $steps.ScrollBars='Vertical'
    $steps.BackColor=[Drawing.Color]::FromArgb(41,44,47); $steps.ForeColor=$form.ForeColor
    $steps.Text=@('Скрипт будет автоматически добавлен в Actions.','Если REAPER закрыт, установщик предложит открыть его.','После установки: Actions → Show action list → Transcriber → Run.','Модели устанавливаются в настройках скрипта.','Перед обновлением закройте окно Ai Transcriber.') -join [Environment]::NewLine
    $form.Controls.Add($steps)
    $script:SetupRegisterButton=New-SetupButton 'Добавить в Actions' 28 420 604 29 $false
    $script:SetupRegisterButton.Visible=$false
    function Update-SetupDestination {
        try {
            $resource=[IO.Path]::GetFullPath($script:SetupResourceBox.Text.Trim())
            $script:SetupDestinationLabel.Text='Скрипт будет установлен в:'+[Environment]::NewLine+(Get-SetupSafePath $resource 'Scripts/Aiwist/Transcriber')
            $imgui=Get-SetupReaImGuiStatus $resource
            $script:SetupDependenciesLabel.Text=if($imgui.Usable){'ReaImGui найден — повторная загрузка не нужна.'}elseif($imgui.Installed){'ReaImGui требует обновления. Закройте REAPER.'}else{'ReaImGui не найден.'}
            $script:SetupImGuiButton.Text=if($imgui.Installed){'Обновить ReaImGui'}else{'Установить ReaImGui'}
            $script:SetupImGuiButton.Visible=-not $imgui.Usable
            $script:SetupRegisterButton.Visible=($script:SetupInstalledResource -eq $resource -and -not $script:SetupRegistered)
        }catch{
            $script:SetupDestinationLabel.Text='Проверьте путь к ресурсной папке REAPER.'; $script:SetupDependenciesLabel.Text=$_.Exception.Message
            $script:SetupImGuiButton.Visible=$false
        }
    }
    function Set-SetupBusy([bool]$Busy) {
        $script:SetupBusy=$Busy; $script:SetupForm.UseWaitCursor=$Busy
        foreach($control in $script:SetupForm.Controls){
            if($control -is [Windows.Forms.Button] -or $control -is [Windows.Forms.TextBox] -and -not $control.ReadOnly){$control.Enabled=-not $Busy}
        }
        if(-not $Busy){$script:SetupProgress.Visible=$false;Update-SetupDestination}
        $script:SetupForm.Refresh()
    }
    function Show-SetupProgress($Message,$Bytes,$Total) {
        if($Message -like 'Actions:*'){$script:SetupStepsBox.Text=$Message;$script:SetupProgress.Visible=$false}
        else{
            $script:SetupDependenciesLabel.Text=$Message
            $script:SetupProgress.Visible=($Bytes -gt 0 -and $Total -gt 0)
            if($script:SetupProgress.Visible){$script:SetupProgress.Value=[int][Math]::Max(0,[Math]::Min(100,[Math]::Floor(100.0*$Bytes/$Total)))}
        }
        $script:SetupForm.Refresh();[Windows.Forms.Application]::DoEvents()
    }
    function Complete-SetupRegistration {
        $resource=$script:SetupInstalledResource
        $running=@(Get-SetupRunningReapers);$start=$false
        if(-not $running.Count){
            $answer=[Windows.Forms.MessageBox]::Show($script:SetupForm,'Для автоматического добавления скрипта в Actions нужно открыть REAPER. Открыть его сейчас?','Ai Transcriber — Actions','YesNo','Question')
            if($answer -ne 'Yes'){return $null};$start=$true
        }
        $exe=Find-SetupReaperExecutable $resource
        if(-not $exe){
            $picker=New-Object Windows.Forms.OpenFileDialog
            try{
                $picker.Title='Выберите reaper.exe нужного REAPER';$picker.Filter='REAPER (reaper.exe)|reaper.exe';$picker.CheckFileExists=$true
                if($picker.ShowDialog($script:SetupForm) -ne 'OK'){return $null};$exe=$picker.FileName
            }finally{$picker.Dispose()}
        }
        $result=Invoke-SetupReaperRegistration -ResourcePath $resource -Executable $exe -StartIfMissing:$start -OnProgress {param($Message,$Bytes,$Total) Show-SetupProgress $Message $Bytes $Total}
        $script:SetupRegistered=$result.Registered
        return $result
    }
    $box.Add_TextChanged({Update-SetupDestination});Update-SetupDestination
    $script:SetupImGuiButton.Add_Click({
        try{
            $resource=[IO.Path]::GetFullPath($script:SetupResourceBox.Text.Trim())
            if(-not (Test-Path -LiteralPath (Join-Path $resource 'reaper.ini'))){throw 'AIT-500: Выберите ресурсную папку REAPER с reaper.ini.'}
            Set-SetupBusy $true
            $result=Ensure-SetupReaImGui $resource {param($Message,$Bytes,$Total) Show-SetupProgress $Message $Bytes $Total}
            $script:SetupStepsBox.Text=@('ReaImGui установлен. Полностью перезапустите REAPER, если он был открыт.','Чтобы установить Ai Transcriber, нажмите «Установить / обновить».') -join [Environment]::NewLine
        }catch{[void][Windows.Forms.MessageBox]::Show($script:SetupForm,$_.Exception.Message,'ReaImGui','OK','Error')}
        finally{Set-SetupBusy $false}
    })
    $script:SetupRegisterButton.Add_Click({
        try{
            Set-SetupBusy $true;$registered=Complete-SetupRegistration
            if($registered){$script:SetupStepsBox.Text=@('Ai Transcriber добавлен в Actions.','Actions → Show action list → введите Transcriber → Run.','Если ReaImGui был установлен при открытом REAPER, сначала перезапустите REAPER.') -join [Environment]::NewLine}
        }catch{
            $script:SetupStepsBox.Text='Файлы установлены, но добавление в Actions не подтверждено.'+[Environment]::NewLine+$_.Exception.Message
        }finally{Set-SetupBusy $false}
    })
    $script:SetupInstallButton=New-SetupButton 'Установить / обновить' 28 460 408 38 $true
    $script:SetupInstallButton.Add_Click({
        try{
            Set-SetupBusy $true;$script:SetupStepsBox.Text='Проверка комплекта и установка файлов…'
            $resource=[IO.Path]::GetFullPath($script:SetupResourceBox.Text.Trim())
            $result=Install-AiTranscriber $resource -OnProgress {param($Message,$Bytes,$Total) Show-SetupProgress $Message $Bytes $Total}
            $script:SetupInstalledResource=$resource;$script:SetupRegistered=$false
            $registrationError=''
            try{$registered=Complete-SetupRegistration}catch{$registered=$null;$registrationError=$_.Exception.Message}
            $summary=if($registered){@('Ai Transcriber добавлен в Actions.','Actions → Show action list → Transcriber → Run.') -join [Environment]::NewLine}else{@('Файлы установлены. Добавление в Actions пока не подтверждено.','Откройте нужный REAPER и нажмите «Добавить в Actions».') -join [Environment]::NewLine}
            if($registrationError){$summary+=[Environment]::NewLine+$registrationError}
            if($result.ReaImGui.RestartRequired){$summary+=[Environment]::NewLine+'После установки ReaImGui перезапустите REAPER, если он был открыт.'}
            $script:SetupStepsBox.Text=$summary+[Environment]::NewLine+'Далее: установите модели в настройках скрипта.'
            $script:SetupInstallButton.Text=$(if($registered){'Установлено · v'}else{'Файлы установлены · v'})+$script:SetupVersion
        }catch{
            [void][Windows.Forms.MessageBox]::Show($script:SetupForm,$_.Exception.Message,'Не удалось установить','OK','Error')
        }finally{Set-SetupBusy $false}
    })
    $close=New-SetupButton 'Закрыть' 446 460 186 38 $false;$close.Add_Click({$script:SetupForm.Close()})
    $form.Add_FormClosing({param($Sender,$Event) if($script:SetupBusy){$Event.Cancel=$true}})
    try{
        if($PreviewPath){
            $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-32000,-32000)
            $form.Show();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath)}finally{$bitmap.Dispose()}
        }else{[void]$form.ShowDialog()}
    }finally{$form.Dispose()}
}
if (-not $LibraryOnly) {
    try { Show-SetupWindow }
    catch { Write-Host ('Ошибка установщика: '+$_.Exception.Message); exit 1 }
}
