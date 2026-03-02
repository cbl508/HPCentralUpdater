[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')) {
  throw 'This GUI requires Windows.'
}

# Add required assemblies
Add-Type -AssemblyName System.Web

function Get-ScriptDirectory {
  if ($PSScriptRoot) { return $PSScriptRoot }
  if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
  return [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

$Global:ScriptDir = Get-ScriptDirectory

function Initialize-HPRepoModule {
  $repoRoot = Split-Path $Global:ScriptDir -Parent
  $modulesPath = Join-Path $repoRoot 'Modules'

  if (-not (Test-Path $modulesPath)) {
    throw "Could not find module directory: $modulesPath"
  }

  if ($env:PSModulePath -notlike "*$modulesPath*") {
    $env:PSModulePath = "$modulesPath;$($env:PSModulePath)"
  }

  Import-Module HP.Repo -Force -ErrorAction Stop | Out-Null
}

Initialize-HPRepoModule

# PS2EXE compiled with -noConsole forcibly redirects these cmdlets to WinForms message boxes.
# We must delete these overrides so they write silently to the background job streams.
$ps2exeOverrides = @('Write-Host', 'Write-Verbose', 'Write-Warning', 'Write-Information', 'Write-Debug', 'Write-Progress')
foreach ($cmd in $ps2exeOverrides) {
  if (Get-Command $cmd -CommandType Function -ErrorAction SilentlyContinue) {
    Remove-Item "Function:\$cmd" -ErrorAction SilentlyContinue
  }
}

$script:apiLogs = New-Object System.Collections.Generic.List[string]
$script:apiLogsMaxCount = 500
$script:activeJobs = @()
$script:taskRegistry = @{}

$AppDataDir = Join-Path $env:APPDATA "CentralHPUpdaterManager"
if (-not (Test-Path $AppDataDir)) { New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null }
$configFile = Join-Path $AppDataDir "config.json"
$inventoryFile = Join-Path $AppDataDir "inventory.json"

$script:repoPath = 'C:\SecurePacs'
if (Test-Path $configFile) {
  try {
    $conf = Get-Content $configFile | ConvertFrom-Json
    if ($conf.RepoPath) { $script:repoPath = $conf.RepoPath }
  }
  catch {}
}

if (-not (Test-Path $script:repoPath)) {
  New-Item -ItemType Directory -Path $script:repoPath -Force | Out-Null
}

function Save-Config {
  @{ RepoPath = $script:repoPath } | ConvertTo-Json -Compress | Out-File $configFile
}

function Write-ApiLog ($Message) {
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $script:apiLogs.Add("[$timestamp] $Message")
  
  if ($script:apiLogs.Count -gt $script:apiLogsMaxCount) {
    $script:apiLogs.RemoveAt(0)
  }
  Write-Host "[$timestamp] $Message" # Also write to host for immediate feedback
}

function Update-ActiveJobs {
  if ($script:activeJobs.Count -eq 0) { return }

  foreach ($job in $script:activeJobs) {
    if ($null -eq $job) { continue }

    $taskId = "task_$($job.Id)"
    if (-not $script:taskRegistry.ContainsKey($taskId)) {
      $script:taskRegistry[$taskId] = @{
        id        = $job.Id
        name      = "Task $($job.Id)"
        state     = 'Running'
        startTime = $job.PSBeginTime
        messages  = New-Object System.Collections.Generic.List[string]
        progress  = @{ total = 0; completed = 0; percentage = 0; currentStep = ''; results = @() }
      }
    }
    $taskEntry = $script:taskRegistry[$taskId]

    # Capture main output
    try {
      $results = Receive-Job -Job $job -ErrorAction SilentlyContinue
      foreach ($res in $results) {
        $msg = "[Task $($job.Id)] Output: $res"
        Write-ApiLog $msg
        $taskEntry.messages.Add($msg)
      }
    }
    catch {
      $msg = "[Task $($job.Id)] ERROR: $_"
      Write-ApiLog $msg
      $taskEntry.messages.Add($msg)
    }

    # Capture verbose, err, warning, info, progress streams
    if ($job.ChildJobs.Count -gt 0) {
      foreach ($child in $job.ChildJobs) {
        $child.Verbose.ReadAll() | ForEach-Object {
          # Filter out noisy PowerShell/CIM internal messages
          if ($_ -match '^(Importing|Exporting) (alias|function|cmdlet)' -or
            $_ -match '^Perform operation' -or
            $_ -match "^Operation '" -or
            $_ -match '^Loading module' -or
            $_ -match '^Loaded module') {
            return
          }

          $msg = "[Task $($job.Id)] $_"
          Write-ApiLog $msg
          $taskEntry.messages.Add($msg)

          # Always update currentStep with latest verbose line for live status
          $taskEntry.progress.currentStep = "$_"

          # Parse [X/Y] progress counters from deploy messages
          if ($_ -match '\[(\d+)/(\d+)\]') {
            $taskEntry.progress.completed = [int]$Matches[1]
            $taskEntry.progress.total = [int]$Matches[2]
            if ($taskEntry.progress.total -gt 0) {
              $taskEntry.progress.percentage = [math]::Round(($taskEntry.progress.completed / $taskEntry.progress.total) * 100)
            }
          }

          # Parse result markers: EXITCODE:N for exit codes
          if ($_ -match 'EXITCODE:(\d+)\s+for\s+(\S+)') {
            $exitCode = [int]$Matches[1]
            $pkgId = $Matches[2]
            $status = if ($exitCode -eq 0) { 'Success' } elseif ($exitCode -eq 3010) { 'Reboot Required' } else { "Error ($exitCode)" }
            $taskEntry.progress.results += @{ id = $pkgId; exitCode = $exitCode; status = $status }
          }
        }
        $child.Warning.ReadAll() | ForEach-Object {
          $msg = "[Task $($job.Id)] [!] WARNING: $_"
          Write-ApiLog $msg
          $taskEntry.messages.Add($msg)
          $taskEntry.progress.currentStep = "[!] $_"
        }
        $child.Error.ReadAll() | ForEach-Object {
          $msg = "[Task $($job.Id)] [X] ERROR: $_"
          Write-ApiLog $msg
          $taskEntry.messages.Add($msg)
          $taskEntry.progress.currentStep = "[X] $_"
        }
        $child.Information.ReadAll() | ForEach-Object {
          $infoStr = "$_"
          if ($infoStr -match '^Importing ' -or $infoStr -match '^Perform operation' -or $infoStr -match "^Operation '") { return }
          $msg = "[Task $($job.Id)] [i] $infoStr"
          Write-ApiLog $msg
          $taskEntry.messages.Add($msg)
        }
        $child.Progress.ReadAll() | ForEach-Object {
          # Skip noisy module loading progress
          if ($_.Activity -match 'Preparing modules' -or $_.Activity -match 'Loading module') { return }
          if ($_.PercentComplete -ge 0) {
            $msg = "[Task $($job.Id)] [~] $($_.Activity): $($_.StatusDescription) [$($_.PercentComplete)%]"
            if ($taskEntry.progress.total -eq 0) {
              $taskEntry.progress.percentage = $_.PercentComplete
            }
          }
          else {
            $msg = "[Task $($job.Id)] [~] $($_.Activity): $($_.StatusDescription)"
          }
          $taskEntry.progress.currentStep = "$($_.Activity): $($_.StatusDescription)"
          Write-ApiLog $msg
          $taskEntry.messages.Add($msg)
        }
      }
    }

    # If job finished, update state
    if ($job.State -ne 'Running') {
      $successCount = ($taskEntry.progress.results | Where-Object { $_.exitCode -eq 0 }).Count
      $totalResults = $taskEntry.progress.results.Count
      $hasErrors = ($taskEntry.messages | Where-Object { $_ -match '\[X\] ERROR' -or $_ -match 'failed' }).Count -gt 0
      $allFailed = $totalResults -gt 0 -and $successCount -eq 0
      
      if ($job.State -eq 'Completed' -and (-not $hasErrors) -and (-not $allFailed)) {
        $taskEntry.state = 'Completed'
      } elseif ($job.State -eq 'Completed' -and $hasErrors -or $allFailed) {
        $taskEntry.state = 'Failed'
      } else {
        $taskEntry.state = 'Failed'
      }
      
      $taskEntry.progress.percentage = 100
      if ($totalResults -gt 0) {
        $taskEntry.progress.currentStep = "Finished: $successCount/$totalResults packages succeeded"
      }
      elseif ($hasErrors) {
        $taskEntry.progress.currentStep = "Failed"
      }
      else {
        $taskEntry.progress.currentStep = "Finished ($($job.State))"
      }
      $finishMsg = "[Task $($job.Id)] [OK] Task finished with state: $($taskEntry.state). $($taskEntry.messages.Count) messages captured."
      Write-ApiLog $finishMsg
      $taskEntry.messages.Add($finishMsg)
      Remove-Job -Job $job -Force
    }
  }

  $script:activeJobs = @($script:activeJobs | Where-Object { $_.State -eq 'Running' })
}

function ConvertFrom-JsonString {
  param([string]$Json)
  try {
    if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
    return $Json | ConvertFrom-Json
  }
  catch {
    return @{}
  }
}

function Send-Response {
  param(
    $Response,
    [int]$StatusCode = 200,
    [string]$ContentType = 'application/json',
    [string]$Body = ''
  )
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.AddHeader("Access-Control-Allow-Origin", "*")

  if ($Body) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
  }
  $Response.OutputStream.Close()
}

$port = 8080
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-ApiLog "Backend server listening on http://localhost:$port"
Start-Process "http://localhost:$port"

$publicDir = Join-Path $Global:ScriptDir 'public'
if (-not (Test-Path $publicDir)) {
  New-Item -ItemType Directory -Path $publicDir | Out-Null
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
        
    $method = $request.HttpMethod
    $urlPath = $request.Url.LocalPath.TrimEnd('/')
    if ($urlPath -eq '') { $urlPath = '/' }

    try {
      if ($urlPath -eq '/favicon.ico') {
        Send-Response -Response $response -StatusCode 204
        continue
      }
      if ($method -eq 'GET' -and ($urlPath -eq '/' -or $urlPath.StartsWith('/public') -or $urlPath -eq '/style.css' -or $urlPath -eq '/app.js')) {
        $filePath = if ($urlPath -eq '/') { 
          Join-Path $publicDir 'index.html' 
        }
        else { 
          Join-Path $publicDir ($urlPath -replace '/public/', '') 
        }

        if (Test-Path $filePath -PathType Leaf) {
          $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
          $contentType = switch ($ext) {
            '.html' { 'text/html' }
            '.css' { 'text/css' }
            '.js' { 'application/javascript' }
            '.png' { 'image/png' }
            default { 'application/octet-stream' }
          }
          # Read bytes for exact binary serving (prevent encoding issues)
          $bytes = [System.IO.File]::ReadAllBytes($filePath)
          $response.StatusCode = 200
          $response.ContentType = $contentType
          $response.ContentLength64 = $bytes.Length
          $response.OutputStream.Write($bytes, 0, $bytes.Length)
          $response.OutputStream.Close()
        }
        else {
          Send-Response -Response $response -StatusCode 404 -ContentType 'text/plain' -Body "File not found: $filePath"
        }
        continue
      }

      if ($urlPath.StartsWith('/api/')) {
        $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
        $reqBodyStr = $reader.ReadToEnd()
        $reqBody = ConvertFrom-JsonString -Json $reqBodyStr

        $resData = @{ success = $true; message = 'OK' }

        switch -Regex ($urlPath) {
          '^/api/path$' {
            if ($method -eq 'GET') {
              $resData.path = $script:repoPath
            }
            elseif ($method -eq 'POST') {
              if ($reqBody.path -and (Test-Path $reqBody.path)) {
                $script:repoPath = $reqBody.path
                $resData.path = $script:repoPath
                Save-Config
              }
              else {
                $resData.success = $false
                $resData.message = 'Invalid Path'
              }
            }
          }
          '^/api/inventory$' {
            if ($method -eq 'GET') {
              if (Test-Path $inventoryFile) {
                try {
                  $invObj = Get-Content $inventoryFile -Raw | ConvertFrom-Json
                  if ($null -ne $invObj) {
                    $resData.inventory = @($invObj)
                  }
                  else {
                    $resData.inventory = @()
                  }
                }
                catch {
                  $resData.inventory = @()
                }
              }
              else {
                $resData.inventory = @()
              }
            }
            elseif ($method -eq 'POST') {
              try {
                Set-Content -Path $inventoryFile -Value $reqBodyStr -Encoding UTF8
                $resData.message = "Inventory saved"
              }
              catch {
                $resData.success = $false
                $resData.message = $_.Exception.Message
              }
            }
          }
          '^/api/logs$' {
            if ($method -eq 'GET') {
              Update-ActiveJobs
              $resData.logs = $script:apiLogs.ToArray()
            }
          }
          '^/api/tasks$' {
            if ($method -eq 'GET') {
              Update-ActiveJobs
              $taskList = @()
              foreach ($key in $script:taskRegistry.Keys) {
                $t = $script:taskRegistry[$key]
                $recentMsgs = @()
                if ($t.messages -and $t.messages.Count -gt 0) {
                  $start = [Math]::Max(0, $t.messages.Count - 20)
                  $recentMsgs = @($t.messages.GetRange($start, $t.messages.Count - $start))
                }
                $taskList += @{
                  id        = $t.id
                  name      = $t.name
                  state     = $t.state
                  startTime = if ($t.startTime) { $t.startTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
                  messages  = $recentMsgs
                  progress  = if ($t.progress) { $t.progress } else { @{ total = 0; completed = 0; percentage = 0; currentStep = ''; results = @() } }
                }
              }
              $resData.tasks = $taskList
            }
          }
          '^/api/info$' {
            Push-Location $script:repoPath
            try {
              $info = Get-HPRepositoryInfo *>&1 | Out-String
              $resData.info = $info
                            
              $missing = Get-HPRepositoryConfiguration -Setting OnRemoteFileNotFound
              $cache = Get-HPRepositoryConfiguration -Setting OfflineCacheMode
              $report = Get-HPRepositoryConfiguration -Setting RepositoryReport

              $resData.settings = @{
                OnRemoteFileNotFound = [string]$missing
                OfflineCacheMode     = [string]$cache
                RepositoryReport     = [string]$report
              }

              $resData.filters = @()
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
            finally {
              Pop-Location
            }
          }
          '^/api/settings$' {
            Push-Location $script:repoPath
            try {
              if ($reqBody.missing) {
                Set-HPRepositoryConfiguration -Setting OnRemoteFileNotFound -Value $reqBody.missing -Verbose *>&1 | ForEach-Object { Write-ApiLog "$_" }
              }
              if ($reqBody.cache) {
                Set-HPRepositoryConfiguration -Setting OfflineCacheMode -CacheValue $reqBody.cache -Verbose *>&1 | ForEach-Object { Write-ApiLog "$_" }
              }
              if ($reqBody.report) {
                Set-HPRepositoryConfiguration -Setting RepositoryReport -Format $reqBody.report -Verbose *>&1 | ForEach-Object { Write-ApiLog "$_" }
              }
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
            finally {
              Pop-Location
            }
          }
          '^/api/tasks/abort$' {
            if ($method -eq 'POST') {
              $taskId = $reqBody.taskId
              if (-not $taskId) { throw "taskId is required" }
              $taskKey = "task_$taskId"
              $matchedJob = $script:activeJobs | Where-Object { $_.Id -eq $taskId }
              if ($matchedJob) {
                Stop-Job -Job $matchedJob -ErrorAction SilentlyContinue
                Remove-Job -Job $matchedJob -Force -ErrorAction SilentlyContinue
                $script:activeJobs = @($script:activeJobs | Where-Object { $_.Id -ne $taskId })
                Write-ApiLog "[Task $taskId] Aborted by user."
              }
              if ($script:taskRegistry.ContainsKey($taskKey)) {
                $script:taskRegistry[$taskKey].state = 'Aborted'
                if ($script:taskRegistry[$taskKey].progress) {
                  $script:taskRegistry[$taskKey].progress.percentage = 100
                  $script:taskRegistry[$taskKey].progress.currentStep = 'Aborted by user'
                }
                else {
                  $script:taskRegistry[$taskKey].progress = @{ total = 0; completed = 0; percentage = 100; currentStep = 'Aborted by user'; results = @() }
                }
                if ($script:taskRegistry[$taskKey].messages) {
                  $script:taskRegistry[$taskKey].messages.Add("[Task $taskId] Aborted by user.")
                }
              }
              $resData.message = "Task $taskId aborted"
            }
          }
          '^/api/init$' {
            if (-not (Test-Path $script:repoPath)) {
              New-Item -ItemType Directory -Path $script:repoPath | Out-Null
            }
            Write-ApiLog "Starting Initialize-HPRepository background task..."
            $modulePath = $env:PSModulePath
            $job = Start-Job -ScriptBlock {
              param($repoPath, $modPath)
              $VerbosePreference = 'Continue'
              $env:PSModulePath = $modPath
              Import-Module HP.Repo -Force -ErrorAction Stop
              Write-Verbose "Module loaded. Initializing repository at $repoPath..."
              Push-Location $repoPath
              Initialize-HPRepository -Verbose
              Write-Verbose "Repository initialization complete."
            } -ArgumentList $script:repoPath, $modulePath
            $script:activeJobs += $job
            $script:taskRegistry["task_$($job.Id)"] = @{
              id = $job.Id; name = 'Initialize Repository'; state = 'Running'
              startTime = Get-Date; messages = New-Object System.Collections.Generic.List[string]
              progress = @{ total = 0; completed = 0; percentage = 0; currentStep = 'Initializing...'; results = @() }
            }
            $resData.message = "Task $($job.Id) created"
          }
          '^/api/sync$' {
            # Gather unique platform IDs from fleet if provided
            $platforms = @()
            if ($reqBody.platforms) {
              $platforms = @($reqBody.platforms | Where-Object { $_ -and $_ -ne '' -and $_ -ne 'Unknown' } | Select-Object -Unique)
            }
            Write-ApiLog "Starting Invoke-HPRepositorySync background task (platforms: $($platforms -join ', '))..."
            $modulePath = $env:PSModulePath
            $job = Start-Job -ScriptBlock {
              param($repoPath, $refUrl, $platforms, $modPath)
              $VerbosePreference = 'Continue'
              $env:PSModulePath = $modPath
              Import-Module HP.Repo -Force -ErrorAction Stop
              Write-Verbose "Module loaded. Syncing repository..."
              Push-Location $repoPath
              
              # Add repository filters for each fleet platform
              if ($platforms.Count -gt 0) {
                foreach ($platId in $platforms) {
                  try {
                    Write-Verbose "Adding repository filter for platform $platId..."
                    Add-HPRepositoryFilter -Platform $platId -ErrorAction SilentlyContinue
                  }
                  catch {
                    Write-Warning "Could not add filter for platform $platId : $_"
                  }
                }
              }
              
              if ($refUrl) {
                Invoke-HPRepositorySync -ReferenceUrl $refUrl -Verbose
              }
              else {
                Invoke-HPRepositorySync -Verbose
              }
              Write-Verbose "Repository sync complete."
            } -ArgumentList $script:repoPath, $reqBody.refUrl, $platforms, $modulePath
            $script:activeJobs += $job
            $script:taskRegistry["task_$($job.Id)"] = @{
              id = $job.Id; name = 'Sync Repository'; state = 'Running'
              startTime = Get-Date; messages = New-Object System.Collections.Generic.List[string]
              progress = @{ total = 0; completed = 0; percentage = 0; currentStep = 'Starting sync...'; results = @() }
            }
            $resData.message = "Task $($job.Id) created"
          }
          '^/api/cleanup$' {
            Write-ApiLog "Starting Invoke-HPRepositoryCleanup background task..."
            $modulePath = $env:PSModulePath
            $job = Start-Job -ScriptBlock {
              param($repoPath, $modPath)
              $VerbosePreference = 'Continue'
              $env:PSModulePath = $modPath
              Import-Module HP.Repo -Force -ErrorAction Stop
              Write-Verbose "Module loaded. Cleaning up repository..."
              Push-Location $repoPath
              Invoke-HPRepositoryCleanup -Verbose
              Write-Verbose "Repository cleanup complete."
            } -ArgumentList $script:repoPath, $modulePath
            $script:activeJobs += $job
            $script:taskRegistry["task_$($job.Id)"] = @{
              id = $job.Id; name = 'Cleanup Repository'; state = 'Running'
              startTime = Get-Date; messages = New-Object System.Collections.Generic.List[string]
              progress = @{ total = 0; completed = 0; percentage = 0; currentStep = 'Cleaning up...'; results = @() }
            }
            $resData.message = "Task $($job.Id) created"
          }
          '^/api/fleet/scan$' {
            try {
              $hostname = $reqBody.hostname
              if (-not $hostname) { throw "Hostname is required" }

              Write-ApiLog "Scanning endpoint $hostname..."
              
              if (-not (Test-Connection -ComputerName $hostname -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                $resData.status = 'Offline'
                $resData.message = 'Unreachable via Ping'
              }
              else {
                try {
                  $session = New-CimSession -ComputerName $hostname -ErrorAction Stop
                }
                catch {
                  $opt = New-CimSessionOption -Protocol Dcom
                  $session = New-CimSession -ComputerName $hostname -SessionOption $opt -ErrorAction Stop
                }

                $modelInfo = Get-CimInstance -ClassName Win32_ComputerSystem -CimSession $session
                $biosInfo = Get-CimInstance -ClassName Win32_BIOS -CimSession $session
                $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -CimSession $session
                $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard -CimSession $session

                Remove-CimSession $session

                $manufacturer = if ($modelInfo.Manufacturer) { $modelInfo.Manufacturer } else { 'Unknown' }
                
                $resData.system = @{
                  model    = $(if ($modelInfo.Model) { $modelInfo.Model } else { 'Unknown' })
                  serial   = $(if ($biosInfo.SerialNumber) { $biosInfo.SerialNumber } else { 'Unknown' })
                  platform = $(if ($baseBoard.Product) { $baseBoard.Product } else { 'Unknown' })
                  os       = $(if ($osInfo.Caption) { $osInfo.Caption -replace 'Microsoft Windows ', '' } else { 'Unknown' })
                }
                
                if ($manufacturer -notmatch 'HP|Hewlett-Packard') {
                  $resData.status = 'Not Applicable'
                  $resData.message = 'Not an HP Computer'
                  $resData.applicable = @()
                }
                else {
                  $resData.status = 'Online'
                    
                  # Fetch applicable packages directly using HPCMSL
                  $applicable = @()
                  Import-Module HP.Repo -ErrorAction SilentlyContinue
                  if ($resData.system.platform -ne 'Unknown') {
                    try {
                      Write-ApiLog "Fetching available updates from HP for platform $($resData.system.platform)..."
                      $softpaqs = Get-HPSoftpaqList -Platform $resData.system.platform -Category "Firmware", "Driver" -ReleaseType "Critical", "Recommended" -ErrorAction SilentlyContinue
                      if ($softpaqs) {
                        foreach ($sp in $softpaqs) {
                          $pkgId = if ($sp.Id) { $sp.Id } elseif ($sp.Number) { $sp.Number } else { $null }
                          if ($pkgId) {
                            $applicable += @{
                              id       = $pkgId
                              type     = 'SoftPaq'
                              name     = $(if ($sp.Name) { $sp.Name } else { 'Unknown' })
                              category = $(if ($sp.Category) { $sp.Category } else { 'Unknown' })
                              version  = $(if ($sp.Version) { $sp.Version } else { 'N/A' })
                              date     = $(if ($sp.DateReleased) { $sp.DateReleased } elseif ($sp.ReleaseDate) { $sp.ReleaseDate } else { 'N/A' })
                            }
                          }
                        }
                      }
                    }
                    catch {
                      Write-ApiLog "Warning: Failed to fetch SoftPaq list for platform $($resData.system.platform): $_"
                    }
                    
                    try {
                      $biosUpdates = Get-HPBIOSUpdates -Platform $resData.system.platform -ErrorAction SilentlyContinue
                      if ($biosUpdates) {
                        $bArray = if ($biosUpdates -is [array]) { $biosUpdates } else { @($biosUpdates) }
                        foreach ($b in $bArray) {
                          if ($b.Version) {
                            $applicable += @{
                              id       = $b.Version
                              type     = 'BIOS'
                              name     = "BIOS Update $(if ($b.Name) { $b.Name } else { $b.Version })"
                              category = 'BIOS'
                              version  = $b.Version
                              date     = $(if ($b.Date) { $b.Date } elseif ($b.DateReleased) { $b.DateReleased } else { 'N/A' })
                              platform = $resData.system.platform
                            }
                          }
                        }
                      }
                    }
                    catch {
                      Write-ApiLog "Warning: Failed to fetch BIOS updates for platform $($resData.system.platform): $_"
                    }
                  }
                  $resData.applicable = $applicable
                }
              }
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
          }
          '^/api/fleet/discover$' {
            try {
              Write-ApiLog "Starting network discovery scan..."
              $devices = @()
              
              # Get local subnet from first active adapter
              $adapter = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | Select-Object -First 1
              $localIP = $adapter.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
              $subnet = ($localIP -split '\.')[0..2] -join '.'
              
              Write-ApiLog "Scanning subnet $subnet.0/24..."
              
              # Quick ping sweep using Test-Connection in parallel (batch of IPs)
              $ips = 1..254 | ForEach-Object { "$subnet.$_" }
              $alive = @()
              foreach ($ip in $ips) {
                if (Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeToLive 32 -ErrorAction SilentlyContinue) {
                  $alive += $ip
                }
              }
              
              Write-ApiLog "Found $($alive.Count) live hosts, probing for HP devices..."
              
              foreach ($ip in $alive) {
                try {
                  $opt = New-CimSessionOption -Protocol Dcom
                  $sess = New-CimSession -ComputerName $ip -SessionOption $opt -ErrorAction Stop
                  $cs = Get-CimInstance -CimSession $sess -ClassName Win32_ComputerSystem -ErrorAction Stop
                  $bios = Get-CimInstance -CimSession $sess -ClassName Win32_BIOS -ErrorAction Stop
                  Remove-CimSession $sess
                  
                  if ($cs.Manufacturer -match 'HP|Hewlett') {
                    $devices += @{
                      hostname = $ip
                      status   = 'Online'
                      system   = @{
                        model    = $cs.Model
                        serial   = $bios.SerialNumber
                        platform = 'Pending'
                        os       = ''
                      }
                    }
                    Write-ApiLog "Discovered HP device: $ip ($($cs.Model))"
                  }
                }
                catch {
                  # Not accessible or not HP — skip
                }
              }
              
              $resData.devices = $devices
              $resData.message = "Discovery complete. Found $($devices.Count) HP devices."
              Write-ApiLog "Network discovery complete. Found $($devices.Count) HP devices."
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
          }
          '^/api/deploy$' {
            try {
              $targetsStr = $reqBody.targets -replace "`n", ","
              $targets = $targetsStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
              $packages = if ($reqBody.packages) { $reqBody.packages } else { @() }
                            
              Write-ApiLog "Starting background deployment task for: $($targets -join ', ')"
                            
              if ($targets.Count -eq 0 -or $packages.Count -eq 0) {
                throw "Targets and packages must be provided."
              }
              
              $modulePath = $env:PSModulePath
              $pkgArray = @($packages)
              $job = Start-Job -ScriptBlock {
                param($targets, $packages, $repoPath, $modPath)
                $VerbosePreference = 'Continue'
                $env:PSModulePath = $modPath
                Import-Module HP.Repo -Force -ErrorAction Stop
                $packages = @($packages)
                $totalPkgs = $packages.Count
                
                foreach ($pctarget in $targets) {
                  if (-not (Test-Connection -ComputerName $pctarget -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                    Write-Error "Cannot reach $pctarget - skipping"
                    continue
                  }
                  Write-Verbose "Connected to $pctarget - $totalPkgs package(s)"
                  
                  $pkgNum = 0
                  $successCount = 0
                  $failCount = 0
                                  
                  foreach ($pkgObj in $packages) {
                    $pkgNum++
                    $pkg = $pkgObj.id
                    $pkgName = $pkgObj.name
                    
                    if ($pkgObj.type -eq 'BIOS') {
                      Write-Verbose "[$pkgNum/$totalPkgs] Flashing BIOS on $pctarget..."
                      try {
                        Get-HPBIOSUpdates -Platform $pkgObj.platform -Flash -Yes -BitLocker Suspend -Target $pctarget -ErrorAction Stop
                        Write-Verbose "[$pkgNum/$totalPkgs] BIOS flash complete. EXITCODE:0 for $pkg"
                        $successCount++
                      }
                      catch {
                        Write-Error "[$pkgNum/$totalPkgs] BIOS flash failed: $_. EXITCODE:1 for $pkg"
                        $failCount++
                      }
                    }
                    else {
                      # Find or download SoftPaq
                      $localPkgPath = $null
                      foreach ($p in @((Join-Path $repoPath "$pkg.exe"), (Join-Path $repoPath $pkg))) {
                        if (Test-Path $p) { $localPkgPath = $p; break }
                      }
                      
                      if (-not $localPkgPath) {
                        $savePath = Join-Path $repoPath "$pkg.exe"
                        try {
                          Get-Softpaq -Number $pkg -SaveAs $savePath -Overwrite yes -ErrorAction Stop | Out-Null
                          $localPkgPath = $savePath
                        }
                        catch {
                          Write-Error "[$pkgNum/$totalPkgs] $pkg download failed: $_"
                          $failCount++
                          continue
                        }
                      }

                      try {
                        $fileName = Split-Path $localPkgPath -Leaf
                        $remoteSmbDest = "\\$pctarget\c$\SWSetup\$fileName"
                        
                        # Ensure remote directory exists
                        $remoteSmbDir = "\\$pctarget\c$\SWSetup"
                        if (-not (Test-Path $remoteSmbDir)) {
                          New-Item -ItemType Directory -Path $remoteSmbDir -Force | Out-Null
                        }
                        
                        # Copy to remote with retry
                        for ($retry = 0; $retry -lt 3; $retry++) {
                          try {
                            Copy-Item -Path $localPkgPath -Destination $remoteSmbDest -Force -ErrorAction Stop
                            break
                          }
                          catch {
                            if ($retry -ge 2) { throw $_ }
                            Start-Sleep -Seconds 3
                          }
                        }
                        
                        if (-not (Test-Path $remoteSmbDest)) {
                          Write-Error "[$pkgNum/$totalPkgs] $pkg - copy to $pctarget failed"
                          $failCount++
                          continue
                        }
                        Write-Verbose "[$pkgNum/$totalPkgs] $pkg ($pkgName) copied to $pctarget"
                        
                        # Create a small batch file on remote to capture exit code
                        $batSmb = "\\$pctarget\c$\SWSetup\run_${pkg}.bat"
                        $resultSmb = "\\$pctarget\c$\SWSetup\${pkg}_result.txt"
                        # Write batch file via SMB (plain ASCII text, no escaping issues)
                        "@`"C:\SWSetup\$fileName`" /s`r`necho EXITCODE=%ERRORLEVEL% > C:\SWSetup\${pkg}_result.txt" | Set-Content -Path $batSmb -Encoding ASCII -Force
                        
                        Write-Verbose "[$pkgNum/$totalPkgs] $pkg ($pkgName) installing on $pctarget..."
                        $session = $null
                        try { $session = New-CimSession -ComputerName $pctarget -ErrorAction Stop }
                        catch {
                          $opt = New-CimSessionOption -Protocol Dcom
                          $session = New-CimSession -ComputerName $pctarget -SessionOption $opt -ErrorAction Stop
                        }
                        
                        $commandLine = "cmd.exe /c C:\SWSetup\run_${pkg}.bat"
                        $invokeResult = Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine } -ErrorAction Stop
                        
                        if ($invokeResult.ReturnValue -eq 0) {
                          $pidVal = $invokeResult.ProcessId
                          
                          $maxWait = 1800
                          $elapsed = 0
                          while ($elapsed -lt $maxWait) {
                            Start-Sleep -Seconds 15
                            $elapsed += 15
                            $proc = Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "ProcessId = $pidVal" -ErrorAction SilentlyContinue
                            if (-not $proc) {
                              Start-Sleep -Seconds 3
                              break
                            }
                          }
                          
                          # Read result
                          $exitCode = -1
                          try {
                            if (Test-Path $resultSmb) {
                              $resultContent = (Get-Content $resultSmb -ErrorAction Stop | Select-Object -First 1).Trim()
                              if ($resultContent -match 'EXITCODE=(-?\d+)') {
                                $exitCode = [int]$Matches[1]
                              }
                              Remove-Item $resultSmb -Force -ErrorAction SilentlyContinue
                            }
                          }
                          catch { $exitCode = -1 }
                          
                          # Cleanup batch file
                          Remove-Item $batSmb -Force -ErrorAction SilentlyContinue
                          
                          $exitStatus = switch ($exitCode) {
                            0 { 'Success' }
                            1641 { 'Reboot Initiated' }
                            3010 { 'Reboot Required' }
                            1602 { 'User Cancelled' }
                            1603 { 'Fatal Error' }
                            1618 { 'Another Install In Progress' }
                            -2 { 'Extract Failed' }
                            -3 { 'No Installer Found' }
                            -4 { 'Script Error' }
                            default { "Error ($exitCode)" }
                          }
                          
                          if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
                            Write-Verbose "[$pkgNum/$totalPkgs] $pkg ($pkgName) - $exitStatus. EXITCODE:$exitCode for $pkg"
                            $successCount++
                          }
                          else {
                            Write-Error "[$pkgNum/$totalPkgs] $pkg ($pkgName) - $exitStatus. EXITCODE:$exitCode for $pkg"
                            $failCount++
                          }
                          
                          if ($elapsed -ge $maxWait) {
                            Write-Warning "[$pkgNum/$totalPkgs] $pkg timed out after ${maxWait}s"
                          }
                        }
                        else {
                          Write-Error "[$pkgNum/$totalPkgs] Failed to start on $pctarget. WMI code: $($invokeResult.ReturnValue)"
                          $failCount++
                        }
                        
                        if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
                      }
                      catch {
                        Write-Error "[$pkgNum/$totalPkgs] $pkg ($pkgName) failed: $_"
                        $failCount++
                      }
                    }
                  }
                  Write-Verbose "Deployment to $pctarget complete: $successCount succeeded, $failCount failed"
                }
              } -ArgumentList $targets, $pkgArray, $script:repoPath, $modulePath

              $script:activeJobs += $job
              $script:taskRegistry["task_$($job.Id)"] = @{
                id = $job.Id; name = "Deploy to $($targets -join ', ')"; state = 'Running'
                startTime = Get-Date; messages = New-Object System.Collections.Generic.List[string]
                progress = @{ total = $pkgArray.Count; completed = 0; percentage = 0; currentStep = 'Starting deployment...'; results = @() }
              }
              $resData.taskId = $job.Id
              $resData.message = "Task $($job.Id) created for deployment"
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
          }
          '^/api/open-folder$' {
            try {
              if (Test-Path $script:repoPath) {
                Invoke-Item $script:repoPath
                $resData.message = "Folder opened"
              }
              else {
                throw "Repository path does not exist"
              }
            }
            catch {
              $resData.success = $false
              $resData.message = $_.Exception.Message
            }
          }
          '^/api/exit$' {
            Write-ApiLog "Received shutdown request from Web UI."
            $resData.message = "Server shutting down..."
            Send-Response -Response $response -Body ($resData | ConvertTo-Json -Depth 5 -Compress)
            
            # Allow a brief moment for the response to send before killing the process
            Start-Sleep -Milliseconds 500
            if ($listener) {
              $listener.Stop()
              $listener.Close()
            }
            Stop-Process -Id $PID -Force
          }
          default {
            $resData.success = $false
            $resData.message = "Unknown API Endpoint"
            Send-Response -Response $response -StatusCode 404 -Body ($resData | ConvertTo-Json -Depth 5)
            continue
          }
        }
                
        $jsonResponse = $resData | ConvertTo-Json -Depth 5 -Compress
        Send-Response -Response $response -Body $jsonResponse
      }
      else {
        Send-Response -Response $response -StatusCode 404 -ContentType 'text/plain' -Body 'Not Found'
      }
    }
    catch {
      Write-ApiLog "Error handling request: $($_.Exception.Message)"
      $errRes = @{ success = $false; message = $_.Exception.Message } | ConvertTo-Json -Depth 2 -Compress
      Send-Response -Response $response -StatusCode 500 -Body $errRes
    }
  }
}
finally {
  if ($listener) {
    $listener.Stop()
    $listener.Close()
  }
}
