# Shared by the ZIP installer and ReaPack's hidden launcher.
# Change only mandatory integrity labels on this application and its engines.
function Repair-AitEngineIntegrity([string]$AppRoot) {
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
