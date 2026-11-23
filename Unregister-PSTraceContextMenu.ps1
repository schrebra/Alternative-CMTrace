<#
.SYNOPSIS
    Removes the PSTrace Explorer integration added by
    Register-PSTraceContextMenu.ps1.

.DESCRIPTION
    Deletes, under HKEY_CURRENT_USER\Software\Classes:
      * the "Open with PSTrace" context menu entry for all files
      * the PSTrace.LogFile progid
      * the PSTrace entry in the .log "Open with" list
      * the .log default association, but only when it currently points
        at PSTrace.LogFile (a default the user changed afterwards is
        left alone)
    Per user only; no administrator rights are needed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$classes = 'HKCU:\Software\Classes'

$verb = Join-Path $classes '*\shell\OpenWithPSTrace'
if (Test-Path -LiteralPath $verb) {
    Remove-Item -LiteralPath $verb -Recurse -Force
    Write-Host 'Removed Explorer context menu entry: *\shell\OpenWithPSTrace'
}

$progId = Join-Path $classes 'PSTrace.LogFile'
if (Test-Path -LiteralPath $progId) {
    Remove-Item -LiteralPath $progId -Recurse -Force
    Write-Host 'Removed progid PSTrace.LogFile'
}

$openWith = Join-Path $classes '.log\OpenWithProgids'
if (Test-Path -LiteralPath $openWith) {
    Remove-ItemProperty -LiteralPath $openWith -Name 'PSTrace.LogFile' -ErrorAction SilentlyContinue
    Write-Host 'Removed PSTrace from the .log "Open with" list.'
}

$logKey = Join-Path $classes '.log'
if (Test-Path -LiteralPath $logKey) {
    $current = (Get-Item -LiteralPath $logKey).GetValue('')
    if ($current -eq 'PSTrace.LogFile') {
        Remove-ItemProperty -LiteralPath $logKey -Name '(Default)' -ErrorAction SilentlyContinue
        Write-Host 'Removed the .log default association to PSTrace.'
    }
}

Write-Host ''
Write-Host 'PSTrace Explorer integration removed for the current user.'
