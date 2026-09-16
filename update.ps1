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
    # Puede haber DOS tablas con esta misma cabecera (pendientes normales +
    # "requiere targeting explícito" cuando hay pines de por medio) -- nos
    # quedamos con la primera (la de pendientes normales) y cogemos solo un
    # LineNumber escalar, si no `-1` revienta con un array.
    $headerLineObj = $lines | Select-String -Pattern '^Name\s+ID\s+Version' | Select-Object -First 1
    if (-not $headerLineObj) { return @() }
    $headerIndex = $headerLineObj.LineNumber - 1
    $headerLine = $lines[$headerIndex]
    $idStart = $headerLine.IndexOf("ID")
    $versionStart = $headerLine.IndexOf("Version")

    # Límite de la columna "Version instalada": donde empieza el siguiente
    # texto no-espacio tras la palabra "Version" en la cabecera -- así no
    # hace falta saber cómo se llama esa siguiente columna en cada idioma
    # ("Verfügbar", "Available"...).
    $versionEnd = -1
    if ($versionStart -ge 0) {
        $afterVersion = $headerLine.Substring([Math]::Min($versionStart + "Version".Length, $headerLine.Length))
        $gapMatch = [regex]::Match($afterVersion, '\S')
        if ($gapMatch.Success) { $versionEnd = $versionStart + "Version".Length + $gapMatch.Index }
    }

    $results = @()
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -match '^\d+\s') { break }   # línea de resumen ("3 Aktualisierungen...", "3 Pakete...")
        if ($line.Length -lt $idStart) { break }
        $endIdx = if ($versionStart -gt $idStart -and $versionStart -le $line.Length) { $versionStart } else { $line.Length }
        $id = $line.Substring($idStart, $endIdx - $idStart).Trim()
        if (-not $id) { continue }

        # Versión instalada sin ningún dígito ("Unknown"/"Unbekannt"/...) --
        # WinGet no puede determinarla de verdad, así que tampoco nosotros
        # podemos decidir con fiabilidad si hace falta actualizar. Mejor
        # omitirlo que arriesgarse a un reintento infinito o un "falso
        # update" (el caso real que nos pasó con OpenAL).
        $versionUpperBound = if ($versionEnd -gt $versionStart -and $versionEnd -le $line.Length) { $versionEnd } else { $line.Length }
        $versionText = if ($versionUpperBound -gt $versionStart) { $line.Substring($versionStart, $versionUpperBound - $versionStart).Trim() } else { "" }
        if ($versionText -and ($versionText -notmatch '\d')) { continue }

        $results += $id
    }
    return $results
}

# Intenta actualizar un paquete de WinGet con reintentos progresivos:
#   1) upgrade normal
#   2) si falla, desinstalar + instalar limpio -- cubre tanto "la nueva
#      versión usa otra tecnología de instalador" (WinGet rechaza el upgrade
#      in-place) como bloqueos de archivo puntuales que ya se liberaron
#   3) si sigue fallando, "winget repair" -- cubre paquetes que el propio
#      WinGet cree instalados pero tienen archivos rotos/incompletos
#   4) si sigue fallando, o el paquete está en $ForceChocoList, Chocolatey
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
        $p = Start-Process winget -ArgumentList "upgrade --id $Id --include-pinned --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
        $ok = ($p.ExitCode -eq 0)

        if (-not $ok) {
            Write-Host "  🔁 Upgrade normal falló. Reinstalando limpio ($Id)..." -ForegroundColor Yellow
            Uninstall-WingetPackageSafe -Id $Id | Out-Null
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

            if (-not $ok) {
                # Último recurso antes de Chocolatey: "winget repair" -- cubre
                # el caso real que nos pasó con EA app, instalado según su
                # propio registro pero con archivos rotos/incompletos, donde
                # upgrade/uninstall/install en bucle no arregla nada porque
                # el propio paquete se cree ya instalado.
                Write-Host "  🔧 Reintentando con reparación de WinGet ($Id)..." -ForegroundColor Yellow
                $p4 = Start-Process winget -ArgumentList "repair --id $Id --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
                $ok = ($p4.ExitCode -eq 0)
            }
        }
    }

    if (-not $ok -and $ChocoInstalled) {
        $chocoName = if ($ChocoMapping.ContainsKey($Id)) { $ChocoMapping[$Id] } else { $Id.ToLower() }
        $chocoHas = choco list --local-only --exact $chocoName 2>$null | Select-String -SimpleMatch $chocoName
        if ($chocoHas) {
            Write-Host "  🍫 Intentando con Chocolatey ('$chocoName')..." -ForegroundColor Cyan
            choco upgrade $chocoName -y
        } else {
            $motivo = if ($useChocoDirect) { "paquete WinGet marcado como roto para este ID" } else { "WinGet falló" }
            Write-Host "  ⚠️ No se pudo actualizar $Id ($motivo; '$chocoName' no está en Chocolatey)." -ForegroundColor Red
        }
    } elseif (-not $ok) {
        Write-Host "  ⚠️ No se pudo actualizar $Id (WinGet falló, sin Chocolatey de rescate)." -ForegroundColor Red
    }
}

# Desinstala un paquete WinGet SIN privilegios de administrador, vía el
# Programador de tareas con /rl limited -- fuerza un token sin elevar aunque
# quien crea la tarea sea admin (a diferencia del truco COM de
# Shell.Application, que en la práctica NO desactiva la elevación aquí).
# WinGet rechaza desinstalar paquetes de scope "user" desde un proceso admin.
function Uninstall-WingetPackageNonElevated {
    param([Parameter(Mandatory)][string]$Id)

    Write-Host "  ⏳ Reintentando sin privilegios de administrador (Programador de tareas)..." -ForegroundColor Yellow

    $taskName = "TempWingetUninstall_$PID"
    $scriptPath = Join-Path $env:TEMP "winget_uninstall_$PID.cmd"
    $logPath = Join-Path $env:TEMP "winget_uninstall_$PID.log"
    Remove-Item $scriptPath, $logPath -Force -ErrorAction SilentlyContinue

    $wingetPath = (Get-Command winget.exe).Source
    @"
@echo off
"$wingetPath" uninstall --id $Id --disable-interactivity > "$logPath" 2>&1
echo WINGET_DONE>> "$logPath"
"@ | Set-Content -Path $scriptPath -Encoding ASCII

    schtasks /create /tn $taskName /tr "`"$scriptPath`"" /sc once /st 00:00 /rl limited /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠️ No se pudo crear la tarea programada (código $LASTEXITCODE)." -ForegroundColor Red
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
        return
    }
    schtasks /run /tn $taskName | Out-Null

    $done = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ((Test-Path $logPath) -and ((Get-Content $logPath -Raw) -match "WINGET_DONE")) { $done = $true; break }
    }
    schtasks /delete /tn $taskName /f 2>$null | Out-Null
    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

    if (Test-Path $logPath) {
        Get-Content $logPath | Where-Object { $_ -notmatch "WINGET_DONE" -and $_.Trim() } | ForEach-Object { Write-Host "    $_" }
        Remove-Item $logPath -Force -ErrorAction SilentlyContinue
    }

    if (-not $done) {
        Write-Host "  ⚠️ La tarea no terminó a tiempo (30s)." -ForegroundColor Red
        return $false
    }

    Start-Sleep -Seconds 1
    $found = winget list --id $Id --exact 2>$null | Select-String -SimpleMatch $Id
    if ($found) {
        Write-Host "  ⚠️ No se pudo confirmar la desinstalación de $Id." -ForegroundColor Red
        return $false
    } else {
        Write-Host "  ✅ $Id desinstalado." -ForegroundColor Green
        return $true
    }
}

# Desinstala un paquete de WinGet con el mismo criterio en todo el script:
# intento elevado normal y, si falla (típico de apps de scope "user" bajo
# una sesión admin), fallback automático a Uninstall-WingetPackageNonElevated.
# Devuelve $true/$false según si el paquete queda desinstalado.
function Uninstall-WingetPackageSafe {
    param([Parameter(Mandatory)][string]$Id)

    $p = Start-Process winget -ArgumentList "uninstall --id $Id" -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -eq 0) { return $true }

    Write-Host "  🔁 Desinstalación elevada falló (probable app de scope 'user')..." -ForegroundColor Yellow
    return Uninstall-WingetPackageNonElevated -Id $Id
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

    # --- Pines de WinGet conocidos (`winget pin list`), estado 16.09.2026 ---
    # Apple.Bonjour: YA NO está pineado. Su "upgrade" en caliente falla
    # siempre (exit 43, cambia de tecnología de instalador), pero el
    # fallback de Update-WingetPackage (desinstalar+instalar limpio) lo
    # arregla solo -- probado en real. No hace falta pin ni entrada aquí.
    # CreativeTechnology.OpenAL: SIGUE pineado a propósito. Su instalador
    # nunca registra un "DisplayVersion" real (WinGet siempre lo ve como
    # "Unknown"), así que sin pin, CADA `update` lo reinstalaría de cero
    # aunque ya esté al día -- ruido infinito, no un fallo real. Cubierto
    # por Chocolatey (si está instalado ahí) vía $forceChocoList/mapping.
    # ElectronicArts.EADesktop: YA NO está pineado. Su instalador puede
    # quedarse en un estado "instalado según su propio registro, pero con
    # archivos rotos/incompletos" (nos pasó en real) -- upgrade/uninstall/
    # install normales no lo arreglan, solo "winget repair" (paso 3 del
    # fallback de Update-WingetPackage, añadido justo por este caso).
    #
    # Apple.Bonjour NO va aquí -- "apple-bonjour" no existe en Chocolatey
    # (comprobado), así que forzarlo solo llevaba a un fallo garantizado.
    # Con --include-pinned en Update-WingetPackage, un intento explícito por
    # ID (opción 2) ya prueba WinGet de verdad en vez de saltárselo.
    $forceChocoList = @("CreativeTechnology.OpenAL")

    $chocoMapping = @{
        "CreativeTechnology.OpenAL" = "openal"
        "OBSProject.OBSStudio"      = "obs-studio"
    }

    $sep = "─" * 62

    do {
        Clear-Host
        Write-Host ""
        Write-Host "  🛠️  update — WinGet · Chocolatey · PowerShell" -ForegroundColor Magenta
        Write-Host "  $sep" -ForegroundColor DarkGray
        Write-Host "  🔍 Sincronizando repositorios y buscando actualizaciones..." -ForegroundColor Yellow
        winget source update | Out-Null
        winget upgrade --include-unknown

        # --- COMPROBACIÓN DINÁMICA DE CHOCOLATEY ---
        $chocoInstalled = [bool](Get-Command choco -ErrorAction SilentlyContinue)
        $chocoOutdatedPackages = $false

        if ($chocoInstalled) {
            try {
                $chocoOutdated = choco outdated 2>$null

                if ($chocoOutdated -match "determined 0 package" -or $null -eq $chocoOutdated) {
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

        Write-Host "  $sep" -ForegroundColor DarkGray
        Write-Host "  📋 ¿Cómo deseas proceder?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    [1] " -NoNewline -ForegroundColor DarkGray; Write-Host "Actualizar TODO de golpe (aceptando licencias)" -ForegroundColor Green
        Write-Host "    [2] " -NoNewline -ForegroundColor DarkGray; Write-Host "Actualizar una aplicación específica por su ID" -ForegroundColor Green

        if ($pwshNeedUpdate) {
            Write-Host "    [3] " -NoNewline -ForegroundColor DarkGray; Write-Host "Descargar instalador (.msi) de la nueva versión de PowerShell" -ForegroundColor Magenta
            Write-Host "    [4] " -NoNewline -ForegroundColor DarkGray; Write-Host "Desinstalar una aplicación por su ID" -ForegroundColor Yellow
            Write-Host "    [5] " -NoNewline -ForegroundColor DarkGray; Write-Host "Cancelar y salir" -ForegroundColor Red
            $maxOpcion = 5
        } else {
            Write-Host "    [3] " -NoNewline -ForegroundColor DarkGray; Write-Host "Desinstalar una aplicación por su ID" -ForegroundColor Yellow
            Write-Host "    [4] " -NoNewline -ForegroundColor DarkGray; Write-Host "Cancelar y salir" -ForegroundColor Red
            $maxOpcion = 4
        }
        Write-Host "  $sep" -ForegroundColor DarkGray

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
                    try {
                        Invoke-WebRequest -Uri $downloadAsset.browser_download_url -OutFile $destinationPath -UseBasicParsing
                        Write-Host "`n✨ Descarga completada en: $destinationPath" -ForegroundColor Green
                    } catch {
                        Write-Host "`n⚠️ Descarga fallida: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
            "desinstalar" {
                $id = Read-Host "`nIntroduce el ID de la aplicación a desinstalar"
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Write-Host "`n🗑️ Eliminando con WinGet..." -ForegroundColor Yellow
                    Uninstall-WingetPackageSafe -Id $id | Out-Null

                    if ($chocoInstalled) {
                        $chocoName = if ($chocoMapping.ContainsKey($id)) { $chocoMapping[$id] } else { $id.ToLower() }
                        $chocoHas = choco list --local-only --exact $chocoName 2>$null | Select-String -SimpleMatch $chocoName
                        if ($chocoHas) {
                            Write-Host "🗑️ Asegurando eliminación en Chocolatey..." -ForegroundColor Cyan
                            Start-Process choco -ArgumentList "uninstall $chocoName -y" -NoNewWindow -Wait
                        }
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