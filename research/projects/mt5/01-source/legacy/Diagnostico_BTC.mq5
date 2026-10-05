//+------------------------------------------------------------------+
//| Script: Diagnostico_BTC.mq5                                      |
//| Proposito: Validar comisiones y swaps en Pepperstone Razor       |
//+------------------------------------------------------------------+
void OnStart()
{
   Print("======================================================");
   Print("DIAGNOSTICO DE SIMBOLO: ", _Symbol);
   
   // Validar Swaps
   double swapLong  = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_LONG);
   double swapShort = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_SHORT);
   ENUM_SYMBOL_SWAP_MODE swapMode = (ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_MODE);
   
   Print("Modo de Swap: ", EnumToString(swapMode));
   Print("Costo Swap Compra (Long): ", swapLong);
   Print("Costo Swap Venta (Short): ", swapShort);
   
   // Validar Spread
   int spreadFlotante = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool spreadFloating = (bool)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD_FLOAT);
   
   Print("Spread actual (puntos): ", spreadFlotante);
   Print("Es Spread flotante?: ", spreadFloating ? "SI" : "NO");
   
   // Validar Valor del Tick
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   Print("Tamano del Tick: ", tickSize);
   Print("Valor monetario de 1 Tick (1 Lote): $", tickValue);
   Print("======================================================");
}
//+------------------------------------------------------------------+