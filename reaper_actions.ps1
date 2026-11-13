# Registration uses REAPER's API, not edits to reaper-kb.ini.
function Get-SetupRunningReapers {
    return @(Get-Process -Name reaper -ErrorAction SilentlyContinue | ForEach-Object {
        $path=$null;try{$path=$_.Path}catch{}
        [pscustomobject]@{Id=$_.Id;Path=$path}
    })
}
function Find-SetupReaperExecutable([string]$ResourcePath) {
    $portable=Join-Path $ResourcePath 'reaper.exe'
    if(Test-Path -LiteralPath $portable -PathType Leaf){return $portable}
    $running=@(Get-SetupRunningReapers)
    if($running.Count -eq 1 -and $running[0].Path){return [string]$running[0].Path}
    if($running.Count -gt 1){return $null}
    $candidates=@()
    foreach($reg in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\reaper.exe','HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\reaper.exe')){
        try{$candidates+=(Get-Item -LiteralPath $reg -ErrorAction Stop).GetValue('')}catch{}
    }
    if($env:ProgramFiles){$candidates+=Join-Path $env:ProgramFiles 'REAPER (x64)\reaper.exe';$candidates+=Join-Path $env:ProgramFiles 'REAPER\reaper.exe'}
    foreach($path in $candidates){if($path -and (Test-Path -LiteralPath $path -PathType Leaf)){return $path}}
    return $null
}
function Start-SetupReaperRegistration([string]$Executable,[string[]]$Arguments) {
    # REAPER is the interactive target, not a background helper: keep it visible.
    $null=Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Normal -PassThru
}
function Invoke-SetupReaperRegistration {
    param([string]$ResourcePath,[string]$Executable,[switch]$StartIfMissing,[int]$TimeoutSeconds=45,[scriptblock]$OnProgress)
    $resource=[IO.Path]::GetFullPath($ResourcePath).TrimEnd('\')
    $scripts=Get-SetupSafePath $resource 'Scripts/Aiwist/Transcriber'
    $helper=Get-SetupSafePath $scripts 'Register_Ai_Transcriber.lua'
    $target=Get-SetupSafePath $scripts 'Aiwist_Transcriber.lua'
    foreach($path in @($helper,$target)){Assert-SetupOrdinaryPath $path;if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'AIT2-170: Сначала установите файлы Ai Transcriber.'}}
    if($resource -match '[\r\n]' -or -not (Test-Path -LiteralPath (Join-Path $resource 'reaper.ini') -PathType Leaf)){throw 'AIT2-170: Неверная папка ресурсов REAPER.'}
    if(-not $Executable){$Executable=Find-SetupReaperExecutable $resource}
    if(-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf) -or [IO.Path]::GetFileName($Executable) -ine 'reaper.exe'){
        throw 'AIT2-171: Не найден reaper.exe. Укажите исполняемый файл нужного REAPER, затем повторите добавление в Actions.'
    }
    $running=@(Get-SetupRunningReapers)
    if($running.Count -gt 1){throw 'AIT2-174: Открыто несколько REAPER. Оставьте один нужный экземпляр и повторите добавление в Actions.'}
    if($running.Count -eq 1 -and (-not $running[0].Path -or [IO.Path]::GetFullPath($running[0].Path) -ine [IO.Path]::GetFullPath($Executable))){
        throw 'AIT2-174: Запущен другой REAPER. Откройте нужный экземпляр и повторите добавление в Actions.'
    }
    if(-not $running.Count -and -not $StartIfMissing){throw 'AIT2-172: REAPER не запущен. Откройте его или разрешите запуск для добавления в Actions.'}
    $diagnostics=Get-SetupSafePath $scripts 'setup/registration';Assert-SetupOrdinaryPath $diagnostics
    [void][IO.Directory]::CreateDirectory($diagnostics)
    $request=Get-SetupSafePath $scripts 'reaper_registration.request';Assert-SetupOrdinaryPath $request
    $lockPath=Get-SetupSafePath $diagnostics 'registration.lock';Assert-SetupOrdinaryPath $lockPath
    $lock=$null;$id=[guid]::NewGuid().ToString('N')
    $result=Get-SetupSafePath $diagnostics ('reaper_registration_'+$id+'.txt')
    try{
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'AIT2-175: Другая регистрация уже выполняется. Дождитесь её окончания.'}
        [IO.File]::WriteAllText($request,"resource=$resource`r`nrequest_id=$id`r`n",[Text.UTF8Encoding]::new($false))
        $current=@(Get-SetupRunningReapers)
        if($running.Count -and ($current.Count -ne 1 -or $current[0].Id -ne $running[0].Id)){throw 'AIT2-174: Состояние REAPER изменилось. Повторите регистрацию.'}
        if(-not $running.Count -and $current.Count){throw 'AIT2-174: REAPER уже открылся. Повторите регистрацию в этом экземпляре.'}
        $arguments=if($running.Count){@('-nonewinst',('"'+$helper+'"'))}else{@('-newinst','-nosplash','-cfgfile',('"'+(Join-Path $resource 'reaper.ini')+'"'),('"'+$helper+'"'))}
        Start-SetupReaperRegistration $Executable $arguments
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while([DateTime]::UtcNow -lt $deadline){
            if($OnProgress){& $OnProgress 'Actions: ожидаю подтверждение REAPER…' -1 -1 | Out-Null}
            if(Test-Path -LiteralPath $result -PathType Leaf){
                $text=[IO.File]::ReadAllText($result)
                if($text -match "(?m)^request_id=$id\r?$"){
                    if($text -match '(?m)^status=ok\r?$' -and $text -match '(?m)^command_id=[1-9][0-9]*\r?$'){
                        return [pscustomobject]@{Registered=$true;Report=$result;Script=$target}
                    }
                    if($text -match '(?m)^status=error\r?$'){throw ('AIT2-173: '+(($text -split '\r?\n' | Where-Object {$_ -like 'error=*'}) -join ' '))}
                }
            }
            Start-Sleep -Milliseconds 100
        }
        throw ('AIT2-173: REAPER не подтвердил добавление в Actions. Закройте диалоги REAPER и нажмите «Добавить в Actions» ещё раз. Отчёт: '+$result)
    }finally{
        if($lock){
            # Delete only our own request. Never remove a concurrently replaced one.
            try{if((Test-Path -LiteralPath $request) -and [IO.File]::ReadAllText($request).Contains('request_id='+$id)){[IO.File]::Delete($request)}}
            finally{$lock.Dispose()}
        }
    }
}
