[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Single')][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$StateRoot,
    [Parameter(ParameterSetName='Single')][ValidateSet('Run','Check')][string]$Mode='Run',
    [Parameter(Mandatory=$true,ParameterSetName='Setup')][string]$Config,
    [Parameter(ParameterSetName='Setup')][switch]$Recover
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$work=$null;$started=$false
function Assert-LaunchOrdinary([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked launch paths are not allowed'}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
try {
    $root=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    if($PSCmdlet.ParameterSetName -eq 'Single'){
        $candidate=[IO.Path]::GetFullPath($WorkDir).TrimEnd('\');$id=[IO.Path]::GetFileName($candidate)
        if($id -notmatch '^[a-fA-F0-9]{32}$' -or $candidate -ne (Join-Path $root ('runtime_temp\'+$id))){throw 'Invalid single launch directory'}
        Assert-LaunchOrdinary $candidate;$work=$candidate
        if(-not (Test-Path -LiteralPath (Join-Path $work 'request.json') -PathType Leaf)){throw 'Single launch request is missing'}
        if(Test-Path -LiteralPath (Join-Path $work 'exit.json')){exit 0}
        $runner=Join-Path $PSScriptRoot 'single_runner.ps1'
        if(-not (Test-Path -LiteralPath $runner -PathType Leaf)){throw 'Single runner is missing'}
        $workerArguments=' -WorkDir "'+$work+'" -StateRoot "'+$root+'" -Mode '+$Mode
    }else{
        $configPath=[IO.Path]::GetFullPath($Config);$candidate=Split-Path -Parent $configPath;$id=[IO.Path]::GetFileName($candidate)
        if($id -notmatch '^[a-fA-F0-9]{32}$' -or $candidate -ne (Join-Path $root ('jobs\'+$id)) -or [IO.Path]::GetFileName($configPath) -ne 'job.json'){throw 'Invalid component launch directory'}
        Assert-LaunchOrdinary $configPath;$work=$candidate
        if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)){throw 'Component launch request is missing'}
        if(Test-Path -LiteralPath (Join-Path $work 'result.json')){exit 0}
        $runner=Join-Path $PSScriptRoot 'bootstrap.ps1'
        if(-not (Test-Path -LiteralPath $runner -PathType Leaf)){throw 'Component bootstrap is missing'}
        $workerArguments=' -Config "'+$configPath+'" -StateRoot "'+$root+'"'+$(if($Recover){' -Recover'}else{''})
    }
    foreach($path in @($runner,$work,$root)){if($path -match '["\r\n]'){throw 'Invalid single launch argument'}}
    # No inherited handles: .NET Framework Process.Start can keep REAPER's
    # capture pipes open in a detached child, even with CreateNoWindow.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class AitSingleLaunch {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
        public int cb; public string reserved, desktop, title;
        public int x,y,width,height,xChars,yChars,fill,flags;
        public short show,reservedSize;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(string application, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static uint Start(string executable, string arguments, string directory) {
        var startup=new StartupInfo(); startup.cb=Marshal.SizeOf(typeof(StartupInfo));
        ProcessInfo process;
        var command=new StringBuilder("\""+executable+"\" "+arguments);
        if (!CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,false,
                0x08000000,IntPtr.Zero,directory,ref startup,out process))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return process.pid; }
        finally { CloseHandle(process.thread); CloseHandle(process.process); }
    }
}
'@
    $executable=Join-Path $PSHOME 'powershell.exe'
    $arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$runner+'"'+$workerArguments
    $runnerId=[AitSingleLaunch]::Start($executable,$arguments,$PSScriptRoot)
    $started=$true
    # Success acknowledges creation only, never completion of transcription.
    [Console]::WriteLine('AIT2LAUNCH:'+ $id +':'+$runnerId)
    exit 0
}catch{
    $detail=$_.Exception.GetType().FullName+': '+$_.Exception.Message
    $detail=[regex]::Replace($detail,'hf_[A-Za-z0-9_]+','[TOKEN REDACTED]')
    $detail=[regex]::Replace($detail,'(?i)Bearer\s+[^\s"<>]+','Bearer [REDACTED]')
    if($detail.Length -gt 2400){$detail=$detail.Substring(0,2400)}
    if($work -and -not $started){try{
        $log=Join-Path $work 'launch_error.log';Assert-LaunchOrdinary $log
        [IO.File]::WriteAllText($log,$detail,[Text.UTF8Encoding]::new($false))
    }catch{}}
    [Console]::WriteLine($detail)
    exit 1
}
