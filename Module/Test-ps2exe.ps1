#Requires -Version 5.1
<#
.SYNOPSIS
Test suite for Invoke-ps2exe (ps2exe.ps1).
.DESCRIPTION
Creates simple test scripts in a temporary folder under %TEMP%, compiles them to
executables with different parameter combinations (PS 5.1 host mode and PS7 stub
mode) and checks compilation success plus runtime behavior of the generated exes.
Covers script variations (param block, using statements, comment-based help,
non-ASCII output, BOM-less UTF8) and almost all Invoke-ps2exe parameters.
On success the working folder is removed, on failure it is kept for inspection.
.PARAMETER NoCleanup
Keep the working folder under %TEMP% even when all tests pass.
.NOTES
Run under Windows PowerShell 5.1 (the script relaunches itself when started in
PowerShell 7). PS7 runtime tests are skipped when pwsh.exe is not installed.
Freshly compiled executables may be blocked or slowed down by antivirus software.

Version: 0.1
Date: 2026.09.16
Author: Andrew Afanasiev
#>
param([switch]$NoCleanup)

# --- relaunch under Windows PowerShell 5.1 when started in PowerShell 7 ---
if ($PSVersionTable.PSEdition -eq 'Core')
{
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($NoCleanup) { $relaunchArgs += '-NoCleanup' }
    & powershell.exe @relaunchArgs
    exit $LASTEXITCODE
}

 $ScriptDir = $PSScriptRoot
 $Ps2exeScript = Join-Path $ScriptDir 'ps2exe.ps1'
if (!(Test-Path -LiteralPath $Ps2exeScript -PathType Leaf))
{
    Write-Error "ps2exe.ps1 not found in the script directory ($ScriptDir)"
    exit 1
}
try { . $Ps2exeScript } catch {
    Write-Error "Failed to load ps2exe.ps1: $($_.Exception.Message)"
    exit 1
}

# --- locate pwsh.exe for PS7 runtime tests (compilation works without it) ---
 $pwshCandidates = @(
    (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.Source }),
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
)
 $PwshExe = $pwshCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
 $PwshFound = [bool]$PwshExe

 $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("PS2EXE_TEST_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
 $env:PS2EXE_TEST = $WorkDir

 $Results = New-Object System.Collections.Generic.List[object]
 $Tests = @()

function Write-TestScript {
    # write a test script as UTF8, with BOM unless -NoBom is given
    param([string]$Path, [string]$Content, [switch]$NoBom)
    $encoding = New-Object System.Text.UTF8Encoding(!$NoBom)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-TestParams {
    # build the parameter hashtable for one Invoke-ps2exe call
    param([string]$Script, [string]$ExeName, [hashtable]$Extra = @{})
    $p = @{ inputFile = $Script; outputFile = (Join-Path $WorkDir ($ExeName + '.exe')) }
    foreach ($key in $Extra.Keys) { $p[$key] = $Extra[$key] }
    $p
}

function New-TestIcon {
    # create a small valid .ico file using System.Drawing
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.Clear([System.Drawing.Color]::SteelBlue)
    $graphics.Dispose()
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $stream = [System.IO.File]::Create($Path)
    $icon.Save($stream)
    $stream.Close()
    $icon.Dispose()
    $bmp.Dispose()
}

function Invoke-CompileTest {
    # compile one test exe, capture all output streams and return success + log
    param([hashtable]$Params)
    $exe = [string]$Params['outputFile']
    foreach ($file in @($exe, "$exe.config", "$exe.win32manifest")) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    $log = New-Object System.Collections.Generic.List[string]
    try {
        $streamData = Invoke-ps2exe @Params -Verbose *>&1
        foreach ($item in @($streamData)) { $log.Add([string]$item) }
    } catch {
        $log.Add("EXCEPTION: $($_.Exception.Message)")
    }
    @{ Ok = (Test-Path -LiteralPath $exe -PathType Leaf); Log = ($log -join "`n") }
}

function Invoke-ConsoleExe {
    # run a console exe, capture merged stdout/stderr and the exit code
    param([string]$Exe, [string[]]$ExeArgs = @())
    $output = & $Exe @ExeArgs 2>&1
    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    @{ Text = $text; Code = $LASTEXITCODE }
}

function Invoke-GuiExe {
    # run a GUI (winexe) exe and wait for its exit code with a timeout
    param([string]$Exe, [int]$TimeoutSec = 120)
    $p = Start-Process -FilePath $Exe -PassThru -WindowStyle Hidden
    if (!$p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill()
        @{ Text = ''; Code = $null; Timeout = $true }
    } else {
        @{ Text = ''; Code = $p.ExitCode }
    }
}

function Invoke-StdinExe {
    # run a console exe with redirected stdin/stdout (writes the given lines,
    # then closes stdin); used for $input tests and -wait tests
    param([string]$Exe, [string[]]$ExeArgs = @(), [string[]]$InputLines = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ExeArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    foreach ($line in $InputLines) { $p.StandardInput.WriteLine($line) }
    $p.StandardInput.Close()
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    @{ Text = $text; Code = $p.ExitCode }
}

function Invoke-UnicodeExe {
    # run a console exe compiled with -UNICODEEncoding and decode stdout as UTF-16
    param([string]$Exe)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    @{ Text = $text; Code = $p.ExitCode }
}

function Test-RuntimeResult {
    # evaluate the runtime expectations of a test against a run result
    param([hashtable]$Result, [hashtable]$Test)
    $fails = @()
    if ($Result.ContainsKey('Timeout') -and $Result.Timeout) {
        $fails += 'exe did not exit within the timeout (blocked message box or deadlock)'
    }
    if ($Test.ContainsKey('ExpectCode') -and $Result.Code -ne $Test.ExpectCode) {
        $fails += "exit code is $($Result.Code), expected $($Test.ExpectCode)"
    }
    $text = [string]$Result.Text
    if ($Test.ContainsKey('ExpectText') -and !$text.Contains([string]$Test.ExpectText)) {
        $fails += "output does not contain '$($Test.ExpectText)'"
    }
    if ($Test.ContainsKey('ExpectNoText') -and $text.Contains([string]$Test.ExpectNoText)) {
        $fails += "output unexpectedly contains '$($Test.ExpectNoText)'"
    }
    $fails
}

function Complete-RunTest {
    # record the result of a runtime test
    param([hashtable]$Test, [hashtable]$Result)
    $fails = @(Test-RuntimeResult -Result $Result -Test $Test)
    if ($fails.Count -eq 0) {
        Add-TestResult -Id $Test.Id -Name $Test.Name -Status 'PASS'
    } else {
        $details = $fails -join '; '
        $out = [string]$Result.Text
        if ($out.Length -gt 400) { $out = $out.Substring(0, 400) + '...' }
        $details += "`nexit code: $($Result.Code)"
        if ($out) { $details += "`noutput: $out" }
        Add-TestResult -Id $Test.Id -Name $Test.Name -Status 'FAIL' -Details $details
    }
}

function Add-TestResult {
    # store and print one test result
    param([string]$Id, [string]$Name, [string]$Status, [string]$Details = '')
    $Results.Add([pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Details = $Details })
    switch ($Status) {
        'PASS' { Write-Host ("  [PASS] {0}: {1}" -f $Id, $Name) -ForegroundColor Green }
        'SKIP' { Write-Host ("  [SKIP] {0}: {1} -- {2}" -f $Id, $Name, $Details) -ForegroundColor Yellow }
        default {
            Write-Host ("  [FAIL] {0}: {1}" -f $Id, $Name) -ForegroundColor Red
            if ($Details) {
                $d = $Details -replace "`r?`n", ' | '
                if ($d.Length -gt 600) { $d = $d.Substring(0, 600) + '...' }
                Write-Host "         $d" -ForegroundColor DarkRed
            }
        }
    }
}

function Test-ConfigContent {
    # check that the .config file of an exe exists and contains a string
    param([string]$Exe, [string]$Expected)
    $cfg = "$Exe.config"
    if (!(Test-Path -LiteralPath $cfg -PathType Leaf)) { @{ Ok = $false; Details = "config file missing: $cfg" } }
    else {
        $content = [string](Get-Content -LiteralPath $cfg -Raw)
        @{ Ok = $content.Contains($Expected); Details = "config content: $content" }
    }
}

# --- create the test scripts and helper files ---
 $basic       = Join-Path $WorkDir 'basic.ps1'
 $paramScript = Join-Path $WorkDir 'param_basic.ps1'
 $usingOnly   = Join-Path $WorkDir 'using_only.ps1'
 $usingParam  = Join-Path $WorkDir 'using_param.ps1'
 $helpScript  = Join-Path $WorkDir 'help_script.ps1'
 $exitScript  = Join-Path $WorkDir 'exitcode.ps1'
 $guiExit     = Join-Path $WorkDir 'gui_exit.ps1'
 $embedRoot   = Join-Path $WorkDir 'embed_root.ps1'
 $embedEnv    = Join-Path $WorkDir 'embed_env.ps1'
 $unicode     = Join-Path $WorkDir 'unicode.ps1'
 $nooutScript = Join-Path $WorkDir 'noout_script.ps1'
 $noerrScript = Join-Path $WorkDir 'noerr_script.ps1'
 $bitness     = Join-Path $WorkDir 'bitness.ps1'
 $apt         = Join-Path $WorkDir 'apt.ps1'
 $stdinScript = Join-Path $WorkDir 'stdin_script.ps1'
 $nobom       = Join-Path $WorkDir 'nobom.ps1'
 $embedSource = Join-Path $WorkDir 'embed_source.txt'
 $embedEnvSrc = Join-Path $WorkDir 'embed_env.txt'
 $iconFile    = Join-Path $WorkDir 'test.ico'

 $basicContent = @'
Write-Output "PS2EXE-TEST-OK"
'@
Write-TestScript -Path $basic -Content $basicContent
Write-TestScript -Path $nobom -Content $basicContent -NoBom

Write-TestScript -Path $paramScript -Content @'
param(
    [string]$Name = "World"
)

Write-Output "Hello $Name"
'@

Write-TestScript -Path $usingOnly -Content @'
using namespace System.IO

Write-Output "ext=$([Path]::GetExtension('x.txt'))"
'@

Write-TestScript -Path $usingParam -Content @'
using namespace System.IO

param(
    [string]$Name = "World"
)

Write-Output "ext=$([Path]::GetExtension('x.txt')) name=$Name"
'@

Write-TestScript -Path $helpScript -Content @'
<#
.SYNOPSIS
PS2EXE test synopsis.
.DESCRIPTION
Detailed description of the PS2EXE test script.
#>
param(
    [string]$Name = "World"
)

Write-Output "Hello $Name"
'@

Write-TestScript -Path $exitScript -Content @'
Write-Output "done"
exit 42
'@

# GUI test script must stay silent: any output would open a blocking message box
Write-TestScript -Path $guiExit -Content @'
exit 42
'@

Write-TestScript -Path $embedRoot -Content @'
Write-Output "root=$PSScriptRoot"
Write-Output "cmd=$PSCommandPath"
Write-Output "sroot=$ScriptRoot"
 $embedFile = Join-Path $PSScriptRoot 'ps2exe_embed_test.txt'
 $embedContent = (Get-Content -LiteralPath $embedFile -Raw).Trim()
Write-Output "embed=$embedContent"
'@

Write-TestScript -Path $embedEnv -Content @'
 $embedFile = Join-Path $env:PS2EXE_TEST 'embed_env.txt'
 $embedContent = (Get-Content -LiteralPath $embedFile -Raw).Trim()
Write-Output "envembed=$embedContent"
'@

Write-TestScript -Path $unicode -Content @'
Write-Output "Тест Юникод: OK"
'@

Write-TestScript -Path $nooutScript -Content @'
Write-Output "SHOULD-NOT-APPEAR"
'@

Write-TestScript -Path $noerrScript -Content @'
Write-Error "ERRMARKER"
Write-Output "ok-out"
'@

Write-TestScript -Path $bitness -Content @'
Write-Output "64=$([Environment]::Is64BitProcess)"
'@

Write-TestScript -Path $apt -Content @'
Write-Output "apt=$([System.Threading.Thread]::CurrentThread.GetApartmentState())"
'@

Write-TestScript -Path $stdinScript -Content @'
 $lines = @($input)
Write-Output "lines=$($lines.Count)"
'@

[System.IO.File]::WriteAllText($embedSource, 'EMBED-OK-123')
[System.IO.File]::WriteAllText($embedEnvSrc, 'ENV-OK-456')
New-TestIcon -Path $iconFile

# --- define the test matrix ---
 $Tests += @{ Id='T01'; Name='PS5 console: basic script'; Run='console'; Params=(New-TestParams $basic 't01_basic'); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='T02'; Name='PS5: script with param block (default value)'; Run='console'; Params=(New-TestParams $paramScript 't02_param'); ExpectText='Hello World'; ExpectCode=0 }
 $Tests += @{ Id='T03'; Name='PS5: script with param block (named argument)'; Run='console'; Params=(New-TestParams $paramScript 't03_paramargs'); Args=@('-Name','PS2EXE'); ExpectText='Hello PS2EXE'; ExpectCode=0 }
 $Tests += @{ Id='T04'; Name='PS5: -end separator passes following arguments'; Run='console'; Params=(New-TestParams $paramScript 't04_endargs'); Args=@('-end','-Name','PS2EXE'); ExpectText='Hello PS2EXE'; ExpectCode=0 }
 $Tests += @{ Id='T05'; Name='PS5: using namespace statement at top'; Run='console'; Params=(New-TestParams $usingOnly 't05_using'); ExpectText='ext=.txt'; ExpectCode=0 }
 $Tests += @{ Id='T06'; Name='PS5: using namespace + param block'; Run='console'; Params=(New-TestParams $usingParam 't06_usingparam'); Args=@('-Name','X'); ExpectText='ext=.txt name=X'; ExpectCode=0 }
 $Tests += @{ Id='T07'; Name='PS5: help mode -?'; Run='console'; Params=(New-TestParams $helpScript 't07_help'); Args=@('-?'); ExpectText='PS2EXE test synopsis'; ExpectCode=0 }
 $Tests += @{ Id='T08'; Name='PS5: exit code propagation'; Run='console'; Params=(New-TestParams $exitScript 't08_exit'); ExpectText='done'; ExpectCode=42 }
 $Tests += @{ Id='T09'; Name='PS5: -embedFiles + $PSScriptRoot/$PSCommandPath/$ScriptRoot'; Run='custom';
    Params=(New-TestParams $embedRoot 't09_embed' @{ embedFiles = @{ '.\ps2exe_embed_test.txt' = $embedSource } });
    Script={
        param($exe)
        $r = Invoke-ConsoleExe -Exe $exe
        $lines = @([string]$r.Text -split "`r?`n")
        $fails = @()
        if ($r.Code -ne 0) { $fails += "exit code is $($r.Code)" }
        $expected = @{ root = $WorkDir; cmd = $exe; sroot = $WorkDir; embed = 'EMBED-OK-123' }
        foreach ($key in $expected.Keys) {
            $wanted = "$($key)=$($expected[$key])"
            if ($lines -notcontains $wanted) { $fails += "missing output line '$wanted'" }
        }
        if ($fails.Count -eq 0) { @{ Ok = $true; Details = '' } }
        else { @{ Ok = $false; Details = (($fails -join '; ') + ' -- output: ' + [string]$r.Text) } }
    } }
 $Tests += @{ Id='T10'; Name='PS5: redirected stdin ($input)'; Run='stdin'; Params=(New-TestParams $stdinScript 't10_stdin'); InputLines=@('one','two'); ExpectText='lines=2'; ExpectCode=0 }
 $Tests += @{ Id='T11'; Name='PS5: -wait with redirected stdin'; Run='wait'; Params=(New-TestParams $basic 't11_wait'); Args=@('-wait'); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='T12'; Name='PS5: UTF8 script without BOM'; Run='console'; Params=(New-TestParams $nobom 't12_nobom'); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='T13'; Name='PS5: -UNICODEEncoding with non-ASCII output'; Run='unicode'; Params=(New-TestParams $unicode 't13_unicode' @{ UNICODEEncoding = $true }); ExpectText='OK'; ExpectCode=0 }
 $Tests += @{ Id='T14'; Name='PS5: -noOutput suppresses output'; Run='console'; Params=(New-TestParams $nooutScript 't14_nooutput' @{ noOutput = $true }); ExpectNoText='SHOULD-NOT-APPEAR'; ExpectCode=0 }
 $Tests += @{ Id='T15'; Name='PS5: -noError suppresses error output'; Run='console'; Params=(New-TestParams $noerrScript 't15_noerror' @{ noError = $true }); ExpectText='ok-out'; ExpectNoText='ERRMARKER'; ExpectCode=0 }
 $Tests += @{ Id='T16'; Name='PS5: -STA apartment state'; Run='console'; Params=(New-TestParams $apt 't16_sta' @{ STA = $true }); ExpectText='apt=STA'; ExpectCode=0 }
 $Tests += @{ Id='T17'; Name='PS5: -MTA apartment state'; Run='console'; Params=(New-TestParams $apt 't17_mta' @{ MTA = $true }); ExpectText='apt=MTA'; ExpectCode=0 }
if ([Environment]::Is64BitOperatingSystem)
{
    $Tests += @{ Id='T18'; Name='PS5: -x64 runs as 64-bit process'; Run='console'; Params=(New-TestParams $bitness 't18_x64' @{ x64 = $true }); ExpectText='64=True'; ExpectCode=0 }
    $Tests += @{ Id='T19'; Name='PS5: -x86 runs as 32-bit process'; Run='console'; Params=(New-TestParams $bitness 't19_x86' @{ x86 = $true }); ExpectText='64=False'; ExpectCode=0 }
}
 $Tests += @{ Id='T20'; Name='PS5: -lcid 1033'; Run='console'; Params=(New-TestParams $basic 't20_lcid' @{ lcid = 1033 }); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='T21'; Name='PS5: -prepareDebug writes .cs source'; Run='custom';
    Params=(New-TestParams $basic 't21_debug' @{ prepareDebug = $true });
    Script={
        param($exe)
        $csFile = [System.IO.Path]::ChangeExtension($exe, '.cs')
        @{ Ok = (Test-Path -LiteralPath $csFile -PathType Leaf); Details = "expected debug source file: $csFile" }
    } }
 $Tests += @{ Id='T22'; Name='PS5: version resource metadata'; Run='custom';
    Params=(New-TestParams $basic 't22_meta' @{ title='PS2EXE Test Title'; description='PS2EXE Test Description'; company='PS2EXE Test Company'; product='PS2EXE Test Product'; copyright='PS2EXE Test Copyright'; trademark='PS2EXE Test Trademark'; version='1.2.3.4' });
    Script={
        param($exe)
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        $fails = @()
        if ([string]$vi.FileVersion -ne '1.2.3.4') { $fails += "FileVersion: '$($vi.FileVersion)'" }
        if ([string]$vi.ProductVersion -ne '1.2.3.4') { $fails += "ProductVersion: '$($vi.ProductVersion)'" }
        if ([string]$vi.CompanyName -ne 'PS2EXE Test Company') { $fails += "CompanyName: '$($vi.CompanyName)'" }
        if ([string]$vi.ProductName -ne 'PS2EXE Test Product') { $fails += "ProductName: '$($vi.ProductName)'" }
        if ([string]$vi.LegalCopyright -ne 'PS2EXE Test Copyright') { $fails += "LegalCopyright: '$($vi.LegalCopyright)'" }
        if ([string]$vi.LegalTrademarks -ne 'PS2EXE Test Trademark') { $fails += "LegalTrademarks: '$($vi.LegalTrademarks)'" }
        if ([string]$vi.FileDescription -ne 'PS2EXE Test Title') { $fails += "FileDescription: '$($vi.FileDescription)'" }
        @{ Ok = ($fails.Count -eq 0); Details = ($fails -join '; ') }
    } }
 $Tests += @{ Id='T23'; Name='PS5: -configFile writes exe.config'; Run='custom';
    Params=(New-TestParams $basic 't23_config' @{ configFile = $true });
    Script={ param($exe) Test-ConfigContent -Exe $exe -Expected 'supportedRuntime' } }
 $Tests += @{ Id='T24'; Name='PS5: -longPaths config entry'; Run='custom';
    Params=(New-TestParams $basic 't24_longpaths' @{ longPaths = $true });
    Script={ param($exe) Test-ConfigContent -Exe $exe -Expected 'BlockLongPaths' } }
 $Tests += @{ Id='T25'; Name='PS5: -winFormsDPIAware config entry'; Run='custom';
    Params=(New-TestParams $basic 't25_wfdpi' @{ winFormsDPIAware = $true });
    Script={ param($exe) Test-ConfigContent -Exe $exe -Expected 'DpiAwareness' } }
 $Tests += @{ Id='T26'; Name='PS5: -iconFile'; Params=(New-TestParams $basic 't26_icon' @{ iconFile = $iconFile }) }
 $Tests += @{ Id='T27'; Name='PS5: -conHost'; Params=(New-TestParams $basic 't27_conhost' @{ conHost = $true }) }
 $Tests += @{ Id='T28'; Name='PS5: -credentialGUI'; Params=(New-TestParams $basic 't28_credgui' @{ credentialGUI = $true }) }
 $Tests += @{ Id='T29'; Name='PS5: -virtualize (forces x86)'; Params=(New-TestParams $basic 't29_virtualize' @{ virtualize = $true }) }
 $Tests += @{ Id='T30'; Name='PS5: -requireAdmin'; Params=(New-TestParams $basic 't30_admin' @{ requireAdmin = $true }) }
 $Tests += @{ Id='T31'; Name='PS5: -supportOS'; Params=(New-TestParams $basic 't31_supportos' @{ supportOS = $true }) }
 $Tests += @{ Id='T32'; Name='PS5: -DPIAware'; Params=(New-TestParams $basic 't32_dpiaware' @{ DPIAware = $true }) }
 $Tests += @{ Id='T33'; Name='PS5: -noConfigFile'; Params=(New-TestParams $basic 't33_noconfig' @{ noConfigFile = $true }) }
 $Tests += @{ Id='T34'; Name='PS5: -noConsole (compile regression) + exit code'; Run='gui'; Params=(New-TestParams $guiExit 't34_gui' @{ noConsole = $true }); ExpectCode=42 }
 $Tests += @{ Id='T35'; Name='PS5: -noConsole -exitOnCancel (compile regression)'; Params=(New-TestParams $basic 't35_exitcancel' @{ noConsole = $true; exitOnCancel = $true }) }
 $Tests += @{ Id='T36'; Name='PS5: console -exitOnCancel (compile regression)'; Run='console'; Params=(New-TestParams $basic 't36_consolecancel' @{ exitOnCancel = $true }); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='T37'; Name='PS5: -noConsole -noVisualStyles'; Params=(New-TestParams $basic 't37_novisual' @{ noConsole = $true; noVisualStyles = $true }) }
 $Tests += @{ Id='T38'; Name='PS5: -noConsole -DPIAware'; Params=(New-TestParams $basic 't38_guidpi' @{ noConsole = $true; DPIAware = $true }) }
 $Tests += @{ Id='T39'; Name='PS5: -extract writes script to file'; Run='custom';
    Params=(New-TestParams $basic 't39_extract');
    Script={
        param($exe)
        $extracted = Join-Path $WorkDir 'extracted_t39.ps1'
        if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Force }
        $r = Invoke-ConsoleExe -Exe $exe -ExeArgs @("-extract:$extracted")
        $content = ''
        if (Test-Path -LiteralPath $extracted) { $content = [string](Get-Content -LiteralPath $extracted -Raw) }
        $ok = ($r.Code -eq 0) -and $content.Contains('PS2EXE-TEST-OK') -and $content.Contains('# PS2EXE: script path variables')
        @{ Ok = $ok; Details = "exit code: $($r.Code), extracted file present: $(Test-Path -LiteralPath $extracted)" }
    } }
 $Tests += @{ Id='T40'; Name='PS5: -embedFiles with environment variable target'; Run='console';
    Params=(New-TestParams $embedEnv 't40_embedenv' @{ embedFiles = @{ '%PS2EXE_TEST%\embed_env.txt' = $embedEnvSrc } });
    ExpectText='envembed=ENV-OK-456'; ExpectCode=0 }

 $Tests += @{ Id='P01'; Name='PS7 stub: basic script'; Run='console'; Params=(New-TestParams $basic 'p01_basic' @{ ps7 = $true }); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='P02'; Name='PS7: param block (default value)'; Run='console'; Params=(New-TestParams $paramScript 'p02_param' @{ ps7 = $true }); ExpectText='Hello World'; ExpectCode=0 }
 $Tests += @{ Id='P03'; Name='PS7: param block (named argument)'; Run='console'; Params=(New-TestParams $paramScript 'p03_paramargs' @{ ps7 = $true }); Args=@('-Name','PS2EXE'); ExpectText='Hello PS2EXE'; ExpectCode=0 }
 $Tests += @{ Id='P04'; Name='PS7: -end separator'; Run='console'; Params=(New-TestParams $paramScript 'p04_endargs' @{ ps7 = $true }); Args=@('-end','-Name','PS2EXE'); ExpectText='Hello PS2EXE'; ExpectCode=0 }
 $Tests += @{ Id='P05'; Name='PS7: using namespace + param block'; Run='console'; Params=(New-TestParams $usingParam 'p05_usingparam' @{ ps7 = $true }); Args=@('-Name','X'); ExpectText='ext=.txt name=X'; ExpectCode=0 }
 $Tests += @{ Id='P06'; Name='PS7: using namespace at top'; Run='console'; Params=(New-TestParams $usingOnly 'p06_using' @{ ps7 = $true }); ExpectText='ext=.txt'; ExpectCode=0 }
 $Tests += @{ Id='P07'; Name='PS7: help mode -?'; Run='console'; Params=(New-TestParams $helpScript 'p07_help' @{ ps7 = $true }); Args=@('-?'); ExpectText='PS2EXE test synopsis'; ExpectCode=0 }
 $Tests += @{ Id='P08'; Name='PS7: exit code propagation'; Run='console'; Params=(New-TestParams $exitScript 'p08_exit' @{ ps7 = $true }); ExpectText='done'; ExpectCode=42 }
 $Tests += @{ Id='P09'; Name='PS7: -embedFiles + path variables'; Run='custom';
    Params=(New-TestParams $embedRoot 'p09_embed' @{ ps7 = $true; embedFiles = @{ '.\ps2exe_embed_test.txt' = $embedSource } });
    Script={
        param($exe)
        $r = Invoke-ConsoleExe -Exe $exe
        $lines = @([string]$r.Text -split "`r?`n")
        $fails = @()
        if ($r.Code -ne 0) { $fails += "exit code is $($r.Code)" }
        $expected = @{ root = $WorkDir; cmd = $exe; sroot = $WorkDir; embed = 'EMBED-OK-123' }
        foreach ($key in $expected.Keys) {
            $wanted = "$($key)=$($expected[$key])"
            if ($lines -notcontains $wanted) { $fails += "missing output line '$wanted'" }
        }
        if ($fails.Count -eq 0) { @{ Ok = $true; Details = '' } }
        else { @{ Ok = $false; Details = (($fails -join '; ') + ' -- output: ' + [string]$r.Text) } }
    } }
 $Tests += @{ Id='P10'; Name='PS7: -noConsole GUI exit code'; Run='gui'; Params=(New-TestParams $guiExit 'p10_gui' @{ ps7 = $true; noConsole = $true }); ExpectCode=42 }
 $Tests += @{ Id='P11'; Name='PS7: -noConsole -exitOnCancel (warning)'; Params=(New-TestParams $basic 'p11_exitcancel' @{ ps7 = $true; noConsole = $true; exitOnCancel = $true }); ExpectWarn='exitOnCancel is not applicable' }
 $Tests += @{ Id='P12'; Name='PS7: -conHost ignored with warning'; Params=(New-TestParams $basic 'p12_conhost' @{ ps7 = $true; conHost = $true }); ExpectWarn='-conHost is not applicable' }
 $Tests += @{ Id='P13'; Name='PS7: -UNICODEEncoding ignored with warning'; Params=(New-TestParams $basic 'p13_unicode' @{ ps7 = $true; UNICODEEncoding = $true }); ExpectWarn='-UNICODEEncoding is not applicable' }
 $Tests += @{ Id='P14'; Name='PS7: -noOutput warning'; Params=(New-TestParams $basic 'p14_nooutput' @{ ps7 = $true; noOutput = $true }); ExpectWarn='-noOutput is not implemented' }
 $Tests += @{ Id='P15'; Name='PS7: -extract writes script to file'; Run='custom';
    Params=(New-TestParams $basic 'p15_extract' @{ ps7 = $true });
    Script={
        param($exe)
        $extracted = Join-Path $WorkDir 'extracted_p15.ps1'
        if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Force }
        $r = Invoke-ConsoleExe -Exe $exe -ExeArgs @("-extract:$extracted")
        $content = ''
        if (Test-Path -LiteralPath $extracted) { $content = [string](Get-Content -LiteralPath $extracted -Raw) }
        $ok = ($r.Code -eq 0) -and $content.Contains('PS2EXE-TEST-OK') -and $content.Contains('# PS2EXE: script path variables')
        @{ Ok = $ok; Details = "exit code: $($r.Code), extracted file present: $(Test-Path -LiteralPath $extracted)" }
    } }
 $Tests += @{ Id='P16'; Name='PS7: -wait with redirected stdin'; Run='wait'; Params=(New-TestParams $basic 'p16_wait' @{ ps7 = $true }); Args=@('-wait'); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
if ([Environment]::Is64BitOperatingSystem)
{
    $Tests += @{ Id='P17'; Name='PS7: -x86 stub finds 64-bit pwsh'; Run='console'; Params=(New-TestParams $basic 'p17_x86' @{ ps7 = $true; x86 = $true }); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
}
 $Tests += @{ Id='P18'; Name='PS7: -longPaths writes no config file'; Run='custom';
    Params=(New-TestParams $basic 'p18_longpaths' @{ ps7 = $true; longPaths = $true });
    Script={
        param($exe)
        @{ Ok = !(Test-Path -LiteralPath "$exe.config"); Details = 'no .config file expected for the PS7 stub' }
    } }
 $Tests += @{ Id='P19'; Name='PS7: -lcid 1033'; Run='console'; Params=(New-TestParams $basic 'p19_lcid' @{ ps7 = $true; lcid = 1033 }); ExpectText='PS2EXE-TEST-OK'; ExpectCode=0 }
 $Tests += @{ Id='P20'; Name='PS7: -noConsole -winFormsDPIAware'; Params=(New-TestParams $basic 'p20_wfdpi' @{ ps7 = $true; noConsole = $true; winFormsDPIAware = $true }) }

# --- additional regression tests for the marker injection ---
 $multiUsing = Join-Path $WorkDir 'multi_using.ps1'
Write-TestScript -Path $multiUsing -Content @'
using namespace System.IO
using namespace System.Text

param(
    [string]$Name = "World"
)

Write-Output "ext=$([Path]::GetExtension('x.txt')) name=$Name len=$([Encoding]::UTF8.GetByteCount($Name))"
'@
 $Tests += @{ Id='T41'; Name='PS5: multiple using statements + param'; Run='console'; Params=(New-TestParams $multiUsing 't41_multiusing'); Args=@('-Name','X'); ExpectText='ext=.txt name=X len=1'; ExpectCode=0 }
 $Tests += @{ Id='P21'; Name='PS7: multiple using statements + param'; Run='console'; Params=(New-TestParams $multiUsing 'p21_multiusing' @{ ps7 = $true }); Args=@('-Name','X'); ExpectText='ext=.txt name=X len=1'; ExpectCode=0 }

# --- run all tests ---
Write-Host "PS2EXE test suite"
Write-Host "  ps2exe.ps1 : $Ps2exeScript"
Write-Host "  work dir   : $WorkDir"
Write-Host "  pwsh.exe   : $(if ($PwshFound) { $PwshExe } else { 'not found (PS7 runtime tests will be skipped)' })"
Write-Host "  tests      : $($Tests.Count)"
Write-Host ""

foreach ($t in $Tests) {
    $compile = Invoke-CompileTest -Params $t.Params
    if (!$compile.Ok) {
        Add-TestResult -Id $t.Id -Name $t.Name -Status 'FAIL' -Details ("compilation failed`n" + $compile.Log)
        continue
    }
    if ($t.ContainsKey('ExpectWarn') -and !$compile.Log.Contains([string]$t.ExpectWarn)) {
        Add-TestResult -Id $t.Id -Name $t.Name -Status 'FAIL' -Details "expected warning containing '$($t.ExpectWarn)' was not emitted during compilation"
        continue
    }

    $runKind = [string]$t.Run
    if (!$runKind) { $runKind = 'none' }
    if ($runKind -eq 'none') {
        Add-TestResult -Id $t.Id -Name $t.Name -Status 'PASS'
        continue
    }
    if ($t.Params.ContainsKey('ps7') -and !$PwshFound) {
        Add-TestResult -Id $t.Id -Name $t.Name -Status 'SKIP' -Details 'pwsh.exe not found'
        continue
    }

    $exe = [string]$t.Params['outputFile']
    $exeArgs = @()
    if ($t.ContainsKey('Args')) { $exeArgs = [string[]]$t.Args }

    try {
        switch ($runKind) {
            'console' {
                $r = Invoke-ConsoleExe -Exe $exe -ExeArgs $exeArgs
                Complete-RunTest -Test $t -Result $r
            }
            'gui' {
                $r = Invoke-GuiExe -Exe $exe
                Complete-RunTest -Test $t -Result $r
            }
            'stdin' {
                $lines = @()
                if ($t.ContainsKey('InputLines')) { $lines = [string[]]$t.InputLines }
                $r = Invoke-StdinExe -Exe $exe -ExeArgs $exeArgs -InputLines $lines
                Complete-RunTest -Test $t -Result $r
            }
            'wait' {
                $r = Invoke-StdinExe -Exe $exe -ExeArgs $exeArgs
                Complete-RunTest -Test $t -Result $r
            }
            'unicode' {
                $r = Invoke-UnicodeExe -Exe $exe
                Complete-RunTest -Test $t -Result $r
            }
            'custom' {
                $res = & $t.Script $exe
                if ($res -and $res.Ok) { Add-TestResult -Id $t.Id -Name $t.Name -Status 'PASS' }
                else { Add-TestResult -Id $t.Id -Name $t.Name -Status 'FAIL' -Details ([string]$res.Details) }
            }
            default {
                Add-TestResult -Id $t.Id -Name $t.Name -Status 'FAIL' -Details "unknown run kind '$runKind'"
            }
        }
    } catch {
        Add-TestResult -Id $t.Id -Name $t.Name -Status 'FAIL' -Details "runner exception: $($_.Exception.Message)"
    }
}

# --- summary ---
 $failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
 $skipped = @($Results | Where-Object { $_.Status -eq 'SKIP' })
 $passed = @($Results | Where-Object { $_.Status -eq 'PASS' })

Write-Host ""
Write-Host ("Summary: {0} tests, {1} passed, {2} failed, {3} skipped" -f $Results.Count, $passed.Count, $failed.Count, $skipped.Count)

Remove-Item Env:\PS2EXE_TEST -ErrorAction SilentlyContinue

if ($failed.Count -gt 0)
{
    Write-Host ""
    Write-Host "Errors found:" -ForegroundColor Red
    foreach ($f in $failed) {
        $d = [string]$f.Details
        if ($d.Length -gt 600) { $d = $d.Substring(0, 600) + '...' }
        Write-Host ("  [{0}] {1}: {2}" -f $f.Id, $f.Name, ($d -replace "`r?`n", ' | ')) -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Working directory kept for inspection: $WorkDir" -ForegroundColor Yellow
    exit 1
}

if ($NoCleanup)
{
    Write-Host "No errors. Working directory kept (-NoCleanup): $WorkDir"
}
else
{
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "No errors. Working directory cleaned up."
}
exit 0