#property strict
// An expert advisor.
input double Lots = 0.1;

int OnInit() {
   Print("started"); /* log */
   return(INIT_SUCCEEDED);
}

void OnTick() {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if (price > 0 && true) Comment("price: ", price);
}
