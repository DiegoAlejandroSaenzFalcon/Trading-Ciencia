import sys
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier, VotingClassifier
from sklearn.neural_network import MLPClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, classification_report
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.impute import SimpleImputer
import joblib

import os
import glob

# 1. Cargar datos
print("Cargando historial de trading...")
base_dir = os.path.dirname(os.path.abspath(__file__))
# Busca todos los archivos CSV de análisis técnico
archivos_csv = glob.glob(os.path.join(base_dir, "analisis_tecnico_*.csv"))

if not archivos_csv:
    print("Error: No se encontraron archivos de historial (.csv). El bot debe operar primero para generar datos.")
    sys.exit(1)

df_list = []
for f in archivos_csv:
    try:
        df_temp = pd.read_csv(f, low_memory=False)
        df_list.append(df_temp)
    except: pass

if not df_list:
    sys.exit(1)

df = pd.concat(df_list, ignore_index=True)

# 2. Limpieza y Preprocesamiento
# Convertir RESULTADO a numérico (WIN=1, LOSS=0)
df = df[df['RESULTADO'].isin(['WIN', 'LOSS'])].copy() # Ignorar empates o nulos
df['TARGET'] = df['RESULTADO'].apply(lambda x: 1 if x == 'WIN' else 0)

# Seleccionar las características (Features) que usará la IA
# Deben coincidir con lo que el bot calcula en tiempo real
features = ['RSI', 'STOCH_K', 'ADX', 'DIST_EMA50', 'RSI_SLOPE', 'VOLATILITY']

for col in features:
    if col not in df.columns:
        df[col] = 0.0
    df[col] = pd.to_numeric(df[col], errors='coerce')

print(f"Datos procesados: {len(df)} operaciones encontradas.")

if len(df) < 50:
    print("Advertencia: Pocos datos para entrenar una IA fiable. Se recomienda tener al menos 100 operaciones.")

# 3. Entrenamiento del Modelo
X = df[features]
y = df['TARGET']

# Dividir en entrenamiento y prueba para validar
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# --- ARQUITECTURA DE IA AVANZADA (ENSAMBLE) ---

# 1. Random Forest (El Estratega)
rf = RandomForestClassifier(n_estimators=100, max_depth=10, random_state=42)

# 2. Red Neuronal (El Cerebro)
mlp = make_pipeline(
    StandardScaler(),
    MLPClassifier(hidden_layer_sizes=(50, 30), max_iter=500, activation='relu', solver='adam', random_state=42)
)

# 3. Gradient Boosting (El Francotirador) - Alta precisión en datos tabulares
gb = GradientBoostingClassifier(n_estimators=100, learning_rate=0.1, max_depth=5, random_state=42)

# 4. Votación (El Consejo) - Combina los 3 modelos
# 'soft' voting promedia las probabilidades de cada uno
voting_model = VotingClassifier(estimators=[('rf', rf), ('mlp', mlp), ('gb', gb)], voting='soft')

print("Entrenando Ensamble Híbrido (RF + Red Neuronal + Gradient Boosting)...")
voting_model.fit(X_train, y_train)

# 4. Evaluación
y_pred = voting_model.predict(X_test)
acc = accuracy_score(y_test, y_pred)
print(f"\nPrecisión del Modelo en pruebas: {acc*100:.2f}%")
print("\nReporte de Clasificación:")
print(classification_report(y_test, y_pred))

# 5. Guardar el cerebro
ruta_modelo = os.path.join(base_dir, "cerebro_fenix.pkl")
joblib.dump(voting_model, ruta_modelo)
print(f"\n✅ Modelo guardado exitosamente en: {ruta_modelo}")