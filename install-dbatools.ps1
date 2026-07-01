<#
.SYNOPSIS
    Instalación de dbatools y configuración inicial
#>

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  INSTALACIÓN DE DEPENDENCIAS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# 1. Verificar PowerShell versión
$psVersion = $PSVersionTable.PSVersion.Major
Write-Host "Versión PowerShell: $psVersion" -ForegroundColor Yellow

if ($psVersion -lt 5) {
    Write-Host "[ERROR] Se requiere PowerShell 5.0 o superior" -ForegroundColor Red
    exit 1
}

# 2. Configurar TLS 1.2 (requerido para PowerShell Gallery)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "[OK] TLS 1.2 configurado" -ForegroundColor Green

# 3. Instalar dbatools
Write-Host "`nInstalando dbatools..." -ForegroundColor Yellow
try {
    Install-Module -Name dbatools -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
    Write-Host "[OK] dbatools instalado correctamente" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] No se pudo instalar dbatools: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Intenta ejecutar como Administrador" -ForegroundColor Yellow
    exit 1
}

# 4. Importar módulo
Write-Host "`nImportando dbatools..." -ForegroundColor Yellow
try {
    Import-Module dbatools -ErrorAction Stop
    Write-Host "[OK] dbatools importado" -ForegroundColor Green
    Write-Host "Versión: $(Get-Module dbatools | Select-Object -ExpandProperty Version)" -ForegroundColor Gray
} catch {
    Write-Host "[ERROR] No se pudo importar dbatools" -ForegroundColor Red
    exit 1
}

# 5. Verificar conectividad SQL Server
Write-Host "`nVerificando conectividad con SQL Server..." -ForegroundColor Yellow
try {
    $testConnection = Test-DbaConnection -SqlInstance "localhost" -WarningAction SilentlyContinue
    if ($testConnection) {
        Write-Host "[OK] Conexión a SQL Server establecida" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] No se pudo conectar a SQL Server" -ForegroundColor Yellow
        Write-Host "Verifica que el servidor esté accesible" -ForegroundColor Gray
    }
} catch {
    Write-Host "[WARNING] Error probando conexión: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  INSTALACIÓN COMPLETADA" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Puedes ejecutar ahora: .\validate-backups.ps1" -ForegroundColor Green