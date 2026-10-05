@echo off
title Instalador de Dependencias Fenix (REPARACION)
color 0A
echo ==========================================
echo   REPARANDO LIBRERIAS DE IA (Pandas/Joblib)
echo ==========================================
echo.
echo Verificando version de Python...
python --version
echo.
echo Instalando herramientas faltantes en el Python actual...
python -m pip install --upgrade pip
python -m pip install pandas scikit-learn joblib numpy colorama configobj iqoptionapi websocket-client
echo.
echo ==========================================
echo   REPARACION COMPLETADA
echo ==========================================
echo.
pause