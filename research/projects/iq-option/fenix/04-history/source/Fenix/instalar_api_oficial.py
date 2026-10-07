import os
import urllib.request
import ssl
import shutil
import zipfile
import io
import re

def main():
    print(">> INICIANDO RESTAURACIÓN DE API (MÉTODO ZIP - FINAL V2)...")
    
    base_dir = os.path.dirname(os.path.abspath(__file__))
    target_dir = os.path.join(base_dir, 'iqoptionapi')
    
    # 1. Limpieza de instalación corrupta
    if os.path.exists(target_dir):
        print(f">> Eliminando instalación anterior...")
        try:
            def remove_readonly(func, path, excinfo):
                os.chmod(path, 0o777)
                func(path)
            shutil.rmtree(target_dir, onerror=remove_readonly)
        except Exception as e:
            print(f">> Error limpiando carpeta: {e}")
            print(">> Cierre cualquier programa que use la carpeta y reintenta.")
            return

    # 2. Descargar ZIP del repositorio oficial
    url = "https://github.com/Lu-Yi-Hsun/iqoptionapi/archive/refs/heads/master.zip"
    print(f">> Descargando repositorio completo desde GitHub...")
    
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    try:
        with urllib.request.urlopen(url, context=ctx) as response:
            zip_data = response.read()
            
        print(">> Descarga exitosa. Extrayendo estructura correcta...")
        
        with zipfile.ZipFile(io.BytesIO(zip_data)) as zf:
            count = 0
            for member in zf.infolist():
                if "iqoptionapi-master/iqoptionapi/" in member.filename:
                    new_name = member.filename.replace("iqoptionapi-master/iqoptionapi/", "")
                    if not new_name: continue
                    
                    target_path = os.path.join(target_dir, new_name)
                    
                    if member.is_dir():
                        os.makedirs(target_path, exist_ok=True)
                    else:
                        os.makedirs(os.path.dirname(target_path), exist_ok=True)
                        with open(target_path, "wb") as f:
                            f.write(zf.read(member))
                        count += 1
                            
        print(f">> Extracción exitosa. {count} archivos instalados.")
        
    except Exception as e:
        print(f">> ❌ ERROR CRÍTICO DESCARGANDO ZIP: {e}")
        return

    # 3. Aplicar Parches y Optimizaciones
    print(">> Aplicando optimizaciones FENIX...")
    stable_api_path = os.path.join(target_dir, 'stable_api.py')
    
    if os.path.exists(stable_api_path):
        try:
            with open(stable_api_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Parche 1: Bug Digitales (KeyError: underlying)
            bug = 'self.digital_payout_data[i["underlying"]] = i'
            fix = 'if "underlying" in i: self.digital_payout_data[i["underlying"]] = i'
            bug_sq = "self.digital_payout_data[i['underlying']] = i"
            fix_sq = "if 'underlying' in i: self.digital_payout_data[i['underlying']] = i"
            
            if bug in content:
                content = content.replace(bug, fix)
                print("   - [x] Parche Digitales aplicado.")
            elif bug_sq in content:
                content = content.replace(bug_sq, fix_sq)
                print("   - [x] Parche Digitales aplicado.")
            
            # Parche 2: Fix Conexión Infinita (Timeout)
            pattern_conn = r'(\s*)while\s+global_value\.balance_id\s*==\s*None:\s*\n\s*pass'
            match_conn = re.search(pattern_conn, content)
            if match_conn:
                indent = match_conn.group(1)
                fix_conn = f"""{indent}start_t = time.time()
{indent}while global_value.balance_id == None:
{indent}    if time.time() - start_t > 10:
{indent}        return False, "Timeout: El broker no envió el ID de balance."
{indent}    time.sleep(0.1)"""
                content = re.sub(pattern_conn, fix_conn, content)
                print("   - [x] Parche Conexión (Timeout) aplicado.")

            # Parche 3: Inyección de captura_binarias (Optimización FENIX)
            if "def captura_binarias" not in content:
                custom_code = """
    def captura_binarias(self):
        # Función personalizada para FENIX
        activos = {}
        try:
            data = self.get_all_open_time()
            if data:
                if 'turbo' in data: activos['turbo'] = data['turbo']
                if 'binary' in data: activos['binary'] = data['binary']
                if 'digital' in data: activos['digital'] = data['digital']
        except:
            pass
        return activos
"""
                content += "\n" + custom_code
                print("   - [x] Función 'captura_binarias' inyectada.")
    
            with open(stable_api_path, 'w', encoding='utf-8') as f:
                f.write(content)
        except Exception as e:
             print(f">> Error aplicando parches: {e}")

    print("\n>> ¡INSTALACIÓN COMPLETADA!")
    print(">> FENIX está listo.")

if __name__ == "__main__":
    main()
    input("\nPresione Enter para salir...")