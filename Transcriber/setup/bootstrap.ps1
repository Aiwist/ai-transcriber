[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Config,[Parameter(Mandatory=$true)][string]$StateRoot,[switch]$Recover)
# Deliberately dependency-free: errors while loading worker modules must remain
# diagnosable even when common.ps1 cannot be parsed or a file is quarantined.
$ErrorActionPreference='Stop'
$state=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
$configPath=[IO.Path]::GetFullPath($Config)
$directory=Split-Path -Parent $configPath
$id=[IO.Path]::GetFileName($directory)
if($id -notmatch '^[A-Fa-f0-9]{32}$' -or $directory -ne (Join-Path $state ('jobs\'+$id)) -or [IO.Path]::GetFileName($configPath) -ne 'job.json'){
    throw 'AIT2-100: Invalid bootstrap job path.'
}
foreach($folder in @($state,(Join-Path $state 'jobs'),$directory)){
    if((Get-Item -LiteralPath $folder -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AIT2-100: Linked bootstrap paths are not allowed.'}
}
function Write-BootstrapJson([string]$Name,$Value){
    $path=Join-Path $directory $Name
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AIT2-100: Linked bootstrap output is not allowed.'}
    [IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
}
Write-BootstrapJson 'bootstrap.json' @{schema=1;job_id=$id;phase='loading_worker';updated=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();powershell=$PSVersionTable.PSVersion.ToString()}
try{
    & (Join-Path $PSScriptRoot 'worker.ps1') -Config $configPath -StateRoot $state -Recover:$Recover
}catch{
    $detail=($_.Exception.GetType().FullName+': '+$_.Exception.Message)
    $detail=[regex]::Replace($detail,'hf_[A-Za-z0-9_]+','[TOKEN REDACTED]')
    $detail=[regex]::Replace($detail,'(?i)Bearer\s+[^\s"<>]+','Bearer [REDACTED]')
    if($detail.Length -gt 2400){$detail=$detail.Substring(0,2400)}
    $result=@{schema=1;job_id=$id;ok=$false;message='AIT2-201: Не удалось загрузить файлы помощника';error=@{
        code='AIT2-201';title='Не удалось загрузить файлы помощника';stage='Запуск помощника';detail=$detail;
        help=@('Посмотрите подробности ошибки ниже. Проверьте, что установочный архив распакован полностью и файлы из папки setup доступны.');retry_page=1}}
    Write-BootstrapJson 'bootstrap_error.json' $result
    if(-not (Test-Path -LiteralPath (Join-Path $directory 'result.json'))){Write-BootstrapJson 'result.json' $result}
}
