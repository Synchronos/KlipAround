Set-StrictMode -Version Latest

function Initialize-KlipAroundClipboardListenerType {
    [CmdletBinding()]
    param()

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return
    }

    if ($null -ne ('KlipAround.ClipboardListener' -as [type])) {
        return
    }

    $typeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace KlipAround
{
    public sealed class ClipboardListener : IDisposable
    {
        private const int WM_CLIPBOARDUPDATE = 0x031D;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        private readonly AutoResetEvent _changeEvent = new AutoResetEvent(false);
        private readonly ManualResetEvent _readyEvent = new ManualResetEvent(false);
        private readonly Thread _thread;
        private ListenerForm _form;
        private volatile bool _disposed;
        private volatile bool _registered;
        private int _changeCount;

        public ClipboardListener()
        {
            _thread = new Thread(ThreadMain);
            _thread.Name = "KlipAroundClipboardListener";
            _thread.IsBackground = true;
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            _readyEvent.WaitOne(2000);
        }

        public bool IsOperational
        {
            get { return !_disposed && _registered && _thread.IsAlive; }
        }

        public bool WaitForChange(int millisecondsTimeout)
        {
            if (_disposed)
            {
                return false;
            }
            return _changeEvent.WaitOne(millisecondsTimeout);
        }

        public int ChangeCount
        {
            get { return Volatile.Read(ref _changeCount); }
        }

        private void ThreadMain()
        {
            try
            {
                using (var form = new ListenerForm(this))
                {
                    _form = form;
                    IntPtr _ = form.Handle;
                    Application.Run(form);
                }
            }
            catch
            {
            }
            finally
            {
                _readyEvent.Set();
                _changeEvent.Set();
            }
        }

        internal void OnHandleReady(IntPtr handle)
        {
            try
            {
                _registered = AddClipboardFormatListener(handle);
            }
            catch
            {
                _registered = false;
            }
            _readyEvent.Set();
        }

        internal void OnClipboardUpdated()
        {
            Interlocked.Increment(ref _changeCount);
            _changeEvent.Set();
        }

        internal void OnClosed(IntPtr handle)
        {
            if (_registered)
            {
                try
                {
                    RemoveClipboardFormatListener(handle);
                }
                catch
                {
                }
                _registered = false;
            }
            _changeEvent.Set();
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;

            try
            {
                if (_form != null && _form.IsHandleCreated)
                {
                    _form.BeginInvoke(new MethodInvoker(delegate { _form.Close(); }));
                }
            }
            catch
            {
            }

            if (!_thread.Join(1000))
            {
                try
                {
                    _thread.Interrupt();
                }
                catch
                {
                }
            }

            _changeEvent.Dispose();
            _readyEvent.Dispose();
        }

        private sealed class ListenerForm : Form
        {
            private readonly ClipboardListener _owner;

            public ListenerForm(ClipboardListener owner)
            {
                _owner = owner;
                ShowInTaskbar = false;
                FormBorderStyle = FormBorderStyle.None;
                Width = 0;
                Height = 0;
                StartPosition = FormStartPosition.Manual;
                Location = new System.Drawing.Point(-32000, -32000);
            }

            protected override void SetVisibleCore(bool value)
            {
                base.SetVisibleCore(false);
            }

            protected override void OnHandleCreated(EventArgs e)
            {
                base.OnHandleCreated(e);
                _owner.OnHandleReady(Handle);
            }

            protected override void OnFormClosed(FormClosedEventArgs e)
            {
                _owner.OnClosed(Handle);
                base.OnFormClosed(e);
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WM_CLIPBOARDUPDATE)
                {
                    _owner.OnClipboardUpdated();
                }

                base.WndProc(ref m);
            }
        }
    }
}
'@

    $referencedAssemblies = @(
        'System.Windows.Forms',
        'System.Drawing'
    )
    $referenceAssemblyDirectory = Join-Path -Path $PSHOME -ChildPath 'ref'
    if (Test-Path -Path $referenceAssemblyDirectory -PathType Container) {
        $referencedAssemblies = @(
            Get-ChildItem -Path $referenceAssemblyDirectory -Filter '*.dll' -File -ErrorAction Stop |
                ForEach-Object { $_.FullName }
        )
        $referencedAssemblies += @(
            Get-ChildItem -Path $PSHOME -Filter 'System.Windows.Forms*.dll' -File -ErrorAction Stop |
                ForEach-Object { $_.FullName }
            Get-ChildItem -Path $PSHOME -Filter 'System.Drawing*.dll' -File -ErrorAction Stop |
                ForEach-Object { $_.FullName }
            Get-ChildItem -Path $PSHOME -Filter 'System.Private.Windows*.dll' -File -ErrorAction Stop |
                ForEach-Object { $_.FullName }
        )
    }

    Add-Type -TypeDefinition $typeSource -ReferencedAssemblies $referencedAssemblies
}

function New-KlipAroundClipboardListener {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Listener setup is an internal part of clipboard monitoring.')]
    param()

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $null
    }

    try {
        Initialize-KlipAroundClipboardListenerType
        $listener = [KlipAround.ClipboardListener]::new()
        if (-not $listener.IsOperational) {
            $listener.Dispose()
            Write-Verbose 'Clipboard event listener could not start; falling back to polling.'
            return $null
        }
        return $listener
    }
    catch {
        Write-Verbose "Clipboard event listener could not initialize: $($_.Exception.Message). Falling back to polling."
        return $null
    }
}

function Invoke-KlipAroundXclip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Read', 'Write')]
        [string]$Operation,

        [Parameter()]
        [string]$Text,

        [Parameter()]
        [ValidateRange(1, 3600000)]
        [int]$TimeoutMilliseconds = 60000
    )

    if ([string]::IsNullOrWhiteSpace($env:DISPLAY)) {
        throw [System.InvalidOperationException]::new('Linux clipboard requires an accessible X11 or XWayland display; DISPLAY is not set.')
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'xclip'
    $startInfo.Arguments = if ($Operation -eq 'Read') { '-selection clipboard -out' } else { '-selection clipboard -in' }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = ($Operation -eq 'Read')
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($Operation -eq 'Read') {
        $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $remainingMilliseconds = {
        return [int][Math]::Max(0, $TimeoutMilliseconds - $timer.ElapsedMilliseconds)
    }
    $timeoutMessage = "xclip $Operation timed out after $TimeoutMilliseconds milliseconds."
    try {
        try {
            [void]$process.Start()
            $started = $true
        }
        catch {
            if ($_.Exception.InnerException -is [System.ComponentModel.Win32Exception] -and
                $_.Exception.InnerException.NativeErrorCode -eq 2) {
                throw [System.InvalidOperationException]::new('Linux clipboard requires xclip on PATH. Install xclip and use an accessible X11 or XWayland display.', $_.Exception)
            }
            throw [System.InvalidOperationException]::new("Could not start xclip: $($_.Exception.Message)", $_.Exception)
        }
        $stdout = if ($Operation -eq 'Read') { $process.StandardOutput.ReadToEndAsync() } else { $null }
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($Operation -eq 'Write') {
            $process.StandardInput.AutoFlush = $true
            $write = $process.StandardInput.WriteAsync($Text)
            if (-not $write.Wait((& $remainingMilliseconds))) {
                throw [System.InvalidOperationException]::new($timeoutMessage)
            }
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit((& $remainingMilliseconds))) {
            throw [System.InvalidOperationException]::new($timeoutMessage)
        }
        # A successful write forks an owner that can keep stderr open.
        if ($process.ExitCode -ne 0) {
            if (-not $stderr.Wait((& $remainingMilliseconds))) {
                throw [System.InvalidOperationException]::new($timeoutMessage)
            }
            $errorOutput = $stderr.GetAwaiter().GetResult().Trim()
            if ($Operation -eq 'Read' -and $errorOutput -match '(?i)target .+ not available') {
                throw 'Clipboard is empty or does not contain text.'
            }
            throw [System.InvalidOperationException]::new("xclip failed (exit $($process.ExitCode)): $errorOutput")
        }
        if ($Operation -eq 'Read') {
            if (-not $stdout.Wait((& $remainingMilliseconds))) {
                throw [System.InvalidOperationException]::new($timeoutMessage)
            }
            return $stdout.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            try {
                Stop-Process -Id $process.Id -ErrorAction Stop
            }
            catch {
                if (-not $process.HasExited) { throw }
            }
            [void]$process.WaitForExit(1000)
        }
        $process.Dispose()
    }
}

function Set-KlipAroundClipboardText {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal protocol writes cannot be individually skipped.')]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter()]
        [ValidateRange(1, 3600000)]
        [int]$TimeoutMilliseconds = 60000
    )

    if ($PSVersionTable.PSEdition -eq 'Core' -and $IsLinux) {
        [void](Invoke-KlipAroundXclip -Operation Write -Text $Text -TimeoutMilliseconds $TimeoutMilliseconds)
        return
    }

    if (-not (Get-Command -Name Set-Clipboard -ErrorAction Ignore)) {
        throw 'Set-Clipboard is not available in this PowerShell session.'
    }

    Set-Clipboard -Value $Text -ErrorAction Stop
}

function Get-KlipAroundClipboardText {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 3600000)]
        [int]$TimeoutMilliseconds = 60000
    )

    if ($PSVersionTable.PSEdition -eq 'Core' -and $IsLinux) {
        $text = Invoke-KlipAroundXclip -Operation Read -TimeoutMilliseconds $TimeoutMilliseconds
    }
    else {
        if (-not (Get-Command -Name Get-Clipboard -ErrorAction Ignore)) {
            throw 'Get-Clipboard is not available in this PowerShell session.'
        }
        $text = Get-Clipboard -Raw -ErrorAction Stop
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Clipboard is empty or does not contain text.'
    }

    return $text
}
