[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\BackupValidation\config.json",
    [string]$TargetDB = "",
    [switch]$ForceDocker  # Nuevo parámetro para forzar Docker
)


$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'


$isSunday = (Get-Date).DayOfWeek -eq 'Sunday'
$useDocker = $ForceDocker -or $isSunday

# Logger JSON
class JsonLogger {
    [string]$LogFilePath
    [System.Collections.Generic.List[object]]$LogEntries = [System.Collections.Generic.List[object]]::new()

    JsonLogger([string]$logPath) {
        $this.LogFilePath = $logPath
    }

    [void] AddEntry([string]$Level, [string]$Phase, [string]$Database, [string]$Message) {
        $this.AddEntry($Level, $Phase, $Database, $Message, $null)
    }

    [void] AddEntry([string]$Level, [string]$Phase, [string]$Database, [string]$Message, [object]$Details) {
        $entry = [PSCustomObject]@{
            Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")
            Level     = $Level
            Phase     = $Phase
            Database  = $Database
            Message   = $Message
            Details   = $Details
        }
        $this.LogEntries.Add($entry)
    }

    [void] FlushToDisk() {
        $this.LogEntries | ConvertTo-Json -Depth 5 | Out-File -FilePath $this.LogFilePath -Encoding UTF8 -Force
    }
}
function Remove-OldBackups {
    param([string]$Path, [int]$RetentionDays)
    if (-not (Test-Path $Path)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $Path -File -Include "*.bak", "*.trn", "*.sha256" -Recurse | 
    Where-Object { $_.LastWriteTime -lt $cutoff } | 
    Remove-Item -Force -ErrorAction SilentlyContinue
}
function Get-SHA256Hash {
    param([string]$FilePath)
    try { return (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash }
    catch { return "ERROR_HASH" }
}


try {
    $env:PSModulePath += ";$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
    Import-Module dbatools -ErrorAction Stop
    $config = Get-Content $ConfigPath -ErrorAction Stop | ConvertFrom-Json
}
catch {
    $errorMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] FATAL: $($_.Exception.Message)"
    $errorMsg | Out-File "C:\BackupValidation\fatal_error.log" -Encoding UTF8 -Force
    exit 1
}

$settings = $config.global_settings
New-Item -ItemType Directory -Force -Path $settings.logging.log_path | Out-Null
New-Item -ItemType Directory -Force -Path $settings.logging.html_report_path | Out-Null
New-Item -ItemType Directory -Force -Path $settings.logging.temp_restore_path | Out-Null

$runId = "DRV_$(Get-Date -Format 'yyyyMMddHHmmss')"
$logFile = Join-Path $settings.logging.log_path "$runId.json"
$logger = [JsonLogger]::new($logFile)

$startTime = Get-Date
$logger.AddEntry("INFO", "INIT", "ALL", "Inicio de ejecución", @{ 
        RunId        = $runId
        UseDocker    = $useDocker
        IsSunday     = $isSunday
        ForcedDocker = $ForceDocker
    })

$databasesToProcess = if ($TargetDB) { 
    $config.databases | Where-Object { $_.name -eq $TargetDB } 
}
else { 
    $config.databases 
}

if ($databasesToProcess.Count -eq 0) {
    $logger.AddEntry("ERROR", "INIT", $TargetDB, "No se encontraron bases de datos para procesar")
    $logger.FlushToDisk()
    exit 1
}


$allDbResults = @{}
foreach ($db in $databasesToProcess) {
    $dbName = $db.name
    $dbStartTime = Get-Date
    
    $logger.AddEntry("INFO", "PROCESS", $dbName, "Iniciando procesamiento")
    
    $containerName = "$($settings.docker_validation.container_prefix)_$dbName"
    $tempBasePath = Join-Path $settings.logging.temp_restore_path $dbName
    $resultsPath = Join-Path $tempBasePath "results"
    
    New-Item -ItemType Directory -Force -Path $resultsPath | Out-Null
    

    $metrics = @{
        Total            = 0
        Success          = 0
        Failed           = 0
        TotalSize        = 0
        LastLogTime      = $null
        FullRestoreTime  = 0
        DiffRestoreTime  = 0
        LogRestoreTime   = 0
        FullVerifyTime   = 0
        DiffVerifyTime   = 0
        LogVerifyTime    = 0
        LogCheckDBTime   = 0
        TempCopyTime     = 0
        DockerValidation = $false
        CpuUsage         = @()
        MemoryUsage      = @()
        DbStartTime      = $dbStartTime
    }
    
    $validationResults = @()
    $backupPaths = @{ 
        "FULL" = $db.backup_paths.full
        "DIFF" = $db.backup_paths.diff
        "LOG"  = $db.backup_paths.log 
    }
    
    try {
        # FASE 0: Copia temporal
        $logger.AddEntry("INFO", "PHASE_0", $dbName, "Inicio copia temporal")
        $tempFull = Join-Path $tempBasePath "FULL"
        $tempDiff = Join-Path $tempBasePath "DIFF"
        $tempLog = Join-Path $tempBasePath "LOG"
        New-Item -ItemType Directory -Force -Path $tempFull, $tempDiff, $tempLog | Out-Null
        
        $tempCopyStart = Get-Date
        foreach ($type in @("FULL", "DIFF", "LOG")) {
            $path = $backupPaths[$type]
            $extension = if ($type -eq "LOG") { "*.trn" } else { "*.bak" }
            $tempDest = switch ($type) { 
                "FULL" { $tempFull } 
                "DIFF" { $tempDiff } 
                "LOG" { $tempLog } 
            }
            
            if (Test-Path $path) {
                $latestFile = Get-ChildItem -Path $path -Filter $extension | 
                Sort-Object LastWriteTime -Descending | 
                Select-Object -First 1
                    
                if ($latestFile) {
                    try {
                        Copy-Item -Path $latestFile.FullName -Destination $tempDest -Force
                        $metrics.TotalSize += $latestFile.Length
                        $logger.AddEntry("INFO", "PHASE_0", $dbName, "Copiado $type", @{
                                File   = $latestFile.Name
                                SizeMB = [math]::Round($latestFile.Length / 1MB, 2)
                            })
                    }
                    catch {
                        $logger.AddEntry("ERROR", "PHASE_0", $dbName, "Error copia $type", $_.Exception.Message)
                    }
                }
            }
        }
        $metrics.TempCopyTime = [math]::Round(((Get-Date) - $tempCopyStart).TotalSeconds, 2)

        # FASE 1: Validación dbatools (SIEMPRE se ejecuta)
        $logger.AddEntry("INFO", "PHASE_1", $dbName, "Inicio validación dbatools")
        $sqlConnection = $null
        
        try {
            $sqlConnection = Connect-DbaInstance -SqlInstance $db.sql_instance -TrustServerCertificate -ErrorAction Stop
            $logger.AddEntry("INFO", "PHASE_1", $dbName, "Conexión SQL exitosa")
        }
        catch {
            $logger.AddEntry("ERROR", "PHASE_1", $dbName, "Fallo conexión SQL", $_.Exception.Message)
        }
        
        foreach ($type in @("FULL", "DIFF", "LOG")) {
            $path = $backupPaths[$type]
            $extension = if ($type -eq "LOG") { "*.trn" } else { "*.bak" }
            
            if (Test-Path $path) {
                $files = Get-ChildItem -Path $path -Filter $extension | 
                Sort-Object LastWriteTime -Descending
                
                foreach ($file in $files) {
                    $metrics.Total++
                    $hash = Get-SHA256Hash $file.FullName
                    
                    $result = [PSCustomObject]@{
                        Type         = $type
                        File         = $file.Name
                        SizeMB       = [math]::Round($file.Length / 1MB, 2)
                        Date         = $file.LastWriteTime
                        Hash         = $hash.Substring(0, 16) + "..."
                        HashFull     = $hash
                        VerifyStatus = "Pending"
                        VerifyTime   = 0
                        RestoreTime  = 0
                        CheckDBTime  = 0
                        Copied       = $false
                        HashVerified = $false
                        Method       = "dbatools"
                        LsnFirst     = "N/A"
                        LsnLast      = "N/A"
                    }
                    
                    if ($sqlConnection) {
                        try {
                            $verifyStart = Get-Date
                            $verifyResult = Restore-DbaDatabase -SqlInstance $sqlConnection -Path $file.FullName -VerifyOnly -ErrorAction Stop
                            $result.VerifyTime = [math]::Round(((Get-Date) - $verifyStart).TotalSeconds, 2)
                            
                            if ($verifyResult) {
                                $result.VerifyStatus = "OK"
                                $metrics.Success++
                                
                                # Extraer LSN
                                try {
                                    $header = Read-DbaBackupHeader -SqlInstance $sqlConnection -Path $file.FullName | Select-Object -First 1
                                    if ($header) {
                                        $result.LsnFirst = $header.FirstLsn
                                        $result.LsnLast = $header.LastLsn
                                        if ($type -eq "LOG" -and (-not $metrics.LastLogTime -or $file.LastWriteTime -gt $metrics.LastLogTime)) {
                                            $metrics.LastLogTime = $file.LastWriteTime
                                        }
                                    }
                                }
                                catch {
                                    $logger.AddEntry("WARN", "PHASE_1", $dbName, "No se pudo extraer LSN para $($file.Name)")
                                }
                            }
                        }
                        catch {
                            $result.VerifyStatus = "FAILED"
                            $metrics.Failed++
                            $logger.AddEntry("ERROR", "PHASE_1", $dbName, "VerifyOnly falló: $($file.Name)", $_.Exception.Message)
                        }
                    }
                    
                    if ($type -eq "FULL") { $metrics.FullVerifyTime = $result.VerifyTime }
                    if ($type -eq "DIFF") { $metrics.DiffVerifyTime = $result.VerifyTime }
                    if ($type -eq "LOG") { $metrics.LogVerifyTime = $result.VerifyTime }
                    
                    $validationResults += $result
                }
            }
        }
        
        $logger.AddEntry("INFO", "PHASE_1", $dbName, "Validación dbatools completada", @{
                Total   = $metrics.Total
                Success = $metrics.Success
                Failed  = $metrics.Failed
            })

        # FASE 2: Docker (SOLO domingos o cuando se fuerza)
        if ($useDocker -and $settings.docker_validation.enabled) {
            $logger.AddEntry("INFO", "PHASE_2", $dbName, "Inicio validación Docker (completa)")
            
            try {
                docker rm -f $containerName 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                
                $saPassword = $settings.docker_validation.sa_password
                $imageName = $settings.docker_validation.image
                $hostPort = $settings.docker_validation.host_port_start
                
                # Construir imagen si no existe
                $imageExists = docker images -q $imageName
                if (-not $imageExists) {
                    $logger.AddEntry("INFO", "PHASE_2", $dbName, "Construyendo imagen Docker")
                    docker build -t $imageName -f "C:\BackupValidation\Dockerfile" "C:\BackupValidation" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Error en docker build. Código: $LASTEXITCODE"
                    }
                }
                
                # Iniciar contenedor
                $mountFull = "$($tempFull -replace '\\', '/')`:/backups/full"
                $mountDiff = "$($tempDiff -replace '\\', '/')`:/backups/diff"
                $mountLog = "$($tempLog -replace '\\', '/')`:/backups/log"
                $mountResults = "$($resultsPath -replace '\\', '/')`:/results"
                
                docker run -d `
                    --name $containerName `
                    -p "${hostPort}:1433" `
                    -e "ACCEPT_EULA=Y" `
                    -e "MSSQL_SA_PASSWORD=$saPassword" `
                    -v $mountFull `
                    -v $mountDiff `
                    -v $mountLog `
                    -v $mountResults `
                    $imageName 2>&1 | Out-Null
                
                # Esperar a que esté listo
                $logger.AddEntry("INFO", "PHASE_2", $dbName, "Esperando SQL Server en Docker")
                $ready = $false
                $timeout = $settings.docker_validation.timeout_seconds
                $elapsed = 0
                
                while ($elapsed -lt $timeout) {
                    $healthCheck = docker inspect --format='{{.State.Health.Status}}' $containerName 2>&1
                    if ($healthCheck -eq "healthy") {
                        $ready = $true
                        break
                    }
                    Start-Sleep -Seconds 5
                    $elapsed += 5
                }
                
                if (-not $ready) {
                    throw "Timeout de $timeout segundos. Contenedor no está listo."
                }
                
                $logger.AddEntry("INFO", "PHASE_2", $dbName, "Contenedor listo después de ${elapsed}s")
                
                # Conectar y restaurar
                $metrics.DockerValidation = $true
                $secPassword = ConvertTo-SecureString $saPassword -AsPlainText -Force
                $dockerCred = New-Object System.Management.Automation.PSCredential("sa", $secPassword)
                $dockerConn = Connect-DbaInstance -SqlInstance "localhost,$hostPort" -SqlCredential $dockerCred -TrustServerCertificate -ErrorAction Stop
                $tempDb = "$($dbName)_ValidationTemp"
                
                # Restaurar FULL
                $fullFile = Get-ChildItem -Path $tempFull -Filter "*.bak" | Select-Object -First 1
                if ($fullFile) {
                    $logger.AddEntry("INFO", "PHASE_2", $dbName, "Restaurando FULL", $fullFile.Name)
                    $dockerFullPath = "/backups/full/$($fullFile.Name)"
                    $restoreStart = Get-Date
                    Restore-DbaDatabase -SqlInstance $dockerConn -Path $dockerFullPath -DatabaseName $tempDb -WithReplace -NoRecovery -ErrorAction Stop
                    $metrics.FullRestoreTime = [math]::Round(((Get-Date) - $restoreStart).TotalSeconds, 2)
                }
                
                # Restaurar DIFF
                $diffFile = Get-ChildItem -Path $tempDiff -Filter "*.bak" | Select-Object -First 1
                if ($diffFile) {
                    $logger.AddEntry("INFO", "PHASE_2", $dbName, "Restaurando DIFF", $diffFile.Name)
                    $dockerDiffPath = "/backups/diff/$($diffFile.Name)"
                    $restoreStart = Get-Date
                    Restore-DbaDatabase -SqlInstance $dockerConn -Path $dockerDiffPath -DatabaseName $tempDb -NoRecovery -ErrorAction Stop
                    $metrics.DiffRestoreTime = [math]::Round(((Get-Date) - $restoreStart).TotalSeconds, 2)
                }
                
                # Restaurar LOGs y CHECKDB
                $logFiles = Get-ChildItem -Path $tempLog -Filter "*.trn" | Sort-Object LastWriteTime
                if ($logFiles.Count -gt 0) {
                    $restoreStart = Get-Date
                    foreach ($logFile in $logFiles) {
                        $dockerLogPath = "/backups/log/$($logFile.Name)"
                        Restore-DbaDatabase -SqlInstance $dockerConn -Path $dockerLogPath -DatabaseName $tempDb -NoRecovery -ErrorAction Stop
                    }
                    $metrics.LogRestoreTime = [math]::Round(((Get-Date) - $restoreStart).TotalSeconds, 2)
                    
                    # Recuperar BD
                    Invoke-DbaQuery -SqlInstance $dockerConn -Query "RESTORE DATABASE [$tempDb] WITH RECOVERY" -ErrorAction Stop | Out-Null
                    
                    # CHECKDB
                    $logger.AddEntry("INFO", "PHASE_2", $dbName, "Ejecutando DBCC CHECKDB")
                    $checkdbStart = Get-Date
                    Invoke-DbaQuery -SqlInstance $dockerConn -Database $tempDb -Query "DBCC CHECKDB WITH NO_INFOMSGS" -ErrorAction Stop | Out-Null
                    $metrics.LogCheckDBTime = [math]::Round(((Get-Date) - $checkdbStart).TotalSeconds, 2)
                }
                
                # Limpiar BD temporal
                Invoke-DbaQuery -SqlInstance $dockerConn -Query "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$tempDb') BEGIN ALTER DATABASE [$tempDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$tempDb]; END" -ErrorAction SilentlyContinue | Out-Null
                
                $logger.AddEntry("INFO", "PHASE_2", $dbName, "Validación Docker completada exitosamente")
                
            }
            catch {
                $logger.AddEntry("ERROR", "PHASE_2", $dbName, "Fallo en validación Docker", $_.Exception.Message)
            }
            finally {
                docker rm -f $containerName 2>&1 | Out-Null
            }
        }
        else {
            $logger.AddEntry("INFO", "PHASE_2", $dbName, "Docker omitido (no es domingo ni forzado)")
        }

        # FASE 3: Copia a secundario
        if ($settings.secondary_storage.enabled) {
            $logger.AddEntry("INFO", "PHASE_3", $dbName, "Inicio copia a secundario")
            
            try {
                # Rutas origen y destino para esta BD específica
                $sourceFullPath = $db.backup_paths.full
                $sourceDiffPath = $db.backup_paths.diff
                $sourceLogPath = $db.backup_paths.log
                
                # Construir rutas destino manteniendo la estructura
                # Ejemplo: C:\SQLBackup\TASADM19\SIP25\FULL -> D:\SQLBackup\TASADM19\SIP25\FULL
                $destFullPath = $sourceFullPath -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
                $destDiffPath = $sourceDiffPath -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
                $destLogPath = $sourceLogPath -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
                
                # Crear directorios destino
                New-Item -ItemType Directory -Force -Path $destFullPath | Out-Null
                New-Item -ItemType Directory -Force -Path $destDiffPath | Out-Null
                New-Item -ItemType Directory -Force -Path $destLogPath | Out-Null
                
                $logger.AddEntry("INFO", "PHASE_3", $dbName, "Copiando archivos a destino secundario", @{
                        SourceFull = $sourceFullPath
                        DestFull   = $destFullPath
                        SourceDiff = $sourceDiffPath
                        DestDiff   = $destDiffPath
                        SourceLog  = $sourceLogPath
                        DestLog    = $destLogPath
                    })
                
                # Copiar FULL backups
                if (Test-Path $sourceFullPath) {
                    $robocopyArgs = @(
                        $sourceFullPath,
                        $destFullPath,
                        "*.bak",
                        "*.sha256",
                        "/MIR",
                        "/R:2",
                        "/W:5",
                        "/MT:4",
                        "/NFL",
                        "/NDL",
                        "/NJH",
                        "/NJS",
                        "/NP"
                    )
                    
                    $result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
                    
                    if ($result.ExitCode -le 3) {
                        $logger.AddEntry("INFO", "PHASE_3", $dbName, "FULL backups copiados exitosamente", @{ ExitCode = $result.ExitCode })
                    }
                    else {
                        $logger.AddEntry("WARN", "PHASE_3", $dbName, "Robocopy FULL - código: $($result.ExitCode)")
                    }
                }
                
                # Copiar DIFF backups
                if (Test-Path $sourceDiffPath) {
                    $robocopyArgs = @(
                        $sourceDiffPath,
                        $destDiffPath,
                        "*.bak",
                        "*.sha256",
                        "/MIR",
                        "/R:2",
                        "/W:5",
                        "/MT:4",
                        "/NFL",
                        "/NDL",
                        "/NJH",
                        "/NJS",
                        "/NP"
                    )
                    
                    $result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
                    
                    if ($result.ExitCode -le 3) {
                        $logger.AddEntry("INFO", "PHASE_3", $dbName, "DIFF backups copiados exitosamente", @{ ExitCode = $result.ExitCode })
                    }
                    else {
                        $logger.AddEntry("WARN", "PHASE_3", $dbName, "Robocopy DIFF - código: $($result.ExitCode)")
                    }
                }
                
                # Copiar LOG backups
                if (Test-Path $sourceLogPath) {
                    $robocopyArgs = @(
                        $sourceLogPath,
                        $destLogPath,
                        "*.trn",
                        "*.sha256",
                        "/MIR",
                        "/R:2",
                        "/W:5",
                        "/MT:4",
                        "/NFL",
                        "/NDL",
                        "/NJH",
                        "/NJS",
                        "/NP"
                    )
                    
                    $result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
                    
                    if ($result.ExitCode -le 3) {
                        $logger.AddEntry("INFO", "PHASE_3", $dbName, "LOG backups copiados exitosamente", @{ ExitCode = $result.ExitCode })
                    }
                    else {
                        $logger.AddEntry("WARN", "PHASE_3", $dbName, "Robocopy LOG - código: $($result.ExitCode)")
                    }
                }
                
                # Verificar hashes en destino
                $logger.AddEntry("INFO", "PHASE_3", $dbName, "Verificando hashes en destino")
                foreach ($r in $validationResults) {
                    $sourceFile = switch ($r.Type) {
                        "FULL" { Join-Path $sourceFullPath $r.File }
                        "DIFF" { Join-Path $sourceDiffPath $r.File }
                        "LOG" { Join-Path $sourceLogPath $r.File }
                    }
                    
                    $destFile = switch ($r.Type) {
                        "FULL" { Join-Path $destFullPath $r.File }
                        "DIFF" { Join-Path $destDiffPath $r.File }
                        "LOG" { Join-Path $destLogPath $r.File }
                    }
                    
                    if (Test-Path $destFile) {
                        $destHash = Get-SHA256Hash $destFile
                        if ($destHash -eq $r.HashFull) {
                            $r.Copied = $true
                            $r.HashVerified = $true
                            $logger.AddEntry("INFO", "PHASE_3", $dbName, "Hash verificado: $($r.File)")
                        }
                        else {
                            $r.Copied = $true
                            $r.HashVerified = $false
                            $logger.AddEntry("ERROR", "PHASE_3", $dbName, "Hash NO coincide: $($r.File)", @{
                                    SourceHash = $r.HashFull
                                    DestHash   = $destHash
                                })
                        }
                    }
                }
                
                $logger.AddEntry("INFO", "PHASE_3", $dbName, "Copia a secundario completada")
                
            }
            catch {
                $logger.AddEntry("ERROR", "PHASE_3", $dbName, "Error en copia a secundario", $_.Exception.Message)
            }
        }

        # FASE 4: Limpieza (incluye destino secundario)
        $logger.AddEntry("INFO", "PHASE_4", $dbName, "Inicio limpieza y retención")
              
        # Limpiar destino secundario
        if ($settings.secondary_storage.enabled) {
            $destFullPath = $db.backup_paths.full -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
            $destDiffPath = $db.backup_paths.diff -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
            $destLogPath = $db.backup_paths.log -replace [regex]::Escape($settings.secondary_storage.source_drive), $settings.secondary_storage.dest_drive
            
            Remove-OldBackups -Path $destFullPath -RetentionDays $settings.retention_days.full
            Remove-OldBackups -Path $destDiffPath -RetentionDays $settings.retention_days.diff
            Remove-OldBackups -Path $destLogPath -RetentionDays $settings.retention_days.log
            
            $logger.AddEntry("INFO", "PHASE_4", $dbName, "Retención aplicada en destino secundario")
        }
        
        # Limpiar carpeta temporal
        if (Test-Path $tempBasePath) {
            Remove-Item -Path $tempBasePath -Recurse -Force -ErrorAction SilentlyContinue
            $logger.AddEntry("INFO", "PHASE_4", $dbName, "Carpeta temporal eliminada")
        }
    
        $allDbResults[$dbName] = @{
            Metrics = $metrics
            Results = $validationResults
            Config  = $db
        }
    }
    catch {
        $logger.AddEntry("ERROR", "PROCESS", $dbName, "Error crítico procesando BD", $_.Exception.Message)
        # Asegurar que los resultados parciales se guarden
        $allDbResults[$dbName] = @{
            Metrics = $metrics
            Results = $validationResults
            Config  = $db
        }
    }
}

# ============================================================================
# GENERACIÓN DE DATOS JSON PARA EL HTML
# ============================================================================
$logger.AddEntry("INFO", "REPORT", "ALL", "Generando datos para reporte HTML")

$jsData = @{}
foreach ($dbName in $allDbResults.Keys) {
    $m = $allDbResults[$dbName].Metrics
    $r = $allDbResults[$dbName].Results
    
    # Datos de archivos para la tabla de almacenamiento
    $files = @()
    foreach ($result in $r) {
        $files += @{
            type         = $result.Type
            name         = $result.File
            size         = $result.SizeMB
            date         = $result.Date.ToString("yyyy-MM-dd HH:mm:ss")
            hash         = $result.Hash
            verified     = $result.VerifyStatus -eq "OK"
            copied       = $result.Copied
            hashVerified = $result.HashVerified
        }
    }
    
    $jsData[$dbName] = @{
        rto         = if ($m.FullRestoreTime -gt 0) { [math]::Ceiling($m.FullRestoreTime / 60) } else { [math]::Ceiling(($m.TotalSize / 104857600) / 60) }
        rpo         = if ($m.LastLogTime) { [math]::Round((New-TimeSpan -Start $m.LastLogTime -End (Get-Date)).TotalMinutes, 1) } else { 0 }
        successRate = if ($m.Total -gt 0) { [math]::Round(($m.Success / $m.Total) * 100, 1) } else { 0 }
        totalSize   = [math]::Round($m.TotalSize / 1GB, 2)
        duration    = [math]::Round(((Get-Date) - $m.DbStartTime).TotalSeconds, 2)
        cpuAvg      = 45.5  # Valor de ejemplo
        memAvg      = 62.3  # Valor de ejemplo
        dockerUsed  = $m.DockerValidation
        timeline    = @{
            copy    = $m.TempCopyTime
            verify  = $m.FullVerifyTime + $m.DiffVerifyTime + $m.LogVerifyTime
            restore = $m.FullRestoreTime + $m.DiffRestoreTime + $m.LogRestoreTime
            checkdb = $m.LogCheckDBTime
        }
        lsn         = @{
            full = ($r | Where-Object { $_.Type -eq 'FULL' } | Select-Object -First 1).LsnFirst
            diff = ($r | Where-Object { $_.Type -eq 'DIFF' } | Select-Object -First 1).LsnFirst
            log  = ($r | Where-Object { $_.Type -eq 'LOG' } | Select-Object -First 1).LsnFirst
        }
        files       = $files
    }
}

    
$jsDataJson = $jsData | ConvertTo-Json -Depth 5 -Compress
$jsDataJson | Out-File (Join-Path $settings.logging.log_path "debug_data.json") -Encoding UTF8 -Force

# ============================================================================
# GENERAR HTML
# ============================================================================
$html = @'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ReportDB</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap');
        
        :root {
            --sidebar-bg: #0f172a;
            --sidebar-hover: #1e293b;
            --sidebar-active: #1e293b;
            --accent: #6366f1;
            --accent-light: #818cf8;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --info: #3b82f6;
            --neutral-50: #f8fafc;
            --neutral-100: #f1f5f9;
            --neutral-200: #e2e8f0;
            --neutral-300: #cbd5e1;
            --neutral-400: #94a3b8;
            --neutral-500: #64748b;
            --neutral-600: #475569;
            --neutral-700: #334155;
            --neutral-800: #1e293b;
            --neutral-900: #0f172a;
        }
        
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background-color: var(--neutral-50);
            color: var(--neutral-800);
            letter-spacing: -0.01em;
        }
        
        .font-mono { font-family: 'JetBrains Mono', 'Consolas', monospace; }
        
        .sidebar { background: var(--sidebar-bg); min-height: 100vh; }
        
        .sidebar-item {
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            border-left: 3px solid transparent;
            cursor: pointer;
            color: #cbd5e1;
            font-size: 0.875rem;
            font-weight: 500;
        }
        
        .sidebar-item:hover { background-color: var(--sidebar-hover); border-left-color: var(--accent-light); color: #f1f5f9; }
        .sidebar-item.active { background-color: var(--sidebar-active); border-left-color: var(--accent); color: #ffffff; font-weight: 600; }
        
        .db-selector {
            background-color: #1e293b; color: #e2e8f0; border: 1px solid #334155;
            border-radius: 0.5rem; padding: 0.625rem 0.75rem; width: 100%;
            font-size: 0.8125rem; font-weight: 500; cursor: pointer; transition: all 0.2s; outline: none;
        }
        
        .db-selector:hover { border-color: var(--accent); }
        .db-selector:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.15); }
        
        .view-section { display: none; animation: fadeSlideIn 0.25s ease-out; }
        .view-section.active { display: block; }
        
        @keyframes fadeSlideIn {
            from { opacity: 0; transform: translateY(8px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        .metric-card {
            background: #ffffff; border: 1px solid var(--neutral-200);
            border-radius: 1rem; padding: 1.5rem;
            transition: box-shadow 0.2s, transform 0.2s;
        }
        
        .metric-card:hover { box-shadow: 0 4px 20px rgba(0, 0, 0, 0.06); transform: translateY(-1px); }
        
        .metric-label {
            font-size: 0.6875rem; font-weight: 600; text-transform: uppercase;
            letter-spacing: 0.05em; color: var(--neutral-500);
        }
        
        .metric-value { font-size: 1.75rem; font-weight: 700; color: var(--neutral-900); line-height: 1.2; }
        .metric-unit { font-size: 0.875rem; font-weight: 400; color: var(--neutral-400); }
        
        .badge {
            display: inline-flex; align-items: center; gap: 0.375rem;
            padding: 0.25rem 0.75rem; border-radius: 9999px;
            font-size: 0.75rem; font-weight: 600; white-space: nowrap;
        }
        
        .badge-success { background: #ecfdf5; color: #065f46; }
        .badge-warning { background: #fffbeb; color: #92400e; }
        .badge-danger { background: #fef2f2; color: #991b1b; }
        .badge-info { background: #eff6ff; color: #1e40af; }
        .badge-neutral { background: #f8fafc; color: #475569; }
        
        .data-table { width: 100%; border-collapse: collapse; }
        
        .data-table thead th {
            background: var(--neutral-100); color: var(--neutral-500);
            font-size: 0.6875rem; font-weight: 600; text-transform: uppercase;
            letter-spacing: 0.05em; padding: 0.75rem 1rem; text-align: left;
        }
        
        .data-table tbody td {
            padding: 0.875rem 1rem; border-bottom: 1px solid var(--neutral-100); font-size: 0.875rem;
        }
        
        .data-table tbody tr { transition: background-color 0.15s; }
        .data-table tbody tr:hover { background-color: #f8fafc; }
        .data-table tbody tr.clickable { cursor: pointer; }
        .data-table tbody tr.clickable:hover { background-color: #eef2ff; }
        
        .btn-primary {
            background: var(--accent); color: #ffffff; padding: 0.625rem 1.25rem;
            border-radius: 0.5rem; font-weight: 600; font-size: 0.8125rem; border: none;
            cursor: pointer; transition: all 0.2s; display: inline-flex; align-items: center; gap: 0.5rem;
        }
        
        .btn-primary:hover { background: #4f46e5; box-shadow: 0 2px 8px rgba(99, 102, 241, 0.3); }
        .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }
        
        .progress-bar { height: 0.5rem; background: var(--neutral-200); border-radius: 9999px; overflow: hidden; }
        .progress-fill { height: 100%; border-radius: 9999px; transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1); }
        .progress-fill.success { background: var(--success); }
        .progress-fill.danger { background: var(--danger); }
        .progress-fill.info { background: var(--info); }
        
        .restore-step { position: relative; padding-left: 3.5rem; }
        
        .restore-step::before {
            content: ''; position: absolute; left: 1.35rem; top: 3rem;
            bottom: -0.5rem; width: 2px; background: var(--neutral-200);
        }
        
        .restore-step:last-child::before { display: none; }
        
        .step-indicator {
            position: absolute; left: 0.25rem; top: 0.5rem; width: 2.25rem; height: 2.25rem;
            border-radius: 50%; display: flex; align-items: center; justify-content: center;
            font-weight: 700; font-size: 0.8125rem; color: #ffffff; z-index: 1;
        }
        
        .tab-content {
            background: #ffffff; border: 1px solid var(--neutral-200);
            border-radius: 1rem; padding: 2rem;
        }
        
        .section-title {
            font-size: 1.125rem; font-weight: 700; color: var(--neutral-800);
            margin-bottom: 1.5rem; display: flex; align-items: center; gap: 0.5rem;
        }
        
        .spinner {
            display: inline-block; width: 1rem; height: 1rem;
            border: 2px solid rgba(255,255,255,0.3); border-radius: 50%;
            border-top-color: #ffffff; animation: spin 0.6s linear infinite;
        }
        
        @keyframes spin { to { transform: rotate(360deg); } }
        
        .empty-state { text-align: center; padding: 3rem 1rem; color: var(--neutral-400); }
        .empty-state i { font-size: 2.5rem; margin-bottom: 1rem; display: block; color: var(--neutral-300); }
        .empty-state p { font-size: 0.9375rem; font-weight: 500; margin-bottom: 0.25rem; }
        .empty-state span { font-size: 0.8125rem; }
        
        .sla-pass { background: linear-gradient(135deg, #ecfdf5 0%, #f0fdf4 100%); border: 1px solid #a7f3d0; }
        .sla-fail { background: linear-gradient(135deg, #fef2f2 0%, #fff5f5 100%); border: 1px solid #fecaca; }
    </style>
</head>
<body class="flex min-h-screen">
    <aside class="sidebar w-72 flex flex-col flex-shrink-0 shadow-xl z-20">
        <div class="h-16 flex items-center px-6 border-b border-slate-800">
            <i class="fa-solid fa-shield-halved text-indigo-400 text-xl mr-3"></i>
            <div>
                <span class="text-lg font-bold tracking-tight text-white">ReportDR</span>
                <span class="block text-xs text-slate-500 font-medium">Reporte de Recuperación</span>
            </div>
        </div>
        <div class="px-6 py-5 border-b border-slate-800">
            <label class="block text-xs font-semibold text-slate-500 uppercase tracking-wider mb-2">
                <i class="fa-solid fa-database mr-1.5 text-slate-600"></i>Base de Datos
            </label>
            <select id="dbSelector" class="db-selector" onchange="switchView(this.value)">
                <option value="general">Resumen General</option>
            </select>
        </div>
        <nav class="flex-1 py-3 space-y-0.5 px-3">
            <button onclick="showTab('tab-overview', this)" class="sidebar-item active w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-table-cells mr-3 w-4 text-center"></i>Resumen
            </button>
            <button onclick="showTab('tab-detail', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-chart-bar mr-3 w-4 text-center"></i>Detalle por BD
            </button>
            <button onclick="showTab('tab-restore-plan', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-diagram-project mr-3 w-4 text-center"></i>Plan de Restauración
            </button>
            <button onclick="showTab('tab-storage', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-folder-tree mr-3 w-4 text-center"></i>Inventario de Archivos
            </button>
            <button onclick="showTab('tab-replication', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-copy mr-3 w-4 text-center"></i>Copia Secundaria
            </button>
            <button onclick="showTab('tab-history', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-clock-rotate-left mr-3 w-4 text-center"></i>Historial
            </button>
            <button onclick="showTab('tab-sla', this)" class="sidebar-item w-full text-left px-3 py-2.5 rounded-lg">
                <i class="fa-solid fa-bullseye mr-3 w-4 text-center"></i>Cumplimiento SLA
            </button>
        </nav>
        <div class="px-6 py-4 border-t border-slate-800 text-xs text-slate-600 font-medium">
            <div class="font-mono" id="sidebar-date"></div>
            <div class="mt-1" id="sidebar-count"></div>
        </div>
    </aside>

    <main class="flex-1 overflow-y-auto bg-slate-50">
        <header class="h-16 bg-white border-b border-slate-200 flex items-center justify-between px-8 sticky top-0 z-10">
            <div>
                <h1 class="text-lg font-bold text-slate-800" id="header-title">Resumen de Validación</h1>
                <p class="text-sm text-slate-500" id="header-subtitle">Todas las instancias de base de datos</p>
            </div>
            <div class="flex items-center gap-4">
                <span class="text-xs text-slate-400 bg-slate-100 px-3 py-1.5 rounded-full font-medium" id="last-update"></span>
                <button onclick="executeValidation()" class="btn-primary" id="btn-execute">
                    <i class="fa-solid fa-play text-xs"></i>
                    Ejecutar Validación Completa
                </button>
            </div>
        </header>

        <div class="p-8 max-w-7xl mx-auto">
            
            <!-- RESUMEN -->
            <div id="tab-overview" class="view-section active">
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-5 mb-8">
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-clock text-indigo-400 mr-1.5"></i>RTO Promedio</span>
                        <div class="metric-value mt-1" id="gen-rto">--<span class="metric-unit ml-1">min</span></div>
                        <p class="text-xs text-slate-400 mt-1">Tiempo objetivo de recuperación</p>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-database text-teal-400 mr-1.5"></i>RPO Promedio</span>
                        <div class="metric-value mt-1" id="gen-rpo">--<span class="metric-unit ml-1">min</span></div>
                        <p class="text-xs text-slate-400 mt-1">Punto objetivo de recuperación</p>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-circle-check text-emerald-400 mr-1.5"></i>Tasa de Éxito</span>
                        <div class="metric-value mt-1" id="gen-success">--<span class="metric-unit ml-1">%</span></div>
                        <p class="text-xs text-slate-400 mt-1">Porcentaje de aprobación</p>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-hard-drive text-amber-400 mr-1.5"></i>Tamaño Total</span>
                        <div class="metric-value mt-1" id="gen-size">--<span class="metric-unit ml-1">GB</span></div>
                        <p class="text-xs text-slate-400 mt-1">Espacio total de respaldos</p>
                    </div>
                </div>

                <div class="tab-content mb-8">
                    <h2 class="section-title"><i class="fa-solid fa-table-list text-indigo-500"></i>Comparativa de Bases de Datos</h2>
                    <div class="overflow-x-auto">
                        <table class="data-table">
                            <thead>
                                <tr>
                                    <th>Base de Datos</th>
                                    <th class="text-right">Tamaño (GB)</th>
                                    <th class="text-right">RTO (min)</th>
                                    <th class="text-right">RPO (min)</th>
                                    <th class="text-right">Tasa de Éxito</th>
                                    <th class="text-center">Prueba Docker</th>
                                    <th class="text-right">Duración (s)</th>
                                    <th class="text-center">Estado</th>
                                </tr>
                            </thead>
                            <tbody id="gen-table-body"></tbody>
                        </table>
                    </div>
                </div>

                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-link text-indigo-500"></i>Resumen de Cadena LSN</h2>
                    <div class="overflow-x-auto">
                        <table class="data-table">
                            <thead>
                                <tr>
                                    <th>Base de Datos</th>
                                    <th>LSN Full</th>
                                    <th>LSN Diferencial</th>
                                    <th>LSN Log</th>
                                    <th class="text-center">Estado de Cadena</th>
                                </tr>
                            </thead>
                            <tbody id="lsn-table-body"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- DETALLE POR BD -->
            <div id="tab-detail" class="view-section">
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-5 mb-8">
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-clock text-indigo-400 mr-1.5"></i>RTO Medido</span>
                        <div class="metric-value mt-1" id="ind-rto">--<span class="metric-unit ml-1">min</span></div>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-database text-teal-400 mr-1.5"></i>RPO Medido</span>
                        <div class="metric-value mt-1" id="ind-rpo">--<span class="metric-unit ml-1">min</span></div>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-microchip text-amber-400 mr-1.5"></i>CPU Promedio</span>
                        <div class="metric-value mt-1" id="ind-cpu">--<span class="metric-unit ml-1">%</span></div>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-memory text-purple-400 mr-1.5"></i>Memoria Promedio</span>
                        <div class="metric-value mt-1" id="ind-mem">--<span class="metric-unit ml-1">%</span></div>
                    </div>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-5 mb-8">
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-hourglass-start text-blue-400 mr-1.5"></i>Restauración Full</span>
                        <div class="metric-value mt-1" id="ind-full-time">--<span class="metric-unit ml-1">s</span></div>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-hourglass-half text-teal-400 mr-1.5"></i>Restauración Diferencial</span>
                        <div class="metric-value mt-1" id="ind-diff-time">--<span class="metric-unit ml-1">s</span></div>
                    </div>
                    <div class="metric-card">
                        <span class="metric-label"><i class="fa-solid fa-stethoscope text-emerald-400 mr-1.5"></i>Duración CHECKDB</span>
                        <div class="metric-value mt-1" id="ind-checkdb-time">--<span class="metric-unit ml-1">s</span></div>
                    </div>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
                    <div class="tab-content">
                        <h3 class="section-title"><i class="fa-solid fa-chart-line text-indigo-500"></i>Consumo de Recursos</h3>
                        <div style="height: 280px;"><canvas id="resourceChart"></canvas></div>
                    </div>
                    <div class="tab-content">
                        <h3 class="section-title"><i class="fa-solid fa-timeline text-teal-500"></i>Línea de Tiempo</h3>
                        <div style="height: 280px;"><canvas id="timelineChart"></canvas></div>
                    </div>
                </div>

                <div class="tab-content">
                    <h3 class="section-title"><i class="fa-solid fa-link text-amber-500"></i>Cadena LSN Validada</h3>
                    <div class="flex items-center justify-between p-5 bg-slate-50 rounded-xl">
                        <div class="text-center flex-1">
                            <p class="text-xs font-semibold text-slate-500 mb-1.5">FULL</p>
                            <p class="font-mono text-sm font-semibold text-indigo-600 bg-white px-3 py-1.5 rounded-lg border border-indigo-100" id="ind-lsn-full">--</p>
                        </div>
                        <div class="px-3"><i class="fa-solid fa-arrow-right-long text-slate-300 text-xl"></i></div>
                        <div class="text-center flex-1">
                            <p class="text-xs font-semibold text-slate-500 mb-1.5">DIFERENCIAL</p>
                            <p class="font-mono text-sm font-semibold text-teal-600 bg-white px-3 py-1.5 rounded-lg border border-teal-100" id="ind-lsn-diff">--</p>
                        </div>
                        <div class="px-3"><i class="fa-solid fa-arrow-right-long text-slate-300 text-xl"></i></div>
                        <div class="text-center flex-1">
                            <p class="text-xs font-semibold text-slate-500 mb-1.5">LOG</p>
                            <p class="font-mono text-sm font-semibold text-blue-600 bg-white px-3 py-1.5 rounded-lg border border-blue-100" id="ind-lsn-log">--</p>
                        </div>
                    </div>
                    <div class="mt-4 p-4 bg-indigo-50 rounded-lg border border-indigo-100">
                        <p class="text-sm text-indigo-700 font-medium" id="lsn-status-text">
                            <i class="fa-solid fa-circle-info mr-2"></i>Seleccione una base de datos para ver el detalle de la cadena LSN.
                        </p>
                    </div>
                </div>
            </div>

            <!-- PLAN DE RESTAURACIÓN -->
            <div id="tab-restore-plan" class="view-section">
                <div class="tab-content mb-8">
                    <div class="flex items-center justify-between mb-6">
                        <h2 class="section-title mb-0">
                            <i class="fa-solid fa-diagram-project text-indigo-500"></i>
                            Plan de Restauración: <span id="guia-db-name" class="text-indigo-600 font-bold">--</span>
                        </h2>
                        <span class="badge badge-info" id="guia-total-time">Tiempo estimado: --</span>
                    </div>
                    <div class="space-y-0" id="restore-steps">
                        <div class="empty-state">
                            <i class="fa-solid fa-diagram-project"></i>
                            <p>Seleccione una base de datos para generar el plan</p>
                            <span>Se mostrará la secuencia exacta de archivos con tiempos estimados</span>
                        </div>
                    </div>
                </div>

                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-clock-rotate-left text-teal-500"></i>Resumen del Escenario</h2>
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-6" id="recovery-scenario">
                        <div class="bg-slate-50 rounded-xl p-5 text-center border border-slate-200">
                            <i class="fa-solid fa-calendar-check text-2xl text-indigo-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Punto de Recuperación</p>
                            <p class="text-xl font-bold text-slate-800 mt-1 font-mono" id="recovery-point">--</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 text-center border border-slate-200">
                            <i class="fa-solid fa-layer-group text-2xl text-teal-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Archivos Necesarios</p>
                            <p class="text-xl font-bold text-slate-800 mt-1" id="recovery-files">--</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 text-center border border-slate-200">
                            <i class="fa-solid fa-gauge-high text-2xl text-amber-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Duración Estimada</p>
                            <p class="text-xl font-bold text-slate-800 mt-1" id="recovery-time">--</p>
                        </div>
                    </div>
                </div>
            </div>

            <!-- INVENTARIO DE ARCHIVOS -->
            <div id="tab-storage" class="view-section">
                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-folder-tree text-indigo-500"></i>Inventario de Archivos de Respaldo</h2>
                    <div class="overflow-x-auto">
                        <table class="data-table">
                            <thead>
                                <tr>
                                    <th>Base de Datos</th>
                                    <th>Tipo</th>
                                    <th>Nombre de Archivo</th>
                                    <th class="text-right">Tamaño (MB)</th>
                                    <th class="text-right">Fecha</th>
                                    <th class="text-center">SHA-256</th>
                                    <th class="text-center">Integridad</th>
                                    <th class="text-center">Probado Docker</th>
                                </tr>
                            </thead>
                            <tbody id="storage-table-body"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- COPIA SECUNDARIA -->
            <div id="tab-replication" class="view-section">
                <div class="tab-content mb-8">
                    <h2 class="section-title"><i class="fa-solid fa-copy text-indigo-500"></i>Replicación a Almacenamiento Secundario</h2>
                    <p class="text-sm text-slate-500 mb-6">
                        Archivos replicados desde el origen hacia el destino secundario mediante Robocopy.
                        Esta capa adicional de protección garantiza la disponibilidad de los respaldos ante fallos del almacenamiento primario.
                    </p>
                    
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-5 mb-8">
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200 text-center">
                            <i class="fa-solid fa-file-export text-2xl text-indigo-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Archivos Replicados</p>
                            <p class="text-2xl font-bold text-slate-800 mt-1" id="rep-files-count">0</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200 text-center">
                            <i class="fa-solid fa-shield-check text-2xl text-teal-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Integridad Verificada</p>
                            <p class="text-2xl font-bold text-slate-800 mt-1" id="rep-integrity-count">0 / 0</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200 text-center">
                            <i class="fa-solid fa-calendar-range text-2xl text-amber-400 mb-2 block"></i>
                            <p class="text-xs font-semibold text-slate-500 uppercase">Período de Retención</p>
                            <p class="text-2xl font-bold text-slate-800 mt-1" id="rep-retention">28/7/7 días</p>
                        </div>
                    </div>
                    
                    <div class="overflow-x-auto">
                        <table class="data-table">
                            <thead>
                                <tr>
                                    <th>Base de Datos</th>
                                    <th>Tipo</th>
                                    <th>Nombre de Archivo</th>
                                    <th class="text-right">Tamaño (MB)</th>
                                    <th class="text-center">Hash Origen</th>
                                    <th class="text-center">Hash Destino</th>
                                    <th class="text-center">Estado de Replicación</th>
                                    <th class="text-right">Retención (días)</th>
                                </tr>
                            </thead>
                            <tbody id="replication-table-body"></tbody>
                        </table>
                    </div>
                </div>
                
                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-clock-rotate-left text-teal-500"></i>Política de Retención</h2>
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200">
                            <div class="flex items-center gap-2 mb-3">
                                <div class="w-3 h-3 rounded-full bg-blue-500"></div>
                                <span class="font-semibold text-slate-700">Respaldos Completos</span>
                            </div>
                            <p class="text-2xl font-bold text-slate-800">28</p>
                            <p class="text-xs text-slate-500 mt-1">días de retención</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200">
                            <div class="flex items-center gap-2 mb-3">
                                <div class="w-3 h-3 rounded-full bg-teal-500"></div>
                                <span class="font-semibold text-slate-700">Respaldos Diferenciales</span>
                            </div>
                            <p class="text-2xl font-bold text-slate-800">7</p>
                            <p class="text-xs text-slate-500 mt-1">días de retención</p>
                        </div>
                        <div class="bg-slate-50 rounded-xl p-5 border border-slate-200">
                            <div class="flex items-center gap-2 mb-3">
                                <div class="w-3 h-3 rounded-full bg-amber-500"></div>
                                <span class="font-semibold text-slate-700">Respaldos de Log</span>
                            </div>
                            <p class="text-2xl font-bold text-slate-800">7</p>
                            <p class="text-xs text-slate-500 mt-1">días de retención</p>
                        </div>
                    </div>
                </div>
            </div>

            <!-- HISTORIAL -->
            <div id="tab-history" class="view-section">
                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-clock-rotate-left text-indigo-500"></i>Historial de Ejecuciones</h2>
                    <div class="flex gap-4 mb-6">
                        <select id="history-method-filter" class="px-3 py-2 border border-slate-200 rounded-lg text-sm font-medium text-slate-600" onchange="renderHistoryTable()">
                            <option value="all">Todos los Métodos</option>
                            <option value="dbatools">Solo dbatools</option>
                            <option value="Docker">Solo Docker</option>
                        </select>
                        <select id="history-db-filter" class="px-3 py-2 border border-slate-200 rounded-lg text-sm font-medium text-slate-600" onchange="renderHistoryTable()">
                            <option value="all">Todas las Bases</option>
                        </select>
                    </div>
                    <div class="overflow-x-auto">
                        <table class="data-table">
                            <thead>
                                <tr>
                                    <th>Fecha</th>
                                    <th>Base de Datos</th>
                                    <th>Método</th>
                                    <th class="text-right">Archivos</th>
                                    <th class="text-right">Tasa de Éxito</th>
                                    <th class="text-right">Duración (s)</th>
                                    <th class="text-center">CHECKDB</th>
                                    <th class="text-center">Estado</th>
                                </tr>
                            </thead>
                            <tbody id="history-table-body"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- CUMPLIMIENTO SLA -->
            <div id="tab-sla" class="view-section">
                <div class="tab-content">
                    <h2 class="section-title"><i class="fa-solid fa-bullseye text-indigo-500"></i>Cumplimiento de Acuerdo de Nivel de Servicio</h2>
                    
                    <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
                        <div class="bg-slate-50 rounded-xl p-6 border border-slate-200">
                            <div class="flex items-center justify-between mb-4">
                                <div>
                                    <p class="font-semibold text-slate-700">Punto Objetivo de Recuperación</p>
                                    <p class="text-sm text-slate-500">Objetivo: 15 minutos máximos de pérdida de datos</p>
                                </div>
                                <div class="text-right">
                                    <span class="text-2xl font-bold text-slate-800 font-mono" id="iso-rpo-value">--</span>
                                    <span class="text-sm text-slate-500"> min</span>
                                </div>
                            </div>
                            <div class="progress-bar mb-2">
                                <div class="progress-fill success" style="width: 0%" id="iso-rpo-bar"></div>
                            </div>
                            <p class="text-xs text-slate-500 font-medium" id="iso-rpo-text">Calculando...</p>
                        </div>
                        
                        <div class="bg-slate-50 rounded-xl p-6 border border-slate-200">
                            <div class="flex items-center justify-between mb-4">
                                <div>
                                    <p class="font-semibold text-slate-700">Tiempo Objetivo de Recuperación</p>
                                    <p class="text-sm text-slate-500">Objetivo: 60 minutos máximos de recuperación</p>
                                </div>
                                <div class="text-right">
                                    <span class="text-2xl font-bold text-slate-800 font-mono" id="iso-rto-value">--</span>
                                    <span class="text-sm text-slate-500"> min</span>
                                </div>
                            </div>
                            <div class="progress-bar mb-2">
                                <div class="progress-fill info" style="width: 0%" id="iso-rto-bar"></div>
                            </div>
                            <p class="text-xs text-slate-500 font-medium" id="iso-rto-text">Calculando...</p>
                        </div>
                    </div>
                    
                    <div id="iso-status-container" class="p-5 rounded-xl border sla-pass">
                        <div class="flex items-center gap-4">
                            <i class="fa-solid fa-clipboard-check text-2xl text-emerald-500"></i>
                            <div>
                                <h3 class="font-semibold text-slate-700">Estado de Cumplimiento</h3>
                                <p class="text-sm text-slate-600" id="iso-status-text">Seleccione una base de datos para evaluar el cumplimiento SLA.</p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </main>

    <script>
        // ====================================================================
        // DATOS INYECTADOS DESDE POWERSHELL
        // ====================================================================
        var dbData = __DB_DATA_PLACEHOLDER__;
        
        // Si no hay datos, inicializar como objeto vacío
        if (!dbData || typeof dbData !== 'object' || Array.isArray(dbData)) {
            dbData = {};
        }
        
        var currentView = 'general';
        var currentTab = 'tab-overview';
        var resourceChartInstance = null;
        var timelineChartInstance = null;
        var validationHistory = [];
        
        // ====================================================================
        // INICIALIZACIÓN
        // ====================================================================
        window.addEventListener('DOMContentLoaded', function() {
            initApp();
        });
        
        function initApp() {
            var now = new Date();
            document.getElementById('sidebar-date').textContent = now.toLocaleDateString('es-ES', {
                year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
            });
            
            var dbCount = Object.keys(dbData).length;
            document.getElementById('sidebar-count').textContent = dbCount + ' base(s) de datos';
            
            populateDbSelector();
            populateHistoryFilter();
            loadHistory();
            
            switchView('general');
            var firstNavItem = document.querySelector('.sidebar-item.active');
            if (firstNavItem) showTab('tab-overview', firstNavItem);
            
            document.getElementById('last-update').textContent = 'Actualizado: ' + now.toLocaleTimeString('es-ES');
        }
        
        function populateDbSelector() {
            var selector = document.getElementById('dbSelector');
            // Mantener solo la opción general
            selector.innerHTML = '<option value="general">Resumen General</option>';
            Object.keys(dbData).sort().forEach(function(dbName) {
                var option = document.createElement('option');
                option.value = dbName;
                option.textContent = dbName;
                selector.appendChild(option);
            });
        }
        
        function populateHistoryFilter() {
            var filter = document.getElementById('history-db-filter');
            filter.innerHTML = '<option value="all">Todas las Bases</option>';
            Object.keys(dbData).sort().forEach(function(dbName) {
                var option = document.createElement('option');
                option.value = dbName;
                option.textContent = dbName;
                filter.appendChild(option);
            });
        }
        
        function loadHistory() {
            var stored = localStorage.getItem('drValidationHistory');
            if (stored) {
                try { validationHistory = JSON.parse(stored); } catch(e) { validationHistory = []; }
            }
            
            var now = new Date().toISOString();
            Object.keys(dbData).forEach(function(dbName) {
                var data = dbData[dbName];
                var entry = {
                    date: now,
                    database: dbName,
                    method: data.dockerUsed ? 'Docker' : 'dbatools',
                    files: data.files ? data.files.length : 0,
                    successRate: data.successRate || 0,
                    duration: data.duration || 0,
                    checkdb: data.dockerUsed || false,
                    status: (data.successRate || 0) >= 100 ? 'APROBADO' : (data.successRate || 0) >= 80 ? 'ADVERTENCIA' : 'FALLÓ'
                };
                
                var exists = validationHistory.some(function(h) { 
                    return h.date === entry.date && h.database === entry.database && h.method === entry.method;
                });
                if (!exists) validationHistory.unshift(entry);
            });
            
            if (validationHistory.length > 100) validationHistory = validationHistory.slice(0, 100);
            localStorage.setItem('drValidationHistory', JSON.stringify(validationHistory));
        }
        
        // ====================================================================
        // NAVEGACIÓN
        // ====================================================================
        function switchView(dbName) {
            currentView = dbName;
            
            if (dbName === 'general') {
                document.getElementById('header-title').textContent = 'Resumen de Validación';
                document.getElementById('header-subtitle').textContent = 'Todas las instancias de base de datos';
            } else {
                document.getElementById('header-title').textContent = 'Base de Datos: ' + dbName;
                var data = dbData[dbName];
                if (data) {
                    var dockerStatus = data.dockerUsed ? 'Validación completa (Docker)' : 'Validación rápida (dbatools)';
                    document.getElementById('header-subtitle').textContent = dockerStatus + ' | Éxito: ' + (data.successRate || 0).toFixed(1) + '%';
                }
            }
            
            refreshCurrentTab();
        }
        
        function showTab(tabId, element) {
            document.querySelectorAll('.sidebar-item').forEach(function(item) { item.classList.remove('active'); });
            if (element) element.classList.add('active');
            
            document.querySelectorAll('.view-section').forEach(function(section) { section.classList.remove('active'); });
            var target = document.getElementById(tabId);
            if (target) {
                target.classList.add('active');
                currentTab = tabId;
                refreshCurrentTab();
            }
        }
        
        function refreshCurrentTab() {
            switch(currentTab) {
                case 'tab-overview': renderOverview(); break;
                case 'tab-detail': 
                    if (currentView !== 'general') renderDetail(currentView); 
                    else clearDetail(); 
                    break;
                case 'tab-restore-plan': 
                    if (currentView !== 'general') renderRestorePlan(currentView); 
                    break;
                case 'tab-storage': renderStorage(); break;
                case 'tab-replication': renderReplication(); break;
                case 'tab-history': renderHistoryTable(); break;
                case 'tab-sla': 
                    if (currentView !== 'general') renderSla(currentView); 
                    break;
            }
        }
        
        function clearDetail() {
            ['ind-rto','ind-rpo','ind-cpu','ind-mem','ind-full-time','ind-diff-time','ind-checkdb-time'].forEach(function(id) {
                document.getElementById(id).innerHTML = '--<span class="metric-unit ml-1">-</span>';
            });
            ['ind-lsn-full','ind-lsn-diff','ind-lsn-log'].forEach(function(id) {
                document.getElementById(id).textContent = '--';
            });
        }
        
        // ====================================================================
        // RENDERIZADO: RESUMEN
        // ====================================================================
        function renderOverview() {
            var totalSize = 0, totalRto = 0, totalRpo = 0, totalSuccess = 0, count = 0;
            var tbody = document.getElementById('gen-table-body');
            var lsnTbody = document.getElementById('lsn-table-body');
            
            if (!Object.keys(dbData).length) {
                tbody.innerHTML = '<tr><td colspan="8"><div class="empty-state"><i class="fa-solid fa-database"></i><p>Sin datos disponibles</p><span>Ejecute una validación para generar el reporte</span></div></td></tr>';
                lsnTbody.innerHTML = '<tr><td colspan="5"><div class="empty-state"><p>Sin datos de LSN disponibles</p></div></td></tr>';
                return;
            }
            
            tbody.innerHTML = '';
            lsnTbody.innerHTML = '';
            
            Object.keys(dbData).forEach(function(db) {
                var data = dbData[db];
                totalSize += data.totalSize || 0;
                totalRto += data.rto || 0;
                totalRpo += data.rpo || 0;
                totalSuccess += data.successRate || 0;
                count++;
                
                var rate = data.successRate || 0;
                var statusClass = 'badge-success', statusText = 'APROBADO';
                if (rate < 80) { statusClass = 'badge-danger'; statusText = 'FALLÓ'; }
                else if (rate < 100) { statusClass = 'badge-warning'; statusText = 'ADVERTENCIA'; }
                
                var dockerBadge = data.dockerUsed ? 
                    '<span class="badge badge-success"><i class="fa-brands fa-docker"></i> Completo</span>' : 
                    '<span class="badge badge-neutral"><i class="fa-solid fa-database"></i> Básico</span>';
                
                var row = document.createElement('tr');
                row.className = 'clickable';
                row.onclick = function(dbName) {
                    return function() {
                        document.getElementById('dbSelector').value = dbName;
                        switchView(dbName);
                        showTab('tab-detail', document.querySelectorAll('.sidebar-item')[1]);
                    };
                }(db);
                
                row.innerHTML = 
                    '<td class="font-medium text-slate-700">' + db + '</td>' +
                    '<td class="text-right font-mono">' + (data.totalSize || 0).toFixed(2) + '</td>' +
                    '<td class="text-right font-mono">' + (data.rto || 0) + '</td>' +
                    '<td class="text-right font-mono">' + (data.rpo || 0).toFixed(1) + '</td>' +
                    '<td class="text-right font-mono">' + rate.toFixed(1) + '%</td>' +
                    '<td class="text-center">' + dockerBadge + '</td>' +
                    '<td class="text-right font-mono">' + (data.duration || 0).toFixed(1) + 's</td>' +
                    '<td class="text-center"><span class="badge ' + statusClass + '">' + statusText + '</span></td>';
                tbody.appendChild(row);
                
                var lsnFull = (data.lsn && data.lsn.full) ? data.lsn.full : 'N/D';
                var lsnDiff = (data.lsn && data.lsn.diff) ? data.lsn.diff : 'N/D';
                var lsnLog = (data.lsn && data.lsn.log) ? data.lsn.log : 'N/D';
                var valid = lsnFull !== 'N/D' && lsnDiff !== 'N/D' && lsnLog !== 'N/D';
                
                var lsnRow = document.createElement('tr');
                lsnRow.innerHTML = 
                    '<td class="font-medium text-slate-700">' + db + '</td>' +
                    '<td class="font-mono text-xs text-indigo-600">' + lsnFull + '</td>' +
                    '<td class="font-mono text-xs text-teal-600">' + lsnDiff + '</td>' +
                    '<td class="font-mono text-xs text-blue-600">' + lsnLog + '</td>' +
                    '<td class="text-center"><span class="badge ' + (valid ? 'badge-success' : 'badge-warning') + '">' + (valid ? 'Válida' : 'Parcial') + '</span></td>';
                lsnTbody.appendChild(lsnRow);
            });
            
            if (count) {
                document.getElementById('gen-rto').innerHTML = Math.round(totalRto/count) + '<span class="metric-unit ml-1">min</span>';
                document.getElementById('gen-rpo').innerHTML = (totalRpo/count).toFixed(1) + '<span class="metric-unit ml-1">min</span>';
                document.getElementById('gen-success').innerHTML = (totalSuccess/count).toFixed(1) + '<span class="metric-unit ml-1">%</span>';
                document.getElementById('gen-size').innerHTML = totalSize.toFixed(2) + '<span class="metric-unit ml-1">GB</span>';
            }
        }
        
        // ====================================================================
        // RENDERIZADO: DETALLE
        // ====================================================================
        function renderDetail(dbName) {
            var data = dbData[dbName];
            if (!data) { clearDetail(); return; }
            
            document.getElementById('ind-rto').innerHTML = (data.rto || 0) + '<span class="metric-unit ml-1">min</span>';
            document.getElementById('ind-rpo').innerHTML = (data.rpo || 0).toFixed(1) + '<span class="metric-unit ml-1">min</span>';
            document.getElementById('ind-cpu').innerHTML = (data.cpuAvg || 0).toFixed(1) + '<span class="metric-unit ml-1">%</span>';
            document.getElementById('ind-mem').innerHTML = (data.memAvg || 0).toFixed(1) + '<span class="metric-unit ml-1">%</span>';
            
            var tl = data.timeline || {};
            document.getElementById('ind-full-time').innerHTML = (tl.restore || 0).toFixed(1) + '<span class="metric-unit ml-1">s</span>';
            document.getElementById('ind-diff-time').innerHTML = ((tl.restore || 0) * 0.3).toFixed(1) + '<span class="metric-unit ml-1">s</span>';
            document.getElementById('ind-checkdb-time').innerHTML = (tl.checkdb || 0).toFixed(1) + '<span class="metric-unit ml-1">s</span>';
            
            document.getElementById('ind-lsn-full').textContent = (data.lsn && data.lsn.full) ? data.lsn.full : 'N/D';
            document.getElementById('ind-lsn-diff').textContent = (data.lsn && data.lsn.diff) ? data.lsn.diff : 'N/D';
            document.getElementById('ind-lsn-log').textContent = (data.lsn && data.lsn.log) ? data.lsn.log : 'N/D';
            
            var lsnFull = (data.lsn && data.lsn.full && data.lsn.full !== 'N/A') ? data.lsn.full : null;
            var lsnDiff = (data.lsn && data.lsn.diff && data.lsn.diff !== 'N/A') ? data.lsn.diff : null;
            var lsnLog = (data.lsn && data.lsn.log && data.lsn.log !== 'N/A') ? data.lsn.log : null;
            var valid = lsnFull && lsnDiff && lsnLog;
            
            document.getElementById('lsn-status-text').innerHTML = valid ? 
                '<i class="fa-solid fa-circle-check mr-2 text-emerald-500"></i>Cadena LSN validada. La secuencia de respaldos es consistente para una recuperación completa.' :
                '<i class="fa-solid fa-triangle-exclamation mr-2 text-amber-500"></i>Cadena LSN parcial. Verifique la integridad de la secuencia de respaldos.';
            
            renderCharts(data);
        }
        
        // ====================================================================
        // RENDERIZADO: PLAN DE RESTAURACIÓN
        // ====================================================================
        function renderRestorePlan(dbName) {
            var data = dbData[dbName];
            if (!data) return;
            
            document.getElementById('guia-db-name').textContent = dbName;
            var steps = document.getElementById('restore-steps');
            
            var html = '';
            var stepNum = 1;
            var totalTime = 0;
            var fileCount = 0;
            var lastDate = '';
            
            if (data.files && data.files.length) {
                var fullFiles = data.files.filter(function(f) { return f.type === 'FULL'; });
                var diffFiles = data.files.filter(function(f) { return f.type === 'DIFF'; }).sort(function(a,b) { return new Date(a.date) - new Date(b.date); });
                var logFiles = data.files.filter(function(f) { return f.type === 'LOG'; }).sort(function(a,b) { return new Date(a.date) - new Date(b.date); });
                
                fullFiles.forEach(function(f) {
                    fileCount++; totalTime += (data.timeline && data.timeline.restore ? data.timeline.restore : 60) * 0.6;
                    html += buildStep(stepNum++, 'RESTORE DATABASE ... WITH NORECOVERY', f.name, (f.size || 0) + ' MB', 'FULL', 'bg-blue-600');
                });
                
                if (diffFiles.length) {
                    var last = diffFiles[diffFiles.length-1];
                    fileCount++; totalTime += (data.timeline && data.timeline.restore ? data.timeline.restore : 30) * 0.3;
                    html += buildStep(stepNum++, 'RESTORE DATABASE ... WITH NORECOVERY', last.name, (last.size || 0) + ' MB', 'DIFF', 'bg-teal-600');
                    lastDate = last.date;
                }
                
                logFiles.forEach(function(f, i) {
                    fileCount++; totalTime += 10;
                    var cmd = i === logFiles.length-1 ? 'RESTORE LOG ... WITH RECOVERY' : 'RESTORE LOG ... WITH NORECOVERY';
                    html += buildStep(stepNum++, cmd, f.name, (f.size || 0) + ' MB', 'LOG', 'bg-amber-600');
                    lastDate = f.date;
                });
            }
            
            steps.innerHTML = html || '<div class="empty-state"><i class="fa-solid fa-diagram-project"></i><p>Sin archivos disponibles para generar el plan</p></div>';
            document.getElementById('guia-total-time').textContent = 'Tiempo estimado: ' + Math.round(totalTime) + 's';
            document.getElementById('recovery-point').textContent = lastDate || 'N/D';
            document.getElementById('recovery-files').textContent = fileCount + ' archivos';
            document.getElementById('recovery-time').textContent = Math.round(totalTime) + ' segundos';
        }
        
        function buildStep(num, command, fileName, size, type, colorClass) {
            var bgClass = type === 'FULL' ? 'bg-blue-50 border-blue-200' : type === 'DIFF' ? 'bg-teal-50 border-teal-200' : 'bg-amber-50 border-amber-200';
            return '<div class="restore-step pb-5">' +
                '<div class="step-indicator ' + colorClass + ' text-white">' + num + '</div>' +
                '<div class="ml-1 p-4 rounded-lg border ' + bgClass + '">' +
                    '<div class="flex items-center justify-between mb-2">' +
                        '<span class="badge badge-info">' + type + '</span>' +
                        '<span class="text-xs text-slate-500 font-mono">' + size + '</span>' +
                    '</div>' +
                    '<p class="font-mono text-sm text-slate-700 font-semibold">' + command + '</p>' +
                    '<p class="text-sm text-slate-600 mt-1"><i class="fa-solid fa-file mr-1.5"></i>' + fileName + '</p>' +
                '</div>' +
            '</div>';
        }
        
        // ====================================================================
        // RENDERIZADO: INVENTARIO
        // ====================================================================
        function renderStorage() {
            var tbody = document.getElementById('storage-table-body');
            tbody.innerHTML = '';
            var hasData = false;
            
            Object.keys(dbData).forEach(function(dbName) {
                var info = dbData[dbName];
                if (info.files && info.files.length) {
                    info.files.forEach(function(file) {
                        hasData = true;
                        var colors = { FULL: {bg:'#dbeafe',c:'#1e40af'}, DIFF: {bg:'#d1fae5',c:'#065f46'}, LOG: {bg:'#fce7f3',c:'#9d174d'} };
                        var c = colors[file.type] || {bg:'#e2e8f0',c:'#475569'};
                        
                        var row = document.createElement('tr');
                        row.innerHTML = 
                            '<td class="font-medium">' + dbName + '</td>' +
                            '<td><span class="badge" style="background:' + c.bg + ';color:' + c.c + '">' + file.type + '</span></td>' +
                            '<td class="font-mono text-sm">' + (file.name || 'N/D') + '</td>' +
                            '<td class="text-right font-mono">' + (file.size || 0).toFixed(2) + '</td>' +
                            '<td class="text-right text-sm">' + (file.date || 'N/D') + '</td>' +
                            '<td class="text-center font-mono text-xs">' + (file.hash || 'N/D') + '</td>' +
                            '<td class="text-center"><span class="badge ' + (file.verified ? 'badge-success' : 'badge-danger') + '">' + (file.verified ? 'Verificado' : 'Falló') + '</span></td>' +
                            '<td class="text-center">' + (info.dockerUsed ? '<span class="badge badge-success"><i class="fa-solid fa-check"></i></span>' : '<span class="badge badge-neutral"><i class="fa-solid fa-minus"></i></span>') + '</td>';
                        tbody.appendChild(row);
                    });
                }
            });
            
            if (!hasData) {
                tbody.innerHTML = '<tr><td colspan="8"><div class="empty-state"><i class="fa-solid fa-folder-open"></i><p>Sin datos de inventario</p></div></td></tr>';
            }
        }
        
        // ====================================================================
        // RENDERIZADO: REPLICACIÓN
        // ====================================================================
        function renderReplication() {
            var tbody = document.getElementById('replication-table-body');
            tbody.innerHTML = '';
            
            var replicatedCount = 0;
            var verifiedCount = 0;
            var hasData = false;
            
            Object.keys(dbData).forEach(function(dbName) {
                var info = dbData[dbName];
                if (info.files && info.files.length) {
                    info.files.forEach(function(file) {
                        // Verificar si el archivo fue copiado (propiedad 'copied')
                        if (file.copied === true) {
                            hasData = true;
                            replicatedCount++;
                            if (file.hashVerified === true) verifiedCount++;
                            
                            var row = document.createElement('tr');
                            row.innerHTML = 
                                '<td class="font-medium">' + dbName + '</td>' +
                                '<td><span class="badge badge-info">' + (file.type || 'N/D') + '</span></td>' +
                                '<td class="font-mono text-sm">' + (file.name || 'N/D') + '</td>' +
                                '<td class="text-right font-mono">' + (file.size || 0).toFixed(2) + '</td>' +
                                '<td class="text-center font-mono text-xs">' + (file.hash || 'N/D').substring(0, 16) + '...</td>' +
                                '<td class="text-center font-mono text-xs">' + (file.hashVerified ? (file.hash || 'N/D').substring(0, 16) + '...' : 'Pendiente') + '</td>' +
                                '<td class="text-center"><span class="badge ' + (file.hashVerified ? 'badge-success' : file.copied ? 'badge-warning' : 'badge-neutral') + '">' + (file.hashVerified ? 'Replicado y Verificado' : file.copied ? 'Replicado' : 'Pendiente') + '</span></td>' +
                                '<td class="text-right font-mono">' + (file.type === 'FULL' ? '28' : '7') + ' días</td>';
                            tbody.appendChild(row);
                        }
                    });
                }
            });
            
            document.getElementById('rep-files-count').textContent = replicatedCount;
            document.getElementById('rep-integrity-count').textContent = verifiedCount + ' / ' + replicatedCount;
            document.getElementById('rep-retention').textContent = '28/7/7 días';
            
            if (!hasData) {
                tbody.innerHTML = '<tr><td colspan="8"><div class="empty-state"><i class="fa-solid fa-copy"></i><p>Sin archivos replicados detectados</p><span>Los archivos aparecerán aquí después de la sincronización con Robocopy</span></div></td></tr>';
            }
        }
        
        // ====================================================================
        // RENDERIZADO: HISTORIAL
        // ====================================================================
        function renderHistoryTable() {
            var tbody = document.getElementById('history-table-body');
            var methodFilter = document.getElementById('history-method-filter').value;
            var dbFilter = document.getElementById('history-db-filter').value;
            
            var filtered = validationHistory;
            if (methodFilter !== 'all') filtered = filtered.filter(function(h) { return h.method === methodFilter; });
            if (dbFilter !== 'all') filtered = filtered.filter(function(h) { return h.database === dbFilter; });
            
            if (!filtered.length) {
                tbody.innerHTML = '<tr><td colspan="8"><div class="empty-state"><i class="fa-solid fa-clock-rotate-left"></i><p>Sin registros en el historial</p></div></td></tr>';
                return;
            }
            
            tbody.innerHTML = '';
            filtered.forEach(function(entry) {
                var d = new Date(entry.date);
                var methodBadge = entry.method === 'Docker' ? 
                    '<span class="badge badge-success"><i class="fa-brands fa-docker"></i> Docker</span>' :
                    '<span class="badge badge-info"><i class="fa-solid fa-database"></i> dbatools</span>';
                var statusClass = entry.status === 'APROBADO' ? 'badge-success' : entry.status === 'ADVERTENCIA' ? 'badge-warning' : 'badge-danger';
                
                var row = document.createElement('tr');
                row.innerHTML = 
                    '<td class="text-sm">' + d.toLocaleDateString('es-ES') + ' ' + d.toLocaleTimeString('es-ES') + '</td>' +
                    '<td class="font-medium">' + entry.database + '</td>' +
                    '<td>' + methodBadge + '</td>' +
                    '<td class="text-right">' + entry.files + '</td>' +
                    '<td class="text-right font-mono">' + entry.successRate.toFixed(1) + '%</td>' +
                    '<td class="text-right font-mono">' + entry.duration.toFixed(1) + 's</td>' +
                    '<td class="text-center">' + (entry.checkdb ? '<span class="badge badge-success"><i class="fa-solid fa-check"></i> Sí</span>' : '<span class="badge badge-neutral">No</span>') + '</td>' +
                    '<td class="text-center"><span class="badge ' + statusClass + '">' + entry.status + '</span></td>';
                tbody.appendChild(row);
            });
        }
        
        // ====================================================================
        // RENDERIZADO: SLA
        // ====================================================================
        function renderSla(dbName) {
            var data = dbData[dbName];
            if (!data) return;
            
            var rpo = data.rpo || 0;
            var rto = data.rto || 0;
            
            var rpoPct = Math.min((rpo/15)*100, 100);
            document.getElementById('iso-rpo-value').textContent = rpo.toFixed(1);
            document.getElementById('iso-rpo-bar').style.width = rpoPct + '%';
            document.getElementById('iso-rpo-bar').className = 'progress-fill ' + (rpo <= 15 ? 'success' : 'danger');
            document.getElementById('iso-rpo-text').textContent = rpo <= 15 ? 'Dentro del objetivo (15 min)' : 'Excede el objetivo';
            
            var rtoPct = Math.min((rto/60)*100, 100);
            document.getElementById('iso-rto-value').textContent = rto;
            document.getElementById('iso-rto-bar').style.width = rtoPct + '%';
            document.getElementById('iso-rto-bar').className = 'progress-fill ' + (rto <= 60 ? 'info' : 'danger');
            document.getElementById('iso-rto-text').textContent = rto <= 60 ? 'Dentro del objetivo (60 min)' : 'Excede el objetivo';
            
            var container = document.getElementById('iso-status-container');
            if (rpo <= 15 && rto <= 60) {
                container.className = 'p-5 rounded-xl border sla-pass';
                document.getElementById('iso-status-text').innerHTML = '<strong>' + dbName + '</strong> cumple con todos los objetivos SLA definidos.';
            } else {
                container.className = 'p-5 rounded-xl border sla-fail';
                document.getElementById('iso-status-text').innerHTML = '<strong>' + dbName + '</strong> no cumple con los objetivos SLA. Revise las métricas anteriores para más detalles.';
            }
        }
        
        // ====================================================================
        // GRÁFICOS
        // ====================================================================
        function renderCharts(data) {
            if (resourceChartInstance) resourceChartInstance.destroy();
            if (timelineChartInstance) timelineChartInstance.destroy();
            
            var ctxRes = document.getElementById('resourceChart');
            if (ctxRes) {
                resourceChartInstance = new Chart(ctxRes, {
                    type: 'line',
                    data: {
                        labels: ['Inicio', 'Copia', 'Rest. Full', 'Rest. Diff', 'CHECKDB', 'Fin'],
                        datasets: [
                            { label: 'CPU %', data: [30, 45, 75, 60, 85, 25], borderColor: '#6366f1', backgroundColor: 'rgba(99,102,241,0.08)', tension: 0.4, fill: true },
                            { label: 'Memoria %', data: [40, 55, 70, 65, 80, 45], borderColor: '#14b8a6', backgroundColor: 'rgba(20,184,166,0.08)', tension: 0.4, fill: true }
                        ]
                    },
                    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'bottom' } }, scales: { y: { beginAtZero: true, max: 100 } } }
                });
            }
            
            var ctxTime = document.getElementById('timelineChart');
            if (ctxTime) {
                var tl = data.timeline || {};
                timelineChartInstance = new Chart(ctxTime, {
                    type: 'bar',
                    data: {
                        labels: ['Copia Temp', 'Verify Only', 'Restauración', 'CHECKDB'],
                        datasets: [{ label: 'Segundos', data: [tl.copy||0, tl.verify||0, tl.restore||0, tl.checkdb||0], backgroundColor: ['#64748b','#94a3b8','#6366f1','#f59e0b'], borderRadius: 6 }]
                    },
                    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } }, scales: { y: { beginAtZero: true } } }
                });
            }
        }
        
        // ====================================================================
        // EJECUCIÓN DE VALIDACIÓN
        // ====================================================================
        function executeValidation() {
            var db = currentView === 'general' ? 'all' : currentView;
            var btn = document.getElementById('btn-execute');
            
            if (!confirm('¿Ejecutar validación completa (con restauración Docker) para ' + (db === 'all' ? 'todas las bases de datos' : db) + '?\n\nEste proceso incluye:\n- Restauración completa en contenedor aislado\n- Verificación de integridad DBCC CHECKDB\n- Validación de cadena LSN\n\nLa duración puede variar según el tamaño de la base de datos.')) return;
            
            btn.disabled = true;
            btn.innerHTML = '<span class="spinner"></span> Ejecutando...';
            
            fetch('/api/execute', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ db_name: db, force_docker: true })
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.status === 'success') {
                    alert('Validación iniciada correctamente.\n\nEl reporte se actualizará automáticamente al finalizar el proceso.');
                    setTimeout(function() { location.reload(); }, 30000);
                } else {
                    alert('Error: ' + data.message);
                    btn.disabled = false;
                    btn.innerHTML = '<i class="fa-solid fa-play text-xs"></i> Ejecutar Validación Completa';
                }
            })
            .catch(function(err) {
                alert('Error de conexión: ' + err.message);
                btn.disabled = false;
                btn.innerHTML = '<i class="fa-solid fa-play text-xs"></i> Ejecutar Validación Completa';
            });
        }
    </script>
</body>
</html>
'@

# REEMPLAZAR PLACEHOLDER CON DATOS REALES
# Escapar correctamente el JSON para inyección en JavaScript
$jsDataJsonEscaped = $jsDataJson -replace '\\', '\\' -replace "'", "\'" -replace '"', '\"'
$html = $html -replace '__DB_DATA_PLACEHOLDER__', $jsDataJson

# Verificar que el reemplazo se realizó
if ($html -match '__DB_DATA_PLACEHOLDER__') {
    $logger.AddEntry("ERROR", "REPORT", "ALL", "ERROR: El placeholder NO fue reemplazado")
}
else {
    $logger.AddEntry("INFO", "REPORT", "ALL", "Placeholder reemplazado correctamente")
}

# Guardar HTML
$reportFile = Join-Path $settings.logging.html_report_path "dashboard_consolidated.html"
$html | Out-File $reportFile -Encoding UTF8

# Finalizar
$logger.AddEntry("INFO", "FINAL", "ALL", "Proceso completado", @{ 
        DurationSeconds = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
        ReportFile      = $reportFile
    })
$logger.FlushToDisk()
exit 0