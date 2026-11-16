# Persist paths relative to the selected data directory / portable REAPER profile.
function Get-AitStorageContext([string]$Path) {
    $folder=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while($folder){
        $marker=Join-Path $folder '.storage_context.json'
        if([IO.File]::Exists($marker)){
            $context=[IO.File]::ReadAllText($marker)|ConvertFrom-Json
            if($context.schema -ne 1){throw 'AITN-710: Invalid storage context.'}
            return @{root=$folder;resource=[string]$context.resource_root;mode=[string]$context.mode}
        }
        $folder=[IO.Path]::GetDirectoryName($folder)
    }
    return $null
}
function Get-AitRelativePath([string]$Path,[string]$Root){
    $p=$Path.Replace('/','\').TrimEnd('\');$r=$Root.Replace('/','\').TrimEnd('\')
    if($p.Equals($r,[StringComparison]::OrdinalIgnoreCase)){return ''}
    if($p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){return $p.Substring($r.Length+1)}
    return $null
}
function Join-AitStoredPath([string]$Root,[string]$Tail){
    if($Tail -match '(^|[\\/])\.\.?([\\/]|$)' -or $Tail -match '^[/\\]|:'){throw 'AITN-710: Invalid relative storage path.'}
    return [IO.Path]::GetFullPath((Join-Path $Root $Tail))
}
function Convert-AitStorageValue($Value,$Context,[bool]$Encode){
    if($null -eq $Value){return $null}
    if($Value -is [string]){
        if($Encode){
            if($Context.mode -eq 'system'){return $Value}
            $tail=Get-AitRelativePath $Value $Context.root
            if($null -ne $tail){return '@data/'+$tail.Replace('\','/')}
            $tail=Get-AitRelativePath $Value $Context.resource
            if($null -ne $tail){return '@reaper/'+$tail.Replace('\','/')}
        }else{
            if($Value.StartsWith('@data/')){return Join-AitStoredPath $Context.root $Value.Substring(6)}
            if($Value.StartsWith('@reaper/')){return Join-AitStoredPath $Context.resource $Value.Substring(8)}
        }
        return $Value
    }
    if($Value -is [Collections.IDictionary]){
        $copy=@{};foreach($key in $Value.Keys){$copy[$key]=Convert-AitStorageValue $Value[$key] $Context $Encode};return $copy
    }
    if($Value -is [array]){
        $copy=@(foreach($entry in $Value){Convert-AitStorageValue $entry $Context $Encode});return ,$copy
    }
    if($Value -is [pscustomobject]){
        $copy=@{};foreach($entry in $Value.PSObject.Properties){$copy[$entry.Name]=Convert-AitStorageValue $entry.Value $Context $Encode};return [pscustomobject]$copy
    }
    return $Value
}
function Convert-AitStorageJson([string]$Path,$Value,[bool]$Encode){
    if([IO.Path]::GetFileName($Path) -in @('config.json','.storage_context.json')){return $Value}
    $context=Get-AitStorageContext $Path
    if($context){return Convert-AitStorageValue $Value $context $Encode}
    return $Value
}
