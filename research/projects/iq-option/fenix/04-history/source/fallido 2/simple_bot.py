from iqoptionapi.stable_api import IQ_Option
import time
import sys
from datetime import datetime
import configparser
import os
import logging
import random

# --- CONFIGURACIÓN DE SISTEMA ---
logging.getLogger("iqoptionapi").setLevel(logging.CRITICAL)
logging.getLogger().setLevel(logging.CRITICAL)

if not os.path.exists("config.txt"):
    print("Error: config.txt no encontrado")
    sys.exit()

config = configparser.ConfigParser()
config.read("config.txt")

EMAIL = config["GENERAL"]["email"]
PASSWORD = config["GENERAL"]["password"]
MERCADO = config["GENERAL"]["mercado"].lower()

# Parámetros de Estrategia
BB_PERIODO = int(config["SIGMA_REVERSION"]["bb_periodo"])
BB_DESVIACION = float(config["SIGMA_REVERSION"]["bb_desviacion"])
RSI_PERIODO = int(config["SIGMA_REVERSION"]["rsi_periodo"])
RSI_TECHO = int(config["SIGMA_REVERSION"]["rsi_techo"])
RSI_PISO = int(config["SIGMA_REVERSION"]["rsi_piso"])

# Lista de Activos Seguros (Mayores + OTC)
ACTIVOS = [
    "EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "EURGBP",
    "EURUSD-OTC", "GBPUSD-OTC", "USDCAD-OTC", "AUDUSD-OTC", "EURGBP-OTC"
]

def conectar():
    print("Conectando a IQ Option...")
    api = IQ_Option(EMAIL, PASSWORD)
    check, reason = api.connect()
    if check:
        print(">> Conexión exitosa.")
        api.change_balance("PRACTICE")
        return api
    else:
        print(f"Error de conexión: {reason}")
        sys.exit(1)

def calcular_indicadores(velas):
    try:
        cierres = [float(v['close']) for v in velas]
        if len(cierres) < BB_PERIODO: return None, None, None, None

        # RSI
        ganancias = []
        perdidas = []
        for i in range(1, len(cierres)):
            diferencia = cierres[i] - cierres[i-1]
            if diferencia > 0:
                ganancias.append(diferencia)
                perdidas.append(0)
            else:
                ganancias.append(0)
                perdidas.append(abs(diferencia))
        
        if len(ganancias) < RSI_PERIODO: return None, None, None, None

        avg_gain = sum(ganancias[-RSI_PERIODO:]) / RSI_PERIODO
        avg_loss = sum(perdidas[-RSI_PERIODO:]) / RSI_PERIODO
        
        if avg_loss == 0: rsi = 100
        else:
            rs = avg_gain / avg_loss
            rsi = 100 - (100 / (1 + rs))

        # Bollinger Bands
        sma = sum(cierres[-BB_PERIODO:]) / BB_PERIODO
        std_dev = (sum([(x - sma) ** 2 for x in cierres[-BB_PERIODO:]]) / BB_PERIODO) ** 0.5
        upper = sma + (BB_DESVIACION * std_dev)
        lower = sma - (BB_DESVIACION * std_dev)
        
        return rsi, upper, lower, cierres[-1]
    except:
        return None, None, None, None

def ejecutar_operacion(api, par, accion, importe):
    # Intentar Binaria
    if MERCADO in ['binario', 'automatico']:
        try:
            check, id_op = api.buy(importe, par, accion, 1)
            if check: return True, "Binaria", id_op
        except: pass
    
    # Intentar Digital
    if MERCADO in ['digital', 'automatico']:
        try:
            api.subscribe_strike_list(par, 1)
            check, id_op = api.buy_digital_spot(par, importe, accion, 1)
            if check: return True, "Digital", id_op
        except: pass
        
    return False, None, None

def main():
    api = conectar()
    
    try:
        importe = float(input("Importe por operación ($): "))
    except:
        importe = 1.0
        print("Usando importe por defecto: $1.0")

    # Operación de prueba automática al inicio (Sin estrategia, silenciosa)
    if ACTIVOS:
from iqoptionapi.stable_api import IQ_Option
import time
import sys
from datetime import datetime
import configparser
import os
import logging
import random
import csv

# --- CONFIGURACIÓN DE SISTEMA ---
logging.getLogger("iqoptionapi").setLevel(logging.CRITICAL)
logging.getLogger().setLevel(logging.CRITICAL)

if not os.path.exists("config.txt"):
    print("Error: config.txt no encontrado")
    sys.exit()

config = configparser.ConfigParser()
config.read("config.txt")

EMAIL = config["GENERAL"]["email"]
PASSWORD = config["GENERAL"]["password"]
MERCADO = config["GENERAL"]["mercado"].lower()

# Parámetros de Estrategia
BB_PERIODO = int(config["SIGMA_REVERSION"]["bb_periodo"])
BB_DESVIACION = float(config["SIGMA_REVERSION"]["bb_desviacion"])
RSI_PERIODO = int(config["SIGMA_REVERSION"]["rsi_periodo"])
RSI_TECHO = int(config["SIGMA_REVERSION"]["rsi_techo"])
RSI_PISO = int(config["SIGMA_REVERSION"]["rsi_piso"])

# Lista de Activos OTC (Extraída del protocolo)
ACTIVOS = [
    "EURUSD-OTC", "GBPUSD-OTC", "USDJPY-OTC", "USDCAD-OTC", "AUDUSD-OTC", "EURGBP-OTC",
    "USDCHF-OTC", "NZDUSD-OTC", "GBPJPY-OTC", "EURJPY-OTC", "GBPCAD-OTC", "EURCAD-OTC",
    "AUDCAD-OTC", "CADJPY-OTC", "EURAUD-OTC", "GBPAUD-OTC", "GBPCHF-OTC", "AUDNZD-OTC",
    "NZDJPY-OTC", "AUDCHF-OTC", "CADCHF-OTC", "EURCHF-OTC", "EURNZD-OTC", "GBPNZD-OTC",
    "AUDJPY-OTC", "CHFJPY-OTC", "NZDCAD-OTC", "NZDCHF-OTC", "USDNOK-OTC", "USDSEK-OTC",
    "USDSGD-OTC", "USDHKD-OTC", "USDINR-OTC", "USDMXN-OTC", "USDBRL-OTC", "USDTRY-OTC",
    "USDZAR-OTC", "USDTHB-OTC", "USDCOP-OTC", "XAUUSD-OTC", "XAGUSD-OTC", "USOUSD-OTC",
    "UKOUSD-OTC", "BTCUSD-OTC", "ETHUSD-OTC", "LTCUSD-OTC", "XRPUSD-OTC", "BCHUSD-OTC",
    "DASHUSD-OTC", "EOSUSD-OTC", "TRON-OTC", "ETCUSD-OTC", "ZECUSD-OTC", "XLMUSD-OTC",
    "ADAUSD-OTC", "DOGEUSD-OTC", "SHIBUSD-OTC", "SOLUSD-OTC", "DOTUSD-OTC", "AVAXUSD-OTC",
    "MATICUSD-OTC", "LINKUSD-OTC", "UNIUSD-OTC", "ATOMUSD-OTC", "ALGOUSD-OTC", "NEARUSD-OTC",
    "ICPUSD-OTC", "FILUSD-OTC", "APEUSD-OTC", "AXSUSD-OTC", "SANDUSD-OTC", "MANAUSD-OTC",
    "THETAUSD-OTC", "XTZUSD-OTC", "EOSUSD-OTC", "AAVEUSD-OTC", "QNTUSD-OTC", "GRTUSD-OTC",
    "SNXUSD-OTC", "NEOUSD-OTC", "KSMUSD-OTC", "CHZUSD-OTC", "BATUSD-OTC", "ENJUSD-OTC",
    "ZILUSD-OTC", "WAVESUSD-OTC", "DASHUSD-OTC", "COMPUSD-OTC", "YFIUSD-OTC", "MKRUSD-OTC",
    "SUSHIUSD-OTC", "1INCHUSD-OTC", "RUNEUSD-OTC", "CELOUSD-OTC", "HOTUSD-OTC", "BATUSD-OTC",
    "ARUSD-OTC", "QTUMUSD-OTC", "OMGUSD-OTC", "ZRXUSD-OTC", "ONTUSD-OTC", "ICXUSD-OTC",
    "IOSTUSD-OTC", "KAVAUSD-OTC", "SCUSD-OTC", "RVNUSD-OTC", "LSKUSD-OTC", "ZENUSD-OTC",
    "RENUSD-OTC", "DGBUSD-OTC", "NANOUSD-OTC", "DENTUSD-OTC", "BTTUSD-OTC", "XVGUSD-OTC",
    "IOSTUSD-OTC", "SNTUSD-OTC", "MCOUSD-OTC", "CVCUSD-OTC", "STORJUSD-OTC", "GNTUSD-OTC",
    "REPUSD-OTC", "SNTUSD-OTC", "MCOUSD-OTC", "CVCUSD-OTC", "STORJUSD-OTC", "GNTUSD-OTC",
    "REPUSD-OTC", "US30-OTC", "SP500-OTC", "USNDAQ100-OTC", "US2000-OTC", "GER30-OTC",
    "UK100-OTC", "FR40-OTC", "EU50-OTC", "JP225-OTC", "HK33-OTC", "AUS200-OTC", "SP35-OTC",
    "APPLE
        # Ejecuta una operación aleatoria en el primer activo para verificar conexión
        ejecutar_operacion(api, ACTIVOS[0], random.choice(["call", "put"]), importe)

    print(f"\nIniciando escaneo en {len(ACTIVOS)} activos...")
    print("Estrategia: RSI + Bollinger Bands (Reversión)")
    print("Presiona Ctrl+C para detener.\n")

    while True:
        for par in ACTIVOS:
            try:
                # Obtener velas (30 es suficiente para BB20 y RSI14)
                velas = api.get_candles(par, 60, 30, time.time())
                
                if not velas:
                    continue

                rsi, upper, lower, precio = calcular_indicadores(velas)
                
                if rsi is None:
                    continue

                # Lógica de Trading
                accion = None
                if precio > upper and rsi > RSI_TECHO:
                    accion = "put"
                elif precio < lower and rsi < RSI_PISO:
                    accion = "call"

                # Salida en consola (Sobrescribir línea para limpieza)
                hora = datetime.now().strftime("%H:%M:%S")
                estado = f"RSI: {rsi:.1f} | Precio: {precio:.5f}"
                sys.stdout.write(f"\r[{hora}] {par:<12} | {estado:<30} | Buscando...")
                sys.stdout.flush()

                if accion:
                    print(f"\n[{hora}] ¡SEÑAL ENCONTRADA en {par}! -> {accion.upper()}")
                    exito, tipo, id_op = ejecutar_operacion(api, par, accion, importe)
                    
                    if exito:
                        print(f">> Operación {tipo} Exitosa. ID: {id_op}")
                        # Pausa para evitar múltiples entradas en la misma vela
                        time.sleep(60) 
                    else:
                        print(f">> Error al abrir operación.")
            
            except Exception as e:
                # Ignorar errores de conexión momentáneos para no ensuciar consola
                pass
            
            # Pequeña pausa entre activos para no saturar CPU/API
            time.sleep(0.2)

        # Verificar conexión cada ciclo completo
        if not api.check_connect():
            print("\nReconectando...")
            api.connect()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nBot detenido por usuario.")
        sys.exit()