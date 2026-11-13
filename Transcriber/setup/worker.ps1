[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Config,[Parameter(Mandatory=$true)][string]$StateRoot,[switch]$Recover)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'maintenance.ps1')
. (Join-Path $PSScriptRoot 'download_progress.ps1')
$state=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\');$configPath=[IO.Path]::GetFullPath($Config);$directory=Split-Path -Parent $configPath;$id=[IO.Path]::GetFileName($directory)
if($id -notmatch '^[A-Fa-f0-9]{32}$' -or $directory -ne (Join-Path $state ('jobs\'+$id)) -or [IO.Path]::GetFileName($configPath) -ne 'job.json'){throw 'Invalid Ai Transcriber setup path'}
Assert-AitOrdinaryPath $directory
$env:AIT2_JOB_DIR=$directory;$env:AIT2_JOB_ID=$id;$env:AIT2_STATUS=Join-Path $directory 'status.json';$env:AIT2_CANCEL=Join-Path $directory 'cancel.request'
$script:AitStage='starting';$script:AitMessage='Запуск помощника…'
if($Recover){
 if(Test-Path -LiteralPath (Join-Path $directory 'result.json')){return}
 $owner=Read-AitJson (Join-Path $directory 'worker.json')
 if($owner){$process=Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue;if($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $owner.started){return}}
 elseif(((Get-Date)-(Get-Item -LiteralPath $configPath).CreationTime).TotalSeconds -lt 90){return}
 Write-AitJson (Join-Path $directory 'result.json') @{job_id=$id;ok=$false;message='Предыдущая установка прервана. Повторите действие.';error=@{code='AIT2-150';title='Помощник был прерван';stage='Запуск помощника'}};return
}
try{
 $job=Read-AitJson $configPath
 if($job.schema -ne 1 -or $job.id -cne $id){throw 'Invalid Ai Transcriber setup request'}
 if($job.action -in @('native_download','native_neuralnote','native_devices')){
  . (Join-Path $PSScriptRoot 'native_setup.ps1');Invoke-NativeModelSetup $job $state $directory $id;return
 }
 if($job.action -notin @('storage_scan','storage_clean')){throw 'Unsupported Ai Transcriber action'}
 Test-AitPayload (Split-Path -Parent $PSScriptRoot);Assert-AitNotCancelled
 Write-AitJson (Join-Path $directory 'worker.json') @{pid=$PID;started=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');job_id=$id}
 $active=Read-AitJson (Join-Path $state 'native_active.json')
 $result=@{schema=1;job_id=$id;ok=$true;action=$job.action}
 if($job.action -eq 'storage_scan'){$result.storage=Save-AitStoragePlan $state (Get-AitStorage $state $active ([string]$job.runtime_instance))}
 else{$result.cleanup=Clear-AitStorage $state $active ([string]$job.plan_id) $job.selected ([string]$job.runtime_instance)}
 Write-AitJson (Join-Path $directory 'result.json') $result
}catch{
 $detail=Protect-AitMessage $_.Exception.Message
 Write-AitJson (Join-Path $directory 'result.json') @{schema=1;job_id=$id;ok=$false;message=$detail;error=@{code='AIT2-310';title='Операция не завершена';stage='Обслуживание';detail=$detail;help=@('Проверьте путь и доступ к папке. Работающие модели сохранены.')}}
}
