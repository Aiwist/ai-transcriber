function Format-AiBytes([double]$Bytes) {
    if ($Bytes -lt 0) { return '—' }
    foreach ($unit in @(@(1GB,'GiB'),@(1MB,'MiB'),@(1KB,'KiB'))) {
        if ($Bytes -ge $unit[0]) { return ('{0:N1} {1}' -f ($Bytes / $unit[0]),$unit[1]) }
    }
    return ('{0:N0} B' -f $Bytes)
}


function New-AiProgressState([string]$Label, [string]$LogPath) {
    return @{
        Label = $Label; BaseLabel = $Label; Stage = ''; Packages = [ordered]@{}; UvPrepared = $false; UvTelemetry = $false
        IsEngine = ($Label -eq '__AIT2_ENGINE__'); LogPath = $LogPath; Timer = [Diagnostics.Stopwatch]::StartNew()
        Bytes = -1L; Total = -1L; Rate = -1.0; LastChange = 0.0; LastSample = 0.0
        LastRender = -10.0; LastLog = -20.0; ElapsedOffset = 0.0; Phase = 'работает'; IdleLabel = 'без новых сообщений'
    }
}


function Update-AiProgressBytes([hashtable]$State, [long]$Bytes, [long]$Total = -1) {
    $now = $State.Timer.Elapsed.TotalSeconds
    if ($Bytes -ne $State.Bytes) {
        $State.Rate = if ($State.Bytes -ge 0 -and $Bytes -ge $State.Bytes -and $now -gt $State.LastSample) {
            ($Bytes - $State.Bytes) / ($now - $State.LastSample)
        } else { 0.0 }
        $State.LastChange = $now
        $State.LastSample = $now
    }
    if (($now - $State.LastChange) -ge 5) { $State.Rate = 0.0 }
    $State.Bytes = $Bytes
    # BITS uses UInt64.MaxValue for an unknown file size.
    $State.Total = if ($Total -gt 0 -and $Total -lt [long]::MaxValue) { $Total } else { -1L }
    $State.IdleLabel = 'без новых данных'
}


function Get-AiProgressText([hashtable]$State) {
    # UV and verification processes do not expose byte counters. Their normal
    # stage messages remain visible; do not add a technical status row for them.
    if ($State.Bytes -lt 0) { return '' }
    $label = [regex]::Replace([string]$State.Label,'[\x00-\x1f]',' ')
    if ($label.Length -gt 24) { $label = $label.Substring(0,23) + '…' }
    $barWidth = 24
    if ($State.Total -gt 0) {
        $ratio = [Math]::Max(0.0,[Math]::Min(1.0,[double]$State.Bytes / $State.Total))
        $filled = [int][Math]::Floor($ratio * $barWidth)
        $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))
        $percent = [int][Math]::Floor($ratio * 100)
        return '{0} [{1}] {2,3}%  ({3} / {4})' -f $label,$bar,$percent,(Format-AiBytes $State.Bytes),(Format-AiBytes $State.Total)
    }
    if ($State.Phase -eq 'проверка файла / ожидание ответа') { return "${label}: подготовка загрузки…" }
    # An unknown size is activity, not a determinate percentage. Animate a short
    # block, without pretending that it measures the portion downloaded.
    $position = ([int][Math]::Floor($State.Timer.Elapsed.TotalSeconds)) % ($barWidth - 2)
    $bar = ('░' * $position) + '███' + ('░' * ($barWidth - $position - 3))
    return '{0} [{1}]  {2}' -f $label,$bar,(Format-AiBytes $State.Bytes)
}


function Get-AiProgressLogText([hashtable]$State) {
    $now = $State.Timer.Elapsed.TotalSeconds
    $quiet = [int][Math]::Max(0,[Math]::Floor($now - $State.LastChange))
    return '{0}; received={1}; total={2}; rate={3}/s; elapsed={4:N0}s; counter_idle={5}s; state={6}' -f $State.Label,(Format-AiBytes $State.Bytes),(Format-AiBytes $State.Total),(Format-AiBytes $State.Rate),$now,$quiet,$State.Phase
}


function Clear-AiProgressLine {
    if ($script:AiProgressWidth -gt 0) {
        Write-Host ("`r" + (' ' * $script:AiProgressWidth) + "`r") -NoNewline
        $script:AiProgressWidth = 0
    }
}


function Show-AiProgress([hashtable]$State, [switch]$Force) {
    # The child engine publishes its own stages. Do not overwrite them in its parent.
    if ($State.IsEngine) { return }
    Assert-AitNotCancelled
    $now = $State.Timer.Elapsed.TotalSeconds
    if (-not $Force -and ($now - $State.LastRender) -lt 2) { return }
    $State.LastRender = $now
    if ($State.UvTelemetry -and ($now - $State.LastChange) -ge 5) { $State.Rate=0.0 }
    Write-AitEvent $State.Stage $State.Label $State.Bytes $State.Total $State.Rate
    $text = Get-AiProgressText $State
    # Do not wrap a live status over multiple rows in a narrow console.
    $width = 160
    try { if ([Console]::BufferWidth -gt 20) { $width = [Console]::BufferWidth - 1 } } catch {}
    if ($text) {
        $visible = if ($text.Length -gt $width) { $text.Substring(0,$width - 1) + '…' } else { $text }
        $padding = [Math]::Max(0,[int]$script:AiProgressWidth - $visible.Length)
        $color = if ($State.Phase -eq 'ошибка') { [ConsoleColor]::Red } else { [ConsoleColor]::Cyan }
        Write-Host ("`r" + $visible + (' ' * $padding)) -NoNewline -ForegroundColor $color
        $script:AiProgressWidth = $visible.Length
    }
    if ($State.LogPath -and ($Force -or ($now - $State.LastLog) -ge 15)) {
        Add-Content -LiteralPath $State.LogPath -Value ('[progress] ' + (Get-AiProgressLogText $State)) -Encoding UTF8 -ErrorAction SilentlyContinue
        $State.LastLog = $now
    }
}


function Show-AiFileProgress([string]$Label, [long]$Bytes, [long]$Total, [int]$ElapsedSeconds, [string]$LogPath) {
    if (-not $script:AiFileProgress -or $script:AiFileProgress.Label -ne $Label -or $ElapsedSeconds -lt $script:AiFileElapsed) {
        Clear-AiProgressLine
        $script:AiFileProgress = New-AiProgressState $Label $LogPath
    }
    $script:AiFileElapsed = $ElapsedSeconds
    Update-AiProgressBytes $script:AiFileProgress $Bytes $Total
    $script:AiFileProgress.Phase = 'загрузка'
    Show-AiProgress $script:AiFileProgress
}


function Complete-AiFileProgress([string]$Destination, [string]$LogPath) {
    $length = (Get-Item -LiteralPath $Destination).Length
    if (-not $script:AiFileProgress) { $script:AiFileProgress = New-AiProgressState ([IO.Path]::GetFileName($Destination)) $LogPath }
    Update-AiProgressBytes $script:AiFileProgress $length $length
    $script:AiFileProgress.Phase = 'готово'
    Show-AiProgress $script:AiFileProgress -Force
    Write-Host
    $script:AiProgressWidth = 0
    $script:AiFileProgress.Timer.Stop()
    $script:AiFileProgress = $null
}


function ConvertTo-AiProcessArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    # Windows CRT quoting; spaces, embedded quotes and trailing backslashes.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}


function Get-AiCurlTotal([string]$HeaderPath) {
    if (-not $HeaderPath -or -not (Test-Path -LiteralPath $HeaderPath)) { return -1L }
    try {
        $blocks = [regex]::Split([IO.File]::ReadAllText($HeaderPath),'(?m)(?=^HTTP/)')
        $last = $blocks[-1]
        if ($last -match '^HTTP/\S+\s+2\d\d' -and $last -match '(?im)^Content-Length:\s*(\d+)') {
            return [long]$Matches[1]
        }
    } catch {}
    return -1L
}


function Invoke-AiLiveProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$LogPath,
          [string]$Label, [string]$MonitorFile, [string]$HeaderPath, [int]$TimeoutSeconds = 0,
          [switch]$TrackPackageDownloads)
    Assert-AitNotCancelled
    if (-not $Label) { $Label = [IO.Path]::GetFileName($FilePath) }
    $state = New-AiProgressState $Label $LogPath
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-AiProcessArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.EnvironmentVariables.Remove('VIRTUAL_ENV')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $streams = @(
            @{Reader=$process.StandardOutput; Task=$process.StandardOutput.ReadLineAsync(); Done=$false},
            @{Reader=$process.StandardError; Task=$process.StandardError.ReadLineAsync(); Done=$false}
        )
        while (-not $process.HasExited -or @($streams | Where-Object { -not $_.Done }).Count -gt 0) {
            foreach ($stream in $streams) {
                # Read stdout and stderr independently; a silent child must not
                # block heartbeat rendering, and a full stderr pipe must drain.
                $drained = 0
                while (-not $stream.Done -and $stream.Task.IsCompleted -and $drained -lt 100) {
                    $line = $stream.Task.GetAwaiter().GetResult()
                    $drained++
                    if ($null -eq $line) { $stream.Done = $true; break }
                    if ($line.StartsWith('@AIT_PROGRESS ')) {
                        try {
                            $data = $line.Substring(14) | ConvertFrom-Json -ErrorAction Stop
                            if ($data.label) { $state.Label = [string]$data.label }
                            $state.Bytes = [long]$data.bytes
                            $state.Total = if ($null -ne $data.total) { [long]$data.total } else { -1L }
                            $state.Rate = [double]$data.rate
                            if ($null -ne $data.elapsed) { $state.ElapsedOffset = $state.Timer.Elapsed.TotalSeconds - [double]$data.elapsed }
                            $state.LastChange = $state.Timer.Elapsed.TotalSeconds - [double]$data.idle
                            $state.IdleLabel = 'без новых данных'
                            $state.Phase = switch ([string]$data.phase) {
                                'ready' {'готово'} 'checking' {'проверка файла / ожидание ответа'} default {'загрузка'}
                            }
                        } catch { $state.Phase = 'работает' }
                    } elseif ($line) {
                        Clear-AiProgressLine
                        # Never include a supplied HF token in console or logs.
                        if ($env:HF_TOKEN -and $env:HF_TOKEN.Length -gt 8) { $line = $line.Replace($env:HF_TOKEN,'[TOKEN REDACTED]') }
                        if (Get-Command Protect-AitMessage -ErrorAction SilentlyContinue) {$line=Protect-AitMessage $line}
                        Write-Host $line
                        if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
                        if (-not $MonitorFile -and $state.Bytes -lt 0) {
                            $state.LastChange = $state.Timer.Elapsed.TotalSeconds
                            $state.Phase = 'работает'
                        }
                    }
                    $stream.Task = $stream.Reader.ReadLineAsync()
                }
            }
            if ($MonitorFile) {
                $bytes = if (Test-Path -LiteralPath $MonitorFile -PathType Leaf) { (Get-Item -LiteralPath $MonitorFile).Length } else { 0L }
                Update-AiProgressBytes $state $bytes (Get-AiCurlTotal $HeaderPath)
                $state.Phase = 'загрузка'
            }
            Show-AiProgress $state
            if ($TimeoutSeconds -gt 0 -and $state.Timer.Elapsed.TotalSeconds -gt $TimeoutSeconds -and -not $process.HasExited) {
                $process.Kill()
                throw "Process exceeded the $TimeoutSeconds-second limit: $Label"
            }
            Start-Sleep -Milliseconds 100
        }
        $process.WaitForExit()
        if ($process.ExitCode -eq 0) {
            if ($MonitorFile -and (Test-Path -LiteralPath $MonitorFile)) {
                $bytes = (Get-Item -LiteralPath $MonitorFile).Length
                Update-AiProgressBytes $state $bytes $bytes
            }
            $state.Phase = 'готово'
            if ($state.Stage -like 'packages_*') {
                $state.Label = $state.BaseLabel + ' — готово'
                $state.Stage = 'packages_ready'
            }
        } else {
            $state.Phase = 'ошибка'
            if ($state.Stage -like 'packages_*') {
                $state.Label = 'Ошибка: ' + $state.BaseLabel + '. Подробности — в журнале.'
                $state.Stage = 'packages_error'
            }
        }
        Show-AiProgress $state -Force
        if ($script:AiProgressWidth -gt 0) { Write-Host }
        $script:AiProgressWidth = 0
        return [int]$process.ExitCode
    } finally {
        Clear-AiProgressLine
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
        $state.Timer.Stop()
    }
}
