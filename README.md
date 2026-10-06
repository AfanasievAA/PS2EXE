# PS2EXE
Rework of the great script of Ingo Karstein with GUI support. The GUI output and input is activated with the `-noConsole` switch, real Windows executables are generated. By default compiles PowerShell 5.x compatible scripts. With `-ps7` a lightweight executable is generated that runs the embedded script via `pwsh.exe` (PowerShell 7+); PowerShell 7+ must be installed on the target machine. With optional graphical front end Win-PS2EXE.

Module version.

Original Authors: Ingo Karstein, Markus Scholtes. You find the original script based version here (https://github.com/MScholtes/TechNet-Gallery).
Fork Author: Andrew Afanasiev

Version: 1.0.19
(PowerShell 7+ support)

Date: 2026.10.06

## Installation

Download from here: https://github.com/AfanasievAA/PS2EXE

## Usage
```powershell
  Invoke-ps2exe .\source.ps1 .\target.exe
```
or
```powershell
  ps2exe .\source.ps1 .\target.exe
```
compiles "source.ps1" into the executable target.exe (if ".\target.exe" is omitted, output is written to ".\source.exe").

or start Win-PS2EXE for a graphical front end with
```powershell
  Win-PS2EXE
```
### Compile a PowerShell 7+ executable (console mode)

```powershell
Invoke-ps2exe -inputFile .\MyScript.ps1 -outputFile .\MyScript7.exe -ps7
```
The resulting executable is a lightweight .NET Framework stub that locates `pwsh.exe` (PowerShell 7+) on the target machine, extracts the embedded script to a temporary wrapper `.ps1` and runs it via `pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File <temp_script>`.

- PowerShell 7+ must be installed on the target machine.
- In console mode `pwsh.exe` inherits the console for interactive input/output.
- `-conHost`, `-credentialGUI` and `-UNICODEEncoding` are not applicable with `-ps7` and are ignored with a warning.

### Compile a PowerShell 7+ GUI executable (no console window)

```powershell
Invoke-ps2exe -inputFile .\MyScript.ps1 -outputFile .\MyScript7.exe `
    -ps7 -noConsole -title "MyScript" -version 1.0.0.1
```
The resulting executable is a graphical application: stdout and stderr of `pwsh.exe` are captured and shown in message boxes. Progress, verbose, debug and information streams are not displayed unless redirected inside the script.

## Parameter
```powershell
ps2exe [-inputFile] '<file_name>' [[-outputFile] '<file_name>']
       [-prepareDebug] [-x86|-x64] [-lcid <id>] [-STA|-MTA] [-noConsole] [-conHost] [-UNICODEEncoding]
       [-credentialGUI] [-iconFile '<filename>'] [-embedFiles <hashtable>] [-title '<title>'] [-description '<description>']
       [-company '<company>'] [-product '<product>'] [-copyright '<copyright>'] [-trademark '<trademark>']
       [-version '<version>'] [-configFile] [-noOutput] [-noError] [-noVisualStyles] [-exitOnCancel]
       [-DPIAware] [-winFormsDPIAware] [-requireAdmin] [-supportOS] [-virtualize] [-longPaths]
       [-ps7]
```

```
      inputFile = Powershell script that you want to convert to executable (file has to be UTF8 or UTF16 encoded)
     outputFile = destination executable file name or folder, defaults to inputFile with extension '.exe'
   prepareDebug = create helpful information for debugging
     x86 or x64 = compile for 32-bit or 64-bit runtime only
           lcid = location ID for the compiled executable. Current user culture if not specified
     STA or MTA = 'Single Thread Apartment' or 'Multi Thread Apartment' mode
      noConsole = the resulting executable will be a Windows Forms app without a console window
        conHost = force start with conhost as console instead of Windows Terminal (disables redirections)
                  not applicable with -ps7
UNICODEEncoding = encode output as UNICODE in console mode
                  not applicable with -ps7
  credentialGUI = use GUI for prompting credentials in console mode
                  not applicable with -ps7
       iconFile = icon file name for the compiled executable
     embedFiles = files to embed given as hash, will be extracted to key of hash, source file names must be unique
                  (e.g. -embedFiles @{'Targetfilepath'='Sourcefilepath'} )
          title = title information (displayed in details tab of Windows Explorer's properties dialog)
    description = description information (not displayed, but embedded in executable)
        company = company information (not displayed, but embedded in executable)
        product = product information (displayed in details tab of Windows Explorer's properties dialog)
      copyright = copyright information (displayed in details tab of Windows Explorer's properties dialog)
      trademark = trademark information (displayed in details tab of Windows Explorer's properties dialog)
        version = version information (displayed in details tab of Windows Explorer's properties dialog)
     configFile = write config file (<outputfile>.exe.config)
       noOutput = the resulting executable will generate no standard output (includes verbose and information channel)
        noError = the resulting executable will generate no error output (includes warning and debug channel)
 noVisualStyles = disable visual styles for a generated windows GUI application (only with -noConsole)
   exitOnCancel = exits program when Cancel or "X" is selected in a Read-Host input box (only with -noConsole)
       DPIAware = if display scaling is activated, GUI controls will be scaled if possible (only with -noConsole)
   requireAdmin = if UAC is enabled, compiled executable run only in elevated context (UAC dialog appears if required)
      supportOS = use functions of newest Windows versions (execute [Environment]::OSVersion to see the difference)
     virtualize = application virtualization is activated (forcing x86 runtime)
      longPaths = enable long paths ( > 260 characters) if enabled on OS (works only with Windows 10)
           ps7 = generate an executable that runs the embedded script via pwsh.exe (PowerShell 7+)
                 PowerShell 7+ must be installed on the target machine.
                 In console mode pwsh.exe inherits the console for interactive input/output.
                 In GUI mode (-noConsole) output is captured and shown in message boxes.
                 Not applicable together with -conHost, -credentialGUI and -UNICODEEncoding
                 (those parameters are ignored with a warning).
```

A generated executable has the following reserved parameters:

```
-? [<MODIFIER>]     Powershell help text of the script inside the executable. The optional parameter combination
                    "-? -detailed", "-? -examples" or "-? -full" can be used to get the appropriate help text.
-debug              Forces the executable to be debugged. It calls "System.Diagnostics.Debugger.Launch()".
-extract:<FILENAME> Extracts the powerShell script inside the executable and saves it as FILENAME.
                    The script will not be executed.
-wait               At the end of the script execution it writes "Hit any key to exit..." and waits for a key to be pressed.
-end                All following options will be passed to the script inside the executable.
                    All preceding options are used by the executable itself and will not be passed to the script.
```


## Remarks

### Use of Powershell Core:
PS2EXE can be used with Powershell Core. To do so just install the module PS2EXE in Powershell Core as described above. Since .NET Core does not ship with a compiler, the .NET Framework compiler is used (both .NET Framework and PowerShell 5.1 are included in Windows).

**Without `-ps7` PS2EXE can only compile PowerShell 5.1 compatible scripts and generates .NET 4.x binaries, but can still be used directly on every supported Windows OS without dependencies.**

**With `-ps7`** PS2EXE generates a lightweight .NET Framework stub executable that:
1. Locates `pwsh.exe` (PowerShell 7+) via registry or well-known paths.
2. Extracts the embedded script to a temporary wrapper `.ps1` file that sets `$ScriptRoot`, `$PSScriptRoot`, `$PSCommandPath` and the culture.
3. Launches `pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File <temp_script> <args>`.
4. In console mode inherits the console for interactive input/output; in GUI mode (`-noConsole`) captures output and shows it in message boxes.
5. Cleans up the temporary file and returns the exit code of `pwsh.exe`.

PowerShell 7+ must be installed on the target machine. `-conHost`, `-credentialGUI` and `-UNICODEEncoding` are not applicable with `-ps7` and are ignored with a warning.

### Embedding files in compiled executables:
With the parameter *-embedFiles* followed by a hash table with paths to files those files will be embedded in the compiled executable.
At startup of the executable those files will be written to disk to the specified paths, e.g. *-embedFiles @{'Targetfilepath1'='Sourcefilepath1';'Targetfilepath2'='Sourcefilepath2'}*.
Source file names must be unique. Absolute and relative paths are allowed. For target paths a relative path beginning with *'.\\'* is interpreted as relative to the executable, without the leading *'.\\'* as relative to the current path at runtime.
Directories are created automaticly on startup if necessary. In the target path environment variables in cmd.exe notation like *%TEMP%* or *%APPDATA%* are expanded at runtime.
A failure in creating one of the embedded files will stop the execution of the compiled executable immediately.

### List of cmdlets not implemented:
The basic input/output commands had to be rewritten in C# for PS2EXE. Not implemented are *Write-Progress* in console mode (too much work) and *Start-Transcript*/*Stop-Transcript* (no proper reference implementation by Microsoft).

### GUI mode output formatting:
By default in powershell outputs of commandlets are formatted line per line (as an array of strings). When your command generates 10 lines of output and you use GUI output, 10 message boxes will appear each awaiting for an OK. To prevent this pipe your commandto the comandlet Out-String. This will convert the output to one string array with 10 lines, all output will be shown in one message box (for example: dir C:\ | Out-String).

### Config files:
PS2EXE can create config files with the name of the generated executable + ".config". In most cases those config files are not necessary, they are a manifest that tells which .Net Framework version should be used. As you will usually use the actual .Net Framework, try running your excutable without the config file.

### Parameter processing:
Compiled scripts process parameters like the original script does. One restriction comes from the Windows environment: for all executables all parameters have the type STRING, if there is no implicit conversion for your parameter type you have to convert explicitly in your script. You can even pipe content to the executable with the same restriction (all piped values have the type STRING).

### Password security:
Never store passwords in your compiled script! One can simply decompile the script with the parameter -extract. For example
```powershell
Output.exe -extract:C:\Output.ps1
```
will decompile the script stored in Output.exe. And notice: the script (intentionally) is stored in clear text in the executable!

### Script variables:
Since PS2EXE converts a script to an executable, script related variables are not available anymore. The variable $MyInvocation is set to other values than in a script.

Since v0.5.1.0 the variables $ScriptRoot, $PSScriptRoot and $PSCommandPath are set by PS2EXE in both PS 5.1 and PS7 modes and point to the location of the executable (in PS7 mode they are set in the wrapper script before user code runs).

You can get $PSScriptRoot independently of compiled/not compiled with the following code line:

```powershell
if (!$PSScriptRoot) { $PSScriptRoot = $ScriptRoot }
```

### Window in background in -noConsole mode:
When an external window is opened in a script with -noConsole mode (i.e. for Get-Credential or for a command that needs a cmd.exe shell) the next window is opened in the background.

The reason for this is that on closing the external window windows tries to activate the parent window. Since the compiled script has no window, the parent window of the compiled script is activated instead, normally the window of Explorer or Powershell.

To work around this, $Host.UI.RawUI.FlushInputBuffer() opens an invisible window that can be activated. The following call of $Host.UI.RawUI.FlushInputBuffer() closes this window (and so on).

The following example will not open a window in the background anymore as a single call of "ipconfig | Out-String" will do:

```powershell
$Host.UI.RawUI.FlushInputBuffer()
ipconfig | Out-String
$Host.UI.RawUI.FlushInputBuffer()
```

## Changes:
### 1.0.19 / 2026-10-06
- bugfixes, more av friendly output

### 1.0.18 - 2026-09-16
- predefined variable $ScriptRoot as replacement for $PSScriptRoot
- powershell 7+ compiling support. new  -ps7 parameter: generates EXE that runs embedded script
         via pwsh.exe (PowerShell 7+). PowerShell 7+ must be installed
         on the target machine

### 1.0.17 / 2025-08-21
- new parameter -embedFiles to embed files in compiled executable

### 1.0.16 / 2025-07-20
- new parameter -conHost for force starting compiled executables in Conhost instead of Windows Terminal

### 1.0.15 / 2025-01-05
- if used only in Powershell Core the module has not to be installed in Powershell 5.1 too

### 1.0.14 / 2024-09-15
- new parameter -? for compiled executables to show the help of the original Powershell script
- in GUI mode window titles are the application title (when set compiling with parameter -title)

### 1.0.13 / 2023-09-26
- now [ and ] are supported in directory name of script
- source file might be larger than 16 MB (for whoever that needs)
- new addtional parameter text field in Win-PS2EXE

### 1.0.12 / 2022-11-22
- new parameter -winFormsDPIAware to support scaling for WinForms in noConsole mode (only Windows 10 or up)

### 1.0.11 / 2021-11-21
- fixed password longer than 24 characters error
- new parameter -DPIAware to support scaling in noConsole mode
- new parameter -exitOnCancel to stop program execution on cancel in input boxes (only in noConsole mode)

### 1.0.10 / 2021-04-10
- parameter outputFile now accepts a target folder (without filename)

### 1.0.9 / 2021-02-28
- new parameter UNICODEEncoding to output as UNICODE
- changed parameter debug to prepareDebug
- finally dared to use advanced parameters

### 1.0.8 / 2020-10-24
- refactored

### 1.0.7 / 2020-08-21
- bug fix for simultanous progress bars in one pipeline

### 1.0.6 / 2020-08-10
- prompt for choice behaves like Powershell now (console mode only)
- (limited) support for Powershell Core (starts Windows Powershell in the background)
- fixed processing of negative parameter values
- support for animated progress bars (noConsole mode only)

### 1.0.5 / 2020-07-11
- support for nested progress bars (noConsole mode only)

### 1.0.4 / 2020-04-19
- Application.EnableVisualStyles() as default for GUI applications, new parameter -noVisualStyles to prevent this

### 1.0.3 / 2020-02-15
- converted files from UTF-16 to UTF-8 to allow git diff
- ignore control keys in secure string request in console mode

### 1.0.2 / 2020-01-08
- added examples to github

### 1.0.1 / 2019-12-16
- fixed "unlimited window width for GUI windows" issue in ps2exe.ps1 and Win-PS2EXE

### 1.0.0 / 2019-11-08
- first stable module version

### 0.0.0 / 2019-09-15
- experimental
