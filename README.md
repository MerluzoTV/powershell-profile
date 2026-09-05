# PowerShell 7 Profile & Dotfiles

![PowerShell](https://img.shields.io/badge/PowerShell-7-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%2011-0078D6?style=flat-square&logo=windows11&logoColor=white)
![Prompt](https://img.shields.io/badge/Prompt-Oh%20My%20Posh-ff69b4?style=flat-square)
![Shell](https://img.shields.io/badge/Navigation-Zoxide-blueviolet?style=flat-square)

Mi perfil de **PowerShell 7** y la configuración completa de mi terminal de Windows:
prompt (Oh My Posh), navegación (Zoxide), listados (Eza), búsqueda (fd/fzf), atajos
de Git y un script único que reconstruye todo el entorno tras formatear.

---

## Instalación

Tras formatear, el camino rápido es un solo script:

```powershell
# 1. PowerShell 7 (si no lo tienes)
winget install --id Microsoft.PowerShell --source winget

# 2. Copia Restore-PowerShellProfile.ps1 y Restaurar-PowerShell.cmd a cualquier
#    carpeta (Descargas, USB...) y haz doble clic en Restaurar-PowerShell.cmd
#    o ejecuta:
pwsh -ExecutionPolicy Bypass -File Restore-PowerShellProfile.ps1
```

El script:

- Clona (o actualiza con `git pull`) este repo **siempre** en la ruta fija
  `$env:OneDrive\Dokumente\PowerShell`, sin importar desde qué carpeta se lanzó —
  evita que `$PROFILE` apunte a otro sitio mientras OneDrive aún redirige
  "Documentos" tras formatear.
- Ejecuta `install.ps1`: oh-my-posh, zoxide, eza, fd, fzf, tipografía, módulos de
  PowerShell, Node.js/npm, Claude Code, Python + pip — y al final **verifica** que
  todo quedó operativo (comandos, módulos, `$PROFILE`, rutas rotas o duplicadas en
  PATH).
- Deja un "puente" en `$PROFILE` si hiciera falta.
- Instala VS Code si falta.
- Configura Windows Terminal: fuente `JetBrainsMonoNL NFM` y perfil de
  PowerShell por defecto (con copia de seguridad de `settings.json` antes de tocarlo).

Restart de Windows Terminal al terminar y listo.

<details>
<summary>Instalación manual, paso a paso (si el script automático falla)</summary>

```powershell
# 1. PowerShell 7
winget install --id Microsoft.PowerShell --source winget

# 2. Clonar en ruta fija -- NO uses cd (Split-Path $PROFILE): justo tras
#    formatear, $PROFILE puede apuntar temporalmente a otro sitio mientras
#    OneDrive redirige "Documentos".
git clone <URL_DE_TU_REPOSITORIO_DE_GITHUB> "$env:OneDrive\Dokumente\PowerShell"

# Comprueba que $PROFILE ya apunta ahí
$PROFILE

# Si Test-Path $PROFILE da False, o apunta a otra carpeta, crea el "puente" a mano:
if (-not (Test-Path (Split-Path $PROFILE))) { New-Item -ItemType Directory -Path (Split-Path $PROFILE) -Force }
". `"$env:OneDrive\Dokumente\PowerShell\Microsoft.PowerShell_profile.ps1`"" | Set-Content $PROFILE
. $PROFILE

# 3. Instalador de dependencias
cd "$env:OneDrive\Dokumente\PowerShell"
./install.ps1
```

**Paso 4 — Windows Terminal a mano:** `Ctrl + ,` > perfil PowerShell > Apariencia >
fuente `JetBrainsMonoNL NFM`. Fija PowerShell 7 como perfil predeterminado.

</details>

---

## Qué incluye

- **Oh My Posh** — prompt con tema personalizado Cobalt2 (`cobalt2.omp.json`, en este repo).
- **Zoxide (`z`)** — navegador inteligente de directorios por frecuencia de uso.
- **Eza** — reemplazo moderno de `ls`/`ll`/`la`/`lt` con iconos.
- **fd / ff** — búsqueda ultra rápida de archivos y carpetas en todos los discos (binario `fd.exe`, de `sharkdp/fd`).
- **Módulos de PowerShell** — `Terminal-Icons`, `posh-git`, `PSFzf`, `PSScriptAnalyzer`, `z`. `PSFzf` además necesita `fzf.exe` (`junegunn/fzf`).
- **Node.js / npm + Claude Code** — `claude` (definido en `CTTcustom.ps1`) es un wrapper al Claude Code real, siempre con `--dangerously-skip-permissions`.
- **Python (versión estable) + pip.**
- **Gestión de paquetes** — automatizaciones cruzadas con `WinGet` y `Chocolatey`.

Todo lo anterior lo instala y verifica automáticamente `install.ps1`.

> **Nota de diseño:** el tema de Oh My Posh se resuelve dinámicamente desde la
> carpeta del propio repo (`$PSScriptRoot/cobalt2.omp.json`) — a propósito **no**
> se fija `$env:POSH_THEME` de forma permanente, para que no se rompa si algún día
> mueves o reclonas el repo en otra ruta.

---

## Comandos rápidos

| Comando | Acción |
| :--- | :--- |
| `update` | Menú interactivo para actualizar apps (WinGet/Choco) y el propio PWSH 7. |
| `lazyg "msg"` | Add, commit y push estricto del proyecto Git en el que estés parado. |
| `lazyp "msg"` | Copia de seguridad automática de estos dotfiles a GitHub (con confirmación de seguridad). |
| `perfil` | Abre toda esta carpeta de configuración directamente en VS Code. |
| `myip` | Muestra tu IP de red local y tu IP pública. |
| `admin` | Lanza una pestaña nueva de la terminal con permisos de Administrador. |
| `claude` | Wrapper de Claude Code, siempre con `--dangerously-skip-permissions` (definido en `CTTcustom.ps1`). |

---

## Troubleshooting

<details>
<summary><b>Ninguna consola abre tras la restauración (cmd.exe incluido) — resuelto el 22/08/2026</b></summary>

**Síntoma:** tras probar el paso de Windows Terminal de `Restore-PowerShellProfile.ps1`,
dejaron de abrir *todas* las consolas — Windows Terminal y `cmd.exe` por igual.

**Descartado:** el diff aplicado a `settings.json` (solo añade el campo `font`,
`defaultProfile` no cambia) — JSON válido, y el perfil de PowerShell cargaba sin
error en `pwsh -NoProfile`.

**Causa real:** el paquete Appx `Microsoft.WindowsTerminal` estaba dañado
(`HRESULT 0x80073D02`, "in use"), y Windows delegaba *todas* las consolas a ese
motor vía "Aplicación de terminal predeterminada"
(`HKCU\Console\%%Startup\DelegationConsole` / `DelegationTerminal`).

**Fix que funcionó:**

```powershell
# 1. Abre cmd.exe (si Windows Terminal no abre nada, cmd normalmente sí).
# 2. Repara el paquete Appx desde ahí:
pwsh -NoProfile -Command "Get-AppxPackage *WindowsTerminal* | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (\"$($_.InstallLocation)\AppXManifest.xml\") }"

# 3. Configuración de Windows > "Aplicación de terminal predeterminada":
#    alterna el motor (Windows Terminal <-> Host de consola de Windows) una o
#    dos veces hasta que las consolas vuelvan a abrir con normalidad.
```

**Regla de oro:** si tras una restauración las consolas dejan de abrir, el primer
sospechoso es la "aplicación de terminal predeterminada" de Windows (paquete Appx
`Microsoft.WindowsTerminal`) — **no** el perfil ni este repo.
`Restore-PowerShellProfile.ps1` ya imprime un aviso de esto justo después de tocar
`settings.json`.

</details>

---

## Soporte

Repo personal — si te sirve de plantilla para el tuyo, adelante.
