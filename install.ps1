# ==============================================================================
# Script: install.ps1
# Descripción: Despliegue automático y restauración del entorno PowerShell 7
# ==============================================================================

Write-Host "🚀 Iniciando instalación automatizada del entorno..." -ForegroundColor Cyan

# 1. Asegurar que estamos en PowerShell 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "⚠️ Se detectó Windows PowerShell clásico. Instalando PowerShell 7 vía WinGet..." -ForegroundColor Yellow
    winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
    Write-Host "✅ PowerShell 7 instalado. Por favor, cierra esta ventana y vuelve a ejecutar este script desde PWSH 7." -ForegroundColor Green
    exit
}

# Recarga el PATH desde el registro para que los binarios instalados por winget
# en este mismo script (oh-my-posh, fd, fzf...) se puedan invocar sin reabrir la sesión.
function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 2. Lista de herramientas esenciales para que el perfil funcione
$apps = @(
    @{ id = "JanDeDobbeleer.OhMyPosh"; name = "Oh My Posh"; cmd = "oh-my-posh" },
    @{ id = "ajeetdsouza.zoxide";     name = "Zoxide";       cmd = "zoxide" },
    @{ id = "eza.eza";                 name = "Eza (ls alternativo)"; cmd = "eza" }
)

Write-Host "`n📦 Comprobando e instalando dependencias del sistema..." -ForegroundColor Yellow
foreach ($app in $apps) {
    if (-not (Get-Command $app.cmd -ErrorAction SilentlyContinue)) {
        Write-Host "📥 Instalando $($app.name)..." -ForegroundColor Blue
        winget install --id $app.id --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
    } else {
        Write-Host "✅ $($app.name) ya está instalado." -ForegroundColor Green
    }
}

Update-SessionPath

# 3. Instalación de la fuente tipográfica obligatoria (Nerd Font para iconos)
Write-Host "`n🎨 Instalando JetBrainsMono Nerd Font (Requerida para iconos de la terminal)..." -ForegroundColor Yellow
winget install --id Git.Git --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null # Asegurar Git por si acaso
oh-my-posh font install jetbrainsmono | Out-Null

# 4. Módulos de PowerShell usados por el perfil
$modules = @("Terminal-Icons", "posh-git", "PSFzf", "PSScriptAnalyzer", "z")
Write-Host "`n📦 Comprobando e instalando módulos de PowerShell..." -ForegroundColor Yellow
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "📥 Instalando módulo $module..." -ForegroundColor Blue
        Install-Module -Name $module -Repository PSGallery -Scope CurrentUser -Force
    } else {
        Write-Host "✅ Módulo $module ya está instalado." -ForegroundColor Green
    }
}

# 5. fd.exe (usado por las funciones fd/ff del perfil) — comprobar con extensión,
#    "fd" a secas resuelve a la función del perfil, no al binario.
Write-Host "`n📦 Comprobando fd.exe..." -ForegroundColor Yellow
if (-not (Get-Command fd.exe -ErrorAction SilentlyContinue)) {
    Write-Host "📥 Instalando fd (sharkdp.fd)..." -ForegroundColor Blue
    winget install --id sharkdp.fd --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
} else {
    Write-Host "✅ fd.exe ya está instalado." -ForegroundColor Green
}

# 6. fzf.exe (binario requerido por el módulo PSFzf, no lo trae el módulo en sí)
Write-Host "`n📦 Comprobando fzf.exe..." -ForegroundColor Yellow
if (-not (Get-Command fzf.exe -ErrorAction SilentlyContinue)) {
    Write-Host "📥 Instalando fzf (junegunn.fzf)..." -ForegroundColor Blue
    winget install --id junegunn.fzf --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
} else {
    Write-Host "✅ fzf.exe ya está instalado." -ForegroundColor Green
}

Update-SessionPath

# 7. Node.js / npm (requerido para instalar y ejecutar Claude Code)
Write-Host "`n📦 Comprobando Node.js / npm..." -ForegroundColor Yellow
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "📥 Instalando Node.js LTS..." -ForegroundColor Blue
    winget install --id OpenJS.NodeJS.LTS --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
    Update-SessionPath
} else {
    Write-Host "✅ npm ya está instalado." -ForegroundColor Green
}

# 8. Claude Code CLI (usado por el wrapper `claude` de CTTcustom.ps1)
Write-Host "`n📦 Comprobando Claude Code CLI..." -ForegroundColor Yellow
$claudeExe = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
if (-not (Test-Path $claudeExe)) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "📥 Instalando @anthropic-ai/claude-code..." -ForegroundColor Blue
        npm install -g @anthropic-ai/claude-code | Out-Null
    } else {
        Write-Warning "npm no disponible, no se puede instalar Claude Code. Revisa el paso de Node.js."
    }
} else {
    Write-Host "✅ Claude Code ya está instalado." -ForegroundColor Green
}

# 9. Python (versión estable) + pip
Write-Host "`n📦 Comprobando Python..." -ForegroundColor Yellow
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "📥 Instalando Python (versión estable)..." -ForegroundColor Blue
    winget install --id Python.Python.3.13 --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
    Update-SessionPath
} else {
    Write-Host "✅ Python ya está instalado." -ForegroundColor Green
}
if ((Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command pip -ErrorAction SilentlyContinue)) {
    Write-Host "📥 Instalando pip..." -ForegroundColor Blue
    python -m ensurepip --upgrade | Out-Null
    Update-SessionPath
} else {
    Write-Host "✅ pip ya está instalado." -ForegroundColor Green
}

Update-SessionPath

Write-Host "`n✨ ¡Ecosistema base configurado con éxito!" -ForegroundColor Green
Write-Host "💡 RECUERDA: Configura tu Terminal de Windows para usar la fuente 'JetBrainsMonoNL NFM' para ver los iconos correctamente." -ForegroundColor Magenta

# ==============================================================================
# 10. Verificación final: comprueba que todo lo anterior quedó realmente
#     operativo (no solo "instalado") y detecta rutas rotas/duplicadas en PATH.
#     Solo informa -- no modifica nada, para no arriesgar el PATH del sistema.
# ==============================================================================
Write-Host "`n🔍 Verificación final del entorno..." -ForegroundColor Cyan
$issues = @()

Write-Host "`n  -- Comandos --" -ForegroundColor DarkCyan
$checkCommands = @("git", "pwsh", "oh-my-posh", "zoxide", "eza", "fd.exe", "fzf.exe", "npm", "node", "python", "pip", "code")
foreach ($cmd in $checkCommands) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "  ✅ $cmd" -ForegroundColor Green
    } else {
        Write-Host "  ❌ $cmd (no encontrado)" -ForegroundColor Red
        $issues += "Comando '$cmd' no se encuentra en PATH tras la instalación."
    }
}

Write-Host "`n  -- Módulos de PowerShell --" -ForegroundColor DarkCyan
foreach ($module in ($modules + "PSReadLine")) {
    if (Get-Module -ListAvailable -Name $module) {
        Write-Host "  ✅ $module" -ForegroundColor Green
    } else {
        Write-Host "  ❌ $module (no instalado)" -ForegroundColor Red
        $issues += "Módulo de PowerShell '$module' no está instalado."
    }
}

Write-Host "`n  -- Archivos clave del repo --" -ForegroundColor DarkCyan
$repoRoot = $PSScriptRoot
$keyFiles = @("cobalt2.omp.json", "Microsoft.PowerShell_profile.ps1")
foreach ($file in $keyFiles) {
    $path = Join-Path $repoRoot $file
    if (Test-Path $path) {
        Write-Host "  ✅ $file" -ForegroundColor Green
    } else {
        Write-Host "  ❌ $file (no existe en $repoRoot)" -ForegroundColor Red
        $issues += "Falta '$file' en la carpeta del repo ($repoRoot)."
    }
}
if (-not (Test-Path $claudeExe)) {
    Write-Host "  ❌ Claude Code CLI (no existe en $claudeExe)" -ForegroundColor Red
    $issues += "Claude Code CLI no se encuentra en '$claudeExe'."
} else {
    Write-Host "  ✅ Claude Code CLI" -ForegroundColor Green
}

Write-Host "`n  -- `$PROFILE --" -ForegroundColor DarkCyan
if (Test-Path $PROFILE) {
    Write-Host "  ✅ $PROFILE" -ForegroundColor Green
} else {
    Write-Host "  ❌ `$PROFILE no existe todavía en $PROFILE" -ForegroundColor Red
    $issues += "`$PROFILE ('$PROFILE') no existe -- ejecuta Restore-PowerShellProfile.ps1 para crear el puente."
}

Write-Host "`n  -- PATH: entradas rotas o duplicadas --" -ForegroundColor DarkCyan
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
$allEntries  = @($machinePath -split ';') + @($userPath -split ';') | Where-Object { $_ -and $_.Trim() }

$broken = $allEntries | Where-Object { -not (Test-Path $_) } | Select-Object -Unique
$duplicates = $allEntries | Group-Object { $_.TrimEnd('\').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group[0] }

if ($broken.Count -eq 0) {
    Write-Host "  ✅ Ninguna carpeta rota en PATH (Machine + User)" -ForegroundColor Green
} else {
    foreach ($b in $broken) {
        Write-Host "  ❌ Ruta rota en PATH: $b" -ForegroundColor Red
        $issues += "PATH contiene una carpeta que ya no existe: '$b'."
    }
}
if ($duplicates.Count -eq 0) {
    Write-Host "  ✅ Sin entradas duplicadas en PATH" -ForegroundColor Green
} else {
    foreach ($d in $duplicates) {
        Write-Host "  ⚠️  Entrada duplicada en PATH: $d" -ForegroundColor Yellow
        $issues += "PATH tiene la carpeta '$d' repetida más de una vez."
    }
}

Write-Host "`n═══════════════════════════════════════════" -ForegroundColor Magenta
if ($issues.Count -eq 0) {
    Write-Host "  🩺 VERIFICACIÓN: TODO OK, nada pendiente." -ForegroundColor Green
} else {
    Write-Host "  🩺 VERIFICACIÓN: $($issues.Count) cosa(s) que revisar:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "     - $_" -ForegroundColor Yellow }
    Write-Host "  (esto solo informa, no se ha modificado nada automáticamente)" -ForegroundColor DarkGray
}
Write-Host "═══════════════════════════════════════════" -ForegroundColor Magenta
