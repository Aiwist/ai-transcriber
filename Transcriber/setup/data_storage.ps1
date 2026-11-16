# Copy before switching profiles. Never remove source data or overwrite a differing file.
function Assert-AitStorageIdle([string]$State,[string]$OwnJob,[string]$Instance){
    foreach($folder in @(Get-ChildItem -LiteralPath (Join-Path $State 'runtime_temp') -Directory -ErrorAction SilentlyContinue)){
        if([IO.File]::Exists((Join-Path $folder.FullName 'exit.json'))){continue}
        foreach($name in @('runner.json','tonal_runner.json')){
            $record=Read-AitJson (Join-Path $folder.FullName $name)
            if(-not $record){continue}
            foreach($identity in @($record.parent,$record.child,$record)){
                if(-not $identity.pid -or -not $identity.started){continue}
                $p=Get-Process -Id ([int]$identity.pid) -ErrorAction SilentlyContinue
                if($p -and ($p.StartTime.ToUniversalTime().ToString('o') -eq $identity.started -or
                    ($name -eq 'tonal_runner.json' -and [math]::Abs(($p.StartTime.ToUniversalTime()-[datetime]$identity.started).TotalSeconds) -lt 60))){
                    throw 'AITN-712: Фоновая обработка ещё работает. Дождитесь её завершения.'
                }
            }
        }
        $request=Join-Path $folder.FullName 'request.json'
        if([IO.File]::Exists($request) -and -not [IO.File]::Exists((Join-Path $folder.FullName 'runner.json')) -and
            ((Get-Date)-(Get-Item -LiteralPath $request).CreationTime).TotalSeconds -lt 120){throw 'AITN-712: Дождитесь запуска обработки.'}
    }
    foreach($session in @(Get-ChildItem -LiteralPath (Join-Path $State 'runtime_temp') -Filter session.json -Recurse -ErrorAction SilentlyContinue)){
        $s=Read-AitJson $session.FullName
        if($s -and -not $s.closed -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$s.updated) -lt 120){
            if($s.busy -or [string]$s.id -ine $Instance){throw 'AITN-712: Завершите обработку и закройте другие окна Ai Transcriber.'}
        }
    }
    foreach($folder in @(Get-ChildItem -LiteralPath (Join-Path $State 'jobs') -Directory -ErrorAction SilentlyContinue)){
        if($folder.Name -ieq $OwnJob -or [IO.File]::Exists((Join-Path $folder.FullName 'result.json'))){continue}
        $worker=Read-AitJson (Join-Path $folder.FullName 'worker.json')
        if($worker){
            $p=Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue
            if($p -and $p.StartTime.ToUniversalTime().ToString('o') -eq $worker.started){throw 'AITN-712: Дождитесь завершения помощника или загрузки моделей.'}
        }elseif(((Get-Date)-$folder.CreationTime).TotalSeconds -lt 120){throw 'AITN-712: Дождитесь запуска другого задания.'}
    }
}
function Get-AitStorageFiles([string]$Root,[string]$Prefix=''){
    foreach($entry in Get-ChildItem -LiteralPath $Root -Force){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('AITN-713: Папка содержит ссылку: '+$entry.FullName)}
        $relative=if($Prefix){$Prefix+'\'+$entry.Name}else{$entry.Name}
        if($entry.PSIsContainer){Get-AitStorageFiles $entry.FullName $relative}else{[pscustomobject]@{file=$entry;relative=$relative}}
    }
}
function Convert-AitMovedValue($Value,$Mappings){
    if($null -eq $Value){return $null}
    if($Value -is [string]){
        foreach($mapping in $Mappings){$tail=Get-AitRelativePath $Value $mapping.source;if($null -ne $tail){return Join-AitStoredPath $mapping.target $tail}}
        return $Value
    }
    if($Value -is [array]){return ,@(foreach($entry in $Value){Convert-AitMovedValue $entry $Mappings})}
    if($Value -is [Collections.IDictionary]){$copy=@{};foreach($k in $Value.Keys){$copy[$k]=Convert-AitMovedValue $Value[$k] $Mappings};return $copy}
    if($Value -is [pscustomobject]){$copy=@{};foreach($p in $Value.PSObject.Properties){$copy[$p.Name]=Convert-AitMovedValue $p.Value $Mappings};return [pscustomobject]$copy}
    return $Value
}
function Invoke-AitStorageMigration($Job,[string]$State,[string]$Directory,[string]$Id){
    $lock=$null;$destinationLock=$null
    try{
        if($Job.schema -ne 1 -or $Job.id -cne $Id -or $Job.storage_mode -notin @('system','portable','custom')){throw 'AITN-710: Invalid storage request.'}
        $source=[IO.Path]::GetFullPath($State).TrimEnd('\')
        $target=[IO.Path]::GetFullPath([string]$Job.target_root).TrimEnd('\')
        $resource=[IO.Path]::GetFullPath([string]$Job.resource_root).TrimEnd('\')
        if($target -notmatch '^[A-Za-z]:\\.+' -or $target -ieq $resource -or
            $null -ne (Get-AitRelativePath $target $source) -or $null -ne (Get-AitRelativePath $source $target)){
            throw 'AITN-710: Выберите отдельную папку, не вложенную в прежнюю папку данных.'
        }
        foreach($p in @($source,$target)){Assert-AitOrdinaryPath $p}
        Write-AitEvent 'storage_scan' 'Проверяю папки и незавершённые задания…'
        $lock=[IO.File]::Open((Join-Path $source 'storage_migration.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Assert-AitStorageIdle $source $Id ([string]$Job.runtime_instance)
        [void][IO.Directory]::CreateDirectory($target)
        $destinationLock=[IO.File]::Open((Join-Path $target 'storage_migration.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Assert-AitStorageIdle $target $Id ''
        Write-AitJson (Join-Path $Directory 'worker.json') @{pid=$PID;started=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');job_id=$Id}
        if($Job.reuse_existing -eq $true){
            $context=Read-AitJson (Join-Path $target '.storage_context.json')
            if(-not $context -or $context.schema -ne 1){throw 'AITN-710: В папке нет корректных данных Ai Transcriber.'}
            Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;action=$Job.action;ok=$true;storage_target=$target;storage_mode=$Job.storage_mode;files=0;message='Выбрана существующая папка данных. Закройте и снова откройте Ai Transcriber.'}
            return
        }
        $mappings=@(@{source=$source;target=$target;state=$true})
        # GGUF / ONNX model folders remain independently selectable. Bring the local
        # Transkun environment into the data folder even if an older version put it with models.
        $native=Read-AitJson (Join-Path $source 'native_active.json')
        if($native.transkun.runtime -and $null -eq (Get-AitRelativePath ([string]$native.transkun.runtime) $source)){
            $runtime=[IO.Path]::GetFullPath([string]$native.transkun.runtime).TrimEnd('\')
            if([IO.Path]::GetFileName($runtime) -ne 'transkun-1.0.0'){throw 'AITN-713: Неизвестная папка окружения Transkun.'}
            Assert-AitOrdinaryPath $runtime
            $mappings=@(@{source=$runtime;target=(Join-Path $target 'runtimes\transkun-1.0.0');state=$false})+$mappings
        }
        $files=@(foreach($mapping in $mappings){
            foreach($entry in Get-AitStorageFiles $mapping.source){
                $rel=$entry.relative
                if($mapping.state -and ($rel -match '(^|\\)([^\\]+\.lock|\.storage_context\.json(\.bak)?|active_job\.json(\.bak)?|running_job\.json(\.bak)?)$' -or
                    $rel.StartsWith('jobs\'+$Id+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    ($Job.runtime_instance -and $rel.StartsWith('runtime_temp\'+$Job.runtime_instance+'\',[StringComparison]::OrdinalIgnoreCase)))){continue}
                [pscustomobject]@{source=$entry.file.FullName;target=(Join-Path $mapping.target $rel);bytes=$entry.file.Length;state=$mapping.state}
            }
        })
        $total=[long](($files|Measure-Object bytes -Sum).Sum);$done=0L
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))
        if($drive.AvailableFreeSpace -lt $total+10485760){throw 'AITN-714: Недостаточно свободного места для копирования данных.'}
        $targetContext=@{root=$target;resource=$resource;mode=[string]$Job.storage_mode}
        foreach($entry in $files){
            Assert-AitNotCancelled
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($entry.target))
            Assert-AitOrdinaryPath $entry.target
            $temporary=$entry.target+'.'+$Id+'.part'
            $inputStream=$null;$outputStream=$null
            try{
                $inputStream=[IO.File]::Open($entry.source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $outputStream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] 1048576
                while(($n=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
                    Assert-AitNotCancelled;$outputStream.Write($buffer,0,$n);$done+=$n
                    Write-AitEvent 'storage_copy' ('Копирование данных: '+[IO.Path]::GetFileName($entry.source)) $done $total
                }
                $outputStream.Dispose();$outputStream=$null;$inputStream.Dispose();$inputStream=$null
                if((Get-FileHash -LiteralPath $entry.source -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash){throw 'AITN-715: Копия файла не прошла проверку.'}
                if($entry.state -and $entry.source -match '\.json(\.bak)?$' -and $entry.bytes -le 8388608){
                    # Read through the source codec, rebase in-memory paths, then store
                    # relative paths for the destination. Engine config stays absolute.
                    $value=[IO.File]::ReadAllText($entry.source)|ConvertFrom-Json
                    $value=Convert-AitStorageJson $entry.source $value $false
                    $value=Convert-AitMovedValue $value $mappings
                    if([IO.Path]::GetFileName($entry.target) -notin @('config.json','config.json.bak')){$value=Convert-AitStorageValue $value $targetContext $true}
                    [IO.File]::WriteAllText($temporary,($value|ConvertTo-Json -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
                }
                if([IO.File]::Exists($entry.target)){
                    if((Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash){throw ('AITN-716: В новой папке уже есть другой файл: '+$entry.target)}
                }else{[IO.File]::Move($temporary,$entry.target)}
            }finally{
                if($inputStream){$inputStream.Dispose()};if($outputStream){$outputStream.Dispose()}
                # Only the temporary file created by this operation is eligible for cleanup.
                if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
            }
        }
        Assert-AitNotCancelled
        Assert-AitStorageIdle $source $Id ([string]$Job.runtime_instance)
        Write-AitJson (Join-Path $target '.storage_context.json') @{schema=1;mode=[string]$Job.storage_mode;data_root=$target;resource_root=$resource}
        Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;action=$Job.action;ok=$true;storage_target=$target;storage_mode=$Job.storage_mode;files=$files.Count;message='Данные скопированы и проверены. Закройте и снова откройте Ai Transcriber.'}
    }catch{
        Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;action=$Job.action;ok=$false;message='Папка данных не изменена.';error=@{code='AITN-710';title='Не удалось сменить папку данных';detail=$_.Exception.Message;help=@('Исходные данные сохранены. Завершите другие задания и выберите пустую папку с достаточным свободным местом.')}}
    }finally{if($destinationLock){$destinationLock.Dispose()};if($lock){$lock.Dispose()}}
}
