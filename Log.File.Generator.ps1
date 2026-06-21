# ==============================================================================
# 1. CONFIGURATION & SETUP
# ==============================================================================
$LogDirectory = "C:\temp\WinLogs"
$LogPath = Join-Path $LogDirectory "WinSysEvents.log"

# Ensure directory exists
if (-not (Test-Path $LogDirectory)) { 
    New-Item -ItemType Directory -Path $LogDirectory | Out-Null 
}

# ==============================================================================
# 2. WINDOWS-SPECIFIC DATA POOLS
# ==============================================================================
$Global:EventLevels  = @("Verbose", "Information", "Warning", "Error", "Critical", "Audit Success", "Audit Failure")
$Global:Servers      = @("CORP-DC01", "CORP-DC02", "EXCH-DAG-01", "SQL-CLUS-NODE1", "RDS-GW-01", "IIS-WEB-04", "HV-HOST-08")
$Global:Providers    = @("Microsoft-Windows-Security-Auditing", "Service Control Manager", "Microsoft-Windows-IIS-W3SVC", "MSSQLSERVER", "Microsoft-Windows-WinRM", "ActiveDirectory_DomainService")
$Global:Resources    = @("\\CORP-FS01\Finance", "HKLM\System\CurrentControlSet\Services", "Root\CIMv2", "C:\Windows\System32\lsass.exe", "/owa/auth/logon.aspx")
$Global:Users        = @("NT AUTHORITY\SYSTEM", "CORP\admin_root", "CORP\jdoe", "IIS APPPOOL\DefaultAppPool", "NT AUTHORITY\NETWORK SERVICE")
$Global:IPs          = @("10.0.4.12", "192.168.42.105", "172.16.8.4", "127.0.0.1", "fe80::1ff:fe23:4567:890a")
$Global:EventIDs     = @(4624, 4625, 7036, 1000, 1002, 5140, 4688, 4740)
$Global:Exceptions   = @("System.UnauthorizedAccessException", "System.ComponentModel.Win32Exception", "COMException (0x80040154)", "System.DirectoryServices.DirectoryServicesCOMException")

# ==============================================================================
# 3. CORE LOGIC FUNCTION
# ==============================================================================
function Get-WindowsChaosLogEntry {
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $Level     = $Global:EventLevels | Get-Random
    $Server    = $Global:Servers | Get-Random
    $Provider  = $Global:Providers | Get-Random
    $EventID   = $Global:EventIDs | Get-Random
    
    # Standard Windows Event Viewer style prefix
    $Prefix = "[$Timestamp] [$Level] [$Server] [$Provider] [EventID:$EventID]"
    
    # Pick a random Windows-specific log schema (1 through 5)
    $SchemaType = 1..5 | Get-Random

    switch ($SchemaType) {
        1 { 
            # FORMAT 1: Windows Event Log JSON (WEF Style)
            $Payload = @{
                TimeCreated  = $Timestamp
                Level        = $Level
                Computer     = $Server
                ProviderName = $Provider
                EventID      = $EventID
                RecordNumber = (Get-Random -Minimum 10000 -Maximum 999999)
                ProcessID    = (Get-Random -Minimum 4 -Maximum 8192)
                ThreadID     = (Get-Random -Minimum 100 -Maximum 9999)
            }
            return ($Payload | ConvertTo-Json -Compress)
        }
        2 { 
            # FORMAT 2: IIS W3C Web Log Style
            $Method      = @("GET", "POST", "RPC_IN_DATA", "RPC_OUT_DATA") | Get-Random
            $Status      = @(200, 304, 401, 403, 404, 500, 503) | Get-Random
            $Ip          = $Global:IPs | Get-Random
            $User        = $Global:Users | Get-Random
            $Resource    = "/owa/api/v1/mailbox/" + (Get-Random -Minimum 100 -Maximum 999)
            $Win32Status = @(0, 5, 64, 2148074254) | Get-Random # Success, Access Denied, Network Name Deleted, etc.
            
            return "$Timestamp $Server W3SVC1 $Ip $Method $Resource - $Status $Win32Status - $User"
        }
        3 { 
            # FORMAT 3: Application Crash / Win32 Exception
            if ($Level -in @("Error", "Critical", "Audit Failure")) {
                $Ex             = $Global:Exceptions | Get-Random
                $App            = @("w3wp.exe", "lsass.exe", "svchost.exe", "spoolsv.exe") | Get-Random
                $FaultingModule = @("ntdll.dll", "kernelbase.dll", "clr.dll", "mscorlib.ni.dll") | Get-Random
                $ExceptionCode  = "0x$( (Get-Random -Minimum 80000000 -Maximum 80070005).ToString('X') )"
                
                return "$Prefix - Faulting application name: $App. Faulting module name: $FaultingModule. Exception code: $ExceptionCode. Error Context: $Ex"
            } else {
                $Service = @("Windows Update", "Print Spooler", "WinRM", "Task Scheduler") | Get-Random
                return "$Prefix - The $Service service entered the running state."
            }
        }
        4 { 
            # FORMAT 4: Active Directory / SMB Security Auditing
            $User     = $Global:Users | Get-Random
            $Resource = $Global:Resources | Get-Random
            $Actions  = @(
                "A network share object was accessed. Share Name: $Resource",
                "An account failed to log on. Account Name: $User. Failure Reason: Unknown user name or bad password.",
                "A user account was locked out. Target Account: $User",
                "Special privileges assigned to new logon. Subject: $User",
                "A new process has been created. Creator Subject: $User. Process Name: C:\Windows\System32\cmd.exe"
            )
            $Action = $Actions | Get-Random
            
            return "$Prefix - [SECURITY_AUDIT] - $Action"
        }
        5 { 
            # FORMAT 5: Perfmon / WMI Counters
            $Cpu = Get-Random -Minimum 5 -Maximum 100
            $Ram = (Get-Random -Minimum 1024 -Maximum 16384)
            $DiskQueue = (Get-Random -Minimum 0 -Maximum 50) / 10
            
            if ($Cpu -gt 90) {
                return "$Prefix - [WMI_ALERT] \Processor(_Total)\% Processor Time exceeded threshold. Current value: $Cpu%"
            } else {
                return "$Prefix - [PERFMON] \Memory\Available MBytes: $Ram | \PhysicalDisk(_Total)\Avg. Disk Queue Length: $DiskQueue"
            }
        }
    }
}

# ==============================================================================
# 4. EXECUTION LOOP
# ==============================================================================
Write-Host "Launching Windows Systems Event Generator at $LogPath..." -ForegroundColor Cyan
Write-Host "Press [CTRL + C] to terminate." -ForegroundColor Yellow

while ($true) {
    # 1. Generate log entry
    $LogEntry = Get-WindowsChaosLogEntry
    
    # 2. Write to File & Console
    Add-Content -Path $LogPath -Value $LogEntry
    Write-Host $LogEntry
    
    # 3. Chaotic Interval Logic
    $IsBursting = (Get-Random -Minimum 1 -Maximum 100) -gt 92
    
    if ($IsBursting) {
        # Micro sleep for intense burst simulation
        Start-Sleep -Milliseconds (Get-Random -Minimum 5 -Maximum 50)
    } else {
        # Regular sleep interval
        $RandomSleepSeconds = (Get-Random -Minimum 200 -Maximum 3500) / 1000
        Start-Sleep -Seconds $RandomSleepSeconds
    }
}
