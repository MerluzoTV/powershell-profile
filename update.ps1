# ==============================================================================
# Script: update.ps1
# Descripción: Gestor dinámico de actualizaciones multiplataforma (WinGet + Chocolatey)
# ==============================================================================

# Parsea la tabla de "winget upgrade --include-unknown" para sacar solo los IDs
# pendientes -- recorta por posición de columna (donde empieza "ID" y "Version"
# en la cabecera), no por espacios, porque el nombre de la app puede traerlos
# ("Epic Online Services", "OBS Studio"...). Si winget cambia el formato de
# tabla o el idioma del sistema, esto puede dejar de encontrar la cabecera y
# simplemente devuelve @() sin romper el resto del script.
function Get-WingetUpgradeIds {
    $lines = winget upgrade --include-unknown | Out-String -Stream
    $headerLineObj = $lines | Select-String -Pattern '^Name\s+ID\s+Version'
    if (-not $headerLineObj) { return @() }
    $headerIndex = $headerLineObj.LineNumber - 1
    $headerLine = $lines[$headerIndex]
    $idStart = $headerLine.IndexOf("ID")
    $versionStart = $headerLine.IndexOf("Version")
    $results = @()
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -match '^\d+\s') { break }   # línea de resumen ("3 Aktualisierungen...", "3 Pakete...")
        if ($line.Length -lt $idStart) { break }
        $endIdx = if ($versionStart -gt $idStart -and $versionStart -le $line.Length) { $versionStart } else { $line.Length }
        $id = $line.Substring($idStart, $endIdx - $idStart).Trim()
        if ($id) { $results += $id }
    }
    return $results
}

# Intenta actualizar un paquete de WinGet con reintentos progresivos:
#   1) upgrade normal
#   2) si falla, desinstalar + instalar limpio -- cubre tanto "la nueva
#      versión usa otra tecnología de instalador" (WinGet rechaza el upgrade
#      in-place) como bloqueos de archivo puntuales que ya se liberaron
#   3) si sigue fallando, o el paquete está en $ForceChocoList, Chocolatey
function Update-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$ChocoMapping = @{},
        [string[]]$ForceChocoList = @(),
        [bool]$ChocoInstalled = $false
    )

    $useChocoDirect = $ChocoInstalled -and ($ForceChocoList -contains $Id)
    $ok = $false

    if (-not $useChocoDirect) {
        Write-Host "  📥 $Id (WinGet)..." -ForegroundColor Blue
        $p = Start-Process winget -ArgumentList "upgrade --id $Id --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
        $ok = ($p.ExitCode -eq 0)

        if (-not $ok) {
            Write-Host "  🔁 Upgrade normal falló. Reinstalando limpio ($Id)..." -ForegroundColor Yellow
            Start-Process winget -ArgumentList "uninstall --id $Id" -NoNewWindow -Wait | Out-Null
            $p2 = Start-Process winget -ArgumentList "install --id $Id --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
            $ok = ($p2.ExitCode -eq 0)

            if (-not $ok) {
                # A veces es un antivirus escaneando los ficheros recien
                # extraidos del instalador (carrera, no bloqueo real) -- un
                # segundo intento tras una pausa corta suele bastar.
                Start-Sleep -Seconds 3
                Write-Host "  🔁 Reintentando instalación una vez más..." -ForegroundColor Yellow
                $p3 = Start-Process winget -ArgumentList "install --id $Id --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
                $ok = ($p3.ExitCode -eq 0)
            }
        }
    }

    if (-not $ok -and $ChocoInstalled) {
        $chocoName = if ($ChocoMapping.ContainsKey($Id)) { $ChocoMapping[$Id] } else { $Id.ToLower() }
        Write-Host "  🍫 Intentando con Chocolatey ('$chocoName')..." -ForegroundColor Cyan
        choco upgrade $chocoName -y
    } elseif (-not $ok) {
        Write-Host "  ⚠️ No se pudo actualizar $Id (WinGet falló, sin Chocolatey de rescate)." -ForegroundColor Red
    }
}

function global:update {
    # Auto-elevación única (método WinUtil): si no somos admin, relanza esta
    # misma función en una pwsh admin y cede el control. Así winget y choco
    # corren juntos en UNA sola sesión elevada, sin ventanas ni UAC a mitad
    # de proceso.
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "🔐 'update' necesita administrador (winget + choco en una sola sesión, sin ventanas extra)..." -ForegroundColor Yellow
        Start-Process wt -Verb RunAs -ArgumentList "new-tab", "pwsh.exe", "-NoExit", "-Command", "update"
        return
    }

    $forceChocoList = @("Apple.Bonjour", "CreativeTechnology.OpenAL")

    $chocoMapping = @{
        "Apple.Bonjour"             = "apple-bonjour"
        "CreativeTechnology.OpenAL" = "openal"
        "OBSProject.OBSStudio"      = "obs-studio"
    }

    do {
        Clear-Host
        Write-Host "🔍 Sincronizando repositorios de WinGet y buscando actualizaciones..." -ForegroundColor Yellow
        winget source update | Out-Null 
        winget upgrade --include-unknown
        
        # --- COMPROBACIÓN DINÁMICA DE CHOCOLATEY ---
        $chocoInstalled = [bool](Get-Command choco -ErrorAction SilentlyContinue)
        $chocoOutdatedPackages = $false

        if ($chocoInstalled) {
            try {
                $chocoOutdated = Invoke-Expression "choco outdated" 2>$null
                
                if ($chocoOutdated -match "determined 0 package" -or $chocoOutdated -eq $null) {
                    Write-Host "✅ Chocolatey está completamente al día." -ForegroundColor Green
                } else {
                    Write-Host "🍫 Chocolatey tiene actualizaciones disponibles:" -ForegroundColor Yellow
                    
                    $chocoOutdated | Select-String -Pattern "\|" | ForEach-Object {
                        Write-Host "   • $($_.Line)" -ForegroundColor DarkYellow
                    }
                    Write-Host "" 
                    $chocoOutdatedPackages = $true
                }
            } catch {
                Write-Host "✅ Chocolatey está al día (comprobación silenciada)." -ForegroundColor Green
            }
        } else {
            Write-Host "⚠️ Nota: Chocolatey no está instalado." -ForegroundColor Gray
        }

        # --- COMPROBACIÓN DINÁMICA DE POWERSHELL 7 ---
        $pwshNeedUpdate = $false
        $latestRelease = $null
        $downloadAsset = $null
        try {
            $repoUri = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
            $latestRelease = Invoke-RestMethod -Uri $repoUri -UseBasicParsing
            $latestVersionString = $latestRelease.tag_name.TrimStart('v')
            if ([version]$latestVersionString -gt $PSVersionTable.PSVersion) {
                Write-Host "📢 ¡Nota: Hay una nueva versión de PowerShell 7 disponible! (GitHub: v$latestVersionString)" -ForegroundColor Magenta
                $downloadAsset = $latestRelease.assets | Where-Object { $_.name -like "*win-x64.msi" } | Select-Object -First 1
                $pwshNeedUpdate = $true
            } else {
                Write-Host "✅ PowerShell 7 está completamente al día." -ForegroundColor Green
            }
        } catch {}

        Write-Host "`n📋 ¿Cómo deseas proceder?" -ForegroundColor Cyan
        Write-Host "  [1] Actualizar TODO de golpe (Aceptando licencias)" -ForegroundColor Green
        Write-Host "  [2] Actualizar una aplicación específica por su ID" -ForegroundColor Green
        
        if ($pwshNeedUpdate) {
            Write-Host "  [3] Descargar instalador (.msi) de la nueva versión de PowerShell" -ForegroundColor Magenta
            Write-Host "  [4] Desinstalar una aplicación por su ID" -ForegroundColor Yellow
            Write-Host "  [5] Cancelar y salir" -ForegroundColor Red
            $maxOpcion = 5
        } else {
            Write-Host "  [3] Desinstalar una aplicación por su ID" -ForegroundColor Yellow
            Write-Host "  [4] Cancelar y salir" -ForegroundColor Red
            $maxOpcion = 4
        }
        
        $opcion = Read-Host "`nSelecciona una opción (1-$maxOpcion)"
        
        if (-not $pwshNeedUpdate) {
            if ($opcion -eq "3") { $opcion = "desinstalar" }
            if ($opcion -eq "4") { $opcion = "cancelar" }
        } else {
            if ($opcion -eq "3") { $opcion = "pwsh" }
            if ($opcion -eq "4") { $opcion = "desinstalar" }
            if ($opcion -eq "5") { $opcion = "cancelar" }
        }

        $pausarAlFinal = $true

        switch ($opcion) {
            "1" {
                Write-Host "`n🚀 Actualizando todo el sistema con WinGet..." -ForegroundColor Green
                winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements

                $stillOutdated = Get-WingetUpgradeIds
                if ($stillOutdated.Count -gt 0) {
                    Write-Host "`n🔁 $($stillOutdated.Count) paquete(s) no se actualizaron en el paso masivo -- reintentando uno a uno..." -ForegroundColor Yellow
                    foreach ($id in $stillOutdated) {
                        Update-WingetPackage -Id $id -ChocoMapping $chocoMapping -ForceChocoList $forceChocoList -ChocoInstalled $chocoInstalled
                    }
                }

                # Ya estamos elevados (self-elevate al entrar en la función),
                # así que choco corre aquí mismo, sin abrir nada más.
                if ($chocoInstalled -and $chocoOutdatedPackages) {
                    Write-Host "`n🍫 Actualizando todo con Chocolatey..." -ForegroundColor Cyan
                    choco upgrade all -y
                } elseif ($chocoInstalled) {
                    Write-Host "`n✅ Chocolatey ya estaba limpio." -ForegroundColor Green
                }
            }
            "2" {
                $id = Read-Host "`nIntroduce el ID de la aplicación"
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Update-WingetPackage -Id $id -ChocoMapping $chocoMapping -ForceChocoList $forceChocoList -ChocoInstalled $chocoInstalled
                } else {
                    Write-Host "❌ ID no válido." -ForegroundColor Red
                }
            }
            "pwsh" {
                if ($downloadAsset) {
                    $downloadsFolder = Join-Path $env:USERPROFILE "Downloads"
                    $destinationPath = Join-Path $downloadsFolder $downloadAsset.name
                    Write-Host "`n📥 Descargando PowerShell..." -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $downloadAsset.browser_download_url -OutFile $destinationPath -UseBasicParsing
                    Write-Host "`n✨ Descarga completada en: $destinationPath" -ForegroundColor Green
                }
            }
            "desinstalar" {
                $id = Read-Host "`nIntroduce el ID de la aplicación a desinstalar"
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Write-Host "`n🗑️ Eliminando con WinGet..." -ForegroundColor Yellow
                    Start-Process winget -ArgumentList "uninstall --id $id" -NoNewWindow -Wait
                    
                    if ($chocoInstalled) {
                        $chocoName = if ($chocoMapping.ContainsKey($id)) { $chocoMapping[$id] } else { $id.ToLower() }
                        Write-Host "🗑️ Asegurando eliminación en Chocolatey..." -ForegroundColor Cyan
                        Start-Process choco -ArgumentList "uninstall $chocoName -y" -NoNewWindow -Wait
                    }
                }
            }
            "cancelar" {
                Write-Host "`n❌ Saliendo..." -ForegroundColor Yellow
                $pausarAlFinal = $false
                return 
            }
            default {
                Write-Host "`n❌ Opción no válida." -ForegroundColor Red
            }
        }

        if ($pausarAlFinal) {
            Write-Host "`n👋 Presiona cualquier tecla para volver al menú..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }

    } while ($true)
}