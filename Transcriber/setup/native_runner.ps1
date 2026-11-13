# Sequential native supervision, following Ai YuE2's hidden owned-process runner.
. (Join-Path $PSScriptRoot 'native_process.ps1')
function Invoke-AitNativeProcess([string]$Work,[string]$Root,[string]$Id,$Request,[string]$Mode) {
    $terminal=Join-Path $Work 'exit.json';$recordPath=Join-Path $Work 'runner.json';$out=Join-Path $Work ([string]$Request.output)
    $lock=$null;$child=$null;$ownedJob=$null;$record=$null;$pending=$null;$uncertain=$false;$cancelled=$false
    function Live-Native($Identity) {
        if(-not $Identity.pid -or -not $Identity.started){return $null}
        $candidate=Get-Process -Id ([int]$Identity.pid) -ErrorAction SilentlyContinue
        if($candidate -and $candidate.StartTime.ToUniversalTime().ToString('o') -ceq $Identity.started){return $candidate}
        return $null
    }
    function Native-Ready {return [IO.File]::Exists($out) -and [IO.File]::Exists($out+'.notes.tsv') -and [IO.File]::Exists($out+'.ready')}
    function Start-NativeChild([string]$Executable,[string[]]$Arguments) {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Executable;$info.WorkingDirectory=Split-Path -Parent $Executable
        $info.Arguments=($Arguments | ForEach-Object {Convert-JobArgument $_}) -join ' '
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $info.EnvironmentVariables['TEMP']=$Work;$info.EnvironmentVariables['TMP']=$Work
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        [void]$process.Start()
        try {if(-not $process.HasExited){$ownedJob.Add($process.Handle)}}catch{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000);throw}}
        return @{process=$process;stdout=$process.StandardOutput.ReadLineAsync();stderr=$process.StandardError.ReadLineAsync()}
    }
    function Pump-NativeLogs($Pending,$Writer,$ErrorWriter) {
        foreach($key in @('stdout','stderr')) {
            $task=$Pending[$key]
            if($null -ne $task -and $task.IsCompleted) {
                $line=$task.Result
                if($null -eq $line){$Pending[$key]=$null}else{
                    if($key -eq 'stderr'){$ErrorWriter.WriteLine($line)}else{$Writer.WriteLine($line)}
                    $Pending[$key]=if($key -eq 'stderr'){$Pending.process.StandardError.ReadLineAsync()}else{$Pending.process.StandardOutput.ReadLineAsync()}
                }
            }
        }
    }
    function Stop-NativeOwned {
        if($child -and -not $child.HasExited) {
            if($ownedJob){$ownedJob.Dispose()}else{
                $live=Live-Native $record.child
                if($live){& (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID ([string]$live.Id) /T /F 2>&1 | Out-Null}
            }
            if(-not $child.WaitForExit(15000)){throw 'AITN-450: Не подтверждена остановка движка. Следующее задание заблокировано.'}
        }
    }
    try {
        $record=Read-AitJson $recordPath
        if($Mode -eq 'Check' -and $record -and (Live-Native $record.parent)){return}
        try{$lock=[IO.File]::Open((Join-Path $Work 'runner.lock'),'OpenOrCreate','ReadWrite','None')}catch{return}
        if([IO.File]::Exists($terminal)){return}
        if($Mode -eq 'Run') {
            if($record){throw 'AITN-151: Повторный запуск того же задания запрещён.'}
            $parent=Get-Process -Id $PID
            $record=@{schema=1;id=$Id;engine='native';parent=@{pid=$PID;started=$parent.StartTime.ToUniversalTime().ToString('o')};launched=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
            Write-AitJson $recordPath $record
            if([IO.File]::Exists((Join-Path $Work 'cancel.request'))){throw 'AITN-499: Обработка отменена до запуска.'}
            Test-AitPayload (Split-Path -Parent $PSScriptRoot)
            if(-not [IO.File]::Exists([string]$Request.executable)){throw 'AITN-101: Нативный движок не найден. Повторно распакуйте Native.'}
            $ownedJob=New-EngineJob
            $pending=Start-NativeChild ([string]$Request.executable) @('--config',(Join-Path $Work 'config.json'),'--out',$out)
            $child=$pending.process;$record.child=@{pid=$child.Id;started=$child.StartTime.ToUniversalTime().ToString('o')}
            Write-AitJson $recordPath $record
        } else {
            if(-not $record) {
                $age=([DateTime]::UtcNow-(Get-Item -LiteralPath (Join-Path $Work 'request.json')).CreationTimeUtc).TotalSeconds
                if($age -lt 30){return}
                [IO.File]::WriteAllText((Join-Path $Work 'cancel.request'),'startup timeout')
                throw 'AITN-201: Нативный помощник не запустился за 30 секунд.'
            }
            $child=Live-Native $record.child
            if(-not $child -and -not $record.child) {
                $uncertain=$true
                $name=[IO.Path]::GetFileName([string]$Request.executable)
                if($name -notmatch '^[A-Za-z0-9_.-]+$'){throw 'AITN-100: Invalid engine name.'}
                $found=@(Get-CimInstance Win32_Process -Filter ("Name='"+$name+"'") -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($Work)})
                if($found.Count -gt 1){throw 'AITN-451: Не удалось однозначно определить процесс задания.'}
                if($found.Count -eq 1){$child=Get-Process -Id $found[0].ProcessId -ErrorAction Stop;$record|Add-Member NoteProperty child @{pid=$child.Id;started=$child.StartTime.ToUniversalTime().ToString('o')} -Force;Write-AitJson $recordPath $record}
                $uncertain=$false
            }
            if(-not $child) {
                if(Native-Ready){Write-AitJson $terminal @{schema=1;id=$Id;code=0;message='MIDI сохранён после прерывания помощника.'};return}
                throw 'AITN-452: Предыдущий процесс завершился без MIDI. Можно повторить это задание.'
            }
        }
        $stdout=[IO.StreamWriter]::new((Join-Path $Work 'muscriptor_helper_log.txt'),$true,[Text.UTF8Encoding]::new($false));$stdout.AutoFlush=$true
        $stderr=[IO.StreamWriter]::new((Join-Path $Work 'muscriptor_helper_log.txt.err'),$true,[Text.UTF8Encoding]::new($false));$stderr.AutoFlush=$true
        try {
            while(-not $child.HasExited -or $pending -and ($null -ne $pending.stdout -or $null -ne $pending.stderr)) {
                if($pending){Pump-NativeLogs $pending $stdout $stderr}
                $elapsed=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$record.launched
                $progress=Read-AitJson (Join-Path $Work 'native_progress.json')
                $message=if($progress.id -ceq $Id){[string]$progress.message}else{'Подключение нативного движка…'}
                $status=@{schema=1;id=$Id;updated=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();message=$message;pid=$child.Id;engine='native'}
                if($progress.id -ceq $Id){
                    $status.phase=[string]$progress.phase
                    if($null -ne $progress.fraction){$status.fraction=$progress.fraction}
                }
                Write-AitJson (Join-Path $Work 'process.json') $status
                if([IO.File]::Exists((Join-Path $Work 'cancel.request'))){$cancelled=$true;Stop-NativeOwned;break}
                if($elapsed -ge 1500){Stop-NativeOwned;throw 'AITN-453: Обработка превысила 25 минут и остановлена.'}
                if(-not $child.HasExited){[void]$child.WaitForExit(100)}else{Start-Sleep -Milliseconds 10}
            }
        } finally {$stdout.Dispose();$stderr.Dispose()}
        $child.WaitForExit()
        if($cancelled){throw 'AITN-499: Обработка отменена. Готовые файлы сохранены.'}
        if($child.ExitCode -ne 0 -or -not (Native-Ready)) {
            $detail='';$errorLog=Join-Path $Work 'muscriptor_helper_log.txt.err'
            if([IO.File]::Exists($errorLog)){$detail=[IO.File]::ReadAllText($errorLog);if($detail.Length -gt 2000){$detail=$detail.Substring($detail.Length-2000)}}
            throw ('AITN-430: Нативный движок не создал MIDI. '+$detail)
        }
        if([IO.File]::Exists((Join-Path $Work 'cancel.request'))){throw 'AITN-499: Обработка отменена.'}
        Write-AitJson $terminal @{schema=1;id=$Id;code=0;message='Готово';engine='native'}
    } catch {
        $detail=Protect-AitMessage $_.Exception.Message
        if($uncertain -or $child -and -not $child.HasExited) {
            Write-AitJson (Join-Path $Work 'process.json') @{schema=1;id=$Id;updated=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();message=$detail;blocked=$true}
        } else {Write-AitJson $terminal @{schema=1;id=$Id;code=1;message=$detail;engine='native'}}
    } finally {
        if($ownedJob){$ownedJob.Dispose()}
        if($child){$child.Dispose()}
        if($lock){$lock.Dispose()}
    }
}
