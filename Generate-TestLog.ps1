
<#
.SYNOPSIS
    Generates a continuously growing CMTrace-format log file for testing.

.DESCRIPTION
    Produces realistic CMTrace log entries at a configurable rate, cycling
    through all log types (Info, Warning, Error) and injecting keyword
    strings (Fatal, Critical, Exception, Debug, Verbose, Success, Audit,
    etc.) so every filter and colour path in the CMTrace viewer is exercised.

    The script also produces:
      - Multi-line log entries (stack traces, JSON payloads)
      - Plain (non-CMTrace) lines
      - Very long messages (stress-tests the MaxLineLength guard)
      - Entries whose message text contains XML/HTML-like characters
      - Rapid bursts followed by quiet periods (tests the fast/slow timer)

    Press Ctrl+C to stop generation.

.PARAMETER Path
    Full path to the log file to create/append.  Parent directory is created
    if it does not exist.  Defaults to $env:TEMP\TestCMTrace.log.

.PARAMETER IntervalMs
    Base delay in milliseconds between entries.  Actual delay is randomised
    within ±50 % of this value to simulate realistic write patterns.
    Defaults to 100 (roughly 10 entries/second on average).

.PARAMETER BurstChance
    Probability (0.0–1.0) that any given tick triggers a burst of 20–80
    rapid-fire entries with no inter-entry delay.  Defaults to 0.05 (5 %).

.PARAMETER MaxEntries
    Stop after this many entries.  0 = unlimited (run until Ctrl+C).
    Defaults to 0.

.PARAMETER Append
    If set, appends to an existing file rather than overwriting it.

.EXAMPLE
    .\Generate-TestLog.ps1
    # Writes to $env:TEMP\TestCMTrace.log at ~10 entries/s until Ctrl+C.

.EXAMPLE
    .\Generate-TestLog.ps1 -Path C:\Logs\test.log -IntervalMs 50 -BurstChance 0.1
    # Faster generation with more frequent bursts.

.EXAMPLE
    .\Generate-TestLog.ps1 -MaxEntries 5000 -Append
    # Appends exactly 5 000 entries then exits.
#>
[CmdletBinding()]
param(
    [string] $Path        = "$env:TEMP\TestCMTrace.log",
    [int]    $IntervalMs  = 100,
    [double] $BurstChance = 0.05,
    [int]    $MaxEntries  = 0,
    [switch] $Append
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Ensure output directory exists.
# ---------------------------------------------------------------------------
$dir = Split-Path $Path -Parent
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Open a StreamWriter with shared read access so the viewer can tail the
# file while we write.  AutoFlush is enabled so every entry is immediately
# visible to the reader without waiting for a buffer fill.
# ---------------------------------------------------------------------------
$fileMode = if ($Append) {
    [System.IO.FileMode]::Append
} else {
    [System.IO.FileMode]::Create
}

$stream = [System.IO.File]::Open(
    $Path,
    $fileMode,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite)

$writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
$writer.AutoFlush = $true

# ---------------------------------------------------------------------------
# Message pools — each pool is picked at random to exercise different code
# paths in the viewer (keyword matching, JSON formatting, XML escaping,
# multi-line handling, etc.).
# ---------------------------------------------------------------------------
$infoMessages = @(
    "Successfully connected to management point https://mp01.contoso.com."
    "Policy download completed in 2.34 seconds."
    "Inventory cycle finished — 412 objects reported."
    "Content transfer started for package PKG00042."
    "State message batch (45 messages) forwarded to site server."
    "Software update scan completed with 0 missing updates."
    "Task sequence execution engine initialised."
    "Client health evaluation passed all checks."
    "BITS download job resumed after network reconnection."
    "Hardware inventory delta report generated successfully."
    "Information: Maintenance window MW-0012 is currently active."
    "Service started: CcmExec (SMS Agent Host)."
)

$warningMessages = @(
    "Warning: Content location fallback to unprotected DP enabled."
    "Warn: Retry 2 of 5 — management point returned HTTP 503."
    "Warning: Certificate will expire in 14 days — renew promptly."
    "Warn: Disk space on C: below 10 % threshold (8.4 % free)."
    "Warning: Client registration pending — approval required."
    "Warn: WMI repository consistency check found 3 orphaned classes."
    "Warning: Software metering rule matched 0 processes."
    "Warn: Distribution point content validation found 1 hash mismatch."
)

$errorMessages = @(
    "Error: Failed to download policy from https://mp01.contoso.com — 0x80072ee7."
    "Error: Task sequence step 'Install Application' returned exit code 1603."
    "Failure: Content hash verification failed for CI_ID 887321."
    "Exception: System.Net.WebException — The remote server returned an error: (500)."
    "Error: WMI query SELECT * FROM CCM_Policy timed out after 120 seconds."
    "Failure: Unable to create execution request — disk full."
    "Error: State message upload rejected — invalid XML payload."
    "Exception: System.IO.IOException — The process cannot access the file."
)

$fatalMessages = @(
    "Fatal: Unrecoverable corruption in WMI repository — rebuild required."
    "Critical: Kernel driver ccmsetup.sys failed to load — BSOD risk."
    "Fatal: CcmExec service terminated unexpectedly (exit code 0xC0000005)."
    "Critical: Site server database connection pool exhausted — all 200 slots in use."
    "Fatal error in task sequence engine — aborting deployment."
)

$verboseDebugMessages = @(
    "Verbose: Entering method CContentDownloadManager::StartDownload."
    "Debug: HTTP request headers: Host=mp01.contoso.com; Content-Type=application/xml."
    "Trace: WMI provider loaded in 12 ms."
    "Verbose: Cache item PKG00042 evicted — last access 72 hours ago."
    "Debug: Registry key HKLM\SOFTWARE\Microsoft\CCM\Logging read successfully."
    "Trace: Message queue depth = 37, consumer thread count = 4."
)

$successAuditMessages = @(
    "Success: Application 'Microsoft 365 Apps' installed successfully."
    "Audit: User CONTOSO\jdoe approved software request REQ-88712."
    "Success: Compliance baseline 'Security-CIS-L1' evaluated — compliant."
    "Audit: Remote control session started by CONTOSO\admin01 on CLIENT042."
    "Success: Operating system deployment completed in 47 minutes."
    "Audit: Collection membership rule change by CONTOSO\sccmadmin."
)

$stoppedMessages = @(
    "Stopped: CcmExec service stopped by administrator."
    "Stopped: BITS transfer job cancelled — user requested abort."
    "Stopped: Task sequence halted at step 3 — break on error enabled."
    "Stopped: Content pre-staging job terminated — maintenance window closed."
)

# Messages containing characters that need XML escaping.
$xmlEscapeMessages = @(
    "Parsed element <PolicyAssignment> with attribute scope=""Machine"" & type=""Required""."
    "Registry value = ""C:\Program Files (x86)\App"" — contains special chars: < > & ' ""."
    "HTML response body: <html><body>Error 500 &amp; retry</body></html>."
    "XPath query: //Configuration[@name='CcmExec' and @enabled='true']."
)

# Multi-line stack traces.
$stackTraces = @(
    @"
System.NullReferenceException: Object reference not set to an instance of an object.
   at Microsoft.ConfigurationManagement.Client.CIDownloader.Start()
   at Microsoft.ConfigurationManagement.Client.AppEnforcer.EnforceApp(UInt32 ciId)
   at Microsoft.ConfigurationManagement.Client.Execution.ExecutionEngine.Run()
"@,
    @"
System.TimeoutException: The operation has timed out.
   at System.Net.HttpWebRequest.GetResponse()
   at Microsoft.ConfigurationManagement.Client.Http.CCMHttpClient.SendRequest(String url)
   at Microsoft.ConfigurationManagement.Client.PolicyAgent.DownloadPolicy(String policyUrl)
   at Microsoft.ConfigurationManagement.Client.PolicyAgent.PolicyEvaluationCycle()
"@,
    @"
System.IO.FileNotFoundException: Could not load file or assembly 'CCMCore, Version=5.0.0.0'.
   at Microsoft.ConfigurationManagement.Client.Framework.Loader.Initialize()
   at Microsoft.ConfigurationManagement.Client.CcmExec.ServiceMain(String[] args)
"@
)

# JSON payloads (single-line — the viewer's Format JSON option should pretty-print them).
$jsonPayloads = @(
    '{"eventType":"Compliance","baselineId":"BL-00451","result":"NonCompliant","settings":[{"name":"PasswordLength","expected":14,"actual":8},{"name":"AuditLogon","expected":"Enabled","actual":"Disabled"}]}'
    '{"deployment":{"id":"DEP-99201","application":"7-Zip 23.01","action":"Install","status":"InProgress","percentComplete":62,"startTime":"2024-11-15T09:23:11Z"}}'
    '{"inventory":{"type":"Hardware","deltaCount":23,"fullCount":412,"duration":"00:00:02.340","errors":[]}}'
    '[{"client":"CLIENT001","status":"Active"},{"client":"CLIENT002","status":"Inactive"},{"client":"CLIENT003","status":"Active","warning":"CertExpiringSoon"}]'
)

# Source components — rotated to make the log look realistic.
$components = @(
    "CcmExec", "PolicyAgent", "ContentAccess", "DataTransferService",
    "AppEnforce", "ScanAgent", "StateMessage", "InventoryAgent",
    "TaskSequence", "CIDownloader", "SoftwareDistribution", "WMIProvider",
    "CcmEval", "LocationServices", "BranchCache", "PeerCache",
    "OSDSetupHook", "ComplianceAgent", "UpdatesHandler", "CcmMessaging"
)

$rng = New-Object System.Random

# ---------------------------------------------------------------------------
# Helper: format a single CMTrace log line.
# CMTrace format:
#   <![LOG[<message>]LOG]!><time="HH:mm:ss.fff+zzz" date="MM-dd-yyyy"
#     component="<comp>" context="" type="<1|2|3>" thread="<tid>" file="<src>">
# ---------------------------------------------------------------------------
function Format-CMTraceEntry {
    param(
        [string] $Message,
        [int]    $Type,          # 1 = Info, 2 = Warning, 3 = Error
        [string] $Component
    )
    $now   = Get-Date
    $time  = $now.ToString("HH:mm:ss.fff")
    # CMTrace typically includes a timezone offset like +000 or -300.
    $tz    = [System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $tzStr = if ($tz -ge 0) { "+$([int]$tz)" } else { "$([int]$tz)" }
    $date  = $now.ToString("MM-dd-yyyy")
    $tid   = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    return "<![LOG[$Message]LOG]!><time=""$time$tzStr"" date=""$date"" component=""$Component"" context="""" type=""$Type"" thread=""$tid"" file=""TestLogGenerator.ps1"">"
}

# ---------------------------------------------------------------------------
# Helper: pick a random element from an array.
# ---------------------------------------------------------------------------
function Get-RandomItem {
    param([array]$Items)
    return $Items[$rng.Next($Items.Count)]
}

# ---------------------------------------------------------------------------
# Helper: generate one log entry (CMTrace or plain) and write it.
# Returns the number of lines written (for the counter).
# ---------------------------------------------------------------------------
function Write-LogEntry {
    $component = Get-RandomItem $components
    $roll      = $rng.NextDouble()

    # Weighted distribution:
    #   50 % Info (type 1)
    #   15 % Warning (type 2)
    #   10 % Error (type 3)
    #    5 % Fatal/Critical keywords (type 3)
    #    5 % Verbose/Debug/Trace keywords (type 1)
    #    5 % Success/Audit keywords (type 1)
    #    3 % Stopped keyword (type 1)
    #    2 % Multi-line stack trace (type 3)
    #    2 % JSON payload (type 1)
    #    1 % XML-escape stress (type 1)
    #    1 % Plain (non-CMTrace) line
    #    1 % Very long message (type 1)

    if ($roll -lt 0.50) {
        # --- Info ---
        $msg = Get-RandomItem $infoMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.65) {
        # --- Warning ---
        $msg = Get-RandomItem $warningMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 2 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.75) {
        # --- Error ---
        $msg = Get-RandomItem $errorMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 3 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.80) {
        # --- Fatal / Critical ---
        $msg = Get-RandomItem $fatalMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 3 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.85) {
        # --- Verbose / Debug / Trace ---
        $msg = Get-RandomItem $verboseDebugMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.90) {
        # --- Success / Audit ---
        $msg = Get-RandomItem $successAuditMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.93) {
        # --- Stopped ---
        $msg = Get-RandomItem $stoppedMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.95) {
        # --- Multi-line stack trace ---
        # The message itself contains newlines; the CMTrace entry is one
        # logical line but the raw text spans multiple lines, which tests
        # the multi-line accumulation logic in the background reader.
        $trace = Get-RandomItem $stackTraces
        $msg   = "Unhandled exception caught:`r`n$trace"
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 3 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.97) {
        # --- JSON payload ---
        $json = Get-RandomItem $jsonPayloads
        $msg  = "Policy evaluation result: $json"
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.98) {
        # --- XML-escape stress ---
        $msg = Get-RandomItem $xmlEscapeMessages
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
    elseif ($roll -lt 0.99) {
        # --- Plain (non-CMTrace) line ---
        # Tests the fallback parser path that handles lines without the
        # <![LOG[ prefix.
        $plainLines = @(
            "=== Non-CMTrace plain text line: service restart at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
            "----------- Configuration dump -----------"
            "PLAIN: Error detected in legacy subsystem — no CMTrace wrapper available."
            "PLAIN: Warning — disk I/O latency exceeded 50 ms threshold."
            "PLAIN: Info — scheduled maintenance completed."
        )
        $plain = Get-RandomItem $plainLines
        $writer.WriteLine($plain)
        return 1
    }
    else {
        # --- Very long message (stress MaxLineLength) ---
        $padding = 'A' * ($rng.Next(5000, 20000))
        $msg     = "Long message stress test (length=$($padding.Length)): $padding"
        $writer.WriteLine((Format-CMTraceEntry -Message $msg -Type 1 -Component $component))
        return 1
    }
}

# ---------------------------------------------------------------------------
# Main generation loop.
# ---------------------------------------------------------------------------
Write-Host "CMTrace Test Log Generator" -ForegroundColor Cyan
Write-Host "  Output : $Path" -ForegroundColor Gray
Write-Host "  Rate   : ~$([int](1000 / $IntervalMs)) entries/s (base)" -ForegroundColor Gray
Write-Host "  Burst  : $([int]($BurstChance * 100)) % chance per tick" -ForegroundColor Gray
if ($MaxEntries -gt 0) {
    Write-Host "  Limit  : $MaxEntries entries" -ForegroundColor Gray
} else {
    Write-Host "  Limit  : unlimited (Ctrl+C to stop)" -ForegroundColor Gray
}
Write-Host ""

$totalEntries  = 0
$startTime     = Get-Date
$lastStatusTime = $startTime

try {
    while ($true) {
        # Check entry limit.
        if ($MaxEntries -gt 0 -and $totalEntries -ge $MaxEntries) {
            Write-Host "`nReached maximum entry count ($MaxEntries). Stopping." -ForegroundColor Yellow
            break
        }

        # Decide whether this tick is a burst.
        if ($rng.NextDouble() -lt $BurstChance) {
            $burstSize = $rng.Next(20, 81)
            for ($b = 0; $b -lt $burstSize; $b++) {
                if ($MaxEntries -gt 0 -and $totalEntries -ge $MaxEntries) { break }
                $totalEntries += Write-LogEntry
            }
        } else {
            $totalEntries += Write-LogEntry
        }

        # Periodic status update to the console (every 5 seconds).
        $now = Get-Date
        if (($now - $lastStatusTime).TotalSeconds -ge 5) {
            $elapsed = ($now - $startTime).TotalSeconds
            $rate    = if ($elapsed -gt 0) { [Math]::Round($totalEntries / $elapsed, 1) } else { 0 }
            $fileSize = if (Test-Path $Path) {
                $bytes = (Get-Item $Path).Length
                if     ($bytes -ge 1MB) { "{0:N1} MB" -f ($bytes / 1MB) }
                elseif ($bytes -ge 1KB) { "{0:N1} KB" -f ($bytes / 1KB) }
                else                    { "$bytes B" }
            } else { "N/A" }
            Write-Host "`r  Entries: $totalEntries | Rate: $rate/s | File: $fileSize    " -NoNewline -ForegroundColor Green
            $lastStatusTime = $now
        }

        # Randomised delay: ±50 % of IntervalMs.
        $jitter  = [int]($IntervalMs * 0.5)
        $delayMs = $IntervalMs + $rng.Next(-$jitter, $jitter + 1)
        if ($delayMs -lt 10) { $delayMs = 10 }
        Start-Sleep -Milliseconds $delayMs
    }
} catch {
    # Ctrl+C raises a PipelineStoppedException — treat it as a clean exit.
    if ($_.Exception -isnot [System.Management.Automation.PipelineStoppedException]) {
        Write-Host "`nError: $_" -ForegroundColor Red
    }
} finally {
    # Clean up the writer and stream.
    if ($null -ne $writer) {
        try { $writer.Flush() } catch {}
        try { $writer.Dispose() } catch {}
    }
    if ($null -ne $stream) {
        try { $stream.Dispose() } catch {}
    }

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    $rate    = if ($elapsed -gt 0) { [Math]::Round($totalEntries / $elapsed, 1) } else { 0 }
    Write-Host ""
    Write-Host ""
    Write-Host "Generation complete." -ForegroundColor Cyan
    Write-Host "  Total entries : $totalEntries" -ForegroundColor Gray
    Write-Host "  Elapsed       : $([Math]::Round($elapsed, 1)) seconds" -ForegroundColor Gray
    Write-Host "  Average rate  : $rate entries/s" -ForegroundColor Gray
    Write-Host "  File          : $Path" -ForegroundColor Gray
}

