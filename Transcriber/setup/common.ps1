function Write-AitJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary,$Path,($Path+'.bak'),$true) }
        else { [IO.File]::Move($temporary,$Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-AitJson([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $stream=$null;$reader=$null
    try {
        $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
        if($stream.Length -gt 1048576){throw 'AIT2-100: oversized state file.'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
        return ($reader.ReadToEnd() | ConvertFrom-Json)
    } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function Protect-AitMessage([string]$Text) {
    if ($env:HF_TOKEN) { $Text=$Text.Replace($env:HF_TOKEN,'[TOKEN REDACTED]') }
    $Text=[regex]::Replace($Text, '(?i)hf_[A-Za-z0-9_]{4,}', '[TOKEN REDACTED]')
    $Text=[regex]::Replace($Text, '(?i)(Bearer\s+)[^\s"<>]+', '$1[REDACTED]')
    return [regex]::Replace($Text, '(https?://[^\s?"<>]+)\?[^\s"<>]+', '$1?[QUERY REDACTED]')
}

function Assert-AitNotCancelled {
    if ($env:AIT2_CANCEL -and (Test-Path -LiteralPath $env:AIT2_CANCEL)) { throw 'AIT2-CANCELLED' }
}

function Write-AitEvent([string]$Stage, [string]$Message, [long]$Bytes = -1, [long]$Total = -1, [double]$Rate = 0) {
    Assert-AitNotCancelled
    if (-not $env:AIT2_STATUS) { return }
    if ($Stage) { $script:AitStage = $Stage }
    if ($Message) { $script:AitMessage = Protect-AitMessage $Message }
    Write-AitJson $env:AIT2_STATUS @{
        schema=1; job_id=$env:AIT2_JOB_ID; state='running'; stage=$script:AitStage
        message=$script:AitMessage; bytes=$Bytes; total=$Total; rate=$Rate; pid=$PID
        updated=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Assert-AitOrdinaryPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            $exists=Test-Path -LiteralPath $current -ErrorAction Stop
            $attributes=if($exists){(Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes}else{$null}
        } catch {
            throw [IO.IOException]::new(('AIT2-111: Не удалось проверить путь: '+$current+'. '+$_.Exception.Message),$_.Exception)
        }
        if ($exists -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "AIT2-110: Выберите обычную папку без junction/символических ссылок: $current"
        }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Test-AitPayload([string]$Root) {
    $manifest=Read-AitJson (Join-Path $Root 'manifest.json')
    if (-not $manifest -or $manifest.version -ne '1.0.2' -or -not $manifest.files) { throw 'AIT2-120: Нет корректного манифеста. Переустановите Ai Transcriber через ReaPack или распакуйте полный установочный архив.' }
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $path=[IO.Path]::GetFullPath((Join-Path $Root $entry.Name))
        if (-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'AIT2-120: Invalid manifest path.' }
        Assert-AitOrdinaryPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.Value) {
            throw ('AIT2-120: Повреждён или изменён файл: '+$entry.Name)
        }
    }
}
