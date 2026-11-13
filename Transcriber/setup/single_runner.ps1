[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkDir,[Parameter(Mandatory=$true)][string]$StateRoot,[ValidateSet('Run','Check')][string]$Mode='Run')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$root=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\');$work=[IO.Path]::GetFullPath($WorkDir).TrimEnd('\');$id=[IO.Path]::GetFileName($work)
if($id -notmatch '^[a-fA-F0-9]{32}$' -or $work -ne (Join-Path $root ('runtime_temp\'+$id))){throw 'Invalid Ai Transcriber work directory'}
Assert-AitOrdinaryPath $work;$env:AIT2_CANCEL='';$env:AIT2_STATUS=''
if(Test-Path -LiteralPath (Join-Path $work 'exit.json')){return}
$request=Read-AitJson (Join-Path $work 'request.json')
if($request.id -cne $id -or $request.schema -ne 1 -or $request.engine -ne 'native' -or $request.output -notmatch '^muscriptor_result_\d+\.mid$'){throw 'Invalid Ai Transcriber request'}
. (Join-Path $PSScriptRoot 'native_runner.ps1')
Invoke-AitNativeProcess $work $root $id $request $Mode
