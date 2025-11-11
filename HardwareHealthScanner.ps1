# HardwareHealthScanner.ps1
# RUN AS ADMINISTRATOR for full functionality

param(
    [string]$OutputPath = ".\HardwareHealthReport.html",
    [switch]$QuickScan
)

# Initialize global variables
$Global:ReportData = @{}
$Global:HealthStatus = @{}
$Global:Warnings = @()
$Global:CriticalIssues = @()

function Get-HealthStatus {
    param(
        [string]$Component,
        [hashtable]$Data
    )
    
    try {
        $status = @{
            Status = "Healthy"
            Message = "No issues detected"
            Priority = "Low"
        }
        
        switch ($Component) {
            "CPU" {
                if ($Data.Temperature -ne "N/A" -and $Data.Temperature -gt 85) {
                    $status.Status = "Critical"
                    $status.Message = "CPU temperature too high! Consider cleaning cooling system."
                    $status.Priority = "High"
                }
                elseif ($Data.Temperature -ne "N/A" -and $Data.Temperature -gt 75) {
                    $status.Status = "Warning"
                    $status.Message = "CPU temperature elevated. Monitor closely."
                    $status.Priority = "Medium"
                }
                
                $loadPercentage = [int]($Data.LoadPercentage -replace '[^0-9]', '')
                if ($loadPercentage -gt 90 -and $Data.Temperature -ne "N/A" -and $Data.Temperature -gt 70) {
                    $status.Status = "Warning"
                    $status.Message = "High CPU usage with elevated temperature."
                    $status.Priority = "Medium"
                }
            }
            
            "Memory" {
                if ($Data.TotalPhysicalMemory -gt 0 -and $Data.AvailablePhysicalMemory -gt 0) {
                    $usedPercentage = ($Data.TotalPhysicalMemory - $Data.AvailablePhysicalMemory) / $Data.TotalPhysicalMemory * 100
                    if ($usedPercentage -gt 90) {
                        $status.Status = "Warning"
                        $status.Message = "Memory usage very high. Consider adding more RAM."
                        $status.Priority = "Medium"
                    }
                }
            }
            
            "Disk" {
                if ($Data.FreeSpaceGB -lt 10) {
                    $status.Status = "Critical"
                    $status.Message = "Disk space critically low! Free up space immediately."
                    $status.Priority = "High"
                }
                elseif ($Data.FreeSpaceGB -lt 20) {
                    $status.Status = "Warning"
                    $status.Message = "Disk space running low."
                    $status.Priority = "Medium"
                }
            }
            
            "Battery" {
                if ($Data.BatteryStatus -like "*Fail*" -or $Data.BatteryStatus -like "*Critical*") {
                    $status.Status = "Critical"
                    $status.Message = "Battery needs replacement!"
                    $status.Priority = "High"
                }
                elseif ($Data.DesignCapacity -gt 0 -and $Data.FullChargeCapacity -gt 0 -and $Data.FullChargeCapacity -lt ($Data.DesignCapacity * 0.5)) {
                    $status.Status = "Warning"
                    $status.Message = "Battery capacity significantly reduced. Consider replacement."
                    $status.Priority = "Medium"
                }
            }
        }
        
        return $status
    }
    catch {
        return @{
            Status = "Unknown"
            Message = "Health check failed: $($_.Exception.Message)"
            Priority = "Low"
        }
    }
}

function Get-CPUInfo {
    Write-Host "Scanning CPU..." -ForegroundColor Yellow
    
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
        $cpuTemp = $null
        
        try {
            $cpuTemp = Get-CimInstance -Namespace root\WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
        }
        catch {
            # Temperature reading not available on all systems
        }
        
        $cpuData = @{
            Name = $cpu.Name
            Cores = $cpu.NumberOfCores
            LogicalProcessors = $cpu.NumberOfLogicalProcessors
            MaxClockSpeed = "$([math]::Round($cpu.MaxClockSpeed / 1000, 2)) GHz"
            CurrentClockSpeed = "$([math]::Round($cpu.CurrentClockSpeed / 1000, 2)) GHz"
            LoadPercentage = "$($cpu.LoadPercentage)%"
            Temperature = if ($cpuTemp -and $cpuTemp.CurrentTemperature) { [math]::Round(($cpuTemp.CurrentTemperature - 2732) / 10, 1) } else { "N/A" }
            L2CacheSize = if ($cpu.L2CacheSize) { "$([math]::Round($cpu.L2CacheSize / 1024, 1)) MB" } else { "N/A" }
            L3CacheSize = if ($cpu.L3CacheSize) { "$([math]::Round($cpu.L3CacheSize / 1024, 1)) MB" } else { "N/A" }
        }
        
        $health = Get-HealthStatus -Component "CPU" -Data $cpuData
        $Global:HealthStatus.CPU = $health
        
        if ($health.Status -eq "Critical") { 
            $Global:CriticalIssues += "CPU: $($health.Message)" 
        }
        elseif ($health.Status -eq "Warning") { 
            $Global:Warnings += "CPU: $($health.Message)" 
        }
        
        return $cpuData
    }
    catch {
        Write-Warning "CPU scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-MemoryInfo {
    Write-Host "Scanning Memory..." -ForegroundColor Yellow
    
    try {
        $memory = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop
        $computerMemory = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        
        $totalMemory = ($memory | Measure-Object -Property Capacity -Sum).Sum
        $memorySlots = @()
        
        foreach ($mem in $memory) {
            $memoryType = switch ($mem.MemoryType) {
                20 { "DDR" }
                21 { "DDR2" }
                24 { "DDR3" }
                26 { "DDR4" }
                34 { "DDR5" }
                default { "Unknown" }
            }
            
            $memorySlots += @{
                Size = "$([math]::Round($mem.Capacity / 1GB, 1)) GB"
                Speed = if ($mem.Speed) { "$($mem.Speed) MHz" } else { "Unknown" }
                Type = $memoryType
                Manufacturer = if ($mem.Manufacturer) { $mem.Manufacturer.Trim() } else { "Unknown" }
            }
        }
        
        $availableMemoryBytes = $os.FreePhysicalMemory * 1KB
        $memoryUsage = if ($totalMemory -gt 0) { [math]::Round((($totalMemory - $availableMemoryBytes) / $totalMemory) * 100, 1) } else { 0 }
        
        $memoryData = @{
            TotalPhysicalMemory = $totalMemory
            TotalMemoryGB = [math]::Round($totalMemory / 1GB, 1)
            AvailablePhysicalMemory = $availableMemoryBytes
            AvailableMemoryGB = [math]::Round($availableMemoryBytes / 1GB, 1)
            MemoryUsage = $memoryUsage
            MemorySlotsUsed = $memory.Count
            TotalMemorySlots = if ($memory.Count -gt 0) { [math]::Ceiling($computerMemory.TotalPhysicalMemory / ($totalMemory / $memory.Count)) } else { 0 }
            MemoryModules = $memorySlots
        }
        
        $health = Get-HealthStatus -Component "Memory" -Data $memoryData
        $Global:HealthStatus.Memory = $health
        
        if ($health.Status -eq "Critical") { 
            $Global:CriticalIssues += "Memory: $($health.Message)" 
        }
        elseif ($health.Status -eq "Warning") { 
            $Global:Warnings += "Memory: $($health.Message)" 
        }
        
        return $memoryData
    }
    catch {
        Write-Warning "Memory scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-DiskInfo {
    Write-Host "Scanning Disks..." -ForegroundColor Yellow
    
    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        $diskData = @()
        
        foreach ($disk in $disks) {
            $sizeGB = if ($disk.Size) { [math]::Round($disk.Size / 1GB, 1) } else { 0 }
            $freeGB = if ($disk.FreeSpace) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { 0 }
            $usedGB = $sizeGB - $freeGB
            $usagePercentage = if ($sizeGB -gt 0) { [math]::Round(($usedGB / $sizeGB) * 100, 1) } else { 0 }
            
            $diskInfo = @{
                Drive = $disk.DeviceID
                SizeGB = $sizeGB
                FreeSpaceGB = $freeGB
                UsedSpaceGB = $usedGB
                UsagePercentage = $usagePercentage
                FileSystem = $disk.FileSystem
            }
            
            $health = Get-HealthStatus -Component "Disk" -Data $diskInfo
            $diskInfo.HealthStatus = $health.Status
            $diskInfo.HealthMessage = $health.Message
            
            if ($health.Status -eq "Critical") { 
                $Global:CriticalIssues += "Disk $($disk.DeviceID): $($health.Message)" 
            }
            elseif ($health.Status -eq "Warning") { 
                $Global:Warnings += "Disk $($disk.DeviceID): $($health.Message)" 
            }
            
            $diskData += $diskInfo
        }
        
        $Global:HealthStatus.Disk = @{Status = "Healthy"; Message = "All disks OK"}
        return $diskData
    }
    catch {
        Write-Warning "Disk scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-GPUInfo {
    Write-Host "Scanning Graphics..." -ForegroundColor Yellow
    
    try {
        $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | 
                Where-Object {$_.Name -notlike "*Remote*" -and $_.Name -notlike "*Microsoft*" -and $_.Name -notlike "*Base*"}
        $gpuData = @()
        
        foreach ($gpu in $gpus) {
            $adapterRAM = if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) { 
                "$([math]::Round($gpu.AdapterRAM / 1GB, 1)) GB" 
            } else { 
                "Unknown" 
            }
            
            $gpuInfo = @{
                Name = $gpu.Name
                DriverVersion = if ($gpu.DriverVersion) { $gpu.DriverVersion } else { "Unknown" }
                CurrentResolution = if ($gpu.CurrentHorizontalResolution -and $gpu.CurrentVerticalResolution) {
                    "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)"
                } else {
                    "Unknown"
                }
                AdapterRAM = $adapterRAM
            }
            $gpuData += $gpuInfo
        }
        
        return $gpuData
    }
    catch {
        Write-Warning "GPU scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-NetworkInfo {
    Write-Host "Scanning Network..." -ForegroundColor Yellow
    
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {$_.Status -eq "Up"}
        $networkData = @()
        
        foreach ($adapter in $adapters) {
            try {
                $adapterStats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
                
                $adapterInfo = @{
                    Name = $adapter.Name
                    InterfaceDescription = $adapter.InterfaceDescription
                    LinkSpeed = $adapter.LinkSpeed
                    MACAddress = $adapter.MacAddress
                    ReceivedBytes = if ($adapterStats.ReceivedBytes) { "$([math]::Round($adapterStats.ReceivedBytes / 1GB, 2)) GB" } else { "Unknown" }
                    SentBytes = if ($adapterStats.SentBytes) { "$([math]::Round($adapterStats.SentBytes / 1GB, 2)) GB" } else { "Unknown" }
                }
                
                $health = Get-HealthStatus -Component "Network" -Data $adapterInfo
                $adapterInfo.HealthStatus = $health.Status
                
                $networkData += $adapterInfo
            }
            catch {
                # Skip this adapter if it causes errors
                continue
            }
        }
        
        return $networkData
    }
    catch {
        Write-Warning "Network scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-BatteryInfo {
    Write-Host "Scanning Battery..." -ForegroundColor Yellow
    
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        
        if ($battery) {
            $batteryData = @{
                BatteryStatus = switch ($battery.BatteryStatus) {
                    1 { "Discharging" }
                    2 { "AC Power" }
                    3 { "Fully Charged" }
                    4 { "Low" }
                    5 { "Critical" }
                    6 { "Charging" }
                    default { "Unknown" }
                }
                DesignCapacity = if ($battery.DesignCapacity) { $battery.DesignCapacity } else { 0 }
                FullChargeCapacity = if ($battery.FullChargeCapacity) { $battery.FullChargeCapacity } else { 0 }
                EstimatedChargeRemaining = if ($battery.EstimatedChargeRemaining) { "$($battery.EstimatedChargeRemaining)%" } else { "Unknown" }
            }
            
            $health = Get-HealthStatus -Component "Battery" -Data $batteryData
            $Global:HealthStatus.Battery = $health
            
            if ($health.Status -eq "Critical") { 
                $Global:CriticalIssues += "Battery: $($health.Message)" 
            }
            elseif ($health.Status -eq "Warning") { 
                $Global:Warnings += "Battery: $($health.Message)" 
            }
            
            return $batteryData
        } else {
            return @{Status = "No battery found (Desktop computer)"}
        }
    }
    catch {
        Write-Warning "Battery scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Get-SystemInfo {
    Write-Host "Scanning System Information..." -ForegroundColor Yellow
    
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        
        return @{
            ComputerName = $env:COMPUTERNAME
            Manufacturer = if ($computer.Manufacturer) { $computer.Manufacturer } else { "Unknown" }
            Model = if ($computer.Model) { $computer.Model } else { "Unknown" }
            OS = if ($os.Caption) { $os.Caption } else { "Unknown" }
            OSVersion = if ($os.Version) { $os.Version } else { "Unknown" }
            LastBootTime = if ($os.LastBootUpTime) { $os.LastBootUpTime } else { "Unknown" }
            BIOSVersion = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion } else { "Unknown" }
        }
    }
    catch {
        Write-Warning "System info scan failed: $($_.Exception.Message)"
        return @{Error = $_.Exception.Message}
    }
}

function Generate-HTMLReport {
    param(
        [hashtable]$Data,
        [hashtable]$HealthStatus,
        [array]$Warnings,
        [array]$CriticalIssues
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Hardware Health Report - $($Data.System.ComputerName)</title>
    <meta charset="UTF-8">
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            margin: 0; 
            padding: 20px; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container { 
            max-width: 1200px; 
            margin: 0 auto; 
            background: white; 
            padding: 30px; 
            border-radius: 15px; 
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
        }
        .header { 
            text-align: center; 
            background: linear-gradient(135deg, #2c3e50 0%, #3498db 100%);
            color: white; 
            padding: 30px; 
            border-radius: 10px; 
            margin-bottom: 30px; 
        }
        .section { 
            margin-bottom: 25px; 
            padding: 20px; 
            border: 1px solid #e0e0e0; 
            border-radius: 8px; 
            background: #fafafa;
        }
        .critical { 
            background-color: #ffebee; 
            border-left: 5px solid #f44336; 
        }
        .warning { 
            background-color: #fff3e0; 
            border-left: 5px solid #ff9800; 
        }
        .healthy { 
            background-color: #e8f5e8; 
            border-left: 5px solid #4caf50; 
        }
        .component { 
            margin-bottom: 15px; 
            padding: 12px; 
            border-radius: 6px; 
            font-weight: bold;
        }
        table { 
            width: 100%; 
            border-collapse: collapse; 
            margin: 15px 0; 
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        th, td { 
            padding: 12px 15px; 
            text-align: left; 
            border-bottom: 1px solid #e0e0e0; 
        }
        th { 
            background-color: #3498db; 
            color: white; 
            font-weight: 600;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .status-critical { color: #e74c3c; font-weight: bold; }
        .status-warning { color: #f39c12; font-weight: bold; }
        .status-healthy { color: #27ae60; font-weight: bold; }
        .status-unknown { color: #7f8c8d; font-weight: bold; }
        .summary { 
            font-size: 1.1em; 
            margin: 20px 0; 
            line-height: 1.6;
        }
        h1 { margin: 0 0 10px 0; font-size: 2.5em; }
        h2 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 8px; }
        h3 { color: #34495e; }
        .icon { margin-right: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🖥️ Hardware Health Report</h1>
            <p><strong>Generated:</strong> $timestamp</p>
            <p><strong>Computer:</strong> $($Data.System.ComputerName)</p>
        </div>

        <div class="summary">
"@

    # Critical Issues
    if ($CriticalIssues.Count -gt 0) {
        $html += @"
            <div class='critical'>
                <h3>🚨 CRITICAL ISSUES ($($CriticalIssues.Count))</h3>
                <ul>
"@
        foreach ($issue in $CriticalIssues) {
            $html += "<li>$issue</li>"
        }
        $html += @"
                </ul>
            </div>
"@
    }

    # Warnings
    if ($Warnings.Count -gt 0) {
        $html += @"
            <div class='warning'>
                <h3>⚠️ WARNINGS ($($Warnings.Count))</h3>
                <ul>
"@
        foreach ($warning in $Warnings) {
            $html += "<li>$warning</li>"
        }
        $html += @"
                </ul>
            </div>
"@
    }

    # All Good
    if ($CriticalIssues.Count -eq 0 -and $Warnings.Count -eq 0) {
        $html += @"
            <div class='healthy'>
                <h3>✅ SYSTEM HEALTHY</h3>
                <p>No critical issues or warnings detected. Your system is in good condition.</p>
            </div>
"@
    }

    $html += @"
        </div>

        <!-- System Information -->
        <div class="section">
            <h2>📊 System Overview</h2>
            <table>
                <tr><th>Property</th><th>Value</th></tr>
                <tr><td>Computer Name</td><td>$($Data.System.ComputerName)</td></tr>
                <tr><td>Manufacturer</td><td>$($Data.System.Manufacturer)</td></tr>
                <tr><td>Model</td><td>$($Data.System.Model)</td></tr>
                <tr><td>Operating System</td><td>$($Data.System.OS)</td></tr>
                <tr><td>Last Boot Time</td><td>$($Data.System.LastBootTime)</td></tr>
            </table>
        </div>

        <!-- CPU Information -->
        <div class="section">
            <h2>⚡ CPU Information</h2>
            <div class="component $($HealthStatus.CPU.Status.ToLower())">
                <span class="status-$($HealthStatus.CPU.Status.ToLower())">$($HealthStatus.CPU.Status): $($HealthStatus.CPU.Message)</span>
            </div>
            <table>
                <tr><th>Property</th><th>Value</th></tr>
"@

    foreach ($key in $Data.CPU.Keys) {
        if ($key -ne "Error") {
            $html += "<tr><td>$key</td><td>$($Data.CPU[$key])</td></tr>"
        }
    }

    $html += @"
            </table>
        </div>

        <!-- Memory Information -->
        <div class="section">
            <h2>💾 Memory Information</h2>
            <div class="component $($HealthStatus.Memory.Status.ToLower())">
                <span class="status-$($HealthStatus.Memory.Status.ToLower())">$($HealthStatus.Memory.Status): $($HealthStatus.Memory.Message)</span>
            </div>
            <table>
                <tr><th>Property</th><th>Value</th></tr>
                <tr><td>Total Memory</td><td>$($Data.Memory.TotalMemoryGB) GB</td></tr>
                <tr><td>Available Memory</td><td>$($Data.Memory.AvailableMemoryGB) GB</td></tr>
                <tr><td>Memory Usage</td><td>$($Data.Memory.MemoryUsage)%</td></tr>
                <tr><td>Memory Slots Used</td><td>$($Data.Memory.MemorySlotsUsed) of $($Data.Memory.TotalMemorySlots)</td></tr>
            </table>
        </div>

        <!-- Disk Information -->
        <div class="section">
            <h2>💿 Disk Information</h2>
            <table>
                <tr><th>Drive</th><th>Size (GB)</th><th>Free Space (GB)</th><th>Usage %</th><th>Health Status</th></tr>
"@

    foreach ($disk in $Data.Disk) {
        $healthClass = $disk.HealthStatus.ToLower()
        $html += "<tr>
                    <td>$($disk.Drive)</td>
                    <td>$($disk.SizeGB)</td>
                    <td>$($disk.FreeSpaceGB)</td>
                    <td>$($disk.UsagePercentage)%</td>
                    <td class='status-$healthClass'>$($disk.HealthStatus)</td>
                  </tr>"
    }

    $html += @"
            </table>
        </div>

        <!-- GPU Information -->
        <div class="section">
            <h2>🎮 Graphics Information</h2>
            <table>
                <tr><th>GPU Name</th><th>Memory</th><th>Driver Version</th><th>Resolution</th></tr>
"@

    if ($Data.GPU -and $Data.GPU.Count -gt 0) {
        foreach ($gpu in $Data.GPU) {
            $html += "<tr>
                        <td>$($gpu.Name)</td>
                        <td>$($gpu.AdapterRAM)</td>
                        <td>$($gpu.DriverVersion)</td>
                        <td>$($gpu.CurrentResolution)</td>
                      </tr>"
        }
    } else {
        $html += "<tr><td colspan='4' style='text-align: center;'>No GPU information available</td></tr>"
    }

    $html += @"
            </table>
        </div>
"@

    # Battery Information (if available)
    if ($Data.Battery -and $Data.Battery.Status -ne "No battery found (Desktop computer)") {
        $batteryHealthClass = $HealthStatus.Battery.Status.ToLower()
        $html += @"
        <div class="section">
            <h2>🔋 Battery Information</h2>
            <div class="component $batteryHealthClass">
                <span class="status-$batteryHealthClass">$($HealthStatus.Battery.Status): $($HealthStatus.Battery.Message)</span>
            </div>
            <table>
                <tr><th>Property</th><th>Value</th></tr>
"@
        foreach ($key in $Data.Battery.Keys) {
            if ($key -ne "Error") {
                $html += "<tr><td>$key</td><td>$($Data.Battery[$key])</td></tr>"
            }
        }
        $html += "</table></div>"
    }

    # Network Information
    $html += @"
        <div class="section">
            <h2>🌐 Network Information</h2>
            <table>
                <tr><th>Adapter Name</th><th>Speed</th><th>Received</th><th>Sent</th><th>Status</th></tr>
"@

    if ($Data.Network -and $Data.Network.Count -gt 0) {
        foreach ($adapter in $Data.Network) {
            $healthClass = $adapter.HealthStatus.ToLower()
            $html += "<tr>
                        <td>$($adapter.Name)</td>
                        <td>$($adapter.LinkSpeed)</td>
                        <td>$($adapter.ReceivedBytes)</td>
                        <td>$($adapter.SentBytes)</td>
                        <td class='status-$healthClass'>$($adapter.HealthStatus)</td>
                      </tr>"
        }
    } else {
        $html += "<tr><td colspan='5' style='text-align: center;'>No active network adapters found</td></tr>"
    }

    $html += @"
            </table>
        </div>

        <footer style='text-align: center; margin-top: 40px; padding: 20px; color: #7f8c8d; border-top: 1px solid #ecf0f1;'>
            <p>Generated by Hardware Health Scanner | $(Get-Date -Format 'yyyy')</p>
            <p><small>Regular hardware monitoring helps prevent system failures and data loss.</small></p>
        </footer>
    </div>
</body>
</html>
"@

    return $html
}

# Main execution
Write-Host "`n" -ForegroundColor Cyan
Write-Host "🖥️  HARDWARE HEALTH SCANNER" -ForegroundColor Cyan
Write-Host "============================" -ForegroundColor Cyan
Write-Host "Starting comprehensive hardware scan..." -ForegroundColor Yellow
Write-Host "This may take a few moments..." -ForegroundColor Gray
Write-Host "`n"

try {
    # Collect all hardware information
    $Global:ReportData.System = Get-SystemInfo
    $Global:ReportData.CPU = Get-CPUInfo
    $Global:ReportData.Memory = Get-MemoryInfo
    $Global:ReportData.Disk = Get-DiskInfo
    $Global:ReportData.GPU = Get-GPUInfo
    $Global:ReportData.Network = Get-NetworkInfo
    $Global:ReportData.Battery = Get-BatteryInfo

    Write-Host "`nGenerating report..." -ForegroundColor Yellow

    # Generate HTML report
    $htmlReport = Generate-HTMLReport -Data $Global:ReportData -HealthStatus $Global:HealthStatus -Warnings $Global:Warnings -CriticalIssues $Global:CriticalIssues

    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Save report
    $htmlReport | Out-File -FilePath $OutputPath -Encoding UTF8

    Write-Host "`n✅ SCAN COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "📄 Report saved to: $OutputPath" -ForegroundColor Cyan

    # Display summary in console
    Write-Host "`n📋 SCAN SUMMARY:" -ForegroundColor Cyan
    Write-Host "----------------" -ForegroundColor Cyan
    
    if ($Global:CriticalIssues.Count -gt 0) {
        Write-Host "🚨 CRITICAL ISSUES: $($Global:CriticalIssues.Count)" -ForegroundColor Red
        foreach ($issue in $Global:CriticalIssues) {
            Write-Host "   • $issue" -ForegroundColor Red
        }
    }

    if ($Global:Warnings.Count -gt 0) {
        Write-Host "`n⚠️  WARNINGS: $($Global:Warnings.Count)" -ForegroundColor Yellow
        foreach ($warning in $Global:Warnings) {
            Write-Host "   • $warning" -ForegroundColor Yellow
        }
    }

    if ($Global:CriticalIssues.Count -eq 0 -and $Global:Warnings.Count -eq 0) {
        Write-Host "✅ No critical issues or warnings detected" -ForegroundColor Green
    }

    # Recommendations
    Write-Host "`n💡 RECOMMENDATIONS:" -ForegroundColor Cyan
    if ($Global:CriticalIssues.Count -gt 0) {
        Write-Host "   • Address critical issues immediately" -ForegroundColor White
    }
    if ($Global:Warnings.Count -gt 0) {
        Write-Host "   • Monitor warning items closely" -ForegroundColor White
    }
    Write-Host "   • Run this scan monthly for ongoing monitoring" -ForegroundColor White
    Write-Host "   • Keep system drivers updated" -ForegroundColor White
    Write-Host "   • Maintain regular backups" -ForegroundColor White

    # Ask to open report
    Write-Host "`n"
    $openReport = Read-Host "Open report in browser now? (Y/N)"
    if ($openReport -eq 'Y' -or $openReport -eq 'y') {
        try {
            Start-Process $OutputPath
            Write-Host "Report opened in default browser" -ForegroundColor Green
        }
        catch {
            Write-Host "Could not open report automatically. Please open manually: $OutputPath" -ForegroundColor Yellow
        }
    }

}
catch {
    Write-Host "`n❌ SCAN FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
}

Write-Host "`n"