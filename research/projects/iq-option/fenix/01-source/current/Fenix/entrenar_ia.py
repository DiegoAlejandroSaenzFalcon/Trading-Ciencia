import os
import sys
import traceback

# Asegurar que estamos en el directorio correcto (donde está el script)
os.chdir(os.path.dirname(os.path.abspath(__file__)))

try:
    import pandas as pd
    import glob
    import joblib
    from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier # UPGRADE: Multi-Modelo
    from sklearn.model_selection import train_test_split, GridSearchCV
    from sklearn.metrics import accuracy_score
    from sklearn.feature_selection import SelectFromModel # NUEVO: Para eliminar ruido
    import colorama
    from colorama import Fore, Style
except ImportError as e:
    print(f"\n[ERROR CRÍTICO] Falta una librería necesaria: {e}")
    print("SOLUCIÓN: Ejecuta el siguiente comando en tu terminal:")
    print("pip install scikit-learn pandas joblib colorama")
    input("\nPresiona Enter para salir...")
    sys.exit(1)

# Inicializar colorama para mensajes coloridos
colorama.init(autoreset=True)

# 1. Cargar todos los archivos CSV de análisis técnico
archivos = glob.glob("analisis_tecnico_*.csv")
dfs = []

try:
    print(f"[*] Buscando archivos en: {os.getcwd()}")
    print(f"[*] Cargando {len(archivos)} archivos de historial...")

    for f in archivos:
        try:
            # ESTRATEGIA ROBUSTA: Leer líneas manualmente para manejar evolución de columnas
            # Esto permite mezclar datos viejos (10 cols) con nuevos (20 cols) sin perder nada.
            
            # Definir la estructura FINAL que esperamos (22 columnas)
            expected_cols = ['FECHA', 'HORA', 'PAR', 'ACCION', 'RESULTADO', 'RSI', 'STOCH_K', 'ADX', 'TREND', 'DIST_EMA50', 'RSI_DIFF', 'BB_WIDTH', 'CANDLE_SIZE', 'WICK_UPPER', 'WICK_LOWER', 'ROC', 'EMA_SLOPE', 'RSI_LAG1', 'RSI_LAG2', 'STOCH_LAG1', 'CUENTA', 'CONTEXTO']
            
            data_rows = []
            with open(f, 'r', encoding='utf-8') as file_obj:
                for line in file_obj:
                    line = line.strip()
                    if not line: continue
                    parts = line.split(',')
                    
                    # Detectar si es encabezado (contiene letras en campos numéricos) y saltarlo
                    if "FECHA" in parts[0] or "RSI" in parts:
                        continue
                        
                    # Limpieza básica
                    parts = [p.strip() for p in parts]
                    
                    # Rellenar columnas faltantes con 0.0 (Datos viejos)
                    while len(parts) < len(expected_cols):
                        parts.append("0.0")
                    
                    # Si sobran (caso raro), cortar
                    if len(parts) > len(expected_cols):
                        parts = parts[:len(expected_cols)]
                        
                    data_rows.append(parts)
            
            # Crear DataFrame con los datos normalizados
            df = pd.DataFrame(data_rows, columns=expected_cols)
            
            # Convertir columnas numéricas explícitamente
            numeric_cols = [c for c in expected_cols[5:] if c not in ['TREND', 'CUENTA', 'CONTEXTO']] # Excluir TREND, CUENTA y CONTEXTO que son texto
            for col in numeric_cols:
                df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0.0)

            dfs.append(df)
            print(f"  -> Cargado: {f} ({len(df)} registros recuperados)")
        except Exception as e:
            print(f"  -> Error leyendo {f}: {e}")

    if not dfs:
        print("Error: No hay datos para entrenar. Asegúrate de tener archivos 'analisis_tecnico_*.csv' generados por el bot.")
        input("Presiona Enter para salir...")
        sys.exit()

    data = pd.concat(dfs, ignore_index=True)

    # --- NUEVO: VISTA PREVIA DE DATOS RECIENTES ---
    # (BLOQUE ELIMINADO POR SOLICITUD DEL USUARIO PARA LIMPIEZA VISUAL)
    # ----------------------------------------------

    # 2. Preprocesamiento de Datos
    # Filtramos solo las columnas numéricas que el bot usa para decidir
    # El CSV tiene: FECHA,HORA,PAR,ACCION,RESULTADO,RSI,STOCH_K,ADX,TREND,DIST_EMA50

    print(f"[*] Total de registros crudos: {len(data)}")

    # Convertir RESULTADO a 1 (WIN) y 0 (LOSS)
    data = data[data['RESULTADO'].isin(['WIN', 'LOSS'])] # Ignorar empates
    data['TARGET'] = data['RESULTADO'].apply(lambda x: 1 if x == 'WIN' else 0)

    # Convertir TREND a numérico (ALCISTA=1, BAJISTA=0)
    data['TREND_VAL'] = data['TREND'].apply(lambda x: 1 if str(x).strip().upper() == 'ALCISTA' else 0)

    # NUEVO: Convertir HORA a valor numérico (0-23) para aprender horarios
    data['HOUR_VAL'] = data['HORA'].apply(lambda x: int(str(x).split(':')[0]))

    # --- LÓGICA ADAPTATIVA: BÁSICO vs EXPERTO ---
    # Contamos cuántos registros tienen datos "HD" (BB_WIDTH != 0)
    rich_data_count = len(data[data['BB_WIDTH'] != 0])
    print(f"[*] Registros HD (Alta Definición): {rich_data_count}")

    features_basic = ['RSI', 'STOCH_K', 'ADX', 'TREND_VAL', 'DIST_EMA50', 'HOUR_VAL']
    features_expert = ['RSI', 'STOCH_K', 'ADX', 'TREND_VAL', 'DIST_EMA50', 'HOUR_VAL', 'RSI_DIFF', 'BB_WIDTH', 'CANDLE_SIZE', 'WICK_UPPER', 'WICK_LOWER', 'ROC', 'EMA_SLOPE', 'RSI_LAG1', 'RSI_LAG2', 'STOCH_LAG1']

    if rich_data_count > 100:
        print(f"{Fore.GREEN}[MODO] ENTRENAMIENTO EXPERTO ACTIVADO 🧠{Style.RESET_ALL}")
        print("       Usando solo datos de alta calidad para máxima precisión.")
        # Usamos solo los datos ricos y todas las columnas
        data_final = data[data['BB_WIDTH'] != 0].copy()
        features = features_expert
    else:
        print(f"{Fore.YELLOW}[MODO] ENTRENAMIENTO BÁSICO (Recopilando Datos...) 🛠{Style.RESET_ALL}")
        print(f"       Se detectaron pocos datos HD ({rich_data_count}/100).")
        print("       Usando estrategia clásica para mantener precisión mientras recolectas más.")
        # Usamos TODOS los datos pero solo columnas básicas para no confundir a la IA
        data_final = data.copy()
        features = features_basic

    X = data_final[features]
    y = data_final['TARGET']

    # Limpiar datos (eliminar filas con errores o vacíos)
    X = X.fillna(0)

    # Verificar balance de clases
    win_count = len(y[y == 1])
    loss_count = len(y[y == 0])
    print(f"[*] Balance de Clases: WIN={win_count} | LOSS={loss_count}")

    if win_count == 0 or loss_count == 0:
        print(f"\n{Fore.RED}[DETENIDO] No se puede entrenar la IA aún.{Style.RESET_ALL}")
        print(f"       Razón: Falta diversidad en los datos (Solo hay {'WINs' if win_count > 0 else 'LOSSes'}).")
        print(f"       La IA necesita ver tanto victorias como derrotas para aprender a distinguir.")
        print(f"       Sigue operando hasta tener al menos 1 resultado opuesto.")
        input("\nPresiona Enter para salir...")
        sys.exit(0)

    # --- NUEVO: FILTRO DE CONTRADICCIONES (Sanitización) ---
    # Elimina registros duplicados que tengan resultados diferentes (Ruido puro)
    print(f"[*] Sanitizando datos (Eliminando contradicciones)...")
    # Creamos un string hash de las features para identificar duplicados
    data_hash = X.apply(lambda row: '_'.join(row.values.astype(str)), axis=1)
    data_final_clean = data_final.copy()
    data_final_clean['hash'] = data_hash
    
    # Identificar hashes que tienen resultados mixtos (WIN y LOSS para la misma entrada)
    contradictory_hashes = data_final_clean.groupby('hash')['TARGET'].nunique()
    contradictory_hashes = contradictory_hashes[contradictory_hashes > 1].index
    
    # Filtrar
    data_final = data_final_clean[~data_final_clean['hash'].isin(contradictory_hashes)].drop(columns=['hash'])
    X = data_final[features].fillna(0)
    y = data_final['TARGET']
    
    print(f"    -> Registros eliminados por contradicción: {len(data_hash) - len(X)}")
    print(f"[*] Registros válidos para entrenamiento: {len(X)}")
    
    if len(X) < 50:
        print(f"{Fore.YELLOW}[ADVERTENCIA] Pocos datos ({len(X)}). La IA podría no ser precisa.")
        print(f"              Sigue operando para mejorar.{Style.RESET_ALL}")

    # 3. Entrenar el Modelo (Competencia de Algoritmos)
    print(f"[*] Entrenando IA (Buscando el mejor algoritmo)...")

    # --- NUEVO: SELECCIÓN DE CARACTERÍSTICAS (Eliminar indicadores basura) ---
    # Usamos un Random Forest rápido para ver qué sirve y qué no
    selector = SelectFromModel(RandomForestClassifier(n_estimators=50, random_state=42), threshold="mean")
    selector.fit(X, y)
    X_new = selector.transform(X)
    
    # Ver qué columnas sobrevivieron
    mask = selector.get_support()
    new_features = [f for f, kept in zip(features, mask) if kept]
    print(f"    -> Indicadores seleccionados (Inteligencia Real): {len(new_features)}/{len(features)}")
    print(f"       {Fore.CYAN}{new_features}{Style.RESET_ALL}")
    
    # Separar en entrenamiento y prueba para validar
    # Usamos stratify para mantener la proporción de WIN/LOSS
    # Usamos X (original) o X_new (filtrado). X_new es más puro pero arriesgado si hay pocos datos.
    # Por ahora usaremos X original pero la IA ya sabe qué ignorar gracias a la regularización,
    # pero el reporte de arriba te servirá para saber qué indicadores son ruido.
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)

    # Definir candidatos
    modelos = {
        'RandomForest': {
            'model': RandomForestClassifier(random_state=42),
            'params': {
                'n_estimators': [100, 200, 300],
                'max_depth': [5, 8, 10], # Limitamos la profundidad para evitar memorización
                'min_samples_split': [5, 10], # Exigimos más datos para crear una regla
                'min_samples_leaf': [2, 4, 6] # CLAVE: Mínimo de datos por hoja para evitar ruido
            }
        },
        'GradientBoosting': {
            'model': GradientBoostingClassifier(random_state=42),
            'params': {
                'n_estimators': [100, 200],
                'learning_rate': [0.01, 0.05], # Aprendizaje más lento y seguro
                'max_depth': [3, 4],
                'subsample': [0.8, 0.9, 1.0] # Usar solo una parte de los datos para generalizar mejor
            }
        }
    }
    
    best_model = None
    best_score = 0
    best_name = ""

    for nombre, config in modelos.items():
        print(f"    -> Probando {nombre}...")
        grid = GridSearchCV(config['model'], config['params'], cv=3, n_jobs=-1, scoring='accuracy')
        grid.fit(X_train, y_train)
        
        score_pct = grid.best_score_ * 100
        if grid.best_score_ > best_score:
            best_score = grid.best_score_
            best_model = grid.best_estimator_
            best_name = nombre
        
        print(f"       ✅ {nombre}: ({score_pct:.2f}%)")

    # 4. Evaluar
    print(f"\n[*] GANADOR FINAL: {best_name}")
    predicciones = best_model.predict(X_test)
    precision = accuracy_score(y_test, predicciones)
    
    print(f"\n[RESULTADOS] Precisión en Prueba (Real): {precision * 100:.2f}%")
    print(f"             Precisión en Entrenamiento:  {best_score * 100:.2f}%")
    
    gap = (best_score - precision) * 100
    if gap > 5:
        print(f"             ⚠️  Overfitting detectado (Caída de {gap:.1f}%). La IA memorizó demasiado.")
    
    # --- PRUEBA DE VIABILIDAD (CONFIDENCE CHECK) ---
    if hasattr(best_model, "predict_proba"):
        print(f"\n{Fore.CYAN}[PRUEBA DE VIABILIDAD] Rentabilidad por Niveles de Confianza:{Style.RESET_ALL}")
        print(" (Esto te dice si el bot es rentable siendo selectivo)")
        probs = best_model.predict_proba(X_test)[:, 1]
        
        thresholds = [0.55, 0.60, 0.65, 0.70]
        viable = False
        
        for t in thresholds:
            mask = probs >= t
            if sum(mask) > 0:
                real_outcomes = y_test[mask]
                wins = sum(real_outcomes)
                total = len(real_outcomes)
                wr = (wins / total) * 100
                color = Fore.GREEN if wr > 56 else Fore.RED
                print(f"   > Si operamos solo con Confianza > {int(t*100)}%: {wins}/{total} aciertos -> {color}Win Rate: {wr:.2f}%{Style.RESET_ALL}")
                if wr > 56: viable = True
            else:
                print(f"   > Confianza > {int(t*100)}%: Sin operaciones suficientes en la prueba.")

    # if precision < 0.51:
    #     print(f"{Fore.YELLOW}[CONSEJO] La precisión es baja. La IA está aprendiendo a generalizar.")
    #     print(f"          Necesitas más datos o el mercado actual es muy aleatorio.{Style.RESET_ALL}")

    # print("\n[REPORTE DETALLADO]")
    # print(classification_report(y_test, predicciones))

    # # 4.5. Analizar Importancia de Features
    # importancias = best_model.feature_importances_
    # df_importancias = pd.DataFrame({
    #     'Indicador': features,
    #     'Importancia': importancias
    # }).sort_values(by='Importancia', ascending=False)
    # print("\n[ANÁLISIS IA] Importancia de cada indicador:")
    # print(df_importancias)

    # 5. Guardar el "Cerebro"
    joblib.dump(best_model, 'cerebro_fenix.pkl')
    print(f"\n[OK] Modelo guardado exitosamente como 'cerebro_fenix.pkl'")
    
    # --- NUEVO: ANÁLISIS DE MEJORES HORAS (INVESTIGACIÓN) ---
    print(f"\n{Fore.MAGENTA}[ANALISIS] Mejores Horarios para Operar (Win Rate):{Style.RESET_ALL}")
    print(" Utiliza esta tabla para configurar tus sesiones de trading.")
    if 'HOUR_VAL' in data_final.columns:
        hourly_stats = data_final.groupby('HOUR_VAL')['TARGET'].agg(['count', 'mean'])
        hourly_stats['win_rate'] = hourly_stats['mean'] * 100
        hourly_stats = hourly_stats[hourly_stats['count'] > 5] # Filtrar horas con pocos datos
        hourly_stats = hourly_stats.sort_values('win_rate', ascending=False)
        
        print(f" {Fore.CYAN}HORA   WIN RATE   OPS{Style.RESET_ALL}")
        for hour, row in hourly_stats.iterrows():
            color = Fore.GREEN if row['win_rate'] > 55 else Fore.RED
            print(f" {hour:02d}:00  {color}{row['win_rate']:6.2f}%{Style.RESET_ALL}   ({int(row['count'])})")
    # --------------------------------------------------------

    print("Ahora reinicia fenix.py para que cargue la nueva inteligencia.")

except Exception as e:
    print(f"\n[ERROR FATAL] {e}")
    traceback.print_exc()

input("\nPresiona Enter para cerrar...")