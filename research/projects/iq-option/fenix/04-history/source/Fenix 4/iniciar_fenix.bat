@echo off
title FENIX TRADING BOT - AUTO LAUNCHER
color 0A
cls

REM --- CORRECCIÓN CRÍTICA PARA MODO ADMINISTRADOR ---
cd /d "%~dp0"

echo ================================================================
echo   SISTEMA FENIX - PREPARACION DE ENTORNO AUTOMATICA
echo ================================================================
echo.

set PYTHON_CMD=python

REM 1. VERIFICAR PYTHON
echo [1/3] Verificando si Python esta instalado...
python --version >nul 2>&1
if %errorlevel% equ 0 goto :FOUND_PYTHON

echo     [X] Comando 'python' no encontrado. Probando 'py'...
py --version >nul 2>&1
if %errorlevel% equ 0 (
    set PYTHON_CMD=py
    goto :FOUND_PYTHON
)

:INSTALL_PYTHON
echo     [X] Python NO detectado.
echo     [!] Descargando instalador...

powershell -Command "Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe' -OutFile 'python_installer.exe'"

if not exist python_installer.exe (
    echo     [ERROR] No se pudo descargar el instalador.
    pause
    exit
)

echo     [!] Ejecutando instalador...
echo     -----------------------------------------------------------
echo     IMPORTANTE: MARCA "Add Python 3.10 to PATH" y dale a "Install Now"
echo     -----------------------------------------------------------

python_installer.exe

echo.
echo     [ATENCION] Instalacion finalizada.
echo     POR FAVOR, CIERRE ESTA VENTANA Y VUELVA A EJECUTARLA.
if exist python_installer.exe del python_installer.exe
pause
exit

:FOUND_PYTHON
echo     [OK] Python encontrado: %PYTHON_CMD%

REM 2. INSTALAR LIBRERIAS
echo.
echo [2/3] Instalando librerias...
%PYTHON_CMD% -m pip install --upgrade pip >nul 2>&1
%PYTHON_CMD% -m pip install -r requirements.txt
if %errorlevel% neq 0 (
    echo     [ERROR] Fallo al instalar librerias.
    pause
    exit
)
echo     [OK] Librerias listas.

REM 3. EJECUTAR FENIX
echo.
echo [3/3] Iniciando FENIX...
echo ================================================================
%PYTHON_CMD% fenix.py

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Cierre inesperado.
)
pause