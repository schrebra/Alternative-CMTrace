<#
.SYNOPSIS
    Registers PSTrace in the Windows Explorer right-click menu (per user).

.DESCRIPTION
    Adds an "Open with PSTrace" entry to the Explorer context menu for
    every file, plus an "Open with" progid for .log files, under
    HKEY_CURRENT_USER\Software\Classes. No administrator rights are
    needed and nothing outside the current user's registry hive is
    touched. The registered command is:

        "<path to PSTrace.exe>" "%1"

    so Explorer hands the clicked file to PSTrace as a command-line
    argument, and PSTrace opens it on launch. The same argument path is
    what makes dropping a file onto the PSTrace shortcut or executable
    icon work.

    Run Unregister-PSTraceContextMenu.ps1 to remove everything this
    script adds.

.PARAMETER ExePath
    Full path to the published PSTrace.exe. Defaults to the bootstrap
    publish output next to this script:
    <script folder>\PSTrace\publish\PSTrace.exe
    If that does not exist yet, the src project publish output is used:
    <script folder>\src\PSTrace\publish\PSTrace.exe

.PARAMETER SetAsDefaultForLog
    Also make PSTrace the default program for .log files (double-click
    opens PSTrace). Off by default: without it, .log files only gain
    PSTrace in their "Open with" list and the right-click entry that
    this script adds to all files.

.EXAMPLE
    .\Register-PSTraceContextMenu.ps1
    .\Register-PSTraceContextMenu.ps1 -ExePath 'C:\Tools\PSTrace\PSTrace.exe' -SetAsDefaultForLog
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [switch]$SetAsDefaultForLog
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $candidates = @(
        (Join-Path (Join-Path $PSScriptRoot 'PSTrace') 'publish\PSTrace.exe'),
        (Join-Path (Join-Path (Join-Path $PSScriptRoot 'src') 'PSTrace') 'publish\PSTrace.exe')
    )
    $ExePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $ExePath) {
        throw "PSTrace executable not found. Build it first (run PSTrace.ps1) or pass -ExePath with the full path to PSTrace.exe. Looked in: $($candidates -join '; ')"
    }
}
elseif (-not (Test-Path -LiteralPath $ExePath)) {
    throw "PSTrace executable not found at '$ExePath'. Build it first (run PSTrace.ps1) or pass -ExePath with the full path to PSTrace.exe."
}
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$command = "`"$ExePath`" `"%1`""
$classes = 'HKCU:\Software\Classes'

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    if ($Name -eq '(Default)') {
        Set-Item -LiteralPath $Path -Value $Value
    } else {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
}

# 1. ProgID describing a PSTrace-openable log file.
$progId = Join-Path $classes 'PSTrace.LogFile'
Set-RegValue -Path $progId -Name '(Default)' -Value 'PSTrace Log File'
Set-RegValue -Path (Join-Path $progId 'DefaultIcon') -Name '(Default)' -Value "`"$ExePath`",0"
Set-RegValue -Path (Join-Path $progId 'shell\open\command') -Name '(Default)' -Value $command
Write-Host "Registered progid PSTrace.LogFile -> $command"

# 2. "Open with PSTrace" on the context menu of every file.
$verb = Join-Path $classes '*\shell\OpenWithPSTrace'
Set-RegValue -Path $verb -Name '(Default)' -Value 'Open with PSTrace'
Set-RegValue -Path $verb -Name 'Icon' -Value "`"$ExePath`",0"
Set-RegValue -Path (Join-Path $verb 'command') -Name '(Default)' -Value $command
Write-Host 'Registered Explorer context menu entry: *\shell\OpenWithPSTrace (Open with PSTrace)'

# 3. Offer PSTrace in the "Open with" list for .log files without
#    changing the current default program.
$openWith = Join-Path $classes '.log\OpenWithProgids'
if (-not (Test-Path -LiteralPath $openWith)) { New-Item -Path $openWith -Force | Out-Null }
New-ItemProperty -LiteralPath $openWith -Name 'PSTrace.LogFile' -Value '' -PropertyType String -Force | Out-Null
Write-Host 'Added PSTrace to the .log "Open with" list.'

# 4. Optional: make PSTrace the default handler for .log files.
if ($SetAsDefaultForLog) {
    Set-RegValue -Path (Join-Path $classes '.log') -Name '(Default)' -Value 'PSTrace.LogFile'
    Write-Host 'Set PSTrace as the default program for .log files.'
}

Write-Host ''
Write-Host 'Done. Right-click any file in Explorer and choose "Open with PSTrace".'
Write-Host 'To remove everything again, run Unregister-PSTraceContextMenu.ps1.'
