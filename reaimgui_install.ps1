# ReaImGui is downloaded from its author, not bundled or loaded by this installer.
function Get-SetupReaImGuiSpec {
    return [pscustomobject]@{Version='0.10.0.5';Minimum='0.10.0.0';Name='reaper_imgui-x64.dll';Bytes=3665920L
        URL='https://github.com/cfillion/reaimgui/releases/download/v0.10.0.5/reaper_imgui-x64.dll'
        SHA256='800b216e0937bf5bb6b08ba2767b7b974a746b3fc3b54943b4d3011da0a68f2a'}
}
function Get-SetupPeMachine([string]$Path) {
    $stream=$null; $reader=$null
    try {
        $stream=[IO.File]::OpenRead($Path); $reader=[IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {return 0}
        $stream.Position=60; $offset=$reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length-6) {return 0}
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550) {return 0}
        return [int]$reader.ReadUInt16()
    } catch {return 0} finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function Get-SetupReaImGuiStatus([string]$ResourcePath) {
    $spec=Get-SetupReaImGuiSpec
    $canonical=Get-SetupSafePath $ResourcePath ('UserPlugins/'+$spec.Name)
    $generic=Get-SetupSafePath $ResourcePath 'UserPlugins/reaper_imgui.dll'
    Assert-SetupOrdinaryPath $canonical; Assert-SetupOrdinaryPath $generic
    $present=@(@($canonical,$generic) | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
    if ($present.Count -gt 1) {throw 'AIT2-163: В UserPlugins найдены две DLL ReaImGui. Уберите дубликат вручную после закрытия REAPER; установщик не удаляет чужие файлы.'}
    $path=if($present.Count){$present[0]}else{$canonical}
    $version=$null; $machine=0
    if ($present.Count) {
        $text=[string](Get-Item -LiteralPath $path).VersionInfo.FileVersion
        if (-not [version]::TryParse(($text -replace '[^0-9.]',''),[ref]$version)) {$version=[version]'0.0'}
        $machine=Get-SetupPeMachine $path
    }
    return [pscustomobject]@{Path=$path;Installed=($present.Count -gt 0);Version=$version;Machine=$machine
        Usable=($present.Count -gt 0 -and $machine -eq 0x8664 -and $version -ge [version]$spec.Minimum)}
}
function Send-SetupReaImGuiProgress([scriptblock]$OnProgress,[string]$Message,[long]$Bytes=0,[long]$Total=3665920) {
    if($OnProgress){& $OnProgress $Message $Bytes $Total | Out-Null}
}
function Test-SetupReaperRunning {return (@(Get-Process -Name reaper -ErrorAction SilentlyContinue).Count -gt 0)}
function Receive-SetupReaImGui([string]$Destination,[scriptblock]$OnProgress,[ValidateSet('Auto','Windows')][string]$Method='Auto') {
    $spec=Get-SetupReaImGuiSpec
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    if($Method -eq 'Auto' -and (Test-Path -LiteralPath $curl -PathType Leaf)) {
        $process=$null
        try {
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$curl
            # URL is pinned; the generated destination cannot contain a quote.
            $info.Arguments='--fail --location --proto "=https" --proto-redir "=https" --silent --show-error --connect-timeout 15 --max-time 60 --output "'+$Destination+'" "'+$spec.URL+'"'
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($info)
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while(-not $process.HasExited) {
                $bytes=if(Test-Path -LiteralPath $Destination){(Get-Item -LiteralPath $Destination).Length}else{0L}
                Send-SetupReaImGuiProgress $OnProgress 'Скачивание ReaImGui с GitHub…' $bytes
                if($timer.Elapsed.TotalSeconds -gt 65){throw 'Истекло время загрузки ReaImGui через curl.'}
                Start-Sleep -Milliseconds 100
            }
            $process.WaitForExit()
            if($process.ExitCode -eq 0){return}
        } catch {
            Send-SetupReaImGuiProgress $OnProgress 'curl не сработал. Пробую HTTPS Windows…'
        } finally {if($process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}}
    }
    # Independent Windows HTTPS fallback. Certificate checks stay enabled.
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request=[Net.HttpWebRequest]::Create($spec.URL); $request.Timeout=60000; $request.ReadWriteTimeout=10000
    $timer=[Diagnostics.Stopwatch]::StartNew(); $response=$null; $stream=$null; $file=$null
    try {
        $pending=$request.BeginGetResponse($null,$null)
        while(-not $pending.IsCompleted) {
            Send-SetupReaImGuiProgress $OnProgress 'Подключение к GitHub через HTTPS Windows…'
            if($timer.Elapsed.TotalSeconds -gt 60){throw 'Истекло время подключения HTTPS Windows.'}
            Start-Sleep -Milliseconds 100
        }
        $response=$request.EndGetResponse($pending)
        if($response.ResponseUri.Scheme -ne 'https'){throw 'Небезопасное перенаправление загрузки ReaImGui.'}
        $stream=$response.GetResponseStream(); $file=[IO.File]::Create($Destination)
        $buffer=New-Object byte[] 65536; $bytes=0L
        while($true) {
            $pending=$stream.BeginRead($buffer,0,$buffer.Length,$null,$null)
            while(-not $pending.IsCompleted) {
                Send-SetupReaImGuiProgress $OnProgress 'Скачивание ReaImGui через HTTPS Windows…' $bytes
                if($timer.Elapsed.TotalSeconds -gt 60){throw 'Истекло время загрузки ReaImGui через HTTPS Windows.'}
                Start-Sleep -Milliseconds 100
            }
            $n=$stream.EndRead($pending); if($n -eq 0){break}
            $file.Write($buffer,0,$n); $bytes+=$n
            if($bytes -gt $spec.Bytes){throw 'Получен файл ReaImGui неожиданного размера.'}
            Send-SetupReaImGuiProgress $OnProgress 'Скачивание ReaImGui через HTTPS Windows…' $bytes
        }
    } finally {if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};$request.Abort()}
}
function Install-SetupReaImGuiFile([string]$ResourcePath,[string]$Downloaded) {
    $spec=Get-SetupReaImGuiSpec
    if((Get-Item -LiteralPath $Downloaded).Length -ne $spec.Bytes -or
        (Get-FileHash -LiteralPath $Downloaded).Hash.ToLowerInvariant() -cne $spec.SHA256){throw 'AIT2-161: Размер или SHA-256 ReaImGui не совпали. DLL не установлена.'}
    $status=Get-SetupReaImGuiStatus $ResourcePath
    if($status.Usable){return [pscustomobject]@{Status=$status;Changed=$false;RestartRequired=$false;Backup=''}}
    if($status.Installed -and (Test-SetupReaperRunning)){throw 'AIT2-162: Для обновления ReaImGui сохраните проект и полностью закройте REAPER. Затем повторите установку. Рабочий файл не изменён.'}
    $staged=$status.Path+'.candidate-'+[guid]::NewGuid().ToString('N')
    # No DLL suffix: REAPER must never try to load backups as extra extensions.
    $backup=$status.Path+'.backup-'+[guid]::NewGuid().ToString('N')
    $changed=$false
    Assert-SetupOrdinaryPath $status.Path; Assert-SetupOrdinaryPath $staged; Assert-SetupOrdinaryPath $backup
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $status.Path))
        [IO.File]::Copy($Downloaded,$staged,$false)
        if((Get-FileHash -LiteralPath $staged).Hash.ToLowerInvariant() -cne $spec.SHA256){throw 'AIT2-161: Ошибка проверки временной DLL ReaImGui.'}
        if($status.Installed){[IO.File]::Replace($staged,$status.Path,$backup)}else{[IO.File]::Move($staged,$status.Path)}
        $changed=$true
        $after=Get-SetupReaImGuiStatus $ResourcePath
        if(-not $after.Usable){throw 'AIT2-161: Установленный ReaImGui не прошёл проверку версии/архитектуры.'}
        return [pscustomobject]@{Status=$after;Changed=$true;RestartRequired=$true;Backup=$(if($status.Installed){$backup}else{''})}
    } catch {
        $original=$_
        if($changed -and [IO.File]::Exists($backup)) {
            try{[IO.File]::Replace($backup,$status.Path,[NullString]::Value)}
            catch{throw ('AIT2-164: Не удался откат ReaImGui. Предыдущий файл сохранён: '+$backup)}
        }elseif($changed -and -not $status.Installed -and [IO.File]::Exists($status.Path)){[IO.File]::Delete($status.Path)}
        throw $original
    }finally{if([IO.File]::Exists($staged)){[IO.File]::Delete($staged)}}
}
function Ensure-SetupReaImGui([string]$ResourcePath,[scriptblock]$OnProgress) {
    $status=Get-SetupReaImGuiStatus $ResourcePath
    if($status.Usable){
        Send-SetupReaImGuiProgress $OnProgress ('ReaImGui '+$status.Version+' уже установлен — оставляю без изменений.')
        return [pscustomobject]@{Status=$status;Changed=$false;RestartRequired=$false;Backup=''}
    }
    if($status.Installed -and (Test-SetupReaperRunning)){throw 'AIT2-162: ReaImGui требует обновления. Сохраните проект и полностью закройте REAPER, затем повторите установку.'}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('ait2_reaimgui_'+[guid]::NewGuid().ToString('N')+'.download')
    try {
        try{Receive-SetupReaImGui $temporary $OnProgress}
        catch{throw ('AIT2-160: Не удалось скачать ReaImGui. Проверьте сеть и повторите установку. '+$_.Exception.Message)}
        Send-SetupReaImGuiProgress $OnProgress 'Проверка SHA-256 и установка ReaImGui…' 3665920 3665920
        return Install-SetupReaImGuiFile $ResourcePath $temporary
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
