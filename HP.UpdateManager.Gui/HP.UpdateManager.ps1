# HP Update Manager GUI
# Requires PowerShell 5.1+ (Windows)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, Microsoft.VisualBasic, System.Windows.Forms

# --- PATH RESOLUTION ---
function Get-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    return [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

$Global:ScriptDir = Get-ScriptDirectory

# --- MODULE INITIALIZATION ---
function Initialize-Modules {
    $scriptDir = $Global:ScriptDir
    $modulesPath = Join-Path $scriptDir "Modules"
    
    if (-not (Test-Path $modulesPath)) {
        $devModulesPath = Join-Path (Split-Path -Parent $scriptDir) "Modules"
        if (Test-Path $devModulesPath) {
            $modulesPath = $devModulesPath
        }
    }
    
    if (Test-Path $modulesPath) {
        if ($env:PSModulePath -notlike "*$modulesPath*") {
            $env:PSModulePath = "$modulesPath;$($env:PSModulePath)"
        }
    }
    
    Import-Module HP.ClientManagement -Force -ErrorAction SilentlyContinue
    Import-Module HP.Softpaq -Force -ErrorAction SilentlyContinue
    Import-Module HP.Firmware -Force -ErrorAction SilentlyContinue
}

# --- DATA MODEL ---
Add-Type @"
using System.ComponentModel;

public class HPComputer : INotifyPropertyChanged {
    private string _hostname;
    private string _model;
    private string _serialNumber;
    private string _platformId;
    private string _status;
    private string _statusColor;
    private string _lastUpdated;
    private string _os;
    private string _freeDisk;
    private string _memory;

    public string Hostname { 
        get { return _hostname; } 
        set { _hostname = value; OnPropertyChanged("Hostname"); } 
    }
    public string Model { 
        get { return _model; } 
        set { _model = value; OnPropertyChanged("Model"); } 
    }
    public string SerialNumber { 
        get { return _serialNumber; } 
        set { _serialNumber = value; OnPropertyChanged("SerialNumber"); } 
    }
    public string PlatformID { 
        get { return _platformId; } 
        set { _platformId = value; OnPropertyChanged("PlatformID"); } 
    }
    public string Status { 
        get { return _status; } 
        set { _status = value; OnPropertyChanged("Status"); } 
    }
    public string StatusColor { 
        get { return _statusColor; } 
        set { _statusColor = value; OnPropertyChanged("StatusColor"); } 
    }
    public string LastUpdated { 
        get { return _lastUpdated; } 
        set { _lastUpdated = value; OnPropertyChanged("LastUpdated"); } 
    }
    public string OS { 
        get { return _os; } 
        set { _os = value; OnPropertyChanged("OS"); } 
    }
    public string FreeDisk { 
        get { return _freeDisk; } 
        set { _freeDisk = value; OnPropertyChanged("FreeDisk"); } 
    }
    public string Memory { 
        get { return _memory; } 
        set { _memory = value; OnPropertyChanged("Memory"); } 
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name) {
        var handler = PropertyChanged;
        if (handler != null) {
            handler(this, new PropertyChangedEventArgs(name));
        }
    }
}

public class UpdateItem : INotifyPropertyChanged {
    private bool _isSelected;
    private string _name;
    private string _id;
    private string _type;

    public bool IsSelected { 
        get { return _isSelected; } 
        set { _isSelected = value; OnPropertyChanged("IsSelected"); } 
    }
    public string Name { 
        get { return _name; } 
        set { _name = value; OnPropertyChanged("Name"); } 
    }
    public string ID { 
        get { return _id; } 
        set { _id = value; OnPropertyChanged("ID"); } 
    }
    public string Type { 
        get { return _type; } 
        set { _type = value; OnPropertyChanged("Type"); } 
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name) {
        var handler = PropertyChanged;
        if (handler != null) {
            handler(this, new PropertyChangedEventArgs(name));
        }
    }
}
"@

$computers = New-Object System.Collections.ObjectModel.ObservableCollection[HPComputer]
$availableUpdates = New-Object System.Collections.ObjectModel.ObservableCollection[UpdateItem]

# --- CONFIGURATION ---
$AppDataDir = Join-Path $env:APPDATA "CentralHPUpdater"
if (-not (Test-Path $AppDataDir)) { New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null }

$configPath = Join-Path $AppDataDir "config.json"
$Global:Config = @{
    Timeout     = 5
    LogPath     = "logs"
    RepoPath    = "Repository"
    AutoRefresh = $false
}

function Load-Config {
    if (Test-Path $configPath) {
        try {
            $loaded = Get-Content $configPath | ConvertFrom-Json
            if ($loaded.Timeout) { $Global:Config.Timeout = $loaded.Timeout }
            if ($loaded.LogPath) { $Global:Config.LogPath = $loaded.LogPath }
            if ($loaded.RepoPath) { $Global:Config.RepoPath = $loaded.RepoPath }
            if ($loaded.AutoRefresh) { $Global:Config.AutoRefresh = $loaded.AutoRefresh }
        }
        catch {
            Write-Log "Failed to load config, using defaults."
        }
    }
    # Ensure log directory exists
    if (-not [System.IO.Path]::IsPathRooted($Global:Config.LogPath)) {
        $Global:Config.LogPath = Join-Path $AppDataDir $Global:Config.LogPath
    }
    if (-not (Test-Path $Global:Config.LogPath)) { New-Item -ItemType Directory -Path $Global:Config.LogPath -Force | Out-Null }

    # Ensure Repo directory exists
    if (-not [System.IO.Path]::IsPathRooted($Global:Config.RepoPath)) {
        $Global:Config.RepoPath = Join-Path $AppDataDir $Global:Config.RepoPath
    }
    if (-not (Test-Path $Global:Config.RepoPath)) { New-Item -ItemType Directory -Path $Global:Config.RepoPath -Force | Out-Null }
}

function Save-Config {
    $Global:Config | ConvertTo-Json | Out-File $configPath
}

# --- PERSISTENCE ---
$inventoryPath = Join-Path $AppDataDir "inventory.json"

function Save-Inventory {
    $data = foreach ($c in $computers) {
        @{
            Hostname     = $c.Hostname
            Model        = $c.Model
            SerialNumber = $c.SerialNumber
            PlatformID   = $c.PlatformID
            Status       = $c.Status
            StatusColor  = $c.StatusColor
            LastUpdated  = $c.LastUpdated
            OS           = $c.OS
            FreeDisk     = $c.FreeDisk
            Memory       = $c.Memory
        }
    }
    $data | ConvertTo-Json | Out-File $inventoryPath
}

function Load-Inventory {
    if (Test-Path $inventoryPath) {
        try {
            $data = Get-Content $inventoryPath | ConvertFrom-Json
            if ($data -is [PSCustomObject]) { $data = @($data) }
            foreach ($item in $data) {
                $c = New-Object HPComputer
                $c.Hostname = $item.Hostname
                $c.Model = $item.Model
                $c.SerialNumber = $item.SerialNumber
                $c.PlatformID = $item.PlatformID
                $c.Status = $item.Status
                $c.StatusColor = $item.StatusColor
                $c.LastUpdated = $item.LastUpdated
                $c.OS = $item.OS
                $c.FreeDisk = $item.FreeDisk
                $c.Memory = $item.Memory
                $computers.Add($c)
            }
        }
        catch {
            Write-Log "Failed to load inventory: $($_.Exception.Message)"
        }
    }
}

# --- UI LOGIC ---
$xamlPath = Join-Path $Global:ScriptDir "MainWindow.xaml"
if (-not (Test-Path $xamlPath)) {
    [System.Windows.MessageBox]::Show("MainWindow.xaml not found at $xamlPath", "Fatal Error")
    exit 1
}

[xml]$xaml = Get-Content $xamlPath
if ($xaml.Window.HasAttribute("x:Class")) {
    $xaml.Window.RemoveAttribute("x:Class")
}

$reader = New-Object System.Xml.XmlNodeReader($xaml)
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
catch {
    [System.Windows.MessageBox]::Show("Error loading XAML: $($_.Exception.Message)", "Fatal Error")
    exit 1
}

# Map UI Elements
$dgComputers = $window.FindName("DgComputers")
$btnAddComputer = $window.FindName("BtnAddComputer")
$btnImport = $window.FindName("BtnImport")
$btnExport = $window.FindName("BtnExport")
$btnRefreshAll = $window.FindName("BtnRefreshAll")
$btnUpdateSelected = $window.FindName("BtnUpdateSelected")
$lstUpdates = $window.FindName("LstUpdates")
$txtLog = $window.FindName("TxtLog")
$txtSearch = $window.FindName("TxtSearch")
$txtDetailHost = $window.FindName("TxtDetailHost")
$txtDetailSerial = $window.FindName("TxtDetailSerial")

# Context Menu
$ctxPing = $window.FindName("CtxPing")
$ctxOpenC = $window.FindName("CtxOpenC")
$ctxRestart = $window.FindName("CtxRestart")
$ctxRemove = $window.FindName("CtxRemove")

# Navigation Elements
$btnDashboard = $window.FindName("BtnDashboard")
$btnComputers = $window.FindName("BtnComputers")
$btnLogs = $window.FindName("BtnLogs")
$btnSettings = $window.FindName("BtnSettings")

$viewDashboard = $window.FindName("ViewDashboard")
$viewInventory = $window.FindName("ViewInventory")
$viewLogs = $window.FindName("ViewLogs")
$viewSettings = $window.FindName("ViewSettings")

$inventoryActions = $window.FindName("InventoryActions")
$txtTitle = $window.FindName("TxtTitle")
$txtSubtitle = $window.FindName("TxtSubtitle")

# Dashboard Elements
$txtTotalSystems = $window.FindName("TxtTotalSystems")
$txtOnlineSystems = $window.FindName("TxtOnlineSystems")
$txtOfflineSystems = $window.FindName("TxtOfflineSystems")
$txtLastRefresh = $window.FindName("TxtLastRefresh")

# Settings Elements
$txtTimeout = $window.FindName("TxtTimeout")
$txtLogPath = $window.FindName("TxtLogPath")
$txtRepoPath = $window.FindName("TxtRepoPath")
$chkAutoRefresh = $window.FindName("ChkAutoRefresh")
$btnSaveSettings = $window.FindName("BtnSaveSettings")

# Loading Elements
$loadingOverlay = $window.FindName("LoadingOverlay")
$txtLoadingStatus = $window.FindName("TxtLoadingStatus")
$pbLoading = $window.FindName("PbLoading")

if ($dgComputers) { $dgComputers.ItemsSource = $computers }
if ($lstUpdates) { $lstUpdates.ItemsSource = $availableUpdates }

# --- UTILITIES ---

function Show-Loading {
    param([string]$Message = "Processing...")
    if ($loadingOverlay) {
        $loadingOverlay.Visibility = "Visible"
        if ($txtLoadingStatus) { $txtLoadingStatus.Text = $Message }
        if ($pbLoading) { $pbLoading.IsIndeterminate = $true }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
    }
}

function Hide-Loading {
    if ($loadingOverlay) {
        $loadingOverlay.Visibility = "Collapsed"
    }
}

function Update-DashboardStats {
    $total = $computers.Count
    $online = ($computers | Where-Object { $_.Status -like "Online*" }).Count
    $offline = $total - $online
    
    if ($window -and $window.Dispatcher) {
        $window.Dispatcher.Invoke({
                if ($txtTotalSystems) { $txtTotalSystems.Text = $total.ToString() }
                if ($txtOnlineSystems) { $txtOnlineSystems.Text = $online.ToString() }
                if ($txtOfflineSystems) { $txtOfflineSystems.Text = $offline.ToString() }
            })
    }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    
    if ($window -and $window.Dispatcher) {
        $window.Dispatcher.Invoke({
                if ($txtLog) {
                    $txtLog.AppendText("$logEntry`r`n")
                    $txtLog.ScrollToEnd()
                }
            })
    }

    try {
        $logFile = Join-Path $Global:Config.LogPath "app_$(Get-Date -Format 'yyyy-MM-dd').log"
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {}
}

# --- NAVIGATION LOGIC ---

function Animate-FadeIn {
    param($Element)
    $Element.Opacity = 0
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = 1
    $anim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.4))
    $anim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $anim.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

function Invoke-AsyncUI {
    param(
        [ScriptBlock]$ScriptBlock,
        [Hashtable]$Arguments,
        [ScriptBlock]$OnComplete
    )
    
    $ps = [powershell]::Create()
    
    $initBlock = {
        param($__Dispatcher, $__TxtLog, $__Config, $__ScriptDir)
        
        $Global:Config = $__Config
        $Global:ScriptDir = $__ScriptDir
        
        $modulesPath = Join-Path $__ScriptDir "Modules"
        if (Test-Path $modulesPath) {
            if ($env:PSModulePath -notlike "*$modulesPath*") {
                $env:PSModulePath = "$modulesPath;$($env:PSModulePath)"
            }
        }
        Import-Module HP.ClientManagement -Force -ErrorAction SilentlyContinue
        Import-Module HP.Softpaq -Force -ErrorAction SilentlyContinue
        Import-Module HP.Firmware -Force -ErrorAction SilentlyContinue

        function Write-Log {
            param([string]$Message)
            $timestamp = Get-Date -Format "HH:mm:ss"
            $logEntry = "[$timestamp] $Message"
            
            if ($__Dispatcher -and $__TxtLog) {
                # Force output to null to avoid leaking into pipeline
                $__Dispatcher.InvokeAsync([Action] {
                        $__TxtLog.AppendText("$logEntry`n")
                        $__TxtLog.ScrollToEnd()
                    }) | Out-Null
            }

            try {
                $logFile = Join-Path $Global:Config.LogPath "app_$(Get-Date -Format 'yyyy-MM-dd').log"
                Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }
    
    $ps.AddScript($initBlock).AddArgument($window.Dispatcher).AddArgument($txtLog).AddArgument($Global:Config).AddArgument($Global:ScriptDir) | Out-Null
    
    $funcBody1 = (Get-Command Get-RemoteSystemInfo).Definition
    $funcBody2 = (Get-Command Get-AvailableUpdates).Definition
    $funcBody3 = (Get-Command Invoke-HPUpdate).Definition
    $ps.AddScript("function Get-RemoteSystemInfo { $funcBody1 }; function Get-AvailableUpdates { $funcBody2 }; function Invoke-HPUpdate { $funcBody3 };") | Out-Null
    
    $ps.AddScript($ScriptBlock) | Out-Null
    if ($Arguments) {
        foreach ($key in $Arguments.Keys) {
            $ps.AddParameter($key, $Arguments[$key]) | Out-Null
        }
    }
    
    $asyncResult = $ps.BeginInvoke()
    
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
            if ($asyncResult.IsCompleted) {
                $timer.Stop()
                $info = $null
                $err = $null
                try {
                    $info = $ps.EndInvoke($asyncResult)
                }
                catch {
                    $err = $_
                }
                finally {
                    $ps.Dispose()
                }
                if ($OnComplete) {
                    & $OnComplete -res $info -errObj $err
                }
            }
        })
    $timer.Start()
}

function Set-ButtonActive {
    param($Button)
    $btnDashboard.IsEnabled = $true
    $btnComputers.IsEnabled = $true
    $btnLogs.IsEnabled = $true
    $btnSettings.IsEnabled = $true
    if ($Button) { $Button.IsEnabled = $false }
}

function Show-View {
    param([string]$ViewName)
    
    $viewDashboard.Visibility = "Collapsed"
    $viewInventory.Visibility = "Collapsed"
    $viewLogs.Visibility = "Collapsed"
    $viewSettings.Visibility = "Collapsed"
    $inventoryActions.Visibility = "Collapsed"
    
    switch ($ViewName) {
        "Dashboard" {
            $viewDashboard.Visibility = "Visible"
            Animate-FadeIn $viewDashboard
            $txtTitle.Text = "Dashboard"
            $txtSubtitle.Text = "Overview of your fleet status"
            Set-ButtonActive $btnDashboard
            Update-DashboardStats
        }
        "Inventory" {
            $viewInventory.Visibility = "Visible"
            Animate-FadeIn $viewInventory
            $inventoryActions.Visibility = "Visible"
            $txtTitle.Text = "Inventory"
            $txtSubtitle.Text = "Manage and update your systems"
            Set-ButtonActive $btnComputers
        }
        "Logs" {
            $viewLogs.Visibility = "Visible"
            Animate-FadeIn $viewLogs
            $txtTitle.Text = "Activity Logs"
            $txtSubtitle.Text = "History of operations and errors"
            Set-ButtonActive $btnLogs
        }
        "Settings" {
            $viewSettings.Visibility = "Visible"
            Animate-FadeIn $viewSettings
            $txtTitle.Text = "Settings"
            $txtSubtitle.Text = "Configure application preferences"
            Set-ButtonActive $btnSettings
            
            if ($txtTimeout) { $txtTimeout.Text = $Global:Config.Timeout }
            if ($txtLogPath) { $txtLogPath.Text = $Global:Config.LogPath }
            if ($txtRepoPath) { $txtRepoPath.Text = $Global:Config.RepoPath }
            if ($chkAutoRefresh) { $chkAutoRefresh.IsChecked = $Global:Config.AutoRefresh }
        }
    }
}

if ($btnDashboard) { $btnDashboard.add_Click({ Show-View "Dashboard" }) }
if ($btnComputers) { $btnComputers.add_Click({ Show-View "Inventory" }) }
if ($btnLogs) { $btnLogs.add_Click({ Show-View "Logs" }) }
if ($btnSettings) { $btnSettings.add_Click({ Show-View "Settings" }) }

# --- CORE FUNCTIONS ---

function Get-RemoteSystemInfo {
    param([string]$Hostname)
    
    Write-Log "Probing ${Hostname}..."
    
    # 1. Ping Check (Fast)
    $ping = Test-Connection -ComputerName $Hostname -Count 1 -Quiet
    if (-not $ping) {
        Write-Log "${Hostname} is unreachable (Ping failed)."
        return @{
            Model       = "Unknown"
            Serial      = "N/A"
            PlatformID  = "N/A"
            Status      = "Unreachable"
            Color       = "#E57373" # Red
            LastUpdated = "Never"
            OS          = "N/A"
            FreeDisk    = "N/A"
            Memory      = "N/A"
        }
    }

    # 2. WMI/CIM Connection
    try {
        $session = $null
        $timeout = $Global:Config.Timeout
        try {
            $session = New-CimSession -ComputerName $Hostname -ErrorAction Stop -OperationTimeoutSec $timeout
        }
        catch {
            Write-Log "WinRM to ${Hostname} failed, trying DCOM..."
            $opt = New-CimSessionOption -Protocol Dcom
            $session = New-CimSession -ComputerName $Hostname -SessionOption $opt -ErrorAction Stop -OperationTimeoutSec $timeout
        }
        
        # HP Info
        $model = Get-HPDeviceModel -CimSession $session
        $serial = Get-HPDeviceSerialNumber -CimSession $session
        $platformId = Get-HPDeviceProductID -CimSession $session
        
        # BIOS Info
        $biosInfo = Get-CimInstance -ClassName Win32_BIOS -CimSession $session
        $biosVersion = $biosInfo.SMBIOSBIOSVersion
        $biosDate = $biosInfo.ReleaseDate
        
        # OS Info
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -CimSession $session
        $osName = $osInfo.Caption -replace "Microsoft Windows ", ""
        
        # Disk Info (C:)
        $diskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -CimSession $session
        $freeSpaceGB = [math]::Round($diskInfo.FreeSpace / 1GB, 1)
        $totalSpaceGB = [math]::Round($diskInfo.Size / 1GB, 1)
        $diskStr = "${freeSpaceGB} GB / ${totalSpaceGB} GB"
        
        # Memory Info
        $memInfo = Get-CimInstance -ClassName Win32_ComputerSystem -CimSession $session
        $memGB = [math]::Round($memInfo.TotalPhysicalMemory / 1GB, 1)
        
        $formattedDate = "Unknown"
        if ($biosDate) {
            if ($biosDate -match '^(\d{4})(\d{2})(\d{2})') {
                $formattedDate = "$($Matches[1])-$($Matches[2])-$($Matches[3])"
            }
        }
        
        Remove-CimSession $session
        Write-Log "Successfully scanned ${Hostname}."
        
        return @{
            Model       = $model
            Serial      = $serial
            PlatformID  = $platformId
            Status      = "Online"
            Color       = "#4CAF50" # Green
            LastUpdated = $formattedDate
            OS          = $osName
            FreeDisk    = $diskStr
            Memory      = "${memGB} GB"
        }
    }
    catch {
        Write-Log "Failed to connect to ${Hostname}: $($_.Exception.Message)"
        $status = "WMI Error"
        if ($_.Exception.Message -match "Access is denied") {
            $status = "Access Denied"
        }
        return @{
            Model       = "Unknown"
            Serial      = "N/A"
            PlatformID  = "N/A"
            Status      = $status
            Color       = "#FFB74D" # Orange/Warning
            LastUpdated = "Never"
            OS          = "N/A"
            FreeDisk    = "N/A"
            Memory      = "N/A"
        }
    }
}

function Get-AvailableUpdates {
    param($PlatformID)
    Write-Log "Checking for available updates for ${PlatformID}..."
    try {
        $biosUpdates = Get-HPBIOSUpdates -Platform $PlatformID -ErrorAction SilentlyContinue
        $softpaqs = Get-HPSoftpaqList -Platform $PlatformID -Category "Firmware", "Driver" -ReleaseType "Critical", "Recommended" -ErrorAction SilentlyContinue
        return @{ BIOS = $biosUpdates; SoftPaqs = $softpaqs }
    }
    catch {
        return @{ BIOS = $null; SoftPaqs = @() }
    }
}

function Invoke-HPUpdate {
    param(
        [string]$Hostname,
        [string]$PlatformID,
        [string]$Type, # BIOS or SoftPaq
        [string]$TargetId # SoftPaq Number or BIOS Version
    )
    
    try {
        if ($Type -eq "BIOS") {
            Write-Host "Starting BIOS Update on ${Hostname}..."
            Get-HPBIOSUpdates -Platform $PlatformID -Flash -Yes -BitLocker Suspend -Target $Hostname -ErrorAction Stop
            Write-Log "Triggered BIOS update on ${Hostname}."
        }
        else {
            Write-Host "Starting SoftPaq Update ($TargetId) on ${Hostname}..."
            
            # --- ENTERPRISE PUSH LOGIC ---
            # 1. Download Local
            $repoPath = $Global:Config.RepoPath
            $softpaqFile = Get-HPSoftpaq -Number $TargetId -Directory $repoPath -SaveAs "$TargetId.exe" -ErrorAction SilentlyContinue
            if (-not $softpaqFile) {
                # Fallback if SaveAs didn't return file object (older versions of CMSL might differ)
                $expectedPath = Join-Path $repoPath "$TargetId.exe"
                if (Test-Path $expectedPath) { $softpaqFile = Get-Item $expectedPath }
            }

            if ($softpaqFile) {
                Write-Log "Local SoftPaq cached: $($softpaqFile.FullName)"
                
                # 2. Push to Target (C$\Windows\Temp)
                $destPath = "\\$Hostname\C$\Windows\Temp\$($softpaqFile.Name)"
                try {
                    Copy-Item -Path $softpaqFile.FullName -Destination $destPath -Force -ErrorAction Stop
                    Write-Log "Pushed $TargetId to $Hostname via SMB."
                    
                    # 3. Execute Remote (WMI)
                    $cmd = "C:\Windows\Temp\$($softpaqFile.Name) -s" # -s for Silent
                    
                    $opt = New-CimSessionOption -Protocol Dcom
                    $session = New-CimSession -ComputerName $Hostname -SessionOption $opt -ErrorAction Stop
                    Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
                    Remove-CimSession $session
                    
                    Write-Log "Executed $TargetId on $Hostname (Agentless Push)."
                    return $true
                }
                catch {
                    Write-Log "SMB Push failed ($($_.Exception.Message)). Falling back to remote download..."
                }
            }
            else {
                Write-Log "Failed to download SoftPaq locally. Falling back to remote download..."
            }

            # --- FALLBACK: REMOTE DOWNLOAD (WinRM/WMI) ---
            $useDcom = $false
            try {
                $test = New-CimSession -ComputerName $Hostname -ErrorAction Stop -OperationTimeoutSec 2
                Remove-CimSession $test
            }
            catch {
                $useDcom = $true
            }

            if (-not $useDcom) {
                Invoke-Command -ComputerName $Hostname -ScriptBlock {
                    param($spNumber)
                    Import-Module HP.Softpaq
                    Get-HPSoftpaq -Number $spNumber -Install -Silent -ErrorAction SilentlyContinue
                } -ArgumentList $TargetId
                Write-Log "Triggered SoftPaq ${TargetId} on ${Hostname} via WinRM."
            }
            else {
                Write-Log "WinRM unavailable for ${Hostname}, attempting WMI/DCOM launch for SoftPaq ${TargetId}..."
                $opt = New-CimSessionOption -Protocol Dcom
                $session = New-CimSession -ComputerName $Hostname -SessionOption $opt -ErrorAction Stop
                $cmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -Command & { Import-Module HP.Softpaq; Get-HPSoftpaq -Number $TargetId -Install -Silent }"
                Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
                Remove-CimSession $session
                Write-Log "Triggered background install for ${TargetId} via WMI."
            }
        }
        return $true
    }
    catch {
        Write-Log "Update failed on ${Hostname}: $($_.Exception.Message)"
        return $false
    }
}

# --- EVENT HANDLERS ---

if ($txtSearch) {
    $txtSearch.add_TextChanged({
            $filter = $txtSearch.Text
            if ([string]::IsNullOrWhiteSpace($filter)) {
                $dgComputers.ItemsSource = $computers
            }
            else {
                $filtered = $computers | Where-Object { 
                    $_.Hostname -like "*$filter*" -or $_.Model -like "*$filter*" -or $_.Status -like "*$filter*" 
                }
                $dgComputers.ItemsSource = $filtered
            }
        })
}

if ($dgComputers) {
    $dgComputers.add_SelectionChanged({
            $selected = $dgComputers.SelectedItem
            if ($selected -and $selected.PlatformID -ne "N/A") {
                if ($txtDetailHost) { $txtDetailHost.Text = $selected.Hostname }
                if ($txtDetailSerial) { $txtDetailSerial.Text = "SN: $($selected.SerialNumber)" }

                Show-Loading "Fetching updates for $($selected.Hostname)..."
            
                Invoke-AsyncUI -ScriptBlock {
                    param($platId)
                    return Get-AvailableUpdates -PlatformID $platId
                } -Arguments @{ platId = $selected.PlatformID } -OnComplete {
                    param($updates, $errObj)
                
                    $availableUpdates.Clear()
                    if ($errObj) {
                        $u = New-Object UpdateItem
                        $u.Name = "Error fetching updates."
                        $u.IsSelected = $false
                        $availableUpdates.Add($u)
                        Hide-Loading
                        return
                    }

                    $hash = $updates[0]
                
                    if ($hash.BIOS) {
                        $u = New-Object UpdateItem
                        $u.Name = "[BIOS] $($hash.BIOS.Version) - $($hash.BIOS.ReleaseDate)"
                        $u.ID = $hash.BIOS.Version
                        $u.Type = "BIOS"
                        $u.IsSelected = $true
                        $availableUpdates.Add($u)
                    }
                    foreach ($sp in $hash.SoftPaqs) {
                        $u = New-Object UpdateItem
                        $u.Name = "[SoftPaq] $($sp.Title) ($($sp.Number))"
                        $u.ID = $sp.Number
                        $u.Type = "SoftPaq"
                        $u.IsSelected = $true
                        $availableUpdates.Add($u)
                    }
                    if ($availableUpdates.Count -eq 0) {
                        $u = New-Object UpdateItem
                        $u.Name = "No updates available."
                        $u.IsSelected = $false
                        $availableUpdates.Add($u)
                    }
                    Hide-Loading
                }
            }
        })
}

if ($btnUpdateSelected) {
    $btnUpdateSelected.add_Click({
            $selectedComputer = $dgComputers.SelectedItem
            if (-not $selectedComputer) { return }
        
            $selectedUpdates = $availableUpdates | Where-Object { $_.IsSelected -eq $true }
            if ($selectedUpdates.Count -eq 0) {
                [System.Windows.MessageBox]::Show("No updates selected.", "Info")
                return
            }
        
            $result = [System.Windows.MessageBox]::Show("Install $($selectedUpdates.Count) selected update(s) on $($selectedComputer.Hostname)?", "Confirm Install", [System.Windows.MessageBoxButton]::YesNo)
            if ($result -eq "Yes") {
                Show-Loading "Installing updates..."

                $flatUpdates = @()
                foreach ($u in $selectedUpdates) { $flatUpdates += @{ Type = $u.Type; ID = $u.ID } }
            
                Invoke-AsyncUI -ScriptBlock {
                    param($HostName, $PlatID, $UpdatesToInstall)
                    foreach ($update in $UpdatesToInstall) {
                        Invoke-HPUpdate -Hostname $Hostname -PlatformID $PlatID -Type $update.Type -TargetId $update.ID
                    }
                } -Arguments @{ HostName = $selectedComputer.Hostname; PlatID = $selectedComputer.PlatformID; UpdatesToInstall = $flatUpdates } -OnComplete {
                    param($res, $errObj)
                    if ($errObj) {
                        [System.Windows.MessageBox]::Show("Error during install: $($errObj.Exception.Message)", "Error")
                    }
                    else {
                        [System.Windows.MessageBox]::Show("Updates triggered successfully.", "Success")
                    }
                    Hide-Loading
                }
            }
        })
}

# Context Menu Handlers
if ($ctxPing) {
    $ctxPing.add_Click({
            $selected = $dgComputers.SelectedItem
            if ($selected) {
                Show-Loading "Pinging $($selected.Hostname)..."
                Invoke-AsyncUI -ScriptBlock {
                    param($HostName)
                    return Test-Connection -ComputerName $HostName -Count 2 -Quiet
                } -Arguments @{ HostName = $selected.Hostname } -OnComplete {
                    param($res, $err)
                    if ($res -and $res[0] -eq $true) {
                        [System.Windows.MessageBox]::Show("$($selected.Hostname) is ONLINE.", "Ping Result")
                    }
                    else {
                        [System.Windows.MessageBox]::Show("$($selected.Hostname) is UNREACHABLE.", "Ping Result")
                    }
                    Hide-Loading
                }
            }
        })
}

if ($ctxOpenC) {
    $ctxOpenC.add_Click({
            $selected = $dgComputers.SelectedItem
            if ($selected) {
                Invoke-Item "\\$($selected.Hostname)\c$"
            }
        })
}

if ($ctxRestart) {
    $ctxRestart.add_Click({
            $selected = $dgComputers.SelectedItem
            if ($selected) {
                $result = [System.Windows.MessageBox]::Show("Are you sure you want to RESTART $($selected.Hostname)?", "Confirm Restart", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                if ($result -eq "Yes") {
                    try {
                        Restart-Computer -ComputerName $selected.Hostname -Force -ErrorAction Stop
                        [System.Windows.MessageBox]::Show("Restart command sent.", "Success")
                    }
                    catch {
                        [System.Windows.MessageBox]::Show("Failed to restart: $($_.Exception.Message)", "Error")
                    }
                }
            }
        })
}

if ($ctxRemove) {
    $ctxRemove.add_Click({
            $selected = $dgComputers.SelectedItem
            if ($selected) {
                $computers.Remove($selected)
                Save-Inventory
                Update-DashboardStats
            }
        })
}


if ($btnAddComputer) {
    $btnAddComputer.add_Click({
            $hostname = [Microsoft.VisualBasic.Interaction]::InputBox("Enter Hostname or IP Address", "Add Computer", "localhost")
            if ($hostname) {
                Show-Loading "Probing ${hostname}..."
                Invoke-AsyncUI -ScriptBlock {
                    param($host)
                    return Get-RemoteSystemInfo -Hostname $host
                } -Arguments @{ host = $hostname } -OnComplete {
                    param($res, $err)
                    if ($err) {
                        Write-Log "Error adding computer: $($err.Exception.Message)"
                        [System.Windows.MessageBox]::Show("Error adding computer: $($err.Exception.Message)", "Error")
                    }
                    else {
                        $info = $res[0]
                        $c = New-Object HPComputer
                        $c.Hostname = $hostname
                        $c.Model = $info.Model
                        $c.SerialNumber = $info.Serial
                        $c.PlatformID = $info.PlatformID
                        $c.Status = $info.Status
                        $c.StatusColor = $info.Color
                        $c.LastUpdated = $info.LastUpdated
                        $c.OS = $info.OS
                        $c.FreeDisk = $info.FreeDisk
                        $c.Memory = $info.Memory
                        $computers.Add($c)
                        Save-Inventory
                        Update-DashboardStats
                    }
                    Hide-Loading
                }
            }
        })
}

if ($btnImport) {
    $btnImport.add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Filter = "Text Files (*.txt)|*.txt|CSV Files (*.csv)|*.csv|All Files (*.*)|*.*"
            $dialog.Title = "Import Computers"
            if ($dialog.ShowDialog() -eq "OK") {
                Show-Loading "Importing systems..."
                $window.Dispatcher.Invoke({
                        try {
                            $lines = Get-Content $dialog.FileName
                            foreach ($line in $lines) {
                                if ($line -match "^#") { continue }
                                $hostToImport = $line.Trim()
                                if ($hostToImport -match ",") { $hostToImport = ($hostToImport -split ",")[0].Trim() }
                        
                                if (-not [string]::IsNullOrWhiteSpace($hostToImport)) {
                                    if (-not ($computers | Where-Object { $_.Hostname -eq $hostToImport })) {
                                        $c = New-Object HPComputer
                                        $c.Hostname = $hostToImport
                                        $c.Model = "Pending"
                                        $c.Status = "Unknown"
                                        $c.StatusColor = "#757575"
                                        $c.PlatformID = "N/A"
                                        $computers.Add($c)
                                    }
                                }
                            }
                            Save-Inventory
                            Update-DashboardStats
                            Write-Log "Imported systems from $($dialog.FileName)"
                        }
                        catch {
                            [System.Windows.MessageBox]::Show("Import failed: $($_.Exception.Message)", "Error")
                        }
                        Hide-Loading
                    }, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        })
}

if ($btnExport) {
    $btnExport.add_Click({
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            $dialog.Filter = "CSV Files (*.csv)|*.csv"
            $dialog.Title = "Export Inventory"
            $dialog.FileName = "HP_Inventory_$(Get-Date -Format 'yyyyMMdd').csv"
        
            if ($dialog.ShowDialog() -eq "OK") {
                try {
                    $computers | Select-Object Hostname, Model, SerialNumber, PlatformID, Status, LastUpdated, OS, FreeDisk, Memory | Export-Csv -Path $dialog.FileName -NoTypeInformation
                    [System.Windows.MessageBox]::Show("Export successful.", "Success")
                }
                catch {
                    [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Error")
                }
            }
        })
}

function Invoke-RefreshAll {
    Show-Loading "Refreshing all systems..."
    
    $hostnames = @()
    foreach ($c in $computers) { $hostnames += $c.Hostname }

    if ($hostnames.Count -eq 0) {
        Hide-Loading
        return
    }

    Invoke-AsyncUI -ScriptBlock {
        param($HostList)
        $results = @()
        foreach ($h in $HostList) {
            $info = Get-RemoteSystemInfo -Hostname $h
            $info.Hostname = $h
            $results += $info
        }
        return $results
    } -Arguments @{ HostList = $hostnames } -OnComplete {
        param($res, $errObj)
        if ($errObj) {
            Write-Log "Bulk refresh failed: $($errObj.Exception.Message)"
        }
        else {
            foreach ($r in $res) {
                # $r is a PSObject representing the hashtable
                $c = $computers | Where-Object { $_.Hostname -eq $r.Hostname }
                if ($c) {
                    $c.Model = $r.Model
                    $c.SerialNumber = $r.Serial
                    $c.PlatformID = $r.PlatformID
                    $c.Status = $r.Status
                    $c.StatusColor = $r.Color
                    $c.LastUpdated = $r.LastUpdated
                    $c.OS = $r.OS
                    $c.FreeDisk = $r.FreeDisk
                    $c.Memory = $r.Memory
                }
            }
            if ($dgComputers) { $dgComputers.Items.Refresh() }
            if ($txtLastRefresh) { $txtLastRefresh.Text = Get-Date -Format "HH:mm:ss" }
            Save-Inventory
            Update-DashboardStats
        }
        Hide-Loading
    }
}

if ($btnRefreshAll) {
    $btnRefreshAll.add_Click({ Invoke-RefreshAll })
}

if ($btnSaveSettings) {
    $btnSaveSettings.add_Click({
            $Global:Config.Timeout = $txtTimeout.Text
            $Global:Config.LogPath = $txtLogPath.Text
            $Global:Config.RepoPath = $txtRepoPath.Text
            $Global:Config.AutoRefresh = $chkAutoRefresh.IsChecked
            Save-Config
            [System.Windows.MessageBox]::Show("Settings saved!", "Success")
        })
}

# --- START APP ---
Initialize-Modules
Load-Config
Load-Inventory
Show-View "Dashboard"

# --- AUTO REFRESH TIMER ---
$Global:AutoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$Global:AutoRefreshTimer.Interval = [TimeSpan]::FromMinutes(15)
$Global:AutoRefreshTimer.Add_Tick({
        if ($Global:Config.AutoRefresh -and $btnRefreshAll.IsEnabled) {
            Invoke-RefreshAll
        }
    })
$Global:AutoRefreshTimer.Start()

if ($window) { $window.ShowDialog() | Out-Null }
