@echo off
title Fenix Bot - Lanzador Remoto (Telegram)
:start
echo.
echo [+] Iniciando Fenix Bot en modo remoto...
python fenix.py --telegram
echo [-] Fenix Bot se ha detenido. Reiniciando en 10 segundos...
timeout /t 10
goto start