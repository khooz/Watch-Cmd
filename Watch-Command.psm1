# Watch-Cmd.psm1
# PowerShell drop-in for Linux’s watch(1)

# ------------------------------------------------------------
# 1. C# P/Invoke Helper in a valid namespace: WatchCommand
# ------------------------------------------------------------
$code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace WatchCommand {

  [StructLayout(LayoutKind.Sequential)]
  public static class VT {

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD {
      public short X;
      public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT {
      public short Left;
      public short Top;
      public short Right;
      public short Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO {
      public COORD dwSize;
      public COORD dwCursorPosition;
      public short wAttributes;
      public SMALL_RECT srWindow;
      public COORD dwMaximumWindowSize;
    }

    private const int STD_OUTPUT_HANDLE = -11;
    private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);
    
    public static void Enable() {
      var handle = GetStdHandle(STD_OUTPUT_HANDLE);
      if (GetConsoleMode(handle, out uint mode)) {
        SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        Console.OutputEncoding = Encoding.UTF8;
      }
    }

    public static CONSOLE_SCREEN_BUFFER_INFO GetScreenBufferInfo() {
      var handle = GetStdHandle(STD_OUTPUT_HANDLE);
      CONSOLE_SCREEN_BUFFER_INFO bufferInfo;
      if (GetConsoleScreenBufferInfo(handle, out bufferInfo)) {
        return bufferInfo;
      } else {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      }
    }
  }
}
'@

# Only compile once per session
if (-not ([type]::GetType("WatchCommand.VT", $false))) {
    Add-Type -TypeDefinition $code -Language CSharp
}

# Expose a simple wrapper
function Enable-AnsiColor {
<#
.SYNOPSIS
  Enables ANSI color support in the console.

.DESCRIPTION
  This function uses P/Invoke to enable virtual terminal processing
  in the console, allowing for ANSI escape codes to be interpreted
  correctly, enabling color and other text formatting.

.EXAMPLE
  Import-Module Watch-Cmd
  Enable-AnsiColor
#>
  [WatchCommand.VT]::Enable()
}

# Strip ANSI escapes helper
function Remove-AnsiEscapes {
<#
.SYNOPSIS
  Removes ANSI escape sequences from a string.

.DESCRIPTION
  This function takes a string and removes any ANSI escape sequences,
  which are used for terminal text formatting like colors.
  Remove-AnsiEscapes TEXT
.EXAMPLE
  Import-Module Watch-Cmd
  Remove-AnsiEscapes "Hello `e[31mWorld`e[0m"
#>
  param([string]$Text)
  return $Text -replace "`e\[[\d;]*[A-Za-z]", ''
}

function Colorize {
<#
.SYNOPSIS
  Colorizes text using ANSI escape codes.
.DESCRIPTION
  This function takes a string and a color name, returning the string
  wrapped in ANSI escape codes for the specified color.
  Colorize COLOR TEXT
.EXAMPLE
  Import-Module Watch-Cmd
  Colorize Green "Hello World"
#>
  param(
    [string]$Color = 'White',
    [string]$Text
  )
  # ANSI 8-color mapping
  $colorCode = @{
    Black   = 30; Red = 31; Green = 32; Yellow = 33;
    Blue    = 34; Magenta = 35; Cyan = 36; White = 37;
    Reset   =0;
  }[$Color]
  if (-not $colorCode) {
    Write-Error "Invalid color: $Color"
    return $Text
  } else {
    return "`e[${colorCode}m$Text`e[0m"
  }
}

function Invoke-ScrollClear {
<#
.SYNOPSIS
  Clears the console screen and scrolls up to the top.
.DESCRIPTION
  This function clears the console screen and scrolls up to the top,
  effectively resetting the view without clearing the entire console.
  It is useful for refreshing the display in a way that mimics the
  behavior of Linux's watch command.
.EXAMPLE
  Import-Module Watch-Cmd
  Invoke-ScrollClear
#>
    # grab host cursor positions
    $bufferInfo = [WatchCommand.VT]::GetScreenBufferInfo()
    $cursor    = $bufferInfo.dwCursorPosition
    
    # write new-line Y times to add space to buffer
    # scroll up so that current row moves to the top
    # Y is calculated after linefeed to the terminal
    # so no index increment
    [Console]::Write("`n" * $cursor.Y)
    if ($rowInView -gt 1) {
        $scrollCount = $rowInView
        [Console]::Write("`e[${scrollCount}T")
    }
    # move cursor to top-left of viewport
    [Console]::Write("`e[1;1H")

    # # clear all lines from cursor downward
    [Console]::Write("`e[J")
}


function Watch-Command {
<#
.SYNOPSIS
  Periodically runs a command and displays its output fullscreen,
  faithfully reproducing Linux’s watch(1) CLI, flags, and behaviors.

.DESCRIPTION
  See watch(1) man-page.
  The main difference is in `-p, --precise` flag, which is always ON
  to implement early key handling and rerun on resize.
  Flags (short & long):
    -b, --beep
    -c, --color
    -C, --no-color
    -d, --differences[=permanent]
    -e, --errexit
    -g, --chgexit
    -n, --interval SECONDS
    -p, --precise
    -q, --equexit <cycles>
    -r, --no-rerun
    -s, --shotsdir <dir>
    -t, --no-title
    -w, --no-wrap
    -x, --exec
    -h, --help
    -v, --version

  Key Controls:
    Space   – refresh immediately
    Q       – quit (exit 0)
    S       – save “screenshot” under shotsdir
    Ctrl+C  – force quit

.EXAMPLE
  Import-Module Watch-Cmd
  watch -n1 -d=permanent -- Get-Process

#>
  #-----------------------------------------------------------------
  # 1. Parse raw $args exactly like Linux’s POSIX parser
  #-----------------------------------------------------------------
  $rawArgs = [System.Collections.Generic.List[string]]::new()
  $args | ForEach-Object { $rawArgs.Add($_) }

  # Default settings
  $Beep            = $false;   $Color       = $false;
  $NoColor         = $false;   $Differences = $false;
  $PermDiff        = $false;   $ErrExit     = $false;
  $ChgExit         = $false;   # $Precise     = $false; It's always precise to provide rerun and early key handling
  $NoRerun         = $false;   $NoTitle     = $false;
  $NoWrap          = $false;   $Exec        = $false;
  $VersionFlag     = $false;   $HelpFlag    = $false;
  $ShotsDir        = $null;    $EquExit      = $null;
  $Interval        = $env:WATCH_INTERVAL ? [double]$env:WATCH_INTERVAL : 2.0;

  # Clamps a value to range [100, 2678400000] (1.0s to 31 days) for sleeping
  function Clamp($v) {
    if ($v -lt 100)   { return 100 }
    if ($v -gt 2678400000) { return 2678400000 }
    return $v
  }

  # Truncates lines to fit within the terminal width
  function NoWrap($l) {
    $w = $env:COLUMNS ? [int]$env:COLUMNS : [Console]::WindowWidth
    $l = $l | ForEach-Object {
      if ($_.Length -gt $w) { $_.Substring(0, $w) } else { $_ }
    }
    return $l
  }
  
  # Flag loop
  :argparse for ($i = 0; $i -lt $rawArgs.Count; $i++) {
    $a = $rawArgs[$i]
    switch -Wildcard ($a) {
      '-h'              { $HelpFlag     = $true; break; }
      '--help'          { $HelpFlag     = $true; break; }
      '-v'              { $VersionFlag  = $true; break; }
      '--version'       { $VersionFlag  = $true; break; }
      '-b'              { $Beep         = $true; break; }
      '--beep'          { $Beep         = $true; break; }
      '-c'              { $Color        = $true; break; }
      '--color'         { $Color        = $true; break; }
      '-C'              { $NoColor      = $true; break; }
      '--no-color'      { $NoColor      = $true; break; }
      '-d'              { $Differences  = $true; break; }
      '-e'              { $ErrExit      = $true; break; }
      '--errexit'       { $ErrExit      = $true; break; }
      '-g'              { $ChgExit      = $true; break; }
      '--chgexit'       { $ChgExit      = $true; break; }
      '-p'              { <#$Precise      = $true;#> break; } # Dummy for compatibility
      '--precise'       { <#$Precise      = $true;#> break; } # Dummy for compatibility
      '-r'              { $NoRerun      = $true; break; }
      '--no-rerun'      { $NoRerun      = $true; break; }
      '-t'              { $NoTitle      = $true; break; }
      '--no-title'      { $NoTitle      = $true; break; }
      '-w'              { $NoWrap       = $true; break; }
      '--no-wrap'       { $NoWrap       = $true; break; }
      '-x'              { $Exec         = $true; break; }
      '--exec'          { $Exec         = $true; break; }
      '-d'              { $Differences  = $true; break; }
      '--differences'   { $Differences  = $true; break; }
      '-d=*'            {
        $Differences = $true;
        if ($a.Split('=',2)[1].ToLower() -eq 'permanent') { $PermDiff = $true; }
        break;
      }
      '--differences=*' {
        $Differences = $true;
        if ($a.Split('=',2)[1].ToLower() -eq 'permanent') { $PermDiff = $true; }
        break;
      }
      '-n'              {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing interval'; exit 1; }
        $Interval = Clamp([double]$rawArgs[++$i]); break;
      }
      '--interval'      {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing interval'; exit 1; }
        $Interval = Clamp([double]$rawArgs[++$i]); break;
      }
      '-n=*'            { $Interval = Clamp([double]$a.Split('=',2)[1]); break; }
      '--interval=*'    { $Interval = Clamp([double]$a.Split('=',2)[1]); break; }
      '-q'              {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing cycles'; exit 1; }
        $EquExit = [int]$rawArgs[++$i]; break;
      }
      '--equexit'       {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing cycles'; exit 1; }
        $EquExit = [int]$rawArgs[++$i]; break;
      }
      '-q=*'            { $EquExit = [int]$a.Split('=',2)[1]; break; }
      '--equexit=*'     { $EquExit = [int]$a.Split('=',2)[1]; break; }
      '-s'              {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing dir'; exit 1; }
        $ShotsDir = $rawArgs[++$i]; break;
      }
      '--shotsdir'      {
        if ($i+1 -ge $rawArgs.Count) { Write-Error 'Missing dir'; exit 1; }
        $ShotsDir = $rawArgs[++$i]; break;
      }
      default           { break argparse }
    }
  }
  
  # Remaining args form the command
  $Command = if ($i -lt $rawArgs.Count) { $rawArgs[$i..($rawArgs.Count-1)] } else { @() }
  
  if ($Color)    {
    Enable-AnsiColor
  }

  if ($HelpFlag) {
    # We'll just print the function help block
    Get-Help Watch-Cmd -Full
    return
  }

  if ($VersionFlag) {
    Write-Output "Watch-Cmd version 1.0.0"
    return
  }

  if (-not $Command.Count) {
    Write-Error "No command specified. Usage: watch [options] command"
    return
  }

  # Ensure shots directory exists
  if ($ShotsDir -and -not (Test-Path $ShotsDir)) {
    New-Item -ItemType Directory -Path $ShotsDir | Out-Null
  }

  #-----------------------------------------------------------------
  # 2. Main loop state
  #-----------------------------------------------------------------
  $prevLines     = @()    # previous output lines
  $baseLines     = @()    # base lines for permanent diff
  $stableCount   = 0      # stable run count
  $lastStart     = $null  # last run start time
  $screenHeader  = ''     # header for the screen
  $currentLines  = @()    # current output lines
  $lines         = @()    # output lines
  $STEP          = 100    # sleep step in ms

  # Invokes a process and returns its exit code and output
  function Invoke-Process {
    param($argsArr)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    if ($Exec) {
      $psi.FileName  = $argsArr[0]
      $psi.Arguments = ($argsArr[1..($argsArr.Length-1)] -join ' ')
    }
    else {
      $psi.FileName  = 'cmd.exe'
      $psi.Arguments = '/c ' + ($argsArr -join ' ')
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $p.ExitCode, ($out + ($err ? "`n$err" : ""))
  }

  # Set up console for continues output
  [Console]::CursorVisible = $false
  Invoke-ScrollClear
  $lastWidth  = [Console]::WindowWidth
  $lastHeight = [Console]::WindowHeight

  # Main loop
  :runloop while ($true) {
    # Smooth sleeping loop
    :sleeping while ($null -ne $lastStart) {
      # Determine how long to wait (in ms) until the *next* scheduled run
      # then wakeup if the time has come ($waitTime -lt 0)
      $waitTime = (($Interval * 1000) - ($(Get-Date) - $lastStart).TotalMilliseconds)
      if ($waitTime -lt 0) { $in++; break sleeping }
      # Check for resize
      if ( (-not $NoRerun) -and (([Console]::WindowWidth -ne $lastWidth) -or ([Console]::WindowHeight -ne $lastHeight))) {
        # Size changed and no-rerun is OFF → break to rerun immediately
        $lastWidth  = [Console]::WindowWidth
        $lastHeight = [Console]::WindowHeight
        break sleeping
      }
      # Key handling (Space/Q/S) on-the-fly
      :keycheck while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
          'Spacebar' { break sleeping }
          'Q'        { return }
          'S' {
            if ($ShotsDir) {
              $ts   = (Get-Date).ToString('yyyyMMdd_HHmmss')
              $file = Join-Path $ShotsDir "watch_$ts.txt"
              ($screenHeader + "`n" + ($currentLines -join "`n")) |
                Out-File -FilePath $file -Encoding UTF8
            }
            break keycheck
          }
        }
      }
      # Sleep in small chunks so we can detect resize & keypress
      Start-Sleep -Milliseconds $STEP
    }
    
    # Run
    $lastStart = Get-Date
    $runStart = Get-Date
    $exitCode, $raw = Invoke-Process -argsArr $Command
    
    # Prepare output lines from command invocation
    $lines = $raw -split "`r?`n"
    $screenHeader = "Every $([math]::Floor($Interval * 1000))ms: $($Command -join ' ')    Started: $(Get-Date -Format u)    Elapsed: $([math]::Floor(((Get-Date) - $runStart).TotalMilliseconds))ms    Exit: $exitCode"
    $screenSeparator = '─' * $screenHeader.Length
    
    # Truncate instead of wrap
    if ($NoWrap) {
      $lines = NoWrap $lines
      $screenHeader, $screenSeparator = NoWrap $screenHeader, $screenSeparator
    }

    # Clear the console for a fresh display
    [Console]::Write("`e[H`e[J")



    # Header
    if (-not $NoTitle) {
      [Console]::WriteLine($NoColor ? $screenHeader : (Colorize Cyan $screenHeader))
      [Console]::WriteLine($NoColor ? $screenSeparator : (Colorize Cyan $screenSeparator))
    }

    # Diffs
    if ($Differences) {
      if (-not $baseLines.Count) { $baseLines = $lines }
      $ref = $PermDiff ? $baseLines : $prevLines
      Compare-Object -ReferenceObject $ref -DifferenceObject $lines -PassThru |
        ForEach-Object {
          $line, $colorName = $_.SideIndicator -eq '=>' ? "+ $($_.InputObject)", "Green" : ($_.SideIndicator -eq '<=' ? "- $($_.InputObject)", "Red" : "$($_.InputObject)", "Reset")
          $line = $NoWrap ? (NoWrap "$($line)$($_.InputObject)") : "$($line)$($_.InputObject)"
          [Console]::WriteLine($NoColor ? $line : (Colorize $colorName $line))
        }
    }
    # Normal
    else {
      $lines | ForEach-Object {
        $NoColor ? [Console]::WriteLine((Remove-AnsiEscapes $_)) : [Console]::WriteLine($_)
      }
    }

    # Exit on visible change
    if ($ChgExit -and $prevLines -ne $lines) { return }

    # Exit after stable cycles
    if ($EquExit) {
      if ($prevLines -eq $lines) { $stableCount++ }
      else { $stableCount = 0 }
      if ($stableCount -ge $EquExit) { return }
    }

    # Errexit
    if ($ErrExit -and $exitCode -ne 0) {
      [Console]::WriteLine("`n`e[33mCommand failed exit($exitCode). Press any key to quit…`e[0m")
      [Console]::ReadKey($true) | Out-Null
      return
    }

    # Beep
    if ($Beep -and $exitCode -ne 0) {
      [Console]::Beep(750,200)
    }

    # Save for next iteration
    $prevLines    = $lines
    $currentLines = $lines

    # Clear rest of console
    [Console]::Write("`e[J")
  }
}

Export-ModuleMember -Function Watch-Command, Enable-AnsiColor, Remove-AnsiEscapes, Colorize, Invoke-ScrollClear
Set-Alias -Name watch -Value Watch-Command -Scope Global
Set-Alias -Name w -Value Watch-Command -Scope Global