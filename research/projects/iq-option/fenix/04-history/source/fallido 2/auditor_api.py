import os
import sys
import marshal
import dis
import io
import time
from colorama import Fore, Style, init

init(autoreset=True)

def extract_pyc_data(file_path):
    """
    Intenta cargar un archivo .pyc binario y devolver el objeto código.
    Prueba diferentes tamaños de cabecera estándar de Python.
    """
    try:
        with open(file_path, 'rb') as f:
            data = f.read()
    except Exception as e:
        return None, f"Error de lectura: {e}"
    
    # Offsets comunes: 16 bytes (Py 3.7+), 12 bytes (Py 3.3-3.6), 8 bytes (Py 2.7)
    offsets = [16, 12, 8]
    
    for offset in offsets:
        try:
            if len(data) > offset:
                # marshal.loads convierte los bytes binarios en un objeto de código en memoria
                code_obj = marshal.loads(data[offset:])
                return code_obj, offset
        except Exception:
            continue
            
    return None, "No se pudo decodificar (versión de Python incompatible o archivo corrupto)"

def disassemble_recursive(code_obj, out_stream, indent=0):
    """
    Desensambla el código binario a texto legible (instrucciones) de forma recursiva.
    Esto permite ver funciones y clases anidadas.
    """
    indent_str = " " * indent
    
    # Escribir información básica
    out_stream.write(f"{indent_str}--- CÓDIGO: {code_obj.co_name} (Args: {code_obj.co_argcount}) ---\n")
    
    # Usar dis.dis para convertir opcodes a texto
    try:
        dis.dis(code_obj, file=out_stream)
    except Exception as e:
        out_stream.write(f"{indent_str}[Error en dis.dis: {e}]\n")

    # Buscar constantes que sean a su vez objetos de código (funciones internas, lambdas, clases)
    for const in code_obj.co_consts:
        if hasattr(const, 'co_code'): # Es un objeto de código
            out_stream.write(f"\n{indent_str}>>> DESENSAMBLANDO SUB-CÓDIGO INTERNO: {const.co_name}\n")
            disassemble_recursive(const, out_stream, indent + 4)

def process_directory():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    target_dir = os.path.join(base_dir, 'bot bionic 3.exe_extracted')
    output_file = os.path.join(base_dir, "AUDITORIA_BIONIC_FULL.txt")
    
    print(f"{Fore.CYAN}>> BUSCANDO CARPETA 'bot bionic 3.exe_extracted' EN: {Fore.YELLOW}{base_dir}{Style.RESET_ALL}")
    
    if not os.path.exists(target_dir):
        print(f"{Fore.RED}>> ERROR: No se encontró la carpeta 'bot bionic 3.exe_extracted' en este directorio.{Style.RESET_ALL}")
        return

    print(f"{Fore.GREEN}>> CARPETA ENCONTRADA.{Style.RESET_ALL}")
    print(f"{Fore.YELLOW}>> INICIANDO PROCESO DE INGENIERÍA INVERSA (BINARIO -> TEXTO)...{Style.RESET_ALL}")
    
    archivos_procesados = 0
    
    try:
        with open(output_file, 'w', encoding='utf-8') as outfile:
            outfile.write("REPORTE DE AUDITORÍA E INGENIERÍA INVERSA - FENIX\n")
            outfile.write(f"Objetivo: {target_dir}\n")
            outfile.write(f"Fecha: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            outfile.write("="*80 + "\n\n")
            
            # Recorrer recursivamente todos los archivos y subcarpetas
            for root, dirs, files in os.walk(target_dir):
                for file in files:
                    full_path = os.path.join(root, file)
                    rel_path = os.path.relpath(full_path, base_dir)
                    
                    outfile.write(f"{'='*80}\n")
                    outfile.write(f"ARCHIVO: {rel_path}\n")
                    outfile.write(f"{'='*80}\n")
                    
                    # CASO 1: Archivo de texto fuente (.py)
                    if file.lower().endswith('.py'):
                        outfile.write("FORMATO: Código Fuente (.py)\n")
                        outfile.write("ACCIÓN: Lectura directa\n\n")
                        try:
                            with open(full_path, 'r', encoding='utf-8', errors='replace') as f:
                                outfile.write(f.read())
                        except Exception as e:
                            outfile.write(f"[ERROR LEYENDO ARCHIVO: {e}]")
                            
                    # CASO 2: Archivo compilado binario (.pyc) o sin extensión (común en exes extraídos)
                    elif file.lower().endswith('.pyc') or '.' not in file:
                        outfile.write("FORMATO: Binario Compilado (.pyc) o Sin Extensión\n")
                        outfile.write("ACCIÓN: Desensamblado (Bytecode -> Texto)\n")
                        outfile.write("NOTA: Esto muestra las instrucciones internas de Python.\n")
                        outfile.write("      Busca 'LOAD_CONST' para ver textos, URLs y nombres de variables.\n\n")
                        
                        code_obj, info = extract_pyc_data(full_path)
                        
                        if code_obj:
                            outfile.write(f"Info: Offset detectado {info} bytes\n")
                            outfile.write("-" * 40 + "\n")
                            
                            # Capturar salida de texto
                            string_io = io.StringIO()
                            try:
                                disassemble_recursive(code_obj, string_io)
                                outfile.write(string_io.getvalue())
                            except Exception as e:
                                outfile.write(f"[ERROR DESENSAMBLANDO: {e}]")
                        else:
                            outfile.write(f"[FALLO: {info}]")
                    
                    # CASO 3: Otros archivos
                    else:
                        outfile.write(f"FORMATO: Desconocido ({os.path.splitext(file)[1]})\n")
                        outfile.write("[Contenido omitido por seguridad/formato no soportado]")
                    
                    outfile.write("\n\n")
                    archivos_procesados += 1
                    print(f"Procesado: {rel_path}")

        print(f"\n{Fore.GREEN}>> ¡PROCESO COMPLETADO EXITOSAMENTE!{Style.RESET_ALL}")
        print(f">> Se procesaron {archivos_procesados} archivos.")
        print(f">> Toda la información (código y desensamblado) está en:")
        print(f"   {Fore.YELLOW}{output_file}{Style.RESET_ALL}")
        print(f">> Abre ese archivo y busca 'http', 'sleep' o 'random' para auditar.")

    except Exception as e:
        print(f"{Fore.RED}>> Error crítico durante el proceso: {e}{Style.RESET_ALL}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    process_directory()
    input("\nPresiona Enter para finalizar...")