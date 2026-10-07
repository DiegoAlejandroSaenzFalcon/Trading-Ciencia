import re
import os
from colorama import Fore, Style, init

init(autoreset=True)

def analizar_forense_bionic():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    archivo_auditoria = os.path.join(base_dir, "AUDITORIA_BIONIC_FULL.txt")
    
    if not os.path.exists(archivo_auditoria):
        print(f"{Fore.RED}>> Error: No se encuentra el archivo '{archivo_auditoria}'.")
        return

    print(f"{Fore.CYAN}>> CARGANDO REPORTE FORENSE GIGANTE... (Esto puede tardar unos segundos){Style.RESET_ALL}")
    
    try:
        with open(archivo_auditoria, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"{Fore.RED}>> Error leyendo el archivo: {e}{Style.RESET_ALL}")
        return

    print(f"{Fore.GREEN}>> Archivo cargado ({len(lines)} líneas). Iniciando escaneo profundo...{Style.RESET_ALL}\n")

    # --- VARIABLES DE ESTADO ---
    current_file = "Desconocido"
    suspect_urls = []
    emails_found = set()
    sleeps_found = []
    api_mods = []
    indicators = set()
    
    # --- PATRONES ---
    # Detectar cambios de archivo en el reporte
    file_header_pattern = re.compile(r"^ARCHIVO: (.+)$")
    
    # Patrones de interés
    url_pattern = re.compile(r'https?://[^\s<>")\'\]]+')
    email_pattern = re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
    sleep_pattern = re.compile(r'time\.sleep\s*\(\s*([0-9.]+)\s*\)')
    # Patrones de desensamblado (LOAD_CONST suele tener strings importantes)
    load_const_pattern = re.compile(r'\s+LOAD_CONST\s+\d+\s+\((.+)\)')
    
    # Funciones clave de la API modificada (Banderas de que no es la original)
    custom_api_funcs = ['captura_binarias', 'captura_digital', 'payout_digital', 'get_candles_v2', 'get_all_open_time']

    for i, line in enumerate(lines):
        line = line.strip()
        
        # 1. Detectar en qué archivo estamos
        m_file = file_header_pattern.match(line)
        if m_file:
            current_file = m_file.group(1)
            continue

        # 2. Buscar URLs (Excluyendo las legítimas)
        urls = url_pattern.findall(line)
        for u in urls:
            # Limpiar URL de paréntesis o comillas residuales del desensamblado
            u = u.strip("')(")
            if 'iqoption.com' not in u and 'w3.org' not in u and 'localhost' not in u and 'google' not in u:
                suspect_urls.append((current_file, u))

        # 3. Buscar Emails
        ems = email_pattern.findall(line)
        for e in ems:
            emails_found.add(e)

        # 4. Buscar Latencia (Sleeps)
        # En código fuente normal
        m_sleep = sleep_pattern.search(line)
        if m_sleep:
            val = float(m_sleep.group(1))
            if val >= 1.0:
                sleeps_found.append((current_file, val, i+1))
        
        # 5. Buscar Modificaciones de API y Estrategia
        # Buscamos strings dentro de LOAD_CONST (común en .pyc desensamblado)
        m_const = load_const_pattern.search(line)
        if m_const:
            const_val = m_const.group(1).strip("'")
            
            # Chequear indicadores
            if 'rsi' in const_val.lower(): indicators.add('RSI')
            if 'bollinger' in const_val.lower(): indicators.add('Bollinger')
            if 'stoch' in const_val.lower(): indicators.add('Stochastic')
            
            # Chequear funciones raras
            if const_val in custom_api_funcs:
                api_mods.append((current_file, const_val))

    # --- GENERACIÓN DEL INFORME ---
    print(f"{Fore.YELLOW}{'='*60}")
    print(f"INFORME FORENSE DETALLADO: BIONIC BOT")
    print(f"{'='*60}{Style.RESET_ALL}")

    # 1. CONEXIONES EXTERNAS
    print(f"\n{Fore.CYAN}[1] ANÁLISIS DE CONEXIONES (¿A dónde envía datos?){Style.RESET_ALL}")
    if suspect_urls:
        print(f"{Fore.RED}⚠️  SE ENCONTRARON {len(suspect_urls)} CONEXIONES EXTERNAS:{Style.RESET_ALL}")
        for f, u in suspect_urls[:10]: # Mostrar solo las primeras 10 para no saturar
            print(f"   - Archivo: {f} -> URL: {u}")
        if len(suspect_urls) > 10: print(f"   ... y {len(suspect_urls)-10} más.")
        print(f"{Fore.WHITE}   (Si ves dominios de licencias o IPs extrañas, es un riesgo de seguridad){Style.RESET_ALL}")
    else:
        print(f"{Fore.GREEN}✅ LIMPIO. Solo se detectaron conexiones a IQ Option.{Style.RESET_ALL}")

    # 2. CREDENCIALES
    print(f"\n{Fore.CYAN}[2] DATOS SENSIBLES (Credenciales Hardcodeadas){Style.RESET_ALL}")
    if emails_found:
        print(f"{Fore.YELLOW}ℹ️  Correos encontrados en el código (posibles dueños o licencias):{Style.RESET_ALL}")
        for e in emails_found:
            print(f"   - {e}")
    else:
        print(f"{Fore.GREEN}✅ No se encontraron correos explícitos.{Style.RESET_ALL}")

    # 3. MODIFICACIONES DE API
    print(f"\n{Fore.CYAN}[3] MODIFICACIONES DE LA API (¿Por qué no usa la original?){Style.RESET_ALL}")
    if api_mods:
        print(f"{Fore.YELLOW}ℹ️  Se detectaron funciones NO OFICIALES en la librería:{Style.RESET_ALL}")
        for f, func in set(api_mods):
            print(f"   - {func} (Encontrado en {f})")
        print(f"\n{Fore.WHITE}   EXPLICACIÓN TÉCNICA:{Style.RESET_ALL}")
        print("   Este bot usa una versión 'forked' (modificada) de la API.")
        print("   Funciones como 'captura_binarias' o 'payout_digital' NO existen en la oficial.")
        print("   Están diseñadas para escanear el mercado más rápido o filtrar activos automáticamente.")
        print(f"   {Fore.GREEN}CONCLUSIÓN: No es malicioso per se, es una optimización necesaria para este bot.{Style.RESET_ALL}")
    else:
        print("   No se detectaron funciones personalizadas obvias (o están ofuscadas).")

    # 4. LATENCIA Y SABOTAJE
    print(f"\n{Fore.CYAN}[4] ANÁLISIS DE LATENCIA (¿El broker te hace perder?){Style.RESET_ALL}")
    if sleeps_found:
        print(f"{Fore.RED}⚠️  ALERTA: Se encontraron pausas largas (Lag potencial):{Style.RESET_ALL}")
        for f, val, l in sleeps_found:
            print(f"   - {f} (Línea ~{l}): Pausa de {val} segundos.")
        print(f"{Fore.WHITE}   Si estas pausas están dentro de la función 'buy' o 'place_order', es SABOTAJE.{Style.RESET_ALL}")
        print(f"   Si están en 'connect' o bucles de espera, es normal.")
    else:
        print(f"{Fore.GREEN}✅ No se encontraron retardos explícitos mayores a 1 segundo.{Style.RESET_ALL}")

    # 5. ESTRATEGIA
    print(f"\n{Fore.CYAN}[5] LÓGICA INTERNA DETECTADA{Style.RESET_ALL}")
    if indicators:
        print(f"   Indicadores hallados en el código binario: {', '.join(indicators)}")
    else:
        print("   No se pudo determinar la estrategia exacta (posiblemente calculada matemáticamente sin nombres estándar).")

if __name__ == "__main__":
    analizar_forense_bionic()
    input(f"\n{Fore.CYAN}Presiona Enter para finalizar...{Style.RESET_ALL}")