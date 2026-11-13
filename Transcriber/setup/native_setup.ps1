# Native GGUF setup. No HF account/token and no Python installation for MuScriptor.
function Update-NativeRegistration([string]$State,$Paths,$Sources,$Roots) {
    $lock=$null;$deadline=[datetime]::UtcNow.AddSeconds(30)
    try {
        while(-not $lock){
            Assert-AitNotCancelled
            try{$lock=[IO.File]::Open((Join-Path $State 'native_setup.lock'),'OpenOrCreate','ReadWrite','None')}
            catch [IO.IOException]{
                if([datetime]::UtcNow -gt $deadline){throw 'AITN-235: Не удалось сохранить список моделей: другая установка ещё работает. Дождитесь её завершения и повторите установку.'}
                Start-Sleep -Milliseconds 100
            }
        }
        $path=Join-Path $State 'native_active.json';$old=Read-AitJson $path
        $next=@{schema=1;weights=@{};sources=@{}}
        if($old){foreach($p in $old.PSObject.Properties){$next[$p.Name]=$p.Value}}
        $mergedWeights=@{};$mergedSources=@{}
        if($old.weights){foreach($p in $old.weights.PSObject.Properties){$mergedWeights[$p.Name]=$p.Value}}
        if($old.sources){foreach($p in $old.sources.PSObject.Properties){$mergedSources[$p.Name]=$p.Value}}
        foreach($name in $Paths.Keys){$mergedWeights[$name]=$Paths[$name]}
        foreach($name in $Sources.Keys){$mergedSources[$name]=$Sources[$name]}
        foreach($name in $Roots.Keys){$next[$name]=$Roots[$name]}
        $next.weights=$mergedWeights;$next.sources=$mergedSources
        $saved=$false
        while(-not $saved){
            Assert-AitNotCancelled
            try{Write-AitJson $path $next;$saved=$true}
            catch [IO.IOException]{
                $win32=$_.Exception.HResult -band 65535
                if($win32 -notin @(32,33) -or [datetime]::UtcNow -gt $deadline){throw}
                Start-Sleep -Milliseconds 100
            }
        }
        return $next
    } finally {if($lock){$lock.Dispose()}}
}
function Lock-NativeModel([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))).Replace('-','')}
    finally{$sha.Dispose()}
    $mutex=[Threading.Mutex]::new($false,('Local\AiTranscriberGGUF_'+$key))
    try{
        $acquired=$false
        try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'AITN-234: Эта модель уже загружается в другом окне. Дождитесь завершения той загрузки.'}
        return $mutex
    }catch{$mutex.Dispose();throw}
}
function Get-NativeExternalDigest([string]$Path,[long]$Bytes,[datetime]$Deadline) {
    $stream=$null;$hash=$null
    try {
        $stream=[IO.File]::Open($Path,'Open','Read','Read')
        $hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 1048576
        $done=0L;$updated=[datetime]::MinValue
        while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
            Assert-AitNotCancelled
            if([datetime]::UtcNow -gt $Deadline){throw 'AITN-233: Проверка моделей NeuralNote превысила 3 минуты.'}
            [void]$hash.TransformBlock($buffer,0,$count,$buffer,0);$done+=$count
            if([datetime]::UtcNow -gt $updated.AddSeconds(1)){
                $updated=[datetime]::UtcNow
                Write-AitEvent 'checking' ('Проверка NeuralNote: '+[IO.Path]::GetFileName($Path)) $done $Bytes
            }
        }
        [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
        return ([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
    } finally {if($stream){$stream.Dispose()};if($hash){$hash.Dispose()}}
}
function Invoke-NativeModelSetup($Job,[string]$State,[string]$Directory,[string]$Id) {
    if($Job.schema -ne 1 -or $Job.id -cne $Id){throw 'AITN-100: Invalid native setup request.'}
    $modelMutex=$null
    try {
        Test-AitPayload (Split-Path -Parent $PSScriptRoot)
        Write-AitJson (Join-Path $Directory 'worker.json') @{pid=$PID;started=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');job_id=$Id}
        if($Job.action -eq 'native_devices'){
            $app=Split-Path -Parent $PSScriptRoot;$manifest=Read-AitJson (Join-Path $app 'manifest.json')
            $release=Read-AitJson (Join-Path $app 'native_release.json')
            $runtime=Join-Path $app ([string]$release.runtime.file)
            Write-AitEvent 'hardware' 'Определение видеокарты…'
            $devicesFile=Join-Path $Directory 'native_devices.json'
            $code=Invoke-AiLiveProcess $runtime @('--devices','--out',$devicesFile) (Join-Path $Directory 'native_hardware.log') -TimeoutSeconds 25
            if($code -ne 0){throw 'AITN-411: Не удалось определить доступные устройства. Выберите CPU или обновите драйвер видеокарты.'}
            $devices=Read-AitJson $devicesFile
            $gpu=@($devices.devices|Where-Object {$_.backend -eq 'Vulkan'}|Sort-Object integrated|Select-Object -First 1)
            $hardware=if($gpu.Count){@{mode='vulkan';gpu_name=[string]$gpu[0].name;vram_mib=[math]::Round([double]$gpu[0].memory_total/1MB)}}else{@{mode='cpu'}}
            $cache=@{schema=1;hardware=$hardware;checked=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();devices=@($devices.devices);automatic_index=$devices.automatic_index}
            Write-AitJson (Join-Path $State 'native_hardware.json') $cache
            Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;ok=$true;action=$Job.action;native_hardware=$hardware;native_devices=$devices;message='Доступные устройства определены.'}
            return
        }
        $catalog=Read-AitJson (Join-Path (Split-Path -Parent $PSScriptRoot) 'native_models.json')
        $nativePath=Join-Path $State 'native_active.json'
        $native=Read-AitJson $nativePath
        $next=@{schema=1;weights=@{};sources=@{}}
        if($native){foreach($p in $native.PSObject.Properties){$next[$p.Name]=$p.Value}}
        $weights=@{};if($native.weights){foreach($p in $native.weights.PSObject.Properties){$weights[$p.Name]=$p.Value}}
        $sources=@{};if($native.sources){foreach($p in $native.sources.PSObject.Properties){$sources[$p.Name]=$p.Value}}
        if($Job.action -eq 'native_neuralnote'){
            $folder=if($Job.model_directory){[IO.Path]::GetFullPath([string]$Job.model_directory)}else{
                $roaming=[Environment]::GetFolderPath('ApplicationData')
                if(-not $roaming){throw 'AITN-231: Windows не предоставила папку AppData\Roaming.'}
                Join-Path $roaming 'NeuralNote\models'
            }
            Write-AitEvent 'checking' ('Поиск моделей NeuralNote: '+$folder)
            if(-not [IO.Directory]::Exists($folder)){throw ('AITN-231: Папка моделей NeuralNote не найдена: '+$folder)}
            # Read only the selected folder's files. Never recurse, copy models,
            # create markers, download, or write beside shared external models.
            $files=@(Get-ChildItem -LiteralPath $folder -File -Filter '*.gguf' -ErrorAction Stop|Select-Object -First 129|Sort-Object Name)
            if($files.Count -gt 128){throw 'AITN-232: В папке NeuralNote слишком много GGUF-файлов.'}
            $found=@{};$skipped=New-Object Collections.Generic.List[object];$deadline=[datetime]::UtcNow.AddMinutes(3)
            foreach($file in $files){
                Assert-AitNotCancelled
                if([datetime]::UtcNow -gt $deadline){throw 'AITN-233: Проверка моделей NeuralNote превысила 3 минуты.'}
                $model=$null
                foreach($name in @('small','medium','large')){if($file.Length -eq [long]$catalog.models.$name.bytes){$model=$name;break}}
                if(-not $model){$skipped.Add(@{name=$file.Name;reason='Формат GGUF не поддерживается'});continue}
                if($found.ContainsKey($model)){continue}
                try{$digest=Get-NativeExternalDigest $file.FullName $file.Length $deadline}
                catch{
                    $failure=$_;Assert-AitNotCancelled
                    if($failure.Exception.Message -like 'AITN-233:*'){throw}
                    $skipped.Add(@{name=$file.Name;reason='Файл недоступен или используется для записи'});continue
                }
                if($digest -cne [string]$catalog.models.$model.sha256){$skipped.Add(@{name=$file.Name;reason='Контрольная сумма не совпала: другой формат или повреждение'});continue}
                $found[$model]=$file.FullName
            }
            if(-not $found.Count){throw ('AITN-232: Подходящих моделей MuScriptor GGUF не найдено в папке: '+$folder)}
            $connected=@();foreach($name in @('small','medium','large')){if($found.ContainsKey($name)){
                $weights[$name]=$found[$name];$sources[$name]='external';$connected+=$name
            }}
            $connectedPaths=@{};$connectedSources=@{}
            foreach($name in $connected){$connectedPaths[$name]=$weights[$name];$connectedSources[$name]='external'}
            $next=Update-NativeRegistration $State $connectedPaths $connectedSources @{}
            $message='Подключены модели NeuralNote: '+($connected -join ', ')+'.'
            if($skipped.Count){$message+=' Пропущено файлов: '+$skipped.Count+'.'}
            Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;ok=$true;action=$Job.action;native_active=$next;message=$message;
                native_discovery=@{folder=$folder;connected=@($connected);skipped=@($skipped.ToArray())}}
            return
        }
        $models=@($Job.models);if($Job.model){$models=@([string]$Job.model)}
        if(-not $models.Count -or $models.Count -gt 3){throw 'AITN-120: Select a model.'}
        $changedWeights=@{};$changedSources=@{};$rootUpdates=@{}
        foreach($model in $models) {
            Assert-AitNotCancelled
            if($model -notin @('small','medium','large')){throw 'AITN-120: Unknown model.'}
            $entry=$catalog.models.$model
            if($Job.action -eq 'native_connect') {
                $weight=[IO.Path]::GetFullPath([string]$Job.model_path)
                if(-not [IO.File]::Exists($weight) -or [IO.Path]::GetExtension($weight) -ine '.gguf'){throw 'AITN-220: Select an existing GGUF file. If no model is installed, use Install.'}
                # Explicit external paths/links are read-only. Never create anything beside them.
                if((Get-Item -LiteralPath $weight).Length -ne [long]$entry.bytes){throw 'AITN-221: GGUF size differs from the selected F16 model. Check model size and complete download.'}
                Write-AitEvent 'checking' ('Проверка модели '+$model)
                if((Get-FileHash -LiteralPath $weight -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256){throw 'AITN-222: GGUF checksum mismatch. The model is damaged or uses a different format.'}
                $sources[$model]='external'
            } elseif($Job.action -eq 'native_download') {
                $dataRoot=[IO.Path]::GetFullPath([string]$Job.data_root).TrimEnd('\')
                if($dataRoot -eq [IO.Path]::GetPathRoot($dataRoot).TrimEnd('\')){throw 'AITN-223: Select a dedicated model folder, not a drive root.'}
                Assert-AitOrdinaryPath $dataRoot
                # Persist the chosen location before the first write/download;
                # retries reuse it even if the network operation is interrupted.
                $rootKey='data_root'
                $rootUpdates[$rootKey]=$dataRoot
                if($Job.shared_root){$rootUpdates.components_root=$dataRoot}
                $next=Update-NativeRegistration $State @{} @{} $rootUpdates
                # GGUF is self-contained. Keep all components beside each other;
                # integrity is checked against the catalog, not a directory name.
                $modelFolder=Join-Path $dataRoot 'models'
                Assert-AitOrdinaryPath $modelFolder
                [void][IO.Directory]::CreateDirectory($modelFolder)
                $weight=Join-Path $modelFolder ([string]$entry.file)
                Assert-AitOrdinaryPath $weight
                $modelMutex=Lock-NativeModel $weight
                $complete=[IO.File]::Exists($weight) -and (Get-Item -LiteralPath $weight).Length -eq [long]$entry.bytes -and
                    (Get-FileHash -LiteralPath $weight -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$entry.sha256
                if(-not $complete) {
                    # A shared, user-selected folder may contain unrelated files.
                    # Only replace a damaged file already registered as our download.
                    if([IO.File]::Exists($weight) -and
                        ($sources[$model] -ne 'managed' -or [string]$weights[$model] -ine $weight)){
                        throw ('AITN-229: В папке уже есть другой файл с именем '+[string]$entry.file+'. Он сохранён без изменений. Выберите другую папку для загрузки.')
                    }
                    $partial=$weight+'.part'
                    Assert-AitOrdinaryPath $partial
                    if([IO.File]::Exists($partial) -and (Get-Item -LiteralPath $partial).Length -ge [long]$entry.bytes -and
                        ((Get-Item -LiteralPath $partial).Length -ne [long]$entry.bytes -or (Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -cne [string]$entry.sha256)){
                        $savedPartial=$partial+'.corrupt-'+$Id
                        if([IO.File]::Exists($savedPartial)){throw 'AITN-227: Partial recovery backup already exists.'}
                        [IO.File]::Move($partial,$savedPartial)
                    }
                    $repository=if($entry.repository){[string]$entry.repository}else{[string]$catalog.repository}
                    $revision=if($entry.revision){[string]$entry.revision}else{[string]$catalog.revision}
                    $prefix=if($null -ne $entry.prefix){[string]$entry.prefix}else{'v1/'}
                    $url='https://huggingface.co/'+$repository+'/resolve/'+$revision+'/'+$prefix+[string]$entry.file
                    $lastFailure=$null
                    for($attempt=1;$attempt -le 3;$attempt++) {
                        Assert-AitNotCancelled
                        $response=$null;$stream=$null;$file=$null
                        try {
                            $offset=if([IO.File]::Exists($partial)){[long](Get-Item -LiteralPath $partial).Length}else{0L}
                            if($offset -gt [long]$entry.bytes){throw 'AITN-224: Partial download is larger than expected. Preserve it and select another folder.'}
                            if($offset -eq [long]$entry.bytes){break}
                            Write-AitEvent 'downloading' ('Скачивание '+$model+' · попытка '+$attempt+' из 3')
                            [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                            $request=[Net.HttpWebRequest]::Create($url);$request.UserAgent='Ai-Transcriber-Native';$request.Timeout=30000;$request.ReadWriteTimeout=30000
                            if($offset){$request.AddRange($offset)}
                            $response=$request.GetResponse();$stream=$response.GetResponseStream()
                            if($offset -and [int]$response.StatusCode -ne 206){$offset=0L}
                            if([int]$response.StatusCode -eq 206 -and [string]$response.Headers['Content-Range'] -cne ('bytes '+$offset+'-'+([long]$entry.bytes-1)+'/'+[long]$entry.bytes)){throw 'AITN-228: Server returned an unexpected download range.'}
                            $file=[IO.File]::Open($partial,$(if($offset){'Append'}else{'Create'}),'Write','None')
                            $buffer=New-Object byte[] 262144;$lastUpdate=[DateTime]::MinValue;$received=$offset
                            while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                                Assert-AitNotCancelled;$received+=$count
                                if($received -gt [long]$entry.bytes){throw 'AITN-224: Server returned more bytes than expected.'}
                                $file.Write($buffer,0,$count)
                                if([DateTime]::UtcNow -gt $lastUpdate.AddSeconds(1)) {
                                    $lastUpdate=[DateTime]::UtcNow
                                    Write-AitEvent 'downloading' ('Скачивание '+$model+': '+[math]::Round($received/1MB,1)+' / '+[math]::Round([long]$entry.bytes/1MB,1)+' МиБ') $received ([long]$entry.bytes)
                                }
                            }
                            if($received -ne [long]$entry.bytes){throw 'AITN-225: Download ended early.'}
                            $lastFailure=$null;break
                        } catch {$lastFailure=$_;if(Test-Path -LiteralPath $env:AIT2_CANCEL){throw};if($attempt -eq 3){throw ('AITN-226: Network download failed after 3 attempts. Check VPN/firewall and retry; partial data is kept. '+$_.Exception.Message)}}
                        finally {if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()}}
                    }
                    Assert-AitNotCancelled
                    Write-AitEvent 'checking' ('Проверка контрольной суммы '+$model)
                    if((Get-Item -LiteralPath $partial).Length -ne [long]$entry.bytes -or (Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -cne [string]$entry.sha256){throw 'AITN-222: Download checksum mismatch. Partial data retained; do not use this model.'}
                    if([IO.File]::Exists($weight)) {
                        $backup=$weight+'.corrupt-'+$Id
                        if([IO.File]::Exists($backup)){throw 'AITN-227: Recovery backup already exists.'}
                        [IO.File]::Move($weight,$backup)
                    }
                    [IO.File]::Move($partial,$weight)
                }
                $next[$rootKey]=$dataRoot;$sources[$model]='managed'
            } else {throw 'AITN-100: Unknown native action.'}
            Assert-AitNotCancelled;$weights[$model]=$weight
            $changedWeights[$model]=$weight;$changedSources[$model]=$sources[$model]
            if($modelMutex){$modelMutex.ReleaseMutex();$modelMutex.Dispose();$modelMutex=$null}
        }
        $next=Update-NativeRegistration $State $changedWeights $changedSources $rootUpdates
        Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;ok=$true;action=$Job.action;native_active=$next;message='Модели GGUF подключены. Можно транскрибировать.'}
    } catch {
        $detail=Protect-AitMessage $_.Exception.Message
        $code='AITN-200';if($detail -match '(AITN-\d{3}|AIT2-\d{3})'){$code=$matches[1]}
        $titles=@{'AITN-220'='Файл модели не найден';'AITN-221'='Файл не соответствует выбранной модели';'AITN-222'='Модель повреждена или имеет другой формат';'AITN-223'='Неподходящая папка моделей';'AITN-224'='Сервер вернул неверный размер файла';'AITN-225'='Загрузка модели прервана';'AITN-226'='Не удалось скачать модель';'AITN-228'='Не удалось продолжить загрузку';'AITN-411'='Не удалось определить видеокарту';'AIT2-120'='Повреждён установочный комплект'}
        $titles['AITN-231']='Папка моделей NeuralNote не найдена';$titles['AITN-232']='Подходящие модели NeuralNote не найдены';$titles['AITN-233']='Проверка моделей NeuralNote заняла слишком много времени'
        $titles['AITN-229']='Имя файла модели уже занято'
        $titles['AITN-234']='Модель уже загружается';$titles['AITN-235']='Список моделей занят другой установкой'
        $title=if($titles.ContainsKey($code)){$titles[$code]}else{'Операция не завершена'}
        $help=if($code -in @('AITN-224','AITN-225','AITN-226','AITN-228')){'Проверьте соединение, VPN и доступ к Hugging Face. Повторите установку: загруженная часть сохранена.'}elseif($code -eq 'AITN-220'){'Выберите существующий GGUF-файл или установите модель с нуля.'}elseif($code -eq 'AITN-221' -or $code -eq 'AITN-222'){'Проверьте выбранный размер модели. Повреждённую модель можно загрузить заново; остальные компоненты сохранены.'}elseif($code -eq 'AIT2-120'){'Повторно распакуйте оригинальный установочный комплект.'}else{'Проверьте путь и доступ к папке. Работающие модели сохранены.'}
        if($code -in @('AITN-231','AITN-232')){$help='Нажмите «Указать папку моделей…», если модели скачаны в другое место. Если их ещё нет, нажмите «Установить» в таблице.'}
        if($code -eq 'AITN-233'){$help='Проверьте доступность диска и завершите загрузку модели в NeuralNote. Затем повторите подключение. Текущие модели сохранены.'}
        if($code -eq 'AITN-229'){$help='В выбранной папке уже есть другой файл с таким именем. Выберите другую папку для загрузки; существующий файл не изменён.'}
        if($code -in @('AITN-234','AITN-235')){$help='Дождитесь завершения установки в другом окне и повторите попытку. Остальные загрузки продолжаются.'}
        $cancelled=$detail -match 'AIT2-CANCELLED'
        if($cancelled){$code='AITN-499';$title='Загрузка остановлена';$help='Загруженная часть сохранена. Нажмите «Установить», чтобы продолжить.'}
        if($_.Exception -is [UnauthorizedAccessException]){$code='AITN-230';$title='Нет доступа к папке моделей';$help='Выберите доступную папку или проверьте разрешения и защитное ПО.'}
        $stage=if($Job.action -eq 'native_devices'){'Определение видеокарты'}elseif($Job.action -eq 'native_neuralnote'){'Подключение моделей NeuralNote'}elseif($script:AitStage -eq 'downloading'){'Загрузка модели'}else{'Проверка модели и папки'}
        Write-AitJson (Join-Path $Directory 'result.json') @{schema=1;job_id=$Id;ok=$false;cancelled=$cancelled;action=$Job.action;message=($code+': '+$title);error=@{code=$code;title=$title;stage=$stage;detail=$detail;help=@($help)}}
    } finally {if($modelMutex){$modelMutex.ReleaseMutex();$modelMutex.Dispose()}}
}
