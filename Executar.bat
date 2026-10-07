@echo off
:: Lancador da Otimizacao Windows 11 v3
:: Abre o script PowerShell como Administrador, sem alterar a politica de execucao do sistema.
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Solicitando permissao de Administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%~dp0Otimizar-Win11-v3.ps1" (
    echo Arquivo Otimizar-Win11-v3.ps1 nao encontrado na mesma pasta deste .bat.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Otimizar-Win11-v3.ps1"
