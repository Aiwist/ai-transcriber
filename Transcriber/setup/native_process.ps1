# Reused from Ai YuE2 2.2.5 job_service.ps1: Windows argv quoting and owned job object.
function Convert-JobArgument([string]$Value) {
    # Standard Windows argv quoting. Do not invoke cmd.exe or interpret prompt text.
    $escaped=[Regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[Regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"'+$escaped+'"'
}
function New-EngineJob {
    # Keep only our engine in a Windows job. Closing the runner (including a
    # crash) closes this non-inherited handle and terminates its owned children.
    if (-not ('AiwistEngineJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class AiwistEngineJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcess,PerJob; public uint Flags; public UIntPtr Min,Max; public uint Active; public UIntPtr Affinity; public uint Priority,Scheduling; }
    [StructLayout(LayoutKind.Sequential)] struct Counters { public ulong A,B,C,D,E,F; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic; public Counters IO; public UIntPtr ProcessMemory,JobMemory,PeakProcess,PeakJob; }
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int cls,IntPtr info,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public AiwistEngineJob() {
        handle=CreateJobObject(IntPtr.Zero,null);
        if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        Extended value=new Extended(); value.Basic.Flags=0x2000;
        int size=Marshal.SizeOf(typeof(Extended)); IntPtr data=Marshal.AllocHGlobal(size);
        try { Marshal.StructureToPtr(value,data,false); if(!SetInformationJobObject(handle,9,data,(uint)size)) { int error=Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error); } }
        finally { Marshal.FreeHGlobal(data); }
    }
    public void Add(IntPtr process) { if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } GC.SuppressFinalize(this); }
    ~AiwistEngineJob() { Dispose(); }
}
'@
    }
    return New-Object AiwistEngineJob
}
