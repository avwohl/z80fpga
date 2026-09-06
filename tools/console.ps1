# A minimal serial terminal, so the board can be talked to without installing
# anything.
#
#   powershell -ExecutionPolicy Bypass -File tools/console.ps1
#   powershell -ExecutionPolicy Bypass -File tools/console.ps1 -Port COM4 -Baud 9600
#
# Ctrl+] quits.
#
# This is deliberately simple: it forwards keystrokes and prints what comes
# back, and that is all. It is enough for the RomWBW boot loader and the CP/M
# command line. It is *not* a VT100, so full-screen programs -- WordStar, ZDE,
# Zork's status line -- will not draw properly. Install PuTTY or Tera Term for
# those; see the README.
#
# Only one program can hold a COM port at a time, so close this before running
# anything else that opens the port, and vice versa.

param(
    [string]$Port = "COM3",
    [int]$Baud = 115200
)

$ErrorActionPreference = "Stop"

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$sp.Handshake = "None"
$sp.DtrEnable = $true
$sp.RtsEnable = $true
$sp.ReadTimeout = 50

try {
    $sp.Open()
} catch {
    Write-Host "Could not open $Port : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Something else may already have it open." -ForegroundColor Red
    exit 1
}

Write-Host "--- $Port at $Baud 8N1. Ctrl+] quits. ---" -ForegroundColor Cyan

try {
    while ($true) {
        # anything from the board
        try {
            $in = $sp.ReadExisting()
            if ($in.Length -gt 0) { [Console]::Write($in) }
        } catch [TimeoutException] { }

        # anything from the keyboard
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            # Ctrl+] is 0x1D
            if ($k.KeyChar -eq [char]29) {
                Write-Host "`n--- closed ---" -ForegroundColor Cyan
                $sp.Close()
                exit 0
            }
            if ($k.Key -eq "Enter") {
                $sp.Write("`r")          # CP/M wants CR, not CRLF
            } elseif ($k.KeyChar -ne "`0") {
                $sp.Write([string]$k.KeyChar)
            }
        }

        Start-Sleep -Milliseconds 15
    }
} finally {
    if ($sp.IsOpen) { $sp.Close() }
}
