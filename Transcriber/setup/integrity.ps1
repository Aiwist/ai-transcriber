# Shared by the ZIP installer and ReaPack's hidden launcher.
# Change only mandatory integrity labels on this application and its engines.
function Repair-AitEngineIntegrity([string]$AppRoot) {
    # A portable installation may permit file updates without allowing a security
    # label change. Read the effective label first; normal files need no repair.
    if(-not ('AitIntegrityLabel' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AitIntegrityLabel {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetNamedSecurityInfoW(string name, uint kind, uint info,
        IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr descriptor, uint revision, uint info, out IntPtr text, out uint length);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    public static string Read(string path) {
        IntPtr descriptor=IntPtr.Zero, text=IntPtr.Zero; uint length;
        try {
            uint error=GetNamedSecurityInfoW(path,1,16,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out descriptor);
            // FAT/exFAT volumes do not support mandatory security labels.
            if(error==1 || error==50) return "";
            if(error!=0) throw new Win32Exception((int)error);
            if(!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor,1,16,out text,out length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return Marshal.PtrToStringUni(text) ?? "";
        } finally { if(text!=IntPtr.Zero) LocalFree(text); if(descriptor!=IntPtr.Zero) LocalFree(descriptor); }
    }
}
'@
    }
    $base=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    if($base -eq [IO.Path]::GetPathRoot($base).TrimEnd('\')){throw 'AITN-114: Invalid application folder.'}
    $release=Get-Content -LiteralPath (Join-Path $base 'native_release.json') -Raw | ConvertFrom-Json
    $targets=@(@{Path=$base;Label='(OI)(CI)M'})
    foreach($runtime in @($release.cpu_runtime,$release.runtime)){
        $relative=[string]$runtime.file
        if($relative -notmatch '^runtime/[A-Za-z0-9._-]+/ai_transcriber_native\.exe$'){throw 'AITN-114: Invalid engine path.'}
        $path=[IO.Path]::GetFullPath((Join-Path $base $relative))
        if(-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)){throw 'AITN-114: Engine is missing.'}
        $targets+=@{Path=$path;Label='M'}
    }
    foreach($target in $targets){
        $current=$target.Path
        while($current){
            if((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AITN-114: Linked application paths are not allowed.'}
            $current=[IO.Path]::GetDirectoryName($current)
        }
        if($target.Path -match '["\r\n]'){throw 'AITN-114: Invalid application path.'}
    }
    foreach($target in $targets){
        $label=[AitIntegrityLabel]::Read($target.Path)
        if($label -notmatch ';(LW|UN|S-1-16-0|S-1-16-4096)\)'){continue}
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=Join-Path $env:SystemRoot 'System32\icacls.exe'
        $info.Arguments='"'+$target.Path+'" /setintegritylevel "'+$target.Label+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        try{
            [void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(5000)){$process.Kill();[void]$process.WaitForExit(5000);throw 'AITN-114: Integrity repair timed out.'}
            [void]$stdout.Result;[void]$stderr.Result
            if($process.ExitCode -ne 0){throw ('AITN-114: Cannot restore normal integrity level: '+$target.Path+'. Reinstall Ai Transcriber in a writable REAPER resource folder.')}
        }finally{$process.Dispose()}
    }
}
