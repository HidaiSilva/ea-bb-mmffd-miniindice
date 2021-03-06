//+------------------------------------------------------------------+
//|                                                 BB_FFFD_MINI.mq5 |
//|                                                            Hidai |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Hidai"
#property link      "https://www.mql5.com"
#property version   "1.01"
#property icon "logo03.ico"

#include <Generic\HashMap.mqh>
#include <Trade\Trade.mqh>
CTrade trade;

input group           "Principais"
input double lote = 1; // Quantidade de Lote
input int gain = 100; // Gain
input int loss = 250; // Loss
int internal_gain = gain;
int internal_loss = loss;

input group           "Inativos"
sinput bool enable_compensation_after_loss = false; // Habilitar compensassão após loss
sinput int second_gain = 200; // Gain após um loss
sinput int limit_loss = 2; // Limite de loss permitido

//Candles rates = cotações
MqlRates rates[];

//BB tres buffers - armazernar valores da média
double upBand[];
double middleBand[];
double downBand[];
//Indicador
int handle;

//Tamanho minimo para o Candle de sinal
int signalCandleSize = 10;

//Lista de data:balanço
CHashMap<string, double> balancesDay;

//Status de operação
bool operation = false;

// Data
MqlDateTime dateTimeStruct, dateStruct;

//Balanço anterior
double previousBalance;

//Lista de porcentagem para a mudança do stop loss
string listPercentage;

//Stochastic
int handleStochastic;
double K []; //
double D []; //Média

//Para não repetir operações no mesmo candle
datetime lastOperatingCandle;

//Lista de data:contador
//CHashMap<string, int> balancesDay;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
//Configuração da banda - ativo, perido, deslocamento, desvio, aplicato em qual preço,
   handle = iBands(Symbol(),Period(),20,0,2.00,PRICE_CLOSE);
//                                                k d 
   handleStochastic = iStochastic(_Symbol,_Period,10,3,3,MODE_SMA,STO_LOWHIGH); 
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
//Inverte o array
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(upBand, true);
   ArraySetAsSeries(middleBand, true);
   ArraySetAsSeries(downBand, true);
   ArraySetAsSeries(K, true);
   ArraySetAsSeries(D, true); 
 
   //Candles
   CopyRates(Symbol(),Period(),0,5,rates);
   
   //Passa os valores do handle para as listas BB
   CopyBuffer(handle,0,0,5,middleBand);
   CopyBuffer(handle,1,0,5,upBand);
   CopyBuffer(handle,2,0,5,downBand);
   
   //Stochastic
   CopyBuffer(handleStochastic,0,0,3,K);
   CopyBuffer(handleStochastic,1,0,3,D);
   
   
   int buySign = (int)NormalizeDouble((rates[0].close - rates[0].open)/Point(),0); // candle de compra
   //Print("buySign: " + buySign + " >= signalCandleSize: " + signalCandleSize);


   int sellSign = (int)NormalizeDouble((rates[0].open - rates[0].close)/Point(),0); //candle de venda
   //Print("sellSign: " + sellSign + " >= signalCandleSize: " + signalCandleSize);
   
     
   //Verifica se há operação em andamento
    if(checkPosition() || lastOperatingCandle == rates[0].time) //TODO inserir checkBalance()
     { 
       return;      
     }

   
   //Rescrever as regras 
   //Regra atual... candle de sinal ... a minima/maxima está fora da banda e o fechando está dentro da banda... 
   //Complementos, candle de sinal [1] acima das linhas de baixa e média e candle a favor da venda 
   // se o fechamento do candle de entrada precisa se menor que o fechamento do candle de baixa(anterior) e/ou menor que a abertura do candle de alta(anteriro) rates[0].close < rates[1].close && rates[0].close < rates[1].open   
   if(rates[1].high > upBand[1] && rates[1].close < upBand[1] && rates[1].open > downBand[1] && rates[0].close > middleBand[0])
   {
      ObjectCreate(0, rates[1].time+"_", OBJ_ARROW_STOP, 0, rates[1].time, rates[1].low);
   }
   if(rates[1].high > upBand[1] && rates[1].close < upBand[1] && rates[1].open > downBand[1] && sellSign >= signalCandleSize && rates[0].close > middleBand[0] && rates[0].close < rates[1].close && rates[0].close < rates[1].open)
     {
      Print("Condição de VENDA");
      
      if(D[0] > 70)
        {                      
            Print("Estocastico sobreCOMPRADO");                
           
            if(enable_compensation_after_loss)
            { 
               checkGain();
            }
            
            double SL = SymbolInfoDouble(_Symbol,SYMBOL_ASK) + internal_loss; //loss
            double TP = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - internal_gain; //gain                 
            if(trade.Sell(lote, Symbol(),0.00,SL,TP, NULL))
              {               
               //Pegar % para Stop loss e take e adicionalos
               //addTakeStop();
               previousBalance=AccountInfoDouble(ACCOUNT_BALANCE);
               lastOperatingCandle = rates[0].time;                   
              }             
            
            
        }
      
     }
     
     if(rates[1].low < downBand[1] && rates[1].close > downBand[1] && rates[1].open < upBand[1] && rates[0].close < middleBand[0])
     {
      ObjectCreate(0, rates[1].time+"_", OBJ_ARROW_CHECK, 0, rates[1].time, rates[1].low);
     }
     
     if(rates[1].low < downBand[1] && rates[1].close > downBand[1] && rates[1].open < upBand[1] && buySign >= signalCandleSize && rates[0].close < middleBand[0] && rates[0].close > rates[1].close && rates[0].close > rates[1].open)
     {
      Print("Condição de COMPRA");
      
      if(D[0] < 30)
        {
            Print("Estocastico sobreVENDIDO");
            
            if(enable_compensation_after_loss)
            { 
               checkGain();
            }
            
            double SL = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - internal_loss; //loss
            double TP = SymbolInfoDouble(_Symbol,SYMBOL_ASK) + internal_gain; //gain                 
            if(trade.Buy(lote, Symbol(),0.00,SL,TP, NULL))
              {               
               //Pegar % para Stop loss e take e adicionalos
               //addTakeStop();
               previousBalance=AccountInfoDouble(ACCOUNT_BALANCE);
               lastOperatingCandle = rates[0].time;              
              }
              
            
            
        }
      
     }
     
   
  }

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Verifica o capital para o limite diario                          |
//+------------------------------------------------------------------+

//bool checkBalance()
//{
//
//   // limite loss
//   
//   // Limite de profit ok
//   
//   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
//   //Print("BALANCE %" + balance * 0.01);//Passa o % para variavel global
//   double float_profit=AccountInfoDouble(ACCOUNT_PROFIT);
//   //Print("PROFIT " + float_profit);
//   
//   TimeToStruct(rates[0].time,dateStruct);
//   string day = dateStruct.day;
//   string month = dateStruct.mon;
//   string year = dateStruct.year;
//   
//   if(balancesDay.ContainsKey(day + month + year)) 
//     {
//        // Print("Contem a chave: " + day + month + year);
//         
//         string keys [];
//         double values []; 
//         balancesDay.CopyTo(keys, values); //Copia os valores do hash para poder interagir
//         for(int i=0;i<balancesDay.Count();i++) //Iterage no hash
//           {
//               Print(keys[i]+ ":"+values[i]);
//               if(keys[i] == day + month + year)
//                 {
//                     if(balance - values[i] >= values[i] * 0.01) //balanço atual - balanço anterior >= meta | não opera
//                     {  
//                        //Print("META");
//                        return false;
//                     }
//                     if(values[i] - balance >= values[i] * 0.01) //limite de loss
//                     {
//                        //Print("LIMITE");
//                        return false;
//                     }
//                     else
//                     {
//                        balancesDay.TrySetValue(keys[i], balance);//Atualiza valor do balance na data por ser o mesmo dia
//                        return true;
//                     }                  
//                 }               
//           }          
//         
//         return true;
//     }
//   else //Chave ainda não exite, primeiro trade do dia
//     {
//         balancesDay.Add(day + month + year,balance);
//         //Print ("Adiconado nova chave: " + day + month + year);
//         return true; // liberado para operar   
//     }
//   
//
//}



//Fechar operação
//+------------------------------------------------------------------+
//| Verificação TP SL por pontos - segunda verificação de segurança  |
//+------------------------------------------------------------------+
void checkTPSL(){

   double positionPriceOpen=PositionGetDouble(POSITION_PRICE_OPEN);
   double orderPriceOpen=OrderGetDouble(ORDER_PRICE_OPEN);
  
   int r = (int)NormalizeDouble((rates[0].close)/Point(),0); 
   
   for(int i = PositionsTotal() -1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol == Symbol())
        {
         //Print("TYPEEE " + PositionGetInteger(POSITION_TYPE) + "\nBUY " + POSITION_TYPE_BUY + "\nSELL " + POSITION_TYPE_SELL);

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (positionPriceOpen - rates[0].close) > 130 || (rates[0].close - positionPriceOpen) >= 280)
           {
            closePosition();
           }
          if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (rates[0].close - positionPriceOpen) > 130 || (positionPriceOpen - rates[0].close) >= 280)
           {
            closePosition();
           }
        }
     }
   
   //if( lote * 0.20   )
   //  {
   //      //Print("Take Profit"); 
   //      closePosition();  
   //  } 
   //else if(currentEquity - previousBalance <= -previousBalance * 0.01) //0.005
   //  {
   //      //Print("Stop loss");
   //      closePosition();
   //  }
   //else
   //  {
   //      //changeStopLoss();
   //  }  
      
}

//+------------------------------------------------------------------+
//| Fecha a operação/posição em aberto                               |
//+------------------------------------------------------------------+
void closePosition()
  {
   for(int i = PositionsTotal() -1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol == Symbol())
        {
         //Print("TYPEEE " + PositionGetInteger(POSITION_TYPE) + "\nBUY " + POSITION_TYPE_BUY + "\nSELL " + POSITION_TYPE_SELL);

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY || PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
           {
            ulong ticket = PositionGetInteger(POSITION_TICKET); //Ticket da ordem
            trade.PositionClose(ticket,1);
           }
        }
     }   
  }

//+------------------------------------------------------------------+
//| Verificar se há posição em aberto                                |
//+------------------------------------------------------------------+
bool checkPosition()
  {
   for(int i = PositionsTotal() -1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol == Symbol())
        {
         //Print("TYPEEE " + PositionGetInteger(POSITION_TYPE) + "\nBUY " + POSITION_TYPE_BUY + "\nSELL " + POSITION_TYPE_SELL);

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY || PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
           {
            return true;
           }
        }
     }
     return false;   
  }
  
//+------------------------------------------------------------------+
//| Verificar se há necessidade de alterar Gain após Loss            |
//+------------------------------------------------------------------+
void checkGain(){
     
   ulong tickNumber = 0;
   double orderProfit = 0;
      
   HistorySelect(0, TimeCurrent()); // Todos os periodos
   uint totalNumbersOfDeals = HistoryDealsTotal(); // Todo o histórico
    
    for(uint i=0;i<totalNumbersOfDeals;i++)
      {
         orderProfit = HistoryDealGetDouble(HistoryDealGetTicket(i),DEAL_PROFIT); // Profit bom base no ticket  
      }
    
       
   if(orderProfit < 0) //Se o último profit for negativo o gain é alterado com base % no loss
     {
       internal_gain = second_gain;
     }
   else
     {
        internal_gain = gain;
     }   
}

//+------------------------------------------------------------------+
//| Limite por dia            |
//+------------------------------------------------------------------+
void checkLimit(){
     
   ulong tickNumber = 0;
   double orderProfit = 0;
      
   HistorySelect(0, TimeCurrent()); // Todos os periodos
   uint totalNumbersOfDeals = HistoryDealsTotal(); // Todo o histórico
    
    for(uint i=0;i<totalNumbersOfDeals;i++)
      {
         orderProfit = HistoryDealGetDouble(HistoryDealGetTicket(i),DEAL_PROFIT); // Profit bom base no ticket  
      }
    
       
   if(orderProfit < 0) //Se o último profit for negativo o gain é alterado com base % no loss
     {
       // dia + contador
       //balancesDay.Add(day + month + year,balance);
       
     }
   else
     {
        // dia + contador
     }   
}


//+------------------------------------------------------------------+
//| Take Stop                                                        |
//+------------------------------------------------------------------+
//void addTakeStop()
//  {
//   for(int i = PositionsTotal() -1; i >= 0; i--)
//     {
//      string symbol = PositionGetSymbol(i);
//
//      if(symbol == Symbol())   //Verifica se a ordem aberta é o ativo desejado
//        {
//         ulong ticket = PositionGetInteger(POSITION_TICKET); //Ticket da ordem
//         double enterPrice = PositionGetDouble(POSITION_PRICE_OPEN); //Preço de abertura da ordem
//
//         getPercentageOfCapital(enterPrice); // Preenche TP e SL
//
//         double newSL;
//         double newTP = 0.0;
//
//         //Se a posição for comprada/vendido
//         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
//           {
//
//            newSL = NormalizeDouble(enterPrice - (stopLoss *_Point), _Digits); 
//            //newTP = NormalizeDouble(enterPrice + (takeProfit *_Point), _Digits);
//
//            trade.PositionModify(ticket, newSL,newTP); //Add sl e tp
//
//           }
//         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
//           {   
//
//            double balance=AccountInfoDouble(ACCOUNT_BALANCE);
//            
//            newSL = NormalizeDouble(enterPrice + (stopLoss *_Point), _Digits); //alterar calculo
//            //newTP = NormalizeDouble(enterPrice - (takeProfit *_Point), _Digits);
//
//            trade.PositionModify(ticket, newSL,newTP); //Add sl e tp
//           }
//        }
//     }
//  }