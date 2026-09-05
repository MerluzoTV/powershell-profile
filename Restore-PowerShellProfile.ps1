# ==============================================================================
# Script:      Restore-PowerShellProfile.ps1
# Descripcion: Restauracion completa del entorno PowerShell 7 de Alex tras
#              formatear/reinstalar Windows. Clona el repositorio de GitHub
#              SIEMPRE en la misma ruta fija dentro de OneDrive (sin importar
#              desde que carpeta se ejecute este script), instala todas las
#              dependencias via install.ps1, deja el perfil funcionando
#              aunque OneDrive todavia no haya terminado de sincronizar
#              "Documentos", y configura Windows Terminal (fuente + perfil
#              por defecto) igual que lo tienes ahora.
#
# Repositorio: https://github.com/alexmarzo81/powershell-profile
# ==============================================================================

[CmdletBinding()]
param(
    # URL del repositorio (por si algun dia cambias de nombre de usuario/repo)
    [string]$RepoUrl = "https://github.com/alexmarzo81/powershell-profile.git",

    # Ruta de respaldo si OneDrive no aparece tras esperar (ver -OneDriveTimeoutSec)
    [string]$FallbackPath = (Join-Path $HOME "Documents\PowerShell"),

    # Cuanto esperar (segundos) a que OneDrive este listo antes de usar la ruta de respaldo
    [int]$OneDriveTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    XX  $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 0. Asegurar que corremos en PowerShell 7 (pwsh), reejecutando si hace falta
# -----------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Step "Detectado Windows PowerShell clasico. Instalando PowerShell 7..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err2 "winget no esta disponible en este sistema. Instala 'App Installer' desde la Microsoft Store y vuelve a ejecutar este script."
        exit 1
    }
    winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
    $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) {
        Write-Ok "PowerShell 7 instalado. Reabriendo el script dentro de PowerShell 7..."
        Start-Process -FilePath $pwshPath -ArgumentList "-NoExit", "-ExecutionPolicy Bypass", "-File", "`"$PSCommandPath`""
        exit 0
    } else {
        Write-Warn2 "No se encontro pwsh.exe tras la instalacion. Cierra esta ventana, abre 'PowerShell 7' desde el menu de inicio y vuelve a ejecutar este script."
        exit 1
    }
}

Write-Host ""
Write-Host "########################################################" -ForegroundColor Magenta
Write-Host "#   RESTAURACION DEL ENTORNO POWERSHELL 7 DE ALEX     #" -ForegroundColor Magenta
Write-Host "########################################################" -ForegroundColor Magenta

# -----------------------------------------------------------------------------
# 1. Asegurar Git (necesario para clonar)
# -----------------------------------------------------------------------------
Write-Step "Comprobando Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn2 "Git no encontrado. Instalando..."
    winget install --id Git.Git --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err2 "No se pudo preparar Git automaticamente. Instalalo manualmente y vuelve a ejecutar este script."
    exit 1
}
Write-Ok "Git disponible."

# -----------------------------------------------------------------------------
# 2. Determinar la carpeta MAESTRA de forma fiable — SIEMPRE la misma ruta fija,
#    sin importar desde donde se ejecute este script (Descargas, Escritorio...).
#    Preferimos OneDrive\Dokumente\PowerShell. Si OneDrive tarda en aparecer
#    tras el formateo, esperamos un poco antes de rendirnos.
# -----------------------------------------------------------------------------
Write-Step "Localizando OneDrive..."
$waited = 0
while (-not $env:OneDrive -and $waited -lt $OneDriveTimeoutSec) {
    Write-Warn2 "OneDrive todavia no esta listo (¿has iniciado sesion?). Reintentando en 5s... ($waited/$OneDriveTimeoutSec s)"
    Start-Sleep -Seconds 5
    $waited += 5
    # refrescar variables de entorno de usuario por si OneDrive acaba de definirlas
    $env:OneDrive = [System.Environment]::GetEnvironmentVariable("OneDrive","User")
}

if ($env:OneDrive) {
    $MasterDir = Join-Path $env:OneDrive "Dokumente\PowerShell"
    Write-Ok "OneDrive detectado: $env:OneDrive"
} else {
    $MasterDir = $FallbackPath
    Write-Warn2 "OneDrive no disponible tras esperar. Usando ruta de respaldo: $MasterDir"
    Write-Warn2 "Cuando OneDrive este listo, mueve manualmente esta carpeta dentro de OneDrive y vuelve a ejecutar el script."
}
Write-Host "    Carpeta maestra (fija, no depende de donde se ejecuta este script): $MasterDir" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# 3. Clonar o actualizar el repositorio en la carpeta maestra.
#    Crea cualquier directorio padre que falte antes de clonar.
# -----------------------------------------------------------------------------
Write-Step "Preparando el repositorio en $MasterDir..."
if (Test-Path (Join-Path $MasterDir ".git")) {
    Write-Ok "Ya existe un repositorio ahi. Actualizando con git pull..."
    Push-Location $MasterDir
    git pull
    Pop-Location
} elseif (Test-Path $MasterDir) {
    $items = Get-ChildItem $MasterDir -Force -ErrorAction SilentlyContinue
    if ($items.Count -gt 0) {
        Write-Err2 "La carpeta '$MasterDir' ya existe y tiene contenido, pero no es un repositorio git."
        Write-Err2 "Revisala a mano (podria ser un perfil viejo) y vuelve a ejecutar el script. No se ha tocado nada."
        exit 1
    } else {
        git clone $RepoUrl $MasterDir
    }
} else {
    New-Item -ItemType Directory -Path (Split-Path $MasterDir) -Force -ErrorAction SilentlyContinue | Out-Null
    git clone $RepoUrl $MasterDir
}
Write-Ok "Repositorio listo en $MasterDir"

$MasterProfile = Join-Path $MasterDir "Microsoft.PowerShell_profile.ps1"
if (-not (Test-Path $MasterProfile)) {
    Write-Err2 "No se encuentra Microsoft.PowerShell_profile.ps1 dentro del repositorio clonado. Revisa el repo manualmente."
    exit 1
}

# -----------------------------------------------------------------------------
# 4. Ejecutar el instalador de dependencias del propio repo: oh-my-posh, zoxide,
#    eza, fd, fzf, modulos de PowerShell, Node.js/npm, Claude Code, Python/pip.
# -----------------------------------------------------------------------------
$repoInstaller = Join-Path $MasterDir "install.ps1"
if (Test-Path $repoInstaller) {
    Write-Step "Ejecutando install.ps1 del repositorio (todas las dependencias)..."
    & $repoInstaller
} else {
    Write-Warn2 "No se encontro install.ps1 en el repo, me lo salto."
}

# -----------------------------------------------------------------------------
# 5. El "puente": si $PROFILE de esta sesion NO es ya el perfil maestro,
#    dejamos ahi un archivo puente que carga el maestro por ruta fija.
#    Esto es lo que evita cargar el perfil equivocado mientras OneDrive
#    termina de sincronizar "Documentos" tras un formateo.
# -----------------------------------------------------------------------------
Write-Step "Comprobando que `$PROFILE encuentre el perfil maestro..."

function Set-ProfileBridge($profilePath, $masterPath) {
    $resolvedProfile = [System.IO.Path]::GetFullPath($profilePath)
    $resolvedMaster   = [System.IO.Path]::GetFullPath($masterPath)

    if ($resolvedProfile -eq $resolvedMaster) {
        Write-Ok "$profilePath ya ES el perfil maestro. Nada que hacer."
        return
    }

    $bridgeContent = @"
# --- Puente automatico generado por Restore-PowerShellProfile.ps1 ---
# Este archivo NO es el perfil real. Solo carga el perfil maestro que
# vive en tu carpeta de OneDrive, para que funcione aunque Windows este
# resolviendo `$PROFILE hacia otra carpeta de Documentos.
`$masterProfile = "$masterPath"
if (Test-Path `$masterProfile) {
    . `$masterProfile
} else {
    Write-Warning "No se encontro el perfil maestro en `$masterProfile. Ejecuta Restore-PowerShellProfile.ps1 de nuevo."
}
"@

    $profileDir = Split-Path $profilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing -notmatch 'Puente automatico generado por Restore-PowerShellProfile') {
            $backupPath = "$profilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $profilePath $backupPath
            Write-Warn2 "Ya existia un perfil distinto en $profilePath. Copia de seguridad: $backupPath"
        }
    }

    Set-Content -Path $profilePath -Value $bridgeContent -Encoding UTF8
    Write-Ok "Puente creado en $profilePath -> $masterPath"
}

Set-ProfileBridge -profilePath $PROFILE -masterPath $MasterProfile

# -----------------------------------------------------------------------------
# 6. Extra: VS Code (usado por el atajo 'perfil'). No lo instala install.ps1
#    porque no es una dependencia del perfil en si, solo una comodidad.
# -----------------------------------------------------------------------------
Write-Step "Comprobando Visual Studio Code (usado por el atajo 'perfil')..."
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Write-Warn2 "No encontrado. Instalando..."
    winget install --id Microsoft.VisualStudioCode --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
} else {
    Write-Ok "VS Code ya estaba instalado."
}

# -----------------------------------------------------------------------------
# 7. Windows Terminal: fuente Nerd Font + PowerShell 7 como perfil por defecto,
#    igual que lo tienes configurado ahora mismo. Hace copia de seguridad de
#    settings.json antes de tocarlo.
# -----------------------------------------------------------------------------
Write-Step "Configurando Windows Terminal (fuente Nerd Font + PowerShell 7 por defecto)..."
try {
    $wtSettingsPath = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wtSettingsPath) {
        $json = Get-Content $wtSettingsPath.FullName -Raw | ConvertFrom-Json
        $pwshProfile = $json.profiles.list | Where-Object { $_.commandline -match 'pwsh\.exe$' -or $_.source -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
        if ($pwshProfile) {
            if (-not $pwshProfile.font) { $pwshProfile | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force }
            $pwshProfile.font | Add-Member -NotePropertyName face -NotePropertyValue "JetBrainsMonoNL NFM" -Force
            $json.defaultProfile = $pwshProfile.guid
            $backupSettings = "$($wtSettingsPath.FullName).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $wtSettingsPath.FullName $backupSettings
            ($json | ConvertTo-Json -Depth 20) | Set-Content $wtSettingsPath.FullName -Encoding UTF8
            Write-Ok "Windows Terminal configurado (copia de seguridad: $backupSettings)"
        } else {
            Write-Warn2 "No se encontro el perfil de PowerShell 7 en Windows Terminal todavia (normal si es la primera vez que se abre). Configuralo a mano la primera vez."
        }
    } else {
        Write-Warn2 "No se encontro settings.json de Windows Terminal (¿esta instalado desde la Store?). Configuralo a mano."
    }
} catch {
    Write-Warn2 "No se pudo configurar Windows Terminal automaticamente: $($_.Exception.Message)"
    Write-Warn2 "Hazlo a mano: Ctrl+, > perfil PowerShell > Apariencia > fuente 'JetBrainsMonoNL NFM'."
}

# -----------------------------------------------------------------------------
# Nota (incidente 22/08/2026): si tras ejecutar este script las consolas dejan
# de abrir -- cmd.exe incluido, no solo Windows Terminal -- el culpable casi
# seguro NO es este script ni el perfil. El diff que se aplica a settings.json
# arriba es minimo (solo el campo font, defaultProfile puede quedar igual) y
# no es la causa. Lo que paso esa vez: el paquete Appx Microsoft.WindowsTerminal
# estaba danado (HRESULT 0x80073D02) y Windows delegaba TODAS las consolas a
# ese motor via "Aplicacion de terminal predeterminada"
# (HKCU\Console\%%Startup\DelegationConsole / DelegationTerminal).
#
# Lo que lo arreglo ese dia:
#   1. Abre cmd.exe (si Windows Terminal no abre nada, cmd normalmente si).
#   2. Repara el paquete Appx desde ahi:
#      pwsh -NoProfile -Command "Get-AppxPackage *WindowsTerminal* | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (\"$($_.InstallLocation)\AppXManifest.xml\") }"
#   3. Configuracion de Windows > Aplicacion de terminal predeterminada:
#      alterna el motor (Windows Terminal <-> Host de consola de Windows) una
#      vez o dos hasta que las consolas vuelvan a abrir con normalidad.
# Detalle completo en el README, seccion Troubleshooting.
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "    NOTA: si alguna consola (cmd incluido) deja de abrir despues de esto," -ForegroundColor DarkGray
Write-Host "    no es cosa de este script -- revisa 'Aplicacion de terminal predeterminada'" -ForegroundColor DarkGray
Write-Host "    en Configuracion de Windows. Ver README > Troubleshooting." -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# 8. Resumen final.
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "########################################################" -ForegroundColor Magenta
Write-Host "#                  RESTAURACION COMPLETA               #" -ForegroundColor Magenta
Write-Host "########################################################" -ForegroundColor Magenta
Write-Host ""
Write-Host "Carpeta maestra : $MasterDir" -ForegroundColor White
Write-Host "Perfil activo   : $PROFILE" -ForegroundColor White
Write-Host ""
Write-Host "Cierra esta ventana y abre una nueva pestaña de Windows Terminal para ver el resultado." -ForegroundColor Yellow
