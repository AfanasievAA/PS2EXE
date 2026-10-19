#Requires -Modules Pester
#Requires -Version 5.1

<#
.SYNOPSIS
    Comprehensive test suite for PS2EXE module.
.DESCRIPTION
    Tests all compilation modes: Windows PowerShell 5.x, PS7 stub mode, and Core mode (Roslyn compilation).
    Includes parameter validation, preprocessor features, and error handling tests.
.NOTES
    Version: 1.0.22
    Date: 2026.10.19
    Author: Andrew Afanasiev
    Run with: Invoke-Pester -Path .\Test-ps2exe.ps1
    Or run directly: .\Test-ps2exe.ps1
    Detailed output (green [+] for each passed test) is enabled by default via $PesterPreference.
#>

#Requires -Modules Pester
#Requires -Version 5.1

<#
.SYNOPSIS
    Comprehensive test suite for the PS2EXE module.
.DESCRIPTION
    Tests all compilation modes (Windows PowerShell 5.x in-process host, PS7 stub mode,
    Core mode via dotnet publish), parameter validation, preprocessor features
    (-removeAllComments, -mergeIncludes, -savePreprocessedScript), embedded files,
    config file generation, PE file properties and the runtime behaviour of the
    generated executables (output, parameter binding, $args, exit codes, -extract).
    Console executables built from non-interactive scripts are executed; GUI mode
    (-noConsole) executables are only checked for compilation success and PE subsystem
    because running them would block the test run with message boxes.
.NOTES
    Run with: Invoke-Pester -Path .\Test-ps2exe.ps1
    Or run directly: .\Test-ps2exe.ps1
    Detailed output (green [+] for each passed test) is enabled by default via $PesterPreference.
    Save this file as UTF-8 WITH BOM: it contains non-ASCII test data and must stay
    readable under Windows PowerShell 5.1 as well.
    Tags allow selective runs, e.g. Invoke-Pester -Path .\Test-ps2exe.ps1 -Tag WinPS
    (tags: WinPS, WinPSRuntime, PS7, PS7Runtime, Core, CoreRuntime, Preprocessor).
    A full run with the .NET SDK installed takes several minutes: every Core test
    performs a dotnet publish. The first explicit -targetFramework runs may download
    reference packs via NuGet.
#>

$PesterPreference = New-PesterConfiguration
$PesterPreference.Output.Verbosity = 'Detailed'

# Detect the .NET SDK at file TOP LEVEL (not inside BeforeAll): Pester evaluates the
# -Skip arguments of Describe/Context/It during DISCOVERY, which runs before any
# BeforeAll. With the detection inside BeforeAll the variable is $null at discovery
# time, so -Skip:(-not $script:HasDotnetSDK) evaluates to $true (Core tests skipped
# although the SDK is installed) and -Skip:$script:HasDotnetSDK evaluates to $false
# (the "no SDK" test runs on a machine WITH the SDK and fails when compilation
# succeeds). Get-Command guards against a missing dotnet.exe: a bare
# "& dotnet --version 2>&1" would put the redirected error text into the variable and
# a stale $LASTEXITCODE could produce a false positive.
$script:HasDotnetSDK = $false
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    # dotnet --version succeeds only when an SDK is installed, not just a runtime
    $null = & dotnet --version 2>$null
    $script:HasDotnetSDK = ($LASTEXITCODE -eq 0)
}

# PS7 mode executables need pwsh.exe on the machine running the tests
$script:HasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)

BeforeAll {
    # Re-run the dotnet SDK detection for the RUN phase: Pester executes the test
    # blocks in a fresh script scope (Invoke-InNewScriptScope), so script-scope
    # variables written at file top level during DISCOVERY are not visible inside
    # It bodies at runtime. The top-level copy above feeds only the -Skip arguments,
    # which Pester evaluates at discovery time.
    $script:HasDotnetSDK = $false
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        # dotnet --version succeeds only when an SDK is installed, not just a runtime
        $null = & dotnet --version 2>$null
        $script:HasDotnetSDK = ($LASTEXITCODE -eq 0)
    }

    $modulePath = Join-Path $PSScriptRoot 'ps2exe.psd1'
    Import-Module $modulePath -Force

    # --- Script templates ---------------------------------------------------------

    $script:HelloWorldScript = @'
Write-Output "Hello from PS2EXE test"
'@

    $script:ParamScript = @'
param(
    [string]$Name = "World",
    [int]$Count = 1,
    [switch]$Flag
)
Write-Output "Hello $Name x$Count flag=$($Flag.IsPresent)"
'@

    $script:ArgsScript = @'
Write-Output "count=$($args.Count)"
'@

    $script:ExitCodeScript = @'
Write-Output "exiting"
exit 42
'@

    # The here-string body contains '#' lines that must survive comment stripping.
    # The outer here-string is double quoted because a single quoted one would be
    # closed by the inner closer line; PowerShell variables are escaped with a backtick.
    $script:HereStringScript = @"
`$data = @'
# not a comment
value
'@
Write-Output `$data
"@

    # --- Helpers ------------------------------------------------------------------

    # Create a test script file in the Pester TestDrive
    function New-TestScript {
        param(
            [string]$Name,
            [string]$Content
        )
        $path = Join-Path $TestDrive $Name
        Set-Content -Path $path -Value $Content -Encoding UTF8
        return $path
    }

    # Verify the file exists and starts with a valid PE header (MZ)
    function Test-Executable {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $false }
        $fileInfo = Get-Item $Path
        if ($fileInfo.Length -le 0) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)[0..1]
        return ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    }

    # Return the PE subsystem value: 2 = Windows GUI, 3 = Windows Console
    function Get-PESubsystem {
        param([string]$Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOffset -le 0 -or ($peOffset + 94) -gt $bytes.Length) { return -1 }
        # Subsystem resides at optional header offset 68: PE signature 4 + COFF header 20 + 68
        return [BitConverter]::ToUInt16($bytes, $peOffset + 92)
    }

    # Run a generated console executable and capture output and exit code.
    # ONLY console executables built from non-interactive scripts may be invoked
    # here: a GUI mode (-noConsole) executable would block the whole test run with
    # a message box and a -wait executable would wait for a key press.
    function Invoke-TestExe {
        param(
            [string]$Path,
            [string[]]$Arguments = @()
        )
        $output = & $Path @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{
            Output = ($output -join "`r`n").Trim()
            ExitCode = $LASTEXITCODE
        }
    }

    # Extract a valid .ico from a system executable: the /win32icon compiler
    # switch rejects malformed icon files
    function New-TestIcon {
        param([string]$Path)
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\notepad.exe")
        $stream = [System.IO.File]::Create($Path)
        try { $icon.Save($stream) } finally { $stream.Close() }
        return $Path
    }

    # Stamp a known creation and modification time onto a file
    function Set-TestFileTimes {
        param(
            [string]$Path,
            [datetime]$Time
        )
        $item = Get-Item -LiteralPath $Path
        $item.CreationTime = $Time
        $item.LastWriteTime = $Time
    }
}

AfterAll {
    Remove-Module ps2exe -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# PARAMETER VALIDATION TESTS
# ==============================================================================
Describe 'Parameter Validation' {
    Context 'Input and output file checks' {
        It 'Should not create an executable when no input file is specified' {
            $outputPath = Join-Path $TestDrive 'no-input.exe'
            Invoke-PS2EXE -inputFile $null -outputFile $outputPath | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should not create an executable when the input file does not exist' {
            $outputPath = Join-Path $TestDrive 'nonexistent-input.exe'
            Invoke-PS2EXE -inputFile 'C:\NonExistent\file.ps1' -outputFile $outputPath | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should refuse identical input and output files' {
            $scriptFile = New-TestScript -Name 'identical.ps1' -Content $script:HelloWorldScript
            Invoke-PS2EXE -inputFile $scriptFile -outputFile $scriptFile | Out-Null
            # the input file must survive unchanged (no PE header written into it)
            Test-Executable -Path $scriptFile | Should -BeFalse
        }

        It 'Should reject output files without .exe or .com extension' {
            $scriptFile = New-TestScript -Name 'extension.ps1' -Content $script:HelloWorldScript
            $outputPath = Join-Path $TestDrive 'extension.txt'
            Invoke-PS2EXE -inputFile $scriptFile -outputFile $outputPath | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should reject icon files that do not exist' {
            $scriptFile = New-TestScript -Name 'icon-missing.ps1' -Content $script:HelloWorldScript
            $outputPath = Join-Path $TestDrive 'icon-missing.exe'
            Invoke-PS2EXE -inputFile $scriptFile -outputFile $outputPath -iconFile 'C:\NonExistent\icon.ico' | Out-Null
            $outputPath | Should -Not -Exist
        }
    }

    Context 'Mutually exclusive switches' {
        BeforeAll {
            $script:TestFile = New-TestScript -Name 'mutex.ps1' -Content $script:HelloWorldScript
        }

        It 'Should reject -STA combined with -MTA' {
            $outputPath = Join-Path $TestDrive 'sta-mta.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -STA -MTA | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should reject -noConsole combined with -conHost' {
            $outputPath = Join-Path $TestDrive 'noconsole-conhost.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -noConsole -conHost | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should reject -configFile combined with -noConfigFile' {
            $outputPath = Join-Path $TestDrive 'config-noconfig.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -configFile -noConfigFile | Out-Null
            $outputPath | Should -Not -Exist
        }
    }

    Context 'Invalid values' {
        BeforeAll {
            $script:TestFile = New-TestScript -Name 'invalid.ps1' -Content $script:HelloWorldScript
        }

        It 'Should reject malformed version numbers' {
            $outputPath = Join-Path $TestDrive 'invalid-version.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -version 'v1.0' | Out-Null
            $outputPath | Should -Not -Exist
        }

        It 'Should reject unsupported target frameworks' {
            $outputPath = Join-Path $TestDrive 'invalid-fw.exe'
            # ValidateSet on the parameter fails binding in the CALLING process,
            # so Should -Throw works regardless of the PowerShell edition
            { Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -core -targetFramework 'net99.0' } | Should -Throw
        }
    }

    Context 'SDK dependency' {
        It 'Should report an error when the dotnet SDK is missing' -Skip:$script:HasDotnetSDK {
            $testFile = New-TestScript -Name 'sdk-error.ps1' -Content $script:HelloWorldScript
            $outputPath = Join-Path $TestDrive 'sdk-error.exe'
            # The SDK check runs in the calling process BEFORE the powershell.exe
            # relaunch, so -ErrorAction Stop turns the module's non-terminating
            # Write-Error into a terminating exception Should -Throw reliably catches
            { Invoke-PS2EXE -inputFile $testFile -outputFile $outputPath -core -ErrorAction Stop } | Should -Throw
            $outputPath | Should -Not -Exist
        }
    }

    Context 'Mode priority' {
        BeforeAll {
            $script:TestFile = New-TestScript -Name 'priority.ps1' -Content $script:HelloWorldScript
        }

        It 'Should prioritize -core when both -ps7 and -core are specified' {
            $outputPath = Join-Path $TestDrive 'priority.exe'
            if ($script:HasDotnetSDK) {
                # With SDK: should compile in Core mode without error
                Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -core -ps7 | Out-Null
                Test-Executable -Path $outputPath | Should -BeTrue
            } else {
                # Without SDK: -ErrorAction Stop makes the Write-Error catchable
                { Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -core -ps7 -ErrorAction Stop } | Should -Throw
                $outputPath | Should -Not -Exist
            }
        }
    }

    Context 'Preprocessor switches' {
        It 'Should ignore -savePreprocessedScript without preprocessing switches' {
            # the input base name must differ from the output base name: the module
            # saves the preprocessed script as <outputbase>.ps1, and with equal names
            # that path IS the input file, so the "not exist" assertion below would
            # always fail
            $scriptFile = New-TestScript -Name 'no-pre-src.ps1' -Content $script:HelloWorldScript
            $outputPath = Join-Path $TestDrive 'no-pre.exe'
            Invoke-PS2EXE -inputFile $scriptFile -outputFile $outputPath -savePreprocessedScript | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            [System.IO.Path]::ChangeExtension($outputPath, '.ps1') | Should -Not -Exist
        }
    }
}

# ==============================================================================
# WINDOWS POWERSHELL MODE TESTS (DEFAULT, IN-PROCESS HOST)
# ==============================================================================
Describe 'Windows PowerShell Mode' -Tag 'WinPS' {
    BeforeAll {
        $script:TestFile = New-TestScript -Name 'winps-test.ps1' -Content $script:HelloWorldScript
    }

    Context 'Basic compilation' {
        It 'Should compile a simple script to a console executable' {
            $outputPath = Join-Path $TestDrive 'winps-basic.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 3
        }

        It 'Should accept the compatibility switch -x64' {
            $outputPath = Join-Path $TestDrive 'winps-x64.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -x64 | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should compile with -lcid' {
            $outputPath = Join-Path $TestDrive 'winps-lcid.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -lcid 1033 | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Apartment state' {
        It 'Should compile with -STA' {
            $outputPath = Join-Path $TestDrive 'winps-sta.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -STA | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should compile with -MTA' {
            $outputPath = Join-Path $TestDrive 'winps-mta.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -MTA | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'GUI and console host variants' {
        It 'Should compile with -noConsole as a GUI executable' {
            $outputPath = Join-Path $TestDrive 'winps-gui.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -noConsole | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 2
        }

        It 'Should compile with -conHost as a GUI executable with an allocated console' {
            # /target:winexe is used for -conHost as well, the console is allocated at
            # runtime via AllocConsole; never RUN this executable from the tests
            $outputPath = Join-Path $TestDrive 'winps-conhost.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -conHost | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 2
        }

        It 'Should compile with -credentialGUI' {
            $outputPath = Join-Path $TestDrive 'winps-credgui.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -credentialGUI | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Metadata' {
        It 'Should embed title and version information' {
            $outputPath = Join-Path $TestDrive 'winps-meta.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -title 'Meta Test' -version '1.2.3.4' | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Get-Item $outputPath).VersionInfo.FileVersion | Should -Be '1.2.3.4'
            (Get-Item $outputPath).VersionInfo.FileDescription | Should -Be 'Meta Test'
        }
    }

    Context 'Manifest switches' {
        It 'Should compile with -requireAdmin' {
            $outputPath = Join-Path $TestDrive 'winps-admin.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -requireAdmin | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            # the temporary manifest source must be cleaned up after compilation
            "$outputPath.win32manifest" | Should -Not -Exist
        }

        It 'Should compile with -DPIAware' {
            $outputPath = Join-Path $TestDrive 'winps-dpi.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -DPIAware | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.win32manifest" | Should -Not -Exist
        }

        It 'Should compile with -supportOS' {
            $outputPath = Join-Path $TestDrive 'winps-supportos.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -supportOS | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.win32manifest" | Should -Not -Exist
        }

        It 'Should compile with -longPaths and force a config file' {
            $outputPath = Join-Path $TestDrive 'winps-longpaths.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -longPaths | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.config" | Should -Exist
            "$outputPath.win32manifest" | Should -Not -Exist
        }
    }

    Context 'Icon and debug information' {
        It 'Should embed an icon file' {
            $iconFile = New-TestIcon -Path (Join-Path $TestDrive 'test.ico')
            $outputPath = Join-Path $TestDrive 'winps-icon.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -iconFile $iconFile | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should copy the generated C# source with -prepareDebug' {
            $outputPath = Join-Path $TestDrive 'winps-debug.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -prepareDebug | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            [System.IO.Path]::ChangeExtension($outputPath, '.cs') | Should -Exist
        }
    }
}

# ==============================================================================
# WINDOWS POWERSHELL RUNTIME TESTS
# ==============================================================================
Describe 'Windows PowerShell Runtime' -Tag 'WinPSRuntime' {
    BeforeAll {
        $script:HelloFile = New-TestScript -Name 'run-hello.ps1' -Content $script:HelloWorldScript
        $script:HelloExe = Join-Path $TestDrive 'run-hello.exe'
        Invoke-PS2EXE -inputFile $script:HelloFile -outputFile $script:HelloExe | Out-Null

        $script:ParamFile = New-TestScript -Name 'run-param.ps1' -Content $script:ParamScript
        $script:ParamExe = Join-Path $TestDrive 'run-param.exe'
        Invoke-PS2EXE -inputFile $script:ParamFile -outputFile $script:ParamExe | Out-Null

        $script:ArgsFile = New-TestScript -Name 'run-args.ps1' -Content $script:ArgsScript
        $script:ArgsExe = Join-Path $TestDrive 'run-args.exe'
        Invoke-PS2EXE -inputFile $script:ArgsFile -outputFile $script:ArgsExe | Out-Null

        $script:ExitFile = New-TestScript -Name 'run-exit.ps1' -Content $script:ExitCodeScript
        $script:ExitExe = Join-Path $TestDrive 'run-exit.exe'
        Invoke-PS2EXE -inputFile $script:ExitFile -outputFile $script:ExitExe | Out-Null
    }

    Context 'Output and exit codes' {
        It 'Should write the script output to the console' {
            (Invoke-TestExe -Path $script:HelloExe).Output | Should -Be 'Hello from PS2EXE test'
        }

        It 'Should forward the script exit code' {
            $result = Invoke-TestExe -Path $script:ExitExe
            $result.Output | Should -Be 'exiting'
            $result.ExitCode | Should -Be 42
        }
    }

    Context 'Parameter binding' {
        It 'Should bind named arguments' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Name', 'Pester', '-Count', '3')
            $result.Output | Should -Be 'Hello Pester x3 flag=False'
        }

        It 'Should bind colon separated arguments' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Name:Tester')
            $result.Output | Should -Be 'Hello Tester x1 flag=False'
        }

        It 'Should bind $TRUE to a switch parameter' {
            # guards the escaped "$TRUE" literal in the host template: without the
            # escaping PowerShell would interpolate it to "True" and binding the
            # literal "$TRUE" argument would fail
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Flag:$TRUE')
            $result.Output | Should -Be 'Hello World x1 flag=True'
        }

        It 'Should bind $FALSE to a switch parameter' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Flag:$FALSE')
            $result.Output | Should -Be 'Hello World x1 flag=False'
        }

        It 'Should set a switch parameter passed without a value' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Flag')
            $result.Output | Should -Be 'Hello World x1 flag=True'
        }
    }

    Context '$args variable' {
        It 'Should pass unbound arguments to $args' {
            $result = Invoke-TestExe -Path $script:ArgsExe -Arguments @('a', 'b', 'c')
            $result.Output | Should -Be 'count=3'
        }
    }

    Context '-extract option' {
        It 'Should extract the embedded script unchanged' {
            $extractTarget = Join-Path $TestDrive 'extracted.ps1'
            $result = Invoke-TestExe -Path $script:HelloExe -Arguments @("-extract:$extractTarget")
            $result.ExitCode | Should -Be 0
            $extractTarget | Should -Exist
            # the injected PS2EXE marker must be removed, the rest must match the input
            (Get-Content -Raw $extractTarget).Trim() | Should -Be ((Get-Content -Raw $script:HelloFile).Trim())
        }
    }

    Context 'Timestamp inheritance' {
        It 'Should inherit the file times of the input script' {
            $srcTime = Get-Date -Year 2020 -Month 5 -Day 15 -Hour 10 -Minute 0 -Second 0
            Set-TestFileTimes -Path $script:HelloFile -Time $srcTime
            $outputPath = Join-Path $TestDrive 'timestamps.exe'
            Invoke-PS2EXE -inputFile $script:HelloFile -outputFile $outputPath | Out-Null
            (Get-Item $outputPath).LastWriteTime | Should -Be $srcTime
        }
    }
}

# ==============================================================================
# PS7 STUB MODE TESTS
# ==============================================================================
Describe 'PS7 Stub Mode' -Tag 'PS7' {
    BeforeAll {
        $script:TestFile = New-TestScript -Name 'ps7-test.ps1' -Content $script:HelloWorldScript
    }

    Context 'Basic compilation' {
        It 'Should compile with -ps7 as a console executable' {
            $outputPath = Join-Path $TestDrive 'ps7-basic.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -ps7 | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 3
        }

        It 'Should compile with -ps7 and -noConsole as a GUI executable' {
            $outputPath = Join-Path $TestDrive 'ps7-gui.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -ps7 -noConsole | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 2
        }
    }

    Context 'Incompatible switches are ignored' {
        It 'Should compile when incompatible switches are passed and write no config file' {
            $outputPath = Join-Path $TestDrive 'ps7-incompat.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -ps7 -conHost -credentialGUI -noOutput -noError -exitOnCancel -STA -configFile -winFormsDPIAware | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.config" | Should -Not -Exist
        }
    }
}

# ==============================================================================
# PS7 RUNTIME TESTS
# ==============================================================================
Describe 'PS7 Runtime' -Tag 'PS7Runtime' -Skip:(-not $script:HasPwsh) {
    BeforeAll {
        $script:HelloFile = New-TestScript -Name 'ps7-run-hello.ps1' -Content $script:HelloWorldScript
        $script:HelloExe = Join-Path $TestDrive 'ps7-run-hello.exe'
        Invoke-PS2EXE -inputFile $script:HelloFile -outputFile $script:HelloExe -ps7 | Out-Null

        $script:ParamFile = New-TestScript -Name 'ps7-run-param.ps1' -Content $script:ParamScript
        $script:ParamExe = Join-Path $TestDrive 'ps7-run-param.exe'
        Invoke-PS2EXE -inputFile $script:ParamFile -outputFile $script:ParamExe -ps7 | Out-Null
    }

    Context 'Output' {
        It 'Should run the script via pwsh.exe and forward its output' {
            (Invoke-TestExe -Path $script:HelloExe).Output | Should -Be 'Hello from PS2EXE test'
        }
    }

    Context 'Parameter binding' {
        It 'Should bind named arguments' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Name', 'Pester', '-Count', '3')
            $result.Output | Should -Be 'Hello Pester x3 flag=False'
        }
    }

    Context '-extract option' {
        It 'Should extract the embedded script unchanged' {
            $extractTarget = Join-Path $TestDrive 'ps7-extracted.ps1'
            $result = Invoke-TestExe -Path $script:HelloExe -Arguments @("-extract:$extractTarget")
            $result.ExitCode | Should -Be 0
            $extractTarget | Should -Exist
            (Get-Content -Raw $extractTarget).Trim() | Should -Be ((Get-Content -Raw $script:HelloFile).Trim())
        }
    }
}

# ==============================================================================
# PREPROCESSOR TESTS
# ==============================================================================
Describe 'Preprocessor Features' -Tag 'Preprocessor' {
    Context 'removeAllComments' {
        BeforeAll {
            $commentedScript = @'
# This is a comment
Write-Output "Hello"
<# This is a block comment #>
Write-Output "World"
# Another comment
'@
            # input and output base names differ: -savePreprocessedScript refuses to
            # overwrite the input when both would share the same .ps1 name
            $script:CommentedFile = New-TestScript -Name 'comments-src.ps1' -Content $commentedScript
            $script:CommentExe = Join-Path $TestDrive 'comments.exe'
            Invoke-PS2EXE -inputFile $script:CommentedFile -outputFile $script:CommentExe -removeAllComments -savePreprocessedScript | Out-Null
        }

        It 'Should compile with comments stripped' {
            Test-Executable -Path $script:CommentExe | Should -BeTrue
        }

        It 'Should remove line and block comments but keep the code' {
            $saved = Get-Content -Raw (Join-Path $TestDrive 'comments.ps1')
            $saved | Should -Not -Match 'This is a comment'
            $saved | Should -Not -Match 'Another comment'
            $saved | Should -Not -Match 'block comment'
            $saved | Should -Match 'Write-Output "Hello"'
            $saved | Should -Match 'Write-Output "World"'
        }

        It 'Should run correctly after comment removal' {
            (Invoke-TestExe -Path $script:CommentExe).Output | Should -Be "Hello`r`nWorld"
        }

        It 'Should keep here-string bodies verbatim' {
            $hsFile = New-TestScript -Name 'herestring-src.ps1' -Content $script:HereStringScript
            $hsExe = Join-Path $TestDrive 'herestring.exe'
            Invoke-PS2EXE -inputFile $hsFile -outputFile $hsExe -removeAllComments -savePreprocessedScript | Out-Null
            # '#' lines inside the here-string body must survive stripping
            (Get-Content -Raw (Join-Path $TestDrive 'herestring.ps1')) | Should -Match '# not a comment'
            (Invoke-TestExe -Path $hsExe).Output | Should -Match '# not a comment'
        }

        It 'Should preserve #requires directives' {
            $reqScript = "#requires -Version 5.1`nWrite-Output 'requires-test'"
            $reqFile = New-TestScript -Name 'requires-src.ps1' -Content $reqScript
            $reqExe = Join-Path $TestDrive 'requires.exe'
            Invoke-PS2EXE -inputFile $reqFile -outputFile $reqExe -removeAllComments -savePreprocessedScript | Out-Null
            (Get-Content -Raw (Join-Path $TestDrive 'requires.ps1')) | Should -Match '#requires -Version 5.1'
        }

        It 'Should preserve non-ASCII string content' {
            # encoding round-trip check: no console output comparison (console code
            # pages would make that flaky), the saved script must contain the text
            $uniScript = 'Write-Output "Тест PS2EXE"'
            $uniFile = New-TestScript -Name 'unicode-src.ps1' -Content $uniScript
            $uniExe = Join-Path $TestDrive 'unicode.exe'
            Invoke-PS2EXE -inputFile $uniFile -outputFile $uniExe -removeAllComments -savePreprocessedScript | Out-Null
            (Get-Content -Raw (Join-Path $TestDrive 'unicode.ps1')) | Should -Match 'Тест PS2EXE'
        }

        It 'Should compile a script that contains only comments' {
            $commentOnlyFile = New-TestScript -Name 'comment-only.ps1' -Content '# Just a comment'
            $outputPath = Join-Path $TestDrive 'comment-only.exe'
            Invoke-PS2EXE -inputFile $commentOnlyFile -outputFile $outputPath -removeAllComments | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'mergeIncludes' {
        It 'Should merge a dot-sourced file and run the merged code' {
            $includedScript = 'function Test-Included { return "included function works" }'
            $includedFile = New-TestScript -Name 'included.ps1' -Content $includedScript
            $mainScript = ". `"$includedFile`"`nWrite-Output (Test-Included)"
            $mainFile = New-TestScript -Name 'merge-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes -savePreprocessedScript | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue

            $saved = Get-Content -Raw (Join-Path $TestDrive 'merged.ps1')
            $saved | Should -Match 'function Test-Included'
            # the dot-source line must be replaced by the inlined code
            $saved | Should -Not -Match ([regex]::Escape($includedFile))
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'included function works'
        }

        It 'Should convert dot-source arguments to parameter assignments' {
            $includedScript = @'
param([string]$Greeting = 'Hi')
Write-Output $Greeting
'@
            $includedFile = New-TestScript -Name 'included-param.ps1' -Content $includedScript
            $mainScript = ". `"$includedFile`" -Greeting 'Hello'"
            $mainFile = New-TestScript -Name 'merge-args-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged-args.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes -savePreprocessedScript | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            $saved = Get-Content -Raw (Join-Path $TestDrive 'merged-args.ps1')
            $saved | Should -Match '\$Greeting = ''Hello'''
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'Hello'
        }

        It 'Should merge a call-operator include' {
            $includedScript = 'function Test-CallIncluded { return "call include works" }'
            $includedFile = New-TestScript -Name 'call-included.ps1' -Content $includedScript
            $mainScript = "& `"$includedFile`""
            $mainFile = New-TestScript -Name 'merge-call-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged-call.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes -savePreprocessedScript | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Get-Content -Raw (Join-Path $TestDrive 'merged-call.ps1')) | Should -Match 'function Test-CallIncluded'
        }

        It 'Should merge an Import-Module file reference' {
            $moduleScript = 'function Test-Mod { return "mod works" }'
            $moduleFile = New-TestScript -Name 'testmod.psm1' -Content $moduleScript
            $mainScript = "Import-Module `"$moduleFile`"`nWrite-Output (Test-Mod)"
            $mainFile = New-TestScript -Name 'merge-mod-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged-mod.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'mod works'
        }

        It 'Should redirect a .psd1 manifest to its sibling .psm1 module' {
            $manifestFile = New-TestScript -Name 'testmod2.psd1' -Content "@{ ModuleVersion = '1.0' }"
            $moduleScript = 'function Test-Mod2 { return "psd1 redirect works" }'
            $moduleFile = New-TestScript -Name 'testmod2.psm1' -Content $moduleScript
            $mainScript = "Import-Module `"$manifestFile`"`nWrite-Output (Test-Mod2)"
            $mainFile = New-TestScript -Name 'merge-psd1-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged-psd1.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'psd1 redirect works'
        }

        It 'Should keep an unresolvable include line and still compile' {
            $mainScript = '. "C:\NonExistent\missing.ps1"' + "`n" + 'Write-Output "fallback"'
            $mainFile = New-TestScript -Name 'merge-missing-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'merged-missing.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes | Out-Null
            # the include cannot be resolved: the original line stays in the script
            # (it would fail at RUNTIME, so only compilation is checked here)
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should abort on circular includes' {
            $fileA = New-TestScript -Name 'circ-a.ps1' -Content '. "circ-b.ps1"'
            New-TestScript -Name 'circ-b.ps1' -Content '. "circ-a.ps1"'
            $outputPath = Join-Path $TestDrive 'circular.exe'
            Invoke-PS2EXE -inputFile $fileA -outputFile $outputPath -mergeIncludes | Out-Null
            $outputPath | Should -Not -Exist
        }
    }

    Context 'savePreprocessedScript' {
        It 'Should refuse to overwrite the input file' {
            # input "guard.ps1" and output "guard.exe" produce the preprocessed name
            # "guard.ps1" which equals the input: the module must keep the source
            $guardFile = New-TestScript -Name 'guard.ps1' -Content $script:HelloWorldScript
            $before = Get-Content -Raw $guardFile
            $outputPath = Join-Path $TestDrive 'guard.exe'
            Invoke-PS2EXE -inputFile $guardFile -outputFile $outputPath -removeAllComments -savePreprocessedScript | Out-Null
            Get-Content -Raw $guardFile | Should -Be $before
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should inherit the timestamps of the source' {
            $srcTime = Get-Date -Year 2019 -Month 11 -Day 30 -Hour 12 -Minute 30 -Second 0
            $scriptFile = New-TestScript -Name 'pre-times-src.ps1' -Content $script:HelloWorldScript
            Set-TestFileTimes -Path $scriptFile -Time $srcTime
            $outputPath = Join-Path $TestDrive 'pre-times.exe'
            Invoke-PS2EXE -inputFile $scriptFile -outputFile $outputPath -removeAllComments -savePreprocessedScript | Out-Null
            (Get-Item (Join-Path $TestDrive 'pre-times.ps1')).LastWriteTime | Should -Be $srcTime
        }
    }

    Context 'Timestamp inheritance with includes' {
        It 'Should use the newest timestamps of all merged files' {
            $includedScript = 'function Test-Time { return "time" }'
            $includedFile = New-TestScript -Name 'time-inc.ps1' -Content $includedScript
            $mainScript = ". `"$includedFile`"`nWrite-Output (Test-Time)"
            $mainFile = New-TestScript -Name 'time-main.ps1' -Content $mainScript
            # the include is NEWER than the main script: its timestamps must win
            Set-TestFileTimes -Path $mainFile -Time (Get-Date -Year 2020 -Month 1 -Day 1 -Hour 8 -Minute 0 -Second 0)
            $newerTime = Get-Date -Year 2021 -Month 6 -Day 1 -Hour 9 -Minute 15 -Second 0
            Set-TestFileTimes -Path $includedFile -Time $newerTime
            $outputPath = Join-Path $TestDrive 'time-merged.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -mergeIncludes | Out-Null
            (Get-Item $outputPath).LastWriteTime | Should -Be $newerTime
        }
    }
}

# ==============================================================================
# EMBEDDED FILES TESTS
# ==============================================================================
Describe 'Embedded Files' -Tag 'WinPS' {
    BeforeAll {
        # relative target path WITHOUT a leading .\ resolves against the current
        # directory at runtime
        $script:EmbedScript = 'if (Test-Path ''extracted\data.txt'') { Write-Output ''embed-ok'' } else { Write-Output ''embed-missing'' }'
        $script:EmbedFile = New-TestScript -Name 'embed-src.ps1' -Content $script:EmbedScript
        $script:DataFile = Join-Path $TestDrive 'data.txt'
        Set-Content -Path $script:DataFile -Value 'test data content'
    }

    Context 'Compilation' {
        It 'Should compile with embedded files' {
            $outputPath = Join-Path $TestDrive 'embedded.exe'
            $embedFiles = @{ 'extracted\data.txt' = $script:DataFile }
            Invoke-PS2EXE -inputFile $script:EmbedFile -outputFile $outputPath -embedFiles $embedFiles | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Runtime extraction' {
        It 'Should extract embedded files at startup' {
            $outputPath = Join-Path $TestDrive 'embedded-run.exe'
            $embedFiles = @{ 'extracted\data.txt' = $script:DataFile }
            Invoke-PS2EXE -inputFile $script:EmbedFile -outputFile $outputPath -embedFiles $embedFiles | Out-Null

            $workDir = Join-Path $TestDrive 'embed-work'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            Push-Location $workDir
            try {
                $result = Invoke-TestExe -Path $outputPath
            } finally {
                Pop-Location
            }
            $result.Output | Should -Be 'embed-ok'
            (Join-Path $workDir 'extracted\data.txt') | Should -Exist
        }
    }
}

# ==============================================================================
# CONFIG FILE TESTS
# ==============================================================================
Describe 'Config File Generation' -Tag 'WinPS' {
    BeforeAll {
        $script:TestFile = New-TestScript -Name 'config-src.ps1' -Content $script:HelloWorldScript
    }

    Context 'Config file generation in Windows PowerShell mode' {
        It 'Should generate a config file with -configFile' {
            $outputPath = Join-Path $TestDrive 'config.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -configFile | Out-Null
            "$outputPath.config" | Should -Exist
        }

        It 'Should generate a config file with -longPaths' {
            $outputPath = Join-Path $TestDrive 'longpaths.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -longPaths | Out-Null
            "$outputPath.config" | Should -Exist
        }

        It 'Should generate a config file with -winFormsDPIAware' {
            $outputPath = Join-Path $TestDrive 'winformsdpi.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -winFormsDPIAware | Out-Null
            "$outputPath.config" | Should -Exist
        }
    }

    Context 'Config file exclusions' {
        It 'Should not generate a config file in PS7 mode' {
            $outputPath = Join-Path $TestDrive 'noconfig-ps7.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -ps7 -configFile | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.config" | Should -Not -Exist
        }

        It 'Should not generate a config file in Core mode' -Skip:(-not $script:HasDotnetSDK) {
            $outputPath = Join-Path $TestDrive 'noconfig-core.exe'
            Invoke-PS2EXE -inputFile $script:TestFile -outputFile $outputPath -core -longPaths | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            "$outputPath.config" | Should -Not -Exist
        }
    }
}

# ==============================================================================
# CORE MODE TESTS (DOTNET PUBLISH)
# ==============================================================================
Describe 'Core Mode' -Tag 'Core' -Skip:(-not $script:HasDotnetSDK) {
    BeforeAll {
        $script:CoreTestFile = New-TestScript -Name 'core-test.ps1' -Content $script:HelloWorldScript
    }

    Context 'Basic compilation' {
        It 'Should compile a simple script to a console executable' {
            $outputPath = Join-Path $TestDrive 'core-basic.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            Get-PESubsystem -Path $outputPath | Should -Be 3
        }

        It 'Should compile a script with a param block' {
            $paramFile = New-TestScript -Name 'core-param-src.ps1' -Content $script:ParamScript
            $outputPath = Join-Path $TestDrive 'core-param.exe'
            Invoke-PS2EXE -inputFile $paramFile -outputFile $outputPath -core | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should run the compiled script and forward its output' {
            # end-to-end check that the preprocessed script WITH the injected path
            # variable marker is embedded and the marker replacement works
            $outputPath = Join-Path $TestDrive 'core-run.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core | Out-Null
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'Hello from PS2EXE test'
        }
    }

    Context 'Target framework selection' {
        It 'Should auto-detect the target framework and run the result' {
            # auto-detection picks the framework matching the installed SDK, so the
            # matching runtime is present and the executable can be run
            $outputPath = Join-Path $TestDrive 'core-auto.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'Hello from PS2EXE test'
        }

        It 'Should accept an explicit net6.0 target framework' {
            # compile-only: the machine may have just the newest runtime installed,
            # running a net6.0 binary would then fail with "install .NET 6.0";
            # the first run may download reference packs via NuGet
            $outputPath = Join-Path $TestDrive 'core-net6.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -targetFramework 'net6.0' | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should accept an explicit net8.0 target framework' {
            $outputPath = Join-Path $TestDrive 'core-net8.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -targetFramework 'net8.0' | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Single file publishing' {
        It 'Should produce a single file by default' {
            $outputDir = Join-Path $TestDrive 'core-single'
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            $outputPath = Join-Path $outputDir 'app.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core | Out-Null
            # single file publish must not litter the output folder with dependency DLLs
            (Get-ChildItem $outputDir -Filter '*.dll' | Measure-Object).Count | Should -Be 0
            Test-Executable -Path $outputPath | Should -BeTrue
        }

        It 'Should produce a folder with dependencies with -publishSingleFile:$false' {
            $outputDir = Join-Path $TestDrive 'core-multi'
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            $outputPath = Join-Path $outputDir 'app.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -publishSingleFile:$false | Out-Null
            # the PowerShell SDK dependencies must be deployed next to the executable
            (Get-ChildItem $outputDir -Filter '*.dll' | Measure-Object).Count | Should -BeGreaterOrEqual 1
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Optimization switches' {
        It 'Should compile with -readyToRun' {
            $outputPath = Join-Path $TestDrive 'core-r2r.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -readyToRun | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
        }
    }

    Context 'Incompatible switches are ignored' {
        It 'Should compile when incompatible switches are passed and stay a console application' {
            $outputPath = Join-Path $TestDrive 'core-incompat.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -noConsole -conHost -credentialGUI -noOutput -noError -exitOnCancel -lcid 1033 -STA -configFile -winFormsDPIAware | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            # -noConsole is ignored in Core mode: the result stays a console application
            Get-PESubsystem -Path $outputPath | Should -Be 3
            "$outputPath.config" | Should -Not -Exist
        }
    }

    Context 'Preprocessor features' {
        It 'Should merge includes and run the merged code' {
            # end-to-end check that the PREPROCESSED script is embedded in Core mode
            # (not the raw input file)
            $includedScript = 'function Test-CoreIncluded { return "core included" }'
            $includedFile = New-TestScript -Name 'core-included.ps1' -Content $includedScript
            $mainScript = ". `"$includedFile`"`nWrite-Output (Test-CoreIncluded)"
            $mainFile = New-TestScript -Name 'core-main.ps1' -Content $mainScript
            $outputPath = Join-Path $TestDrive 'core-merged.exe'
            Invoke-PS2EXE -inputFile $mainFile -outputFile $outputPath -core -mergeIncludes | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'core included'
        }

        It 'Should strip comments and run the result' {
            $commentedFile = New-TestScript -Name 'core-comments-src.ps1' -Content "# Comment`nWrite-Output 'core test'"
            $outputPath = Join-Path $TestDrive 'core-nocomments.exe'
            Invoke-PS2EXE -inputFile $commentedFile -outputFile $outputPath -core -removeAllComments | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Invoke-TestExe -Path $outputPath).Output | Should -Be 'core test'
        }

        It 'Should save the preprocessed script' {
            $outputPath = Join-Path $TestDrive 'core-saved.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -removeAllComments -savePreprocessedScript | Out-Null
            $preprocessedPath = [System.IO.Path]::ChangeExtension($outputPath, '.ps1')
            $preprocessedPath | Should -Exist
            (Get-Content -Raw $preprocessedPath) | Should -Match 'Hello from PS2EXE test'
        }
    }

    Context 'Metadata' {
        It 'Should embed title and version information' {
            # requires the assembly attribute block in the Core host template (M1)
            $outputPath = Join-Path $TestDrive 'core-meta.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core -title 'Core Test' -version '2.0.0' | Out-Null
            Test-Executable -Path $outputPath | Should -BeTrue
            (Get-Item $outputPath).VersionInfo.FileVersion | Should -Be '2.0.0'
            (Get-Item $outputPath).VersionInfo.FileDescription | Should -Be 'Core Test'
        }
    }

    Context 'Timestamp inheritance' {
        It 'Should inherit the file times of the input script' {
            $srcTime = Get-Date -Year 2022 -Month 2 -Day 2 -Hour 14 -Minute 20 -Second 0
            Set-TestFileTimes -Path $script:CoreTestFile -Time $srcTime
            $outputPath = Join-Path $TestDrive 'core-times.exe'
            Invoke-PS2EXE -inputFile $script:CoreTestFile -outputFile $outputPath -core | Out-Null
            (Get-Item $outputPath).LastWriteTime | Should -Be $srcTime
        }
    }
}

# ==============================================================================
# CORE RUNTIME TESTS
# ==============================================================================
Describe 'Core Runtime' -Tag 'CoreRuntime' -Skip:(-not $script:HasDotnetSDK) {
    BeforeAll {
        $script:ParamFile = New-TestScript -Name 'core-run-param.ps1' -Content $script:ParamScript
        $script:ParamExe = Join-Path $TestDrive 'core-run-param.exe'
        Invoke-PS2EXE -inputFile $script:ParamFile -outputFile $script:ParamExe -core | Out-Null

        $script:ArgsFile = New-TestScript -Name 'core-run-args.ps1' -Content $script:ArgsScript
        $script:ArgsExe = Join-Path $TestDrive 'core-run-args.exe'
        Invoke-PS2EXE -inputFile $script:ArgsFile -outputFile $script:ArgsExe -core | Out-Null

        $script:ExitFile = New-TestScript -Name 'core-run-exit.ps1' -Content $script:ExitCodeScript
        $script:ExitExe = Join-Path $TestDrive 'core-run-exit.exe'
        Invoke-PS2EXE -inputFile $script:ExitFile -outputFile $script:ExitExe -core | Out-Null
    }

    Context 'Parameter binding' {
        It 'Should bind named arguments' {
            # requires the argument parser in the Core host: a plain AddArgument
            # loop would pass "-Name" as a literal positional string
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Name', 'Pester', '-Count', '3')
            $result.Output | Should -Be 'Hello Pester x3 flag=False'
        }

        It 'Should bind $TRUE and $FALSE to switch parameters' {
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Flag:$TRUE')
            $result.Output | Should -Be 'Hello World x1 flag=True'
            $result = Invoke-TestExe -Path $script:ParamExe -Arguments @('-Flag:$FALSE')
            $result.Output | Should -Be 'Hello World x1 flag=False'
        }
    }

    Context '$args variable' {
        It 'Should pass unbound arguments to $args' {
            $result = Invoke-TestExe -Path $script:ArgsExe -Arguments @('a', 'b', 'c')
            $result.Output | Should -Be 'count=3'
        }
    }

    Context 'Exit codes' {
        It 'Should forward the script exit code' {
            $result = Invoke-TestExe -Path $script:ExitExe
            $result.Output | Should -Be 'exiting'
            $result.ExitCode | Should -Be 42
        }
    }
}