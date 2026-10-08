#Requires -Version 5.1
<#
.SYNOPSIS
Graphical front end for Invoke-ps2exe.
.DESCRIPTION
WinForms GUI for the ps2exe compiler. Written in PowerShell 5.1+,
no external dependencies. Replaces the legacy compiled Win-PS2EXE.exe.
.NOTES
Version: 1.0.20
Date: 2026.10.08
Fork Author: Andrew Afanasiev
Original author: Markus Scholtes (original Win-PS2EXE.exe)
#>

function Show-WinPS2EXE
{
    [CmdletBinding()]
    param()

    # WinForms requires STA: relaunch self in STA when needed (same pattern as ps2exe uses for Core)
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA)
    {
        # loading the script only defines the function, so call it explicitly afterwards
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
        SourceFile   = ''; DestinationFile = ''; IconFile = ''
        ps7 = $FALSE; x64 = $FALSE; x86 = $FALSE; STA = $TRUE; MTA = $FALSE
        noConsole = $FALSE; conHost = $FALSE; UNICODEEncoding = $FALSE; credentialGUI = $FALSE
        noOutput = $FALSE; noError = $FALSE; noVisualStyles = $FALSE; exitOnCancel = $FALSE
        DPIAware = $FALSE; winFormsDPIAware = $FALSE; requireAdmin = $FALSE; supportOS = $FALSE
        virtualize = $FALSE; longPaths = $FALSE; prepareDebug = $FALSE; configFile = $FALSE
        removeAllComments = $FALSE; mergeIncludes = $FALSE; savePreprocessedScript = $FALSE
        title = ''; description = ''; company = ''; product = ''; copyright = ''; trademark = ''; version = ''
    }
    $settings = $defaults.Clone()
    try
    {
        if (Test-Path -LiteralPath $settingsFile)
        {
            $loaded = Import-Clixml -LiteralPath $settingsFile
            foreach ($key in $loaded.Keys) { if ($settings.ContainsKey($key)) { $settings[$key] = $loaded[$key] } }
        }
    } catch { } # corrupted settings file: silently fall back to defaults

    # ==============================================================
    # Form construction
    # ==============================================================
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Win-PS2EXE'
    $form.Size = New-Object System.Drawing.Size(760, 640)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $FALSE
    $form.AutoScaleMode = 'Dpi'

    # --- File section ---
    $gbFiles = New-Object System.Windows.Forms.GroupBox
    $gbFiles.Text = 'Files'; $gbFiles.Location = New-Object System.Drawing.Point(10, 10)
    $gbFiles.Size = New-Object System.Drawing.Size(725, 125)
    $form.Controls.Add($gbFiles)

    function New-FileRow([System.Windows.Forms.Control]$parent, [string]$labelText, [string]$filter, [bool]$saveDialog, [int]$y)
    {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.Location = New-Object System.Drawing.Point(10, ($y + 3)); $lbl.AutoSize = $TRUE
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(140, $y); $tb.Size = New-Object System.Drawing.Size(480, 21)
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Browse...'; $btn.Location = New-Object System.Drawing.Point(630, ($y - 1)); $btn.Size = New-Object System.Drawing.Size(80, 23)
        # capture everything the click handler needs in the button itself:
        # $tb, $saveDialog and $filter are function parameters whose scope is
        # gone when the click fires, so the closure must not reference them
        $btn.Tag = @{ TextBox = $tb; SaveDialog = $saveDialog; Filter = $filter }
        $btn.Add_Click({
            if ($this.Tag.SaveDialog)
            {
                $dlg = New-Object System.Windows.Forms.SaveFileDialog
                $dlg.Filter = 'Executable (*.exe)|*.exe|Command file (*.com)|*.com'
            }
            else { $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = $this.Tag.Filter }
            # preset dialog from the current textbox content; guarded: the text may
            # hold a not-yet-valid path and .NET Framework (PowerShell 5.1) throws
            # in the Path methods, .NET Core does not
            try
            {
                if ($this.Tag.TextBox.Text)
                {
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
        # follow the source file name, but keep the previously chosen destination
        # directory: only the file name part of Destination is replaced.
        # Defensive: while typing (or after pasting e.g. a quoted path) a field can
        # hold text that is not a valid path. .NET Framework (PowerShell 5.1)
        # throws ArgumentException on such input in the Path methods below, while
        # .NET Core (PowerShell 7) tolerates it - so all path processing is
        # guarded and Destination stays unchanged until the input becomes valid
        if ([string]::IsNullOrWhiteSpace($tbSource.Text)) { return }
        # unwrap a fully quoted path: Explorer's "Copy as path" and drag&drop add
        # surrounding quotes; assigning back re-fires this handler once with the
        # clean value
        $src = $tbSource.Text.Trim()
        if ($src.Length -gt 2 -and $src.StartsWith('"') -and $src.EndsWith('"'))
        {
            $tbSource.Text = $src.Trim('"')
            return
        }
        try
        {
            # compute the complete new destination before assigning anything: an
            # exception from any path call must not leave a half-updated state
            $newName = [System.IO.Path]::GetFileNameWithoutExtension($src) + '.exe'
            $destDir = [System.IO.Path]::GetDirectoryName($tbDest.Text)
            if ([string]::IsNullOrWhiteSpace($destDir)) { $newDest = $newName }
            else { $newDest = [System.IO.Path]::Combine($destDir, $newName) }
        }
        catch
        { # Destination text is not a valid path (yet): keep it unchanged
            return
        }
        $tbDest.Text = $newDest
    })
    $tbDest   = New-FileRow $gbFiles 'Destination file' '' $TRUE 55
    $tbIcon   = New-FileRow $gbFiles 'Icon file' 'Icon files (*.ico)|*.ico' $FALSE 85

    # --- Options section (tabs) ---
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 145); $tabs.Size = New-Object System.Drawing.Size(725, 360)
    $form.Controls.Add($tabs)

    $chk = @{}   # checkbox registry by parameter name
    function New-CheckBox([System.Windows.Forms.Control]$parent, [string]$name, [string]$text, [int]$x, [int]$y, [string]$tooltip)
    {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "-$name"; $cb.Tag = $name; $cb.AccessibleName = $name
        $cb.Location = New-Object System.Drawing.Point($x, $y); $cb.AutoSize = $TRUE
        if ($tooltip) { $tt.SetToolTip($cb, $tooltip) }
        $parent.Controls.Add($cb)
        # registry in the function's local scope: event handlers fire inside
        # ShowDialog() while this frame is alive, so dynamic scoping finds it
        # ($script: would point to the loading scope where $chk does not exist)
        $chk[$name] = $cb
        return $cb
    }
    $tt = New-Object System.Windows.Forms.ToolTip
    # keep the tooltip visible long enough to read the multi-line descriptions
    $tt.AutoPopDelay = 15000

    # Hover descriptions for every parameter and option, taken from the
    # Invoke-ps2exe documentation (.PARAMETER help of ps2exe.ps1). Single source
    # of truth: the checkbox loop, the preprocessing checkboxes and the version
    # info fields below all read from this table. ToolTips do not wrap text
    # automatically, so longer descriptions carry manual line breaks
    $paramHelp = @{
        noConsole              = "The resulting executable will be a Windows Forms app without a console window.`nYou might want to pipe your output to Out-String to prevent a message box for every line of output"
        conHost                = "Force start with conhost as console instead of Windows Terminal.`nIf necessary a new console window will appear.`nImportant: disables redirection of input, output or error channel!`nNot applicable with -ps7"
        UNICODEEncoding        = "Encode output as UNICODE in console mode, useful to display special encoded chars.`nNot applicable with -ps7"
        credentialGUI          = "Use GUI for prompting credentials in console mode instead of console input.`nNot applicable with -ps7"
        noOutput               = "The resulting executable will generate no standard output (includes verbose and information channel).`nNot applicable with -ps7"
        noError                = "The resulting executable will generate no error output (includes warning and debug channel).`nNot applicable with -ps7"
        noVisualStyles         = "Disable visual styles for a generated windows GUI application.`nOnly applicable with -noConsole"
        exitOnCancel           = "Exits program when Cancel or `"X`" is selected in a Read-Host input box.`nOnly applicable with -noConsole. Not applicable with -ps7"
        DPIAware               = 'If display scaling is activated, GUI controls will be scaled if possible'
        winFormsDPIAware       = "Creates an entry in the config file for WinForms to use DPI scaling.`nForces -configFile and -supportOS (requires Windows 10 and .NET 4.7 or up).`nNot applicable with -ps7"
        requireAdmin           = 'If UAC is enabled, compiled executable will run only in elevated context (UAC dialog appears if required)'
        supportOS              = 'Use functions of newest Windows versions (execute [Environment]::OSVersion to see the difference)'
        virtualize             = 'Application virtualization is activated (forcing x86 runtime)'
        longPaths              = 'Enable long paths ( > 260 characters) if enabled on OS (works only with Windows 10 or up)'
        prepareDebug           = 'Create helpful information for debugging of the generated executable (see parameter -debug there)'
        configFile             = "Write a config file (<outputfile>.exe.config).`nNot applicable with -ps7"
        removeAllComments      = "Strip all comments (# line, <# #> block, #region/#endregion) from the input script before embedding.`nHere-string bodies are kept verbatim, #requires directives are preserved.`nA script extracted with -extract:<FILENAME> will not match the original input file"
        mergeIncludes          = "Inline every dot-sourced, call-operator or Import-Module file reference (recursively)`ninto one self-contained script before embedding. Implies -removeAllComments.`nParam blocks of included files become parameter assignments"
        savePreprocessedScript = "Save the preprocessed script (result of -removeAllComments or -mergeIncludes) as a .ps1 file`nnext to the output executable, before the PS2EXE path variable marker is injected"
        title                  = "Title information (displayed in details tab of Windows Explorer's properties dialog)"
        description            = 'Description information (not displayed, but embedded in executable)'
        company                = 'Company information (not displayed, but embedded in executable)'
        product                = "Product information (displayed in details tab of Windows Explorer's properties dialog)"
        copyright              = "Copyright information (displayed in details tab of Windows Explorer's properties dialog)"
        trademark              = "Trademark information (displayed in details tab of Windows Explorer's properties dialog)"
        version                = "Version information (displayed in details tab of Windows Explorer's properties dialog).`nForm: n.n.n.n, n.n.n, n.n or n"
        SourceFile             = 'PowerShell script to convert to executable (file has to be UTF8 or UTF16 encoded)'
        DestinationFile        = "Destination executable file name or folder, defaults to the source file name with extension '.exe'"
        IconFile               = 'Icon file name for the compiled executable'
    }

    # file section: hover description on each path textbox
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
    $tabGeneral.Controls.Add($rbPS5); $tabGeneral.Controls.Add($rbPS7)

    # parameters not applicable with -ps7: dimmed and disabled when PS7 is selected
    # (STA/MTA are radio buttons, not checkboxes, so the sync must dim them itself).
    # The sync is a named scriptblock: CheckedChanged fires only when the checked
    # STATE actually changes, so restoring persisted settings that select PS7
    # (rbPS5 goes from "never checked" to "unchecked" - no change) fired nothing
    # and left the PS7 constraints unapplied until the user toggled the runtime
    # selection manually. The restore section invokes the sync once explicitly
    $ps7Incompatible = @('conHost', 'credentialGUI', 'UNICODEEncoding', 'noOutput', 'noError', 'exitOnCancel', 'configFile', 'winFormsDPIAware')
    $syncPs7Constraints = {
        foreach ($name in $ps7Incompatible) { if ($chk[$name]) { $chk[$name].Enabled = $rbPS5.Checked } }
        $rbSTA.Enabled = $rbPS5.Checked
        $rbMTA.Enabled = $rbPS5.Checked
    }
    $rbPS5.Add_CheckedChanged($syncPs7Constraints)

    $gbFlags1 = New-Object System.Windows.Forms.GroupBox
    $gbFlags1.Text = 'Output and behavior'; $gbFlags1.Location = New-Object System.Drawing.Point(10, 75); $gbFlags1.Size = New-Object System.Drawing.Size(345, 240)
    $tabGeneral.Controls.Add($gbFlags1)
    $i = 0
    foreach ($name in @('noConsole', 'conHost', 'UNICODEEncoding', 'credentialGUI', 'noOutput', 'noError', 'noVisualStyles', 'exitOnCancel', 'DPIAware', 'winFormsDPIAware', 'requireAdmin', 'supportOS', 'virtualize', 'longPaths', 'prepareDebug', 'configFile'))
    {
        # two columns: y advances every second checkbox, odd indices shift right
        # (a fixed x combined with Floor($i / 2) stacked every pair on top of each other)
        $cbX = 15; $cbY = 25 + 24 * ([math]::Floor($i / 2))
        if ($i % 2 -eq 1) { $cbX = 180 }
        New-CheckBox $gbFlags1 $name "-$name" $cbX $cbY $paramHelp[$name] | Out-Null
        $i++
    }

    $gbArch = New-Object System.Windows.Forms.GroupBox
    $gbArch.Text = 'Platform and apartment'; $gbArch.Location = New-Object System.Drawing.Point(365, 75); $gbArch.Size = New-Object System.Drawing.Size(345, 130)
    $tabGeneral.Controls.Add($gbArch)
    $rbAny = New-Object System.Windows.Forms.RadioButton; $rbAny.Text = 'AnyCPU (default)'; $rbAny.Location = New-Object System.Drawing.Point(15, 25); $rbAny.AutoSize = $TRUE
    $rbX86 = New-Object System.Windows.Forms.RadioButton; $rbX86.Text = 'x86'; $rbX86.Location = New-Object System.Drawing.Point(15, 50); $rbX86.AutoSize = $TRUE
    $rbX64 = New-Object System.Windows.Forms.RadioButton; $rbX64.Text = 'x64'; $rbX64.Location = New-Object System.Drawing.Point(15, 75); $rbX64.AutoSize = $TRUE
    $rbSTA = New-Object System.Windows.Forms.RadioButton; $rbSTA.Text = 'STA'; $rbSTA.Location = New-Object System.Drawing.Point(180, 25); $rbSTA.AutoSize = $TRUE
    $rbMTA = New-Object System.Windows.Forms.RadioButton; $rbMTA.Text = 'MTA'; $rbMTA.Location = New-Object System.Drawing.Point(180, 50); $rbMTA.AutoSize = $TRUE
    $rbSTA.Tag = 'STA'; $rbMTA.Tag = 'MTA'
    $gbArch.Controls.AddRange(@($rbAny, $rbX86, $rbX64, $rbSTA, $rbMTA))

    # hover descriptions for the runtime and platform options
    $tt.SetToolTip($rbPS5, "Compile a full in-process Windows PowerShell 5.1 host into the executable.`nAll compiler options are available. Needs the .NET Framework (included in Windows)")
    $tt.SetToolTip($rbPS7, "Generate a lightweight stub executable that runs the embedded script via pwsh.exe.`nParameters not applicable with -ps7 are disabled.`nThe target machine must have PowerShell 7+ installed")
    $tt.SetToolTip($rbAny, 'Compile for any CPU: the process runs as 64-bit on 64-bit Windows and as 32-bit on 32-bit Windows')
    $tt.SetToolTip($rbX86, 'Compile for 32-bit runtime only')
    $tt.SetToolTip($rbX64, 'Compile for 64-bit runtime only')
    $tt.SetToolTip($rbSTA, "'Single Thread Apartment' mode (default). Required for clipboard access and most GUI operations in the compiled script")
    $tt.SetToolTip($rbMTA, "'Multi Thread Apartment' mode")

    # --- Tab: Preprocessing ---
    $tabPre = New-Object System.Windows.Forms.TabPage; $tabPre.Text = 'Preprocessing'
    $tabs.Controls.Add($tabPre)
    $cbRemoveComments = New-CheckBox $tabPre 'removeAllComments' '-removeAllComments' 15 25 $paramHelp['removeAllComments']
    $cbMergeIncludes = New-CheckBox $tabPre 'mergeIncludes' '-mergeIncludes' 15 50 $paramHelp['mergeIncludes']
    $lblImpl = New-Object System.Windows.Forms.Label
    $lblImpl.Text = 'mergeIncludes implies removeAllComments'; $lblImpl.ForeColor = 'Gray'
    $lblImpl.Location = New-Object System.Drawing.Point(35, 75); $lblImpl.AutoSize = $TRUE
    $tabPre.Controls.Add($lblImpl)
    $cbSavePre = New-CheckBox $tabPre 'savePreprocessedScript' '-savePreprocessedScript' 15 100 $paramHelp['savePreprocessedScript']
    # the save switch is only meaningful with an active preprocessing switch: keep its
    # enabled state in sync (the handler also fires while persisted settings are restored)
    $syncSaveEnabled = { $cbSavePre.Enabled = ($cbRemoveComments.Checked -or $cbMergeIncludes.Checked) }
    $cbRemoveComments.Add_CheckedChanged($syncSaveEnabled)
    $cbMergeIncludes.Add_CheckedChanged($syncSaveEnabled)
    & $syncSaveEnabled

    # --- Tab: Version info ---
    # labels and textboxes are created directly on the tab page: the New-TextBox
    # helper hardcodes $form as parent, so reparenting only the textbox would
    # leave the labels stranded on the form behind the tab control
    $tabVer = New-Object System.Windows.Forms.TabPage; $tabVer.Text = 'Version info'
    $tabs.Controls.Add($tabVer)
    $tbMeta = @{}
    $verNames = @('title', 'description', 'company', 'product', 'copyright', 'trademark', 'version')
    for ($vi = 0; $vi -lt $verNames.Count; $vi++)
    {
        $name = $verNames[$vi]
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $name; $lbl.Location = New-Object System.Drawing.Point(15, (25 + 32 * $vi)); $lbl.AutoSize = $TRUE
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(140, (20 + 32 * $vi)); $tb.Size = New-Object System.Drawing.Size(540, 21)
        $tabVer.Controls.Add($lbl); $tabVer.Controls.Add($tb)
        # hover description on both the label and the textbox
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
    $btnCompile.Text = 'Compile'; $btnCompile.Location = New-Object System.Drawing.Point(545, 515); $btnCompile.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($btnCompile)
    $btnCmd = New-Object System.Windows.Forms.Button
    $btnCmd.Text = 'Show command line'; $btnCmd.Location = New-Object System.Drawing.Point(390, 515); $btnCmd.Size = New-Object System.Drawing.Size(145, 30)
    $form.Controls.Add($btnCmd)
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Reset'; $btnReset.Location = New-Object System.Drawing.Point(15, 515); $btnReset.Size = New-Object System.Drawing.Size(75, 30)
    $form.Controls.Add($btnReset)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''; $status.Location = New-Object System.Drawing.Point(15, 555); $status.Size = New-Object System.Drawing.Size(700, 23)
    $form.Controls.Add($status)

    # ==============================================================
    # State helpers
    # ==============================================================
    function Get-ParamHashtable
    {
        # Build the splatting hashtable from the current control state.
        # Unselected switches are omitted entirely (not passed as $false).
        $p = @{ inputFile = $tbSource.Text; outputFile = $tbDest.Text }
        if ($tbIcon.Text) { $p.iconFile = $tbIcon.Text }
        if ($rbPS7.Checked) { $p.ps7 = $TRUE }
        if ($rbX86.Checked) { $p.x86 = $TRUE }
        if ($rbX64.Checked) { $p.x64 = $TRUE }
        if ($rbSTA.Checked -and $rbPS5.Checked) { $p.STA = $TRUE }
        if ($rbMTA.Checked -and $rbPS5.Checked) { $p.MTA = $TRUE }
        foreach ($name in $chk.Keys) { if ($chk[$name].Checked -and $chk[$name].Enabled) { $p[$name] = $TRUE } }
        foreach ($name in $tbMeta.Keys) { if ($tbMeta[$name].Text) { $p[$name] = $tbMeta[$name].Text } }
        return $p
    }

    function Test-Form
    {
        # validation: must pass before Invoke-ps2exe is called
        if ([string]::IsNullOrWhiteSpace($tbSource.Text)) { $status.Text = 'Source file is required'; $status.ForeColor = 'Red'; return $FALSE }
        if (-not (Test-Path -LiteralPath $tbSource.Text -PathType Leaf)) { $status.Text = 'Source file not found'; $status.ForeColor = 'Red'; return $FALSE }
        if ([string]::IsNullOrWhiteSpace($tbDest.Text)) { $status.Text = 'Destination file is required'; $status.ForeColor = 'Red'; return $FALSE }
        if ($tbDest.Text -notlike '*.exe' -and $tbDest.Text -notlike '*.com') { $status.Text = "Destination must have extension '.exe' or '.com'"; $status.ForeColor = 'Red'; return $FALSE }
        # destination path check: compilation always ends up under .NET Framework
        # path rules (in-process in PowerShell 5.1, or via the Core redirect to
        # powershell.exe from a PowerShell 7 GUI), where quotes, wildcards, control
        # characters or a colon outside the drive position make the Path methods
        # throw - reject early with a clear message instead of failing deep inside
        # the compiler
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
        # persist the raw control state (same shape as $defaults), not the param
        # hashtable: the restore code below reads these keys
        $state = @{
            SourceFile = $tbSource.Text; DestinationFile = $tbDest.Text; IconFile = $tbIcon.Text
            ps7 = $rbPS7.Checked; x86 = $rbX86.Checked; x64 = $rbX64.Checked
            STA = $rbSTA.Checked; MTA = $rbMTA.Checked
            title = $tbMeta['title'].Text; description = $tbMeta['description'].Text
            company = $tbMeta['company'].Text; product = $tbMeta['product'].Text
            copyright = $tbMeta['copyright'].Text; trademark = $tbMeta['trademark'].Text; version = $tbMeta['version'].Text
        }
        foreach ($name in $chk.Keys) { $state[$name] = $chk[$name].Checked }
        try
        {
            New-Item -ItemType Directory -Path (Split-Path -Parent $settingsFile) -Force | Out-Null
            Export-Clixml -LiteralPath $settingsFile -InputObject $state
        } catch { } # settings persistence is best effort
        # run compilation on a background runspace, poll completion with a WinForms timer.
        # The timer tick fires AFTER the click handler frame is gone, so every variable
        # it needs must be captured in the timer itself, not referenced from the handler
        # scope (otherwise $handle resolves to $null and the timer never completes).
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        # load ps2exe.ps1 from the module folder, then invoke with the splatted parameters
        $psScript = Join-Path $PSScriptRoot 'ps2exe.ps1'
        # mirror all compiler output to a log file: the background runspace has no console,
        # so without this a failure would be invisible. Base name is guarded and sanitized:
        # .NET Framework (PowerShell 5.1) throws on invalid paths, and characters such as
        # a colon would make the log file itself uncreatable
        $logBase = ''
        try { $logBase = [System.IO.Path]::GetFileNameWithoutExtension($tbDest.Text) } catch { }
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $logBase = $logBase.Replace([string]$c, '') }
        if ([string]::IsNullOrWhiteSpace($logBase)) { $logBase = 'compilation' }
        $logFile = Join-Path ([System.IO.Path]::GetTempPath()) ("Win-PS2EXE_" + $logBase + ".log")
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
            try
            {
                $out = $t.PowerShell.EndInvoke($t.Handle)
                # the background script invokes the compiler with 2>&1, so Write-Error
                # output arrives in the pipeline ($out) as ErrorRecords while
                # Streams.Error stays empty: scan the output as well or compile
                # failures are reported as success
                $errorRecords = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                if ($t.PowerShell.HadErrors -or $errorRecords.Count -gt 0)
                {
                    $failed = $TRUE
                    $status.ForeColor = 'Red'
                    $firstError = if ($errorRecords.Count -gt 0) { $errorRecords[0] } else { $t.PowerShell.Streams.Error | Select-Object -First 1 }
                    $status.Text = 'Compilation failed: ' + $firstError.Exception.Message
                    $reportLines.Add('ERRORS:')
                    foreach ($e in $errorRecords) { $reportLines.Add('  ' + $e.Exception.Message) }
                    foreach ($e in $t.PowerShell.Streams.Error) { $reportLines.Add('  ' + $e.Exception.Message) }
                }
                else
                {
                    $status.ForeColor = 'Green'; $status.Text = "Output file $($tbDest.Text) written"
                }
                # merge problems surface as warnings in the console-less background
                # runspace: show them in a separate window instead of the log only
                $warnings = @($t.PowerShell.Streams.Warning)
                if ($warnings.Count -gt 0)
                {
                    if ($reportLines.Count -gt 0) { $reportLines.Add('') }
                    $reportLines.Add("WARNINGS ($($warnings.Count)):")
                    foreach ($w in $warnings) { $reportLines.Add('  ' + $w.Message) }
                }
            }
            catch
            {
                # terminating failure inside the background script itself
                $failed = $TRUE
                $status.ForeColor = 'Red'
                $status.Text = 'Compilation failed: ' + $_.Exception.Message
                $reportLines.Add('ERRORS:')
                $reportLines.Add('  ' + $_.Exception.Message)
            }
            if ($reportLines.Count -gt 0)
            {
                # separate report window with selectable text: any part of the
                # report can be copied (the MessageBox predecessor allowed no
                # selection); the title bar icon reflects the outcome, the full
                # log file path is appended for post-mortem
                $reportLines.Add('')
                $reportLines.Add("Full compiler output: $($t.LogFile)")

                # 910 px = 30% wider than the 700 px command line preview window
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
                # Ctrl+A does not select all in every WinForms/OS combination: enforce it
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
        # transparency window: show the exact command line the Compile button would run
        if (-not (Test-Form)) { return }
        $p = Get-ParamHashtable
        $parts = foreach ($key in $p.Keys) { if ($p[$key] -eq $TRUE) { "-$key" } else { "-$key '$($p[$key])'" } }
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
        $rbPS5.Checked = $TRUE; $rbAny.Checked = $TRUE; $rbSTA.Checked = $TRUE
        foreach ($cb in $chk.Values) { $cb.Checked = $FALSE }
        foreach ($tb in $tbMeta.Values) { $tb.Text = '' }
        $status.Text = ''; $status.ForeColor = 'Black'
    })

    # ==============================================================
    # Restore persisted state into controls
    # ==============================================================
    if ($settings['SourceFile']) { $tbSource.Text = $settings['SourceFile'] }
    if ($settings['DestinationFile']) { $tbDest.Text = $settings['DestinationFile'] }
    if ($settings['IconFile']) { $tbIcon.Text = $settings['IconFile'] }
    $rbPS7.Checked = [bool]$settings['ps7']; $rbPS5.Checked = -not $rbPS7.Checked
    $rbX86.Checked = [bool]$settings['x86']; $rbX64.Checked = [bool]$settings['x64']
    if (-not ($rbX86.Checked -or $rbX64.Checked)) { $rbAny.Checked = $TRUE }
    $rbSTA.Checked = [bool]$settings['STA']; $rbMTA.Checked = [bool]$settings['MTA']
    foreach ($name in $chk.Keys) { if ($settings.ContainsKey($name)) { $chk[$name].Checked = [bool]$settings[$name] } }
    foreach ($name in $tbMeta.Keys) { if ($settings[$name]) { $tbMeta[$name].Text = "$($settings[$name])" } }
    # apply the PS7 parameter constraints to the restored state: CheckedChanged
    # does not fire for a radio button whose state does not change on restore
    & $syncPs7Constraints
    [void]$form.ShowDialog()
}
