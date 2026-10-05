import sys
import os

file_path = r'c:\Users\diego\OneDrive\Documentos\Programas de Trading en Desarrollo\Proyecto Fenix IQ Option\Fenix\Fenix\fenix.py'

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

start_marker = "                        # --- CLASIFICADOR DE CONTEXTO DE MERCADO (IA LIGERA) ---"
end_marker = "                        if accion is None:\n                            continue"

start_idx = content.find(start_marker)
if start_idx == -1:
    print("Start marker not found")
    sys.exit(1)

end_idx = content.find(end_marker, start_idx)
if end_idx == -1:
    print("End marker not found")
    sys.exit(1)

end_idx += len(end_marker)

new_content = content[:start_idx] + """                        # ==========================================================
                        # [APEXQUANT] MODULAR ROUTING SYSTEM
                        # ==========================================================
                        from strategies.router import market_router
                        from strategies.reversion import reversion_module
                        from strategies.continuity import continuity_module
                        from strategies.breakout import breakout_module

                        # 1. PREPARACIÓN DE SENSORES
                        wick_ratio_val = wick_ratio if wick_ratio is not None else 0
                        adx_val_router = adx if adx is not None else 0
                        bb_width_router = bb_width if bb_width is not None else 0
                        roc_router = roc if roc is not None else 0

                        # 2. EVALUACIÓN DEL RÉGIMEN (EL CEREBRO)
                        regime, target_strategy = market_router.evaluate_regime(adx_val_router, bb_width_router, roc_router, wick_ratio_val)
                        contexto_mercado = regime # Sincronizamos con telemetría visual

                        # VISUALIZACIÓN DE ESTADO (UI Consola)
                        payout_color = Fore.CYAN if payout_actual * 100 >= min_payout else Fore.RED
                        rsi_val = int(rsi) if rsi is not None else 0
                        adx_print = int(adx) if adx is not None else 0
                        ctx_color = Fore.MAGENTA if "TREND" in regime or "COMP" in regime else Fore.WHITE
                        
                        print(f"\\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {payout_color}PAY:{int(payout_actual*100)}%{Style.RESET_ALL} {ctx_color}[{contexto_mercado}]{Style.RESET_ALL} RSI:{rsi_val} ADX:{adx_print}\\033[K")

                        # 3. ENRUTAMIENTO Y EJECUCIÓN DE ESTRATEGIAS
                        accion_eval = None
                        estrategia_activa = ""
                        
                        if target_strategy != "KILL_SWITCH":
                            if target_strategy == "STRATEGY_REVERSION":
                                accion_eval, estrategia_activa = reversion_module.evaluate_signal(c_close, c_open, upper_bb, lower_bb, rsi, rsi_diff, wick_upper, wick_lower)
                            
                            elif target_strategy == "STRATEGY_CONTINUITY":
                                accion_eval, estrategia_activa = continuity_module.evaluate_signal(c_close, ema_short, rsi, roc, trend_up, trend_down)
                                
                            elif target_strategy == "STRATEGY_BREAKOUT":
                                accion_eval, estrategia_activa = breakout_module.evaluate_signal(c_close, c_open, upper_bb, lower_bb, roc, rsi_diff, candle_size)

                        # 4. TRADUCCIÓN A COMPUERTAS DE COMPRA ORIGINALES
                        call_condition = (accion_eval == 'call')
                        put_condition = (accion_eval == 'put')
                        accion = accion_eval
                            
                        if accion is None:
                            continue""" + content[end_idx:]

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Replacement successful")