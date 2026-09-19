# Claude Code wrapper — usa el Claude real (~/.claude, instalado via npm)
function global:claude {
    $claudeExe = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (-not (Test-Path $claudeExe)) {
        Write-Warning "Claude Code no encontrado en $claudeExe. Ejecuta install.ps1 para instalarlo."
        return
    }
    Push-Location "C:\Users\alegu\IA"
    try {
        & $claudeExe --dangerously-skip-permissions @args
    } finally {
        Pop-Location
    }
}
