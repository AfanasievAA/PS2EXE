#Requires -Version 5.1
<#
.SYNOPSIS
Graphical front end for Invoke-ps2exe.
.DESCRIPTION
WinForms GUI for the ps2exe compiler. Written in PowerShell 5.1+,
no external dependencies. Replaces the legacy compiled Win-PS2EXE.exe.
.NOTES
Version: 1.0.22
Date: 2026.10.19
Fork Author: Andrew Afanasiev
Original author: Markus Scholtes (original Win-PS2EXE.exe)
#>
function Show-WinPS2EXE {
    [CmdletBinding()]
    param()
    # WinForms requires STA: relaunch self in STA when needed; the script only defines the function, so call it explicitly
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command ". '$PSCommandPath'; Show-WinPS2EXE"
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    # ==============================================================
    # Settings persistence: %APPDATA%\ps2exe\Win-PS2EXE.settings.xml
    # ==============================================================
    $settingsFile = Join-Path $env:APPDATA 'ps2exe\Win-PS2EXE.settings.xml'
    $defaults = @{
        SourceFile = ''; DestinationFile = ''; IconFile = ''
        ps7 = $FALSE; core = $FALSE; STA = $TRUE; MTA = $FALSE
        noConsole = $FALSE; conHost = $FALSE; credentialGUI = $FALSE
        noOutput = $FALSE; noError = $FALSE; exitOnCancel = $FALSE
        DPIAware = $FALSE; winFormsDPIAware = $FALSE; requireAdmin = $FALSE; supportOS = $FALSE
        longPaths = $FALSE; prepareDebug = $FALSE; configFile = $FALSE
        removeAllComments = $FALSE; mergeIncludes = $FALSE; savePreprocessedScript = $FALSE
        targetFramework = ''; publishSingleFile = $TRUE; readyToRun = $FALSE
        title = ''; description = ''; company = ''; product = ''; copyright = ''; trademark = ''; version = ''
    }
    $settings = $defaults.Clone()
    try {
        if (Test-Path -LiteralPath $settingsFile) {
            $loaded = Import-Clixml -LiteralPath $settingsFile
            foreach ($key in $loaded.Keys) { if ($settings.ContainsKey($key)) { $settings[$key] = $loaded[$key] } }
        }
    } catch { } # corrupted settings file: fall back to defaults
    # ==============================================================
    # Form construction
    # ==============================================================
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Win-PS2EXE'
    $form.Size = New-Object System.Drawing.Size(760, 725)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $FALSE
    $form.AutoScaleMode = 'Dpi'
    # --- File section ---
    $gbFiles = New-Object System.Windows.Forms.GroupBox
    $gbFiles.Text = 'Files'; $gbFiles.Location = New-Object System.Drawing.Point(10, 10)
    $gbFiles.Size = New-Object System.Drawing.Size(725, 125)
    $form.Controls.Add($gbFiles)
    function New-FileRow([System.Windows.Forms.Control]$parent, [string]$labelText, [string]$filter, [bool]$saveDialog, [int]$y) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.Location = New-Object System.Drawing.Point(10, ($y + 3)); $lbl.AutoSize = $TRUE
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(140, $y); $tb.Size = New-Object System.Drawing.Size(480, 21)
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Browse...'; $btn.Location = New-Object System.Drawing.Point(630, ($y - 1)); $btn.Size = New-Object System.Drawing.Size(80, 23)
        # capture what the click handler needs in the button: function parameters go out of scope when the handler fires
        $btn.Tag = @{ TextBox = $tb; SaveDialog = $saveDialog; Filter = $filter }
        $btn.Add_Click({
                if ($this.Tag.SaveDialog) {
                    $dlg = New-Object System.Windows.Forms.SaveFileDialog
                    $dlg.Filter = 'Executable (*.exe)|*.exe|Command file (*.com)|*.com'
                } else { $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = $this.Tag.Filter }
                # preset dialog from the textbox; guarded: text may be a not-yet-valid path
                # (.NET Framework throws in the Path methods, .NET Core does not)
                try {
                    if ($this.Tag.TextBox.Text) {
                        $dlg.FileName = [System.IO.Path]::GetFileName($this.Tag.TextBox.Text)
                        $dir = [System.IO.Path]::GetDirectoryName($this.Tag.TextBox.Text)
                        if ($dir) { $dlg.InitialDirectory = $dir }
                    }
                } catch { }
                if ($dlg.ShowDialog() -eq 'OK') { $this.Tag.TextBox.Text = $dlg.FileName }
            })
        $parent.Controls.Add($lbl); $parent.Controls.Add($tb); $parent.Controls.Add($btn)
        return $tb
    }
    $tbSource = New-FileRow $gbFiles 'Source file' 'PowerShell scripts (*.ps1;*.psm1)|*.ps1;*.psm1' $FALSE 25
    $tbSource.Add_TextChanged({
            # follow the source file name but keep the chosen destination directory.
            # All path processing is guarded: .NET Framework throws on invalid paths
            # while typing, Destination stays unchanged until the input is valid
            if ([string]::IsNullOrWhiteSpace($tbSource.Text)) { return }
            # unwrap a quoted path ("Copy as path", drag&drop); assigning back re-fires once with the clean value
            $src = $tbSource.Text.Trim()
            if ($src.Length -gt 2 -and $src.StartsWith('"') -and $src.EndsWith('"')) {
                $tbSource.Text = $src.Trim('"')
                return
            }
            try {
                # compute the full new destination first: an exception must not leave a half-updated state
                $newName = [System.IO.Path]::GetFileNameWithoutExtension($src) + '.exe'
                $destDir = [System.IO.Path]::GetDirectoryName($tbDest.Text)
                if ([string]::IsNullOrWhiteSpace($destDir)) { $newDest = $newName }
                else { $newDest = [System.IO.Path]::Combine($destDir, $newName) }
            } catch { return }
            $tbDest.Text = $newDest
        })
    $tbDest = New-FileRow $gbFiles 'Destination file' '' $TRUE 55
    $tbIcon = New-FileRow $gbFiles 'Icon file' 'Icon files (*.ico)|*.ico' $FALSE 85
    # --- Options section (tabs) ---
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 145); $tabs.Size = New-Object System.Drawing.Size(725, 445)
    $form.Controls.Add($tabs)
    $chk = @{} # checkbox registry by parameter name
    function New-CheckBox([System.Windows.Forms.Control]$parent, [string]$name, [string]$text, [int]$x, [int]$y, [string]$tooltip) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "-$name"; $cb.Tag = $name; $cb.AccessibleName = $name
        $cb.Location = New-Object System.Drawing.Point($x, $y); $cb.AutoSize = $TRUE
        if ($tooltip) { $tt.SetToolTip($cb, $tooltip) }
        $parent.Controls.Add($cb)
        # registry in the function's local scope: handlers fire inside ShowDialog() while this frame is alive,
        # dynamic scoping finds it ($script: would point to the loading scope where $chk does not exist)
        $chk[$name] = $cb
        return $cb
    }
    $tt = New-Object System.Windows.Forms.ToolTip
    # keep the tooltip visible long enough to read the multi-line descriptions
    $tt.AutoPopDelay = 15000
    # hover descriptions from the Invoke-ps2exe documentation (.PARAMETER help of ps2exe.ps1);
    # single source of truth for all checkboxes and the version info fields.
    # ToolTips do not wrap, so longer descriptions carry manual line breaks
    $paramHelp = @{
        noConsole = "The resulting executable will be a Windows Forms app without a console window.`nYou might want to pipe your output to Out-String to prevent a message box for every line of output"
        conHost = "Force start with conhost as console instead of Windows Terminal.`nIf necessary a new console window will appear.`nImportant: disables redirection of input, output or error channel!`nNot applicable with -ps7"
        credentialGUI = "Use GUI for prompting credentials in console mode instead of console input.`nNot applicable with -ps7"
        noOutput = "The resulting executable will generate no standard output (includes verbose and information channel).`nNot applicable with -ps7"
        noError = "The resulting executable will generate no error output (includes warning and debug channel).`nNot applicable with -ps7"
        exitOnCancel = "Exits program when Cancel or `"X`" is selected in a Read-Host input box.`nOnly applicable with -noConsole. Not applicable with -ps7"
        DPIAware = 'If display scaling is activated, GUI controls will be scaled if possible'
        winFormsDPIAware = "Creates an entry in the config file for WinForms to use DPI scaling.`nForces -configFile and -supportOS (requires Windows 10 and .NET 4.7 or up).`nNot applicable with -ps7"
        requireAdmin = 'If UAC is enabled, compiled executable will run only in elevated context (UAC dialog appears if required)'
        supportOS = 'Use functions of newest Windows versions (execute [Environment]::OSVersion to see the difference)'
        longPaths = 'Enable long paths ( > 260 characters) if enabled on OS (works only with Windows 10 or up)'
        prepareDebug = 'Create helpful information for debugging of the generated executable (see parameter -debug there)'
        configFile = "Write a config file (<outputfile>.exe.config).`nNot applicable with -ps7"
        removeAllComments = "Strip all comments (# line, <# #> block, #region/#endregion) from the input script before embedding.`nHere-string bodies are kept verbatim, #requires directives are preserved.`nA script extracted with -extract:<FILENAME> will not match the original input file"
        mergeIncludes = "Inline every dot-sourced, call-operator or Import-Module file reference (recursively)`ninto one self-contained script before embedding. Implies -removeAllComments.`nParam blocks of included files become parameter assignments"
        savePreprocessedScript = "Save the preprocessed script (result of -removeAllComments or -mergeIncludes) as a .ps1 file`nnext to the output executable, before the PS2EXE path variable marker is injected"
        title = "Title information (displayed in details tab of Windows Explorer's properties dialog)"
        description = 'Description information (not displayed, but embedded in executable)'
        company = 'Company information (not displayed, but embedded in executable)'
        product = "Product information (displayed in details tab of Windows Explorer's properties dialog)"
        copyright = "Copyright information (displayed in details tab of Windows Explorer's properties dialog)"
        trademark = "Trademark information (displayed in details tab of Windows Explorer's properties dialog)"
        version = "Version information (displayed in details tab of Windows Explorer's properties dialog).`nForm: n.n.n.n, n.n.n, n.n or n"
        targetFramework = "Target .NET framework version for Core mode: net6.0, net7.0, net8.0, net9.0, net10.0 or net11.0.`nIf not specified, the latest supported version for the installed .NET SDK is used automatically."
        publishSingleFile = "Publish the Core mode executable as a single self-contained file (default: enabled).`nAll managed DLLs are bundled into one exe. Use -publishSingleFile:$false to disable."
        readyToRun = "Pre-compile Core mode assemblies to ReadyToRun (R2R) format for faster startup.`nTrades slightly larger file size for improved launch performance."
        SourceFile = 'PowerShell script to convert to executable (file has to be UTF8 or UTF16 encoded)'
        DestinationFile = "Destination executable file name or folder, defaults to the source file name with extension '.exe'"
        IconFile = 'Icon file name for the compiled executable'
    }
    $tt.SetToolTip($tbSource, $paramHelp['SourceFile'])
    $tt.SetToolTip($tbDest, $paramHelp['DestinationFile'])
    $tt.SetToolTip($tbIcon, $paramHelp['IconFile'])
    # --- Tab: General ---
    $tabGeneral = New-Object System.Windows.Forms.TabPage; $tabGeneral.Text = 'General'
    $tabs.Controls.Add($tabGeneral)
    $lblRuntime = New-Object System.Windows.Forms.Label
    $lblRuntime.Text = 'Runtime:'; $lblRuntime.Location = New-Object System.Drawing.Point(15, 20); $lblRuntime.AutoSize = $TRUE
    $tabGeneral.Controls.Add($lblRuntime)
    $rbPS5 = New-Object System.Windows.Forms.RadioButton
    $rbPS5.Text = 'PowerShell 5.1 (in-process host)'; $rbPS5.Location = New-Object System.Drawing.Point(90, 15); $rbPS5.AutoSize = $TRUE
    $rbPS7 = New-Object System.Windows.Forms.RadioButton
    $rbPS7.Text = 'PowerShell 7+ (pwsh.exe stub)'; $rbPS7.Location = New-Object System.Drawing.Point(90, 40); $rbPS7.AutoSize = $TRUE
    $rbCore = New-Object System.Windows.Forms.RadioButton
    $rbCore.Text = '.NET Core (Roslyn compilation)'; $rbCore.Location = New-Object System.Drawing.Point(90, 65); $rbCore.AutoSize = $TRUE
    $tabGeneral.Controls.Add($rbPS5); $tabGeneral.Controls.Add($rbPS7); $tabGeneral.Controls.Add($rbCore)
    # PS7/Core incompatible parameters: dimmed and disabled (STA/MTA are radio buttons, the sync dims them itself).
    # CheckedChanged fires only on an actual state change, so restoring persisted settings that select PS7 fired
    # nothing; the restore section therefore invokes the sync once explicitly
    $ps7Incompatible = @('conHost', 'credentialGUI', 'noOutput', 'noError', 'exitOnCancel', 'configFile', 'winFormsDPIAware')
    $coreIncompatible = @('conHost', 'credentialGUI', 'noOutput', 'noError', 'exitOnCancel', 'configFile', 'winFormsDPIAware', 'DPIAware', 'longPaths', 'prepareDebug')
    $syncRuntimeConstraints = {
        $ps7Selected = $rbPS7.Checked
        $coreSelected = $rbCore.Checked
        foreach ($name in $coreIncompatible) { if ($chk[$name]) { $chk[$name].Enabled = -not ($ps7Selected -or $coreSelected) } }
        $rbSTA.Enabled = $rbPS5.Checked
        $rbMTA.Enabled = $rbPS5.Checked
        $gbCoreParams.Enabled = $coreSelected
    }
    $rbPS5.Add_CheckedChanged($syncRuntimeConstraints)
    $rbPS7.Add_CheckedChanged($syncRuntimeConstraints)
    $rbCore.Add_CheckedChanged($syncRuntimeConstraints)
    $gbFlags1 = New-Object System.Windows.Forms.GroupBox
    $gbFlags1.Text = 'Output and behavior'; $gbFlags1.Location = New-Object System.Drawing.Point(10, 95); $gbFlags1.Size = New-Object System.Drawing.Size(345, 190)
    $tabGeneral.Controls.Add($gbFlags1)
    $i = 0
    foreach ($name in @('noConsole', 'conHost', 'credentialGUI', 'noOutput', 'noError', 'exitOnCancel', 'DPIAware', 'winFormsDPIAware', 'requireAdmin', 'supportOS', 'longPaths', 'prepareDebug', 'configFile')) {
        # two columns: y advances every second checkbox, odd indices shift right
        $cbX = 15; $cbY = 25 + 23 * ([math]::Floor($i / 2))
        if ($i % 2 -eq 1) { $cbX = 180 }
        New-CheckBox $gbFlags1 $name "-$name" $cbX $cbY $paramHelp[$name] | Out-Null
        $i++
    }
    $gbPre = New-Object System.Windows.Forms.GroupBox
    $gbPre.Text = 'Preprocessing'; $gbPre.Location = New-Object System.Drawing.Point(10, 295); $gbPre.Size = New-Object System.Drawing.Size(345, 105)
    $tabGeneral.Controls.Add($gbPre)
    $cbRemoveComments = New-CheckBox $gbPre 'removeAllComments' '-removeAllComments' 15 25 $paramHelp['removeAllComments']
    $cbMergeIncludes = New-CheckBox $gbPre 'mergeIncludes' '-mergeIncludes' 15 48 $paramHelp['mergeIncludes']
    $lblImpl = New-Object System.Windows.Forms.Label
    $lblImpl.Text = 'mergeIncludes implies removeAllComments'; $lblImpl.ForeColor = 'Gray'
    $lblImpl.Location = New-Object System.Drawing.Point(130, 52); $lblImpl.AutoSize = $TRUE
    $gbPre.Controls.Add($lblImpl)
    $cbSavePre = New-CheckBox $gbPre 'savePreprocessedScript' '-savePreprocessedScript' 15 75 $paramHelp['savePreprocessedScript']
    # the save switch is only meaningful with an active preprocessing switch (handler also fires during settings restore)
    $syncSaveEnabled = { $cbSavePre.Enabled = ($cbRemoveComments.Checked -or $cbMergeIncludes.Checked) }
    $cbRemoveComments.Add_CheckedChanged($syncSaveEnabled)
    $cbMergeIncludes.Add_CheckedChanged($syncSaveEnabled)
    & $syncSaveEnabled
    $gbArch = New-Object System.Windows.Forms.GroupBox
    $gbArch.Text = 'Apartment (PS 5.1 only)'; $gbArch.Location = New-Object System.Drawing.Point(365, 95); $gbArch.Size = New-Object System.Drawing.Size(345, 100)
    $tabGeneral.Controls.Add($gbArch)
    $rbSTA = New-Object System.Windows.Forms.RadioButton; $rbSTA.Text = 'STA (default)'; $rbSTA.Location = New-Object System.Drawing.Point(15, 30); $rbSTA.AutoSize = $TRUE
    $rbMTA = New-Object System.Windows.Forms.RadioButton; $rbMTA.Text = 'MTA'; $rbMTA.Location = New-Object System.Drawing.Point(180, 30); $rbMTA.AutoSize = $TRUE
    $rbSTA.Tag = 'STA'; $rbMTA.Tag = 'MTA'
    $gbArch.Controls.AddRange(@($rbSTA, $rbMTA))
    $tt.SetToolTip($rbPS5, "Compile a full in-process Windows PowerShell 5.1 host into the executable.`nAll compiler options are available. Needs the .NET Framework (included in Windows)")
    $tt.SetToolTip($rbPS7, "Generate a lightweight stub executable that runs the embedded script via pwsh.exe.`nParameters not applicable with -ps7 are disabled.`nThe target machine must have PowerShell 7+ installed")
    $tt.SetToolTip($rbCore, "Compile to a native .NET executable using Roslyn compilation (dotnet publish).`nRequires the .NET SDK on the build machine.`nThe target machine needs the matching .NET Runtime installed")
    $tt.SetToolTip($rbSTA, "'Single Thread Apartment' mode (default). Required for clipboard access and most GUI operations in the compiled script")
    $tt.SetToolTip($rbMTA, "'Multi Thread Apartment' mode")
    # --- Core mode parameters panel ---
    $gbCoreParams = New-Object System.Windows.Forms.GroupBox
    $gbCoreParams.Text = 'Core mode parameters'; $gbCoreParams.Location = New-Object System.Drawing.Point(365, 205); $gbCoreParams.Size = New-Object System.Drawing.Size(345, 105)
    $tabGeneral.Controls.Add($gbCoreParams)
    $lblTF = New-Object System.Windows.Forms.Label
    $lblTF.Text = 'Target framework:'; $lblTF.Location = New-Object System.Drawing.Point(15, 25); $lblTF.AutoSize = $TRUE
    $cboTF = New-Object System.Windows.Forms.ComboBox
    $cboTF.DropDownStyle = 'DropDownList'
    # first item is auto-detection: ps2exe.ps1 resolves the latest supported framework from the installed .NET SDK
    $cboTF.Items.AddRange(@('Auto-detect', 'net6.0', 'net7.0', 'net8.0', 'net9.0', 'net10.0', 'net11.0'))
    $cboTF.SelectedIndex = 0
    $cboTF.Location = New-Object System.Drawing.Point(130, 22); $cboTF.Size = New-Object System.Drawing.Size(200, 21)
    $gbCoreParams.Controls.Add($lblTF); $gbCoreParams.Controls.Add($cboTF)
    $tt.SetToolTip($lblTF, $paramHelp['targetFramework']); $tt.SetToolTip($cboTF, $paramHelp['targetFramework'])
    $cbSingleFile = New-Object System.Windows.Forms.CheckBox
    $cbSingleFile.Text = '-publishSingleFile'; $cbSingleFile.Location = New-Object System.Drawing.Point(15, 55); $cbSingleFile.AutoSize = $TRUE
    $cbSingleFile.Checked = $TRUE
    $gbCoreParams.Controls.Add($cbSingleFile)
    $tt.SetToolTip($cbSingleFile, $paramHelp['publishSingleFile'])
    $cbR2R = New-Object System.Windows.Forms.CheckBox
    $cbR2R.Text = '-readyToRun'; $cbR2R.Location = New-Object System.Drawing.Point(180, 55); $cbR2R.AutoSize = $TRUE
    $gbCoreParams.Controls.Add($cbR2R)
    $tt.SetToolTip($cbR2R, $paramHelp['readyToRun'])
    # --- Tab: Version info ---
    # labels and textboxes are created directly on the tab page: reparenting only the textbox
    # would leave the labels stranded on the form behind the tab control
    $tabVer = New-Object System.Windows.Forms.TabPage; $tabVer.Text = 'Version info'
    $tabs.Controls.Add($tabVer)
    $tbMeta = @{}
    $verNames = @('title', 'description', 'company', 'product', 'copyright', 'trademark', 'version')
    for ($vi = 0; $vi -lt $verNames.Count; $vi++) {
        $name = $verNames[$vi]
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $name; $lbl.Location = New-Object System.Drawing.Point(15, (25 + 32 * $vi)); $lbl.AutoSize = $TRUE
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(140, (20 + 32 * $vi)); $tb.Size = New-Object System.Drawing.Size(540, 21)
        $tabVer.Controls.Add($lbl); $tabVer.Controls.Add($tb)
        $tt.SetToolTip($lbl, $paramHelp[$name]); $tt.SetToolTip($tb, $paramHelp[$name])
        $tbMeta[$name] = $tb
    }
    $tbMeta['version'].Add_TextChanged({
            # live validation of the version string: n.n.n.n / n.n.n / n.n / n
            $v = $tbMeta['version'].Text
            if ($v -and ($v -notmatch '^\d+(\.\d+){0,3}$')) { $tbMeta['version'].BackColor = 'MistyRose' }
            else { $tbMeta['version'].BackColor = 'White' }
        })
    # --- Actions ---
    $btnCompile = New-Object System.Windows.Forms.Button
    $btnCompile.Text = 'Compile'; $btnCompile.Location = New-Object System.Drawing.Point(545, 600); $btnCompile.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($btnCompile)
    $btnCmd = New-Object System.Windows.Forms.Button
    $btnCmd.Text = 'Show command line'; $btnCmd.Location = New-Object System.Drawing.Point(390, 600); $btnCmd.Size = New-Object System.Drawing.Size(145, 30)
    $form.Controls.Add($btnCmd)
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Reset'; $btnReset.Location = New-Object System.Drawing.Point(15, 600); $btnReset.Size = New-Object System.Drawing.Size(75, 30)
    $form.Controls.Add($btnReset)
    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''; $status.Location = New-Object System.Drawing.Point(15, 640); $status.Size = New-Object System.Drawing.Size(700, 23)
    $form.Controls.Add($status)
    # ==============================================================
    # State helpers
    # ==============================================================
    function Get-ParamHashtable {
        # splatting hashtable from the current control state; unselected switches are omitted entirely
        $p = @{ inputFile = $tbSource.Text; outputFile = $tbDest.Text }
        if ($tbIcon.Text) { $p.iconFile = $tbIcon.Text }
        if ($rbPS7.Checked) { $p.ps7 = $TRUE }
        if ($rbCore.Checked) {
            $p.core = $TRUE
            # single-file is ON by default: only pass $false when explicitly unchecked
            if (-not $cbSingleFile.Checked) { $p.publishSingleFile = $FALSE }
            # Auto-detect: omit the parameter so ps2exe.ps1 resolves the framework from the .NET SDK
            if ($cboTF.SelectedItem -and $cboTF.SelectedItem -ne 'Auto-detect') { $p.targetFramework = $cboTF.SelectedItem }
            if ($cbR2R.Checked) { $p.readyToRun = $TRUE }
        }
        if ($rbSTA.Checked -and $rbPS5.Checked) { $p.STA = $TRUE }
        if ($rbMTA.Checked -and $rbPS5.Checked) { $p.MTA = $TRUE }
        foreach ($name in $chk.Keys) { if ($chk[$name].Checked -and $chk[$name].Enabled) { $p[$name] = $TRUE } }
        foreach ($name in $tbMeta.Keys) { if ($tbMeta[$name].Text) { $p[$name] = $tbMeta[$name].Text } }
        return $p
    }
    function Test-Form {
        # validation before Invoke-ps2exe is called
        if ([string]::IsNullOrWhiteSpace($tbSource.Text)) { $status.Text = 'Source file is required'; $status.ForeColor = 'Red'; return $FALSE }
        if (-not (Test-Path -LiteralPath $tbSource.Text -PathType Leaf)) { $status.Text = 'Source file not found'; $status.ForeColor = 'Red'; return $FALSE }
        if ([string]::IsNullOrWhiteSpace($tbDest.Text)) { $status.Text = 'Destination file is required'; $status.ForeColor = 'Red'; return $FALSE }
        if ($tbDest.Text -notlike '*.exe' -and $tbDest.Text -notlike '*.com') { $status.Text = "Destination must have extension '.exe' or '.com'"; $status.ForeColor = 'Red'; return $FALSE }
        # destination path check: quotes, wildcards, control characters or a misplaced colon
        # make the .NET Framework Path methods throw - reject early with a clear message
        $destPath = $tbDest.Text.Trim()
        $invalidChars = [char[]]([System.IO.Path]::GetInvalidPathChars() + [char]'*' + [char]'?' + [char]'"')
        $colonCount = [regex]::Matches($destPath, ':').Count
        if (($destPath.IndexOfAny($invalidChars) -ge 0) -or
            ($colonCount -gt 1) -or (($colonCount -eq 1) -and ($destPath.IndexOf(':') -ne 1)))
        { $status.Text = 'Destination is not a valid path'; $status.ForeColor = 'Red'; return $FALSE }
        if ($tbIcon.Text -and -not (Test-Path -LiteralPath $tbIcon.Text -PathType Leaf)) { $status.Text = 'Icon file not found'; $status.ForeColor = 'Red'; return $FALSE }
        $v = $tbMeta['version'].Text
        if ($v -and ($v -notmatch '^\d+(\.\d+){0,3}$')) { $status.Text = 'Invalid version number (expected n.n.n.n)'; $status.ForeColor = 'Red'; return $FALSE }
        return $TRUE
    }
    # ==============================================================
    # Actions wiring
    # ==============================================================
    $btnCompile.Add_Click({
            if (-not (Test-Form)) { return }
            $p = Get-ParamHashtable
            $btnCompile.Enabled = $FALSE
            $status.ForeColor = 'Black'; $status.Text = 'Compiling...'
            # persist the raw control state (same shape as $defaults), not the param hashtable
            $state = @{
                SourceFile = $tbSource.Text; DestinationFile = $tbDest.Text; IconFile = $tbIcon.Text
                ps7 = $rbPS7.Checked; core = $rbCore.Checked
                STA = $rbSTA.Checked; MTA = $rbMTA.Checked
                # Auto-detect is stored as an empty string so older settings files restore to it too
                targetFramework = $(if ($cboTF.SelectedItem -and $cboTF.SelectedItem -ne 'Auto-detect') { "$($cboTF.SelectedItem)" } else { '' }); publishSingleFile = $cbSingleFile.Checked
                readyToRun = $cbR2R.Checked
                title = $tbMeta['title'].Text; description = $tbMeta['description'].Text
                company = $tbMeta['company'].Text; product = $tbMeta['product'].Text
                copyright = $tbMeta['copyright'].Text; trademark = $tbMeta['trademark'].Text; version = $tbMeta['version'].Text
            }
            foreach ($name in $chk.Keys) { $state[$name] = $chk[$name].Checked }
            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $settingsFile) -Force | Out-Null
                Export-Clixml -LiteralPath $settingsFile -InputObject $state
            } catch { } # settings persistence is best effort
            # run compilation on a background runspace, poll completion with a WinForms timer.
            # The tick fires after the click handler frame is gone, so the timer must capture
            # everything it needs in itself
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            $psScript = Join-Path $PSScriptRoot 'ps2exe.ps1'
            # mirror compiler output to a log file: the background runspace has no console.
            # Base name is sanitized: .NET Framework throws on invalid paths
            $logBase = ''
            try { $logBase = [System.IO.Path]::GetFileNameWithoutExtension($tbDest.Text) } catch { }
            foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $logBase = $logBase.Replace([string]$c, '') }
            if ([string]::IsNullOrWhiteSpace($logBase)) { $logBase = 'compilation' }
            $logFile = Join-Path ([System.IO.Path]::GetTempPath()) ('Win-PS2EXE_' + $logBase + '.log')
            $ps.AddScript("param(`$params, `$logFile) . '$psScript'; Invoke-ps2exe @params 2>&1 | Tee-Object -FilePath `$logFile").AddArgument($p).AddArgument($logFile) | Out-Null
            $handle = $ps.BeginInvoke()
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 200
            $timer.Tag = @{ Handle = $handle; PowerShell = $ps; Runspace = $rs; LogFile = $logFile }
            $timer.Add_Tick({
                    $t = $this.Tag
                    if (-not $t.Handle.IsCompleted) { return }
                    $this.Stop()
                    $reportLines = New-Object System.Collections.Generic.List[string]
                    $failed = $FALSE
                    try {
                        $out = $t.PowerShell.EndInvoke($t.Handle)
                        # the compiler runs with 2>&1, so Write-Error output arrives in the
                        # pipeline as ErrorRecords while Streams.Error stays empty: scan both
                        # or compile failures are reported as success
                        $errorRecords = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                        if ($t.PowerShell.HadErrors -or $errorRecords.Count -gt 0) {
                            $failed = $TRUE
                            $status.ForeColor = 'Red'
                            $firstError = if ($errorRecords.Count -gt 0) { $errorRecords[0] } else { $t.PowerShell.Streams.Error | Select-Object -First 1 }
                            $status.Text = 'Compilation failed: ' + $firstError.Exception.Message
                            $reportLines.Add('ERRORS:')
                            foreach ($e in $errorRecords) { $reportLines.Add(' ' + $e.Exception.Message) }
                            foreach ($e in $t.PowerShell.Streams.Error) { $reportLines.Add(' ' + $e.Exception.Message) }
                        } else {
                            $status.ForeColor = 'Green'; $status.Text = "Output file $($tbDest.Text) written"
                        }
                        # merge problems surface as warnings: show them in a separate window, not the log only
                        $warnings = @($t.PowerShell.Streams.Warning)
                        if ($warnings.Count -gt 0) {
                            if ($reportLines.Count -gt 0) { $reportLines.Add('') }
                            $reportLines.Add("WARNINGS ($($warnings.Count)):")
                            foreach ($w in $warnings) { $reportLines.Add(' ' + $w.Message) }
                        }
                    } catch {
                        # terminating failure inside the background script itself
                        $failed = $TRUE
                        $status.ForeColor = 'Red'
                        $status.Text = 'Compilation failed: ' + $_.Exception.Message
                        $reportLines.Add('ERRORS:')
                        $reportLines.Add(' ' + $_.Exception.Message)
                    }
                    if ($reportLines.Count -gt 0) {
                        # separate report window with selectable text; title bar icon reflects the outcome
                        $reportLines.Add('')
                        $reportLines.Add("Full compiler output: $($t.LogFile)")
                        $repForm = New-Object System.Windows.Forms.Form
                        $repForm.Text = 'PS2EXE compilation report'
                        $repForm.ClientSize = New-Object System.Drawing.Size(910, 410)
                        $repForm.StartPosition = 'CenterParent'
                        $repForm.FormBorderStyle = 'FixedDialog'
                        $repForm.MaximizeBox = $FALSE
                        $repForm.Icon = if ($failed) { [System.Drawing.SystemIcons]::Error } else { [System.Drawing.SystemIcons]::Warning }
                        $repBox = New-Object System.Windows.Forms.TextBox
                        $repBox.Multiline = $TRUE; $repBox.ReadOnly = $TRUE
                        $repBox.ScrollBars = 'Both'; $repBox.WordWrap = $FALSE
                        $repBox.Location = New-Object System.Drawing.Point(10, 10)
                        $repBox.Size = New-Object System.Drawing.Size(890, 340)
                        $repBox.Text = [string]::Join("`r`n", $reportLines)
                        # Ctrl+A is not guaranteed in every WinForms/OS combination: enforce it
                        $repBox.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'A') { $repBox.SelectAll(); $_.SuppressKeyPress = $TRUE } })
                        $btnCopyAll = New-Object System.Windows.Forms.Button
                        $btnCopyAll.Text = 'Copy all to clipboard'
                        $btnCopyAll.Location = New-Object System.Drawing.Point(10, 360)
                        $btnCopyAll.Size = New-Object System.Drawing.Size(160, 25)
                        $btnCopyAll.Add_Click({ Set-Clipboard -Value $repBox.Text })
                        $btnClose = New-Object System.Windows.Forms.Button
                        $btnClose.Text = 'Close'
                        $btnClose.Location = New-Object System.Drawing.Point(825, 360)
                        $btnClose.Size = New-Object System.Drawing.Size(75, 25)
                        $btnClose.DialogResult = 'OK'
                        $repForm.AcceptButton = $btnClose
                        $repForm.CancelButton = $btnClose
                        $repForm.Controls.AddRange(@($repBox, $btnCopyAll, $btnClose))
                        [void]$repForm.ShowDialog($form)
                    }
                    $t.Runspace.Close(); $t.Runspace.Dispose(); $t.PowerShell.Dispose()
                    $btnCompile.Enabled = $TRUE
                })
            $timer.Start()
        })
    $btnCmd.Add_Click({
            # show the exact command line the Compile button would run
            if (-not (Test-Form)) { return }
            $p = Get-ParamHashtable
            $parts = foreach ($key in $p.Keys) { if ($p[$key] -eq $TRUE) { "-$key" } elseif ($p[$key] -eq $FALSE) { "-${key}:`$FALSE" } else { "-$key '$($p[$key])'" } }
            $cmd = 'Invoke-ps2exe ' + ($parts -join ' ')
            $w = New-Object System.Windows.Forms.Form
            $w.Text = 'Command line'; $w.Size = New-Object System.Drawing.Size(700, 180)
            $w.StartPosition = 'CenterParent'; $w.FormBorderStyle = 'FixedDialog'
            $t = New-Object System.Windows.Forms.TextBox
            $t.Multiline = $TRUE; $t.ReadOnly = $TRUE; $t.ScrollBars = 'Vertical'
            $t.Location = New-Object System.Drawing.Point(10, 10); $t.Size = New-Object System.Drawing.Size(670, 90); $t.Text = $cmd
            $b = New-Object System.Windows.Forms.Button
            $b.Text = 'Copy to clipboard'; $b.Location = New-Object System.Drawing.Point(10, 110); $b.Size = New-Object System.Drawing.Size(140, 25)
            $b.Add_Click({ Set-Clipboard -Value $cmd })
            $w.Controls.Add($t); $w.Controls.Add($b)
            [void]$w.ShowDialog($form)
        })
    $btnReset.Add_Click({
            # restore defaults (without saving them)
            $tbSource.Text = ''; $tbDest.Text = ''; $tbIcon.Text = ''
            $rbPS5.Checked = $TRUE; $rbSTA.Checked = $TRUE
            foreach ($cb in $chk.Values) { $cb.Checked = $FALSE }
            foreach ($tb in $tbMeta.Values) { $tb.Text = '' }
            $cboTF.SelectedIndex = 0; $cbSingleFile.Checked = $TRUE
            $cbR2R.Checked = $FALSE
            $status.Text = ''; $status.ForeColor = 'Black'
        })
    # ==============================================================
    # Restore persisted state into controls
    # ==============================================================
    if ($settings['SourceFile']) { $tbSource.Text = $settings['SourceFile'] }
    if ($settings['DestinationFile']) { $tbDest.Text = $settings['DestinationFile'] }
    if ($settings['IconFile']) { $tbIcon.Text = $settings['IconFile'] }
    $rbPS7.Checked = [bool]$settings['ps7']; $rbCore.Checked = [bool]$settings['core']
    $rbPS5.Checked = -not ($rbPS7.Checked -or $rbCore.Checked)
    $rbSTA.Checked = [bool]$settings['STA']; $rbMTA.Checked = [bool]$settings['MTA']
    # empty value and "Auto-detect" both restore to Auto-detect
    if ($settings['targetFramework'] -and $settings['targetFramework'] -ne 'Auto-detect') {
        $cboTF.SelectedItem = "$($settings['targetFramework'])"
    } else {
        $cboTF.SelectedIndex = 0
    }
    $cbSingleFile.Checked = [bool]$settings['publishSingleFile']
    $cbR2R.Checked = [bool]$settings['readyToRun']
    foreach ($name in $chk.Keys) { if ($settings.ContainsKey($name)) { $chk[$name].Checked = [bool]$settings[$name] } }
    foreach ($name in $tbMeta.Keys) { if ($settings[$name]) { $tbMeta[$name].Text = "$($settings[$name])" } }
    # apply constraints to the restored state: CheckedChanged does not fire on restore
    & $syncRuntimeConstraints
    & $syncSaveEnabled
    [void]$form.ShowDialog()
}