//+------------------------------------------------------------------+
//|                                                 BB_FFFD_MINI.mq5 |
//|                                                            Hidai |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Hidai"
#property link      "https://www.mql5.com"
#property version   "1.05"
#property icon "logo03.ico"

#include <Generic\HashMap.mqh>
#include <Trade\Trade.mqh>
#include <Telegram\Telegram.mqh>

CTrade trade;

// INPUTS
input group           "Principais"
input double lote = 1; // Quantidade de Lote
input double gain = 100; // Gain
input double loss = 250; // Loss
//Tamanho minimo para o Candle de sinal
input int signalCandleSize = 10; //Candle de Sinal
double internal_gain = gain;
double internal_loss = loss;

input group           "Horário de Operação"
input string start_time = "09:00"; //Horário de Início - HH:MM
//input datetime hor_encerra = D'16:30'; //Horário de Encerramento de Entradas
input string closing_time = "17:30"; //Horário de Encerramento - HH:MM

input group           "Limites e Compensações"

sinput bool enable_compensation_after_loss = false; // Habilitar compensação após loss
sinput int second_gain = 200; // Gain após um loss
sinput int limit_loss = 3; // Limite de loss permitido por dia
sinput int limit_gain = 1; // Limite de gain permitido por dia

input group           "Telegram"

int user_id_telegram = 464943763; // ID usuário
input string InpToken="1885687937:AAH6pHE9SZiVZTQfFem3qtXNp5HCaNzBClE";//Token

input group           "Teste"

input bool accountBacktest = false; //Base de dados backtest



//Candles rates = cotações
MqlRates rates[];

//BB tres buffers - armazernar valores da média
double upBand[];
double middleBand[];
double downBand[];
//Indicador
int handle;

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
//Informar se teve uma operação
bool hadOperation = true;

//Data Base
//string dataBaseName = "db_mmffd.sqlite";
string dataBaseName;
int dataBaseConnection = -1;

//Telegram
class CMyBot : public CCustomBot
  {
public:
  };

CMyBot bot;


//TODO Alertas... Primeiro do dia...

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
// Telegram
   bot.Token(InpToken);
   sendChat("Iniciado MFFD ");
   
//Verifica em que tipo de conta está sendo executado ..demo, concurso ou real
   checkAccount();

//Construção da base de dados
   BuilDataBase();
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

   if(!isOnTime())
     {
      closePosition();
      return;
     }

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


//Atualizar banoco de dados - ao iniciar verifica uma vez e só verifica novamente se houve uma operação
   if(!statusOperation() && hadOperation) //Se não há uma posição aberta e foi realizada uma operação
     {
      saveOrder();
      hadOperation = false;
     }

//verificação de posição de segurança
   if(statusOperation())
     {
      checkTPSL();
     }

//Verifica se há operação em andamento - último candle
   if(statusOperation() || lastOperatingCandle == rates[0].time)
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

         if(!checkLimit()) //Verifica limite diario, está posicionado aqui para evitar execesso de reuisições no banco de dados.
           {
            double SL = SymbolInfoDouble(_Symbol,SYMBOL_ASK) + internal_loss; //loss
            double TP = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - internal_gain; //gain
            if(trade.Sell(lote, Symbol(),0.00,0.00,0.00, NULL))
              {
               addTakeStop();
               previousBalance=AccountInfoDouble(ACCOUNT_BALANCE);
               lastOperatingCandle = rates[0].time;
               hadOperation = true;
               sendChat("Realizado uma venda ");

              }
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

         if(!checkLimit()) //Verifica limite diario, está posicionado aqui para evitar execesso de reuisições no banco de dados.
           {
            double SL = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - internal_loss; //loss
            double TP = SymbolInfoDouble(_Symbol,SYMBOL_ASK) + internal_gain; //gain
            if(trade.Buy(lote, Symbol(),0.00,0.00,0.00, NULL))
              {
               addTakeStop();
               previousBalance=AccountInfoDouble(ACCOUNT_BALANCE);
               lastOperatingCandle = rates[0].time;
               hadOperation = true;
               sendChat("Realizado uma compra ");
              }
           }

        }

     }

  }

//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Take Stop                                                        |
//+------------------------------------------------------------------+
void addTakeStop()
  {
   for(int i = PositionsTotal() -1; i >= 0; i--)
     {
      Print("Entrando no FOR");
      string symbol = PositionGetSymbol(i);
      Print("Symbol ", symbol);
      if(symbol == Symbol())   //Verifica se a ordem aberta é o ativo desejado
        {
         Print("Simbolo aceito");
         ulong ticket = PositionGetInteger(POSITION_TICKET); //Ticket da ordem
         double enterPrice = PositionGetDouble(POSITION_PRICE_OPEN); //Preço de abertura da ordem
         Print("Ticket: ", ticket, " Perço de abertura: ", enterPrice);
         //getPercentageOfCapital(enterPrice); // Preenche TP e SL

         double newSL = 0.0;
         double newTP = 0.0;

         //Se a posição for comprada/vendido
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
           {

            newSL = NormalizeDouble(enterPrice - (internal_loss *_Point), _Digits);
            newTP = NormalizeDouble(enterPrice + (internal_gain *_Point), _Digits);

            trade.PositionModify(ticket, newSL,newTP); //Add sl e tp
           }
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
           {

            double balance=AccountInfoDouble(ACCOUNT_BALANCE);

            newSL = NormalizeDouble(enterPrice + (internal_loss *_Point), _Digits);
            newTP = NormalizeDouble(enterPrice - (internal_gain *_Point), _Digits);

            trade.PositionModify(ticket, newSL,newTP); //Add sl e tp
           }

         Print("Take Profit: ",newTP," Stop Loss: ",newSL);
         Print("Resultado TP e SL ", trade.ResultRetcode(), " ",trade.ResultRetcodeDescription());
         sendChat("Resultado TP e SL " + trade.ResultRetcode() + " " + trade.ResultRetcodeDescription());
        }
     }
  }

//Fechar operação
//+------------------------------------------------------------------+
//| Verificação TP SL por pontos - segunda verificação de segurança  |
//+------------------------------------------------------------------+
void checkTPSL()
  {

   double positionPriceOpen=PositionGetDouble(POSITION_PRICE_OPEN);
   double orderPriceOpen=OrderGetDouble(ORDER_PRICE_OPEN);

   int r = (int)NormalizeDouble((rates[0].close)/Point(),0);

   for(int i = PositionsTotal() -1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol == Symbol())
        {
         //Print("TYPEEE " + PositionGetInteger(POSITION_TYPE) + "\nBUY " + POSITION_TYPE_BUY + "\nSELL " + POSITION_TYPE_SELL);

         int gainMore = internal_gain + (internal_gain * 0.1);
         int lossMore = internal_loss + (internal_loss * 0.1);

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (positionPriceOpen - rates[0].close) > gainMore || (rates[0].close - positionPriceOpen) >= lossMore)
           {
            closePosition();
            Alert("TAKE NÂO REALIZADO NA VENDA");
            sendChat("TAKE NÂO REALIZADO NA VENDA ❌");
           }
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (rates[0].close - positionPriceOpen) > gainMore || (positionPriceOpen - rates[0].close) >= lossMore)
           {
            closePosition();
            Alert("TAKE NÂO REALIZADO NA COMPRA");
            sendChat("TAKE NÂO REALIZADO NA COMPRA ❌");
           }
        }
     }

  }


//+------------------------------------------------------------------+
//| Verica se esta operando                                          |
//+------------------------------------------------------------------+
bool statusOperation()
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
//| Verificar se há necessidade de alterar Gain após Loss            |
//+------------------------------------------------------------------+
void checkGain()
  {
// TODO analisar se buscar os valores do banco de dados é mais viavel... em teste a versão atual... se não der certo com HistoryDealGetDouble trocar para DB

   ulong tickNumber = 0;
   double orderProfit = 0;

   string date_time = findLastDate(); //Pega no banco a última data para fazer a busca no histórico
   if(date_time == "")
     {
      date_time = "" + (TimeCurrent() - 3600);
     }

   HistorySelect(StringToTime("D"+date_time), TimeCurrent()); //
//HistorySelect(0, TimeCurrent()); // Todos os periodos
   uint totalNumbersOfDeals = HistoryDealsTotal(); // Todo o histórico

   for(uint i=0; i<totalNumbersOfDeals; i++)
     {
      orderProfit = HistoryDealGetDouble(HistoryDealGetTicket(i),DEAL_PROFIT); // Profit bom base no ticket
     }


   if(orderProfit < 0) //Se o último profit for negativo o gain é alterado
     {
      internal_gain = second_gain;
     }
   else
     {
      internal_gain = gain;
     }
  }

//+------------------------------------------------------------------+
//| Limite por dia                                                   |
//+------------------------------------------------------------------+
bool checkLimit()
  {

   datetime curentDate = TimeCurrent();

   int countGain = countByDate(""+curentDate, "gain");
   int countLoss = countByDate(""+curentDate, "loss");

   if(countGain >= limit_gain || countLoss >= limit_loss) //Atingiu o limite não deve operar
     {
      Print("Atingiu o Limite: Gain = " + countGain + " Loss = " + countLoss);
      return true;
     }
   if(countGain == -2 || countLoss == -2) //Falha ao buscar limite, por segurança retorna com se o limite fosse atingido
     {
      Print("Falha ao buscar limite");
      return true;
     }
   return false;

  }


//+------------------------------------------------------------------+
//|Salvar resultado de ordens                                        |
//+------------------------------------------------------------------+
void saveOrder() // Analisar a possibilidade de saida no zero a zero, implemnetar lógica para isso
  {
   ulong tickNumber = 0;
   double orderProfit = 0;
   datetime orderProfitDate;
   int orderType;

//Buscar no banco

   string date_time = findLastDate(); //Pega no banco a última data para fazer a busca no histórico
   if(date_time == "")
     {
      date_time = "" + (TimeCurrent() - 3600);
     }

   HistorySelect(StringToTime("D"+date_time), TimeCurrent()); //
   uint totalNumbersOfDeals = HistoryDealsTotal(); // Todo o histórico conforme as data no HistorySelect

   for(uint i=0; i<totalNumbersOfDeals; i++)
     {
      orderProfit = HistoryDealGetDouble(HistoryDealGetTicket(i),DEAL_PROFIT); // Profit bom base no ticket
      orderProfitDate = HistoryDealGetInteger(HistoryDealGetTicket(i),DEAL_TIME); // Data hora do último Profit
      orderType = HistoryDealGetInteger(HistoryDealGetTicket(i),DEAL_TYPE); // Analisar se será util
     }

   if(orderProfit < 0)  // loss
     {
      //inserir no banco de dados
      insertData(orderProfitDate, "loss");


     }
   else
      if(orderProfit > 0) //gain
        {
         //inserir no banco de dados
         insertData(orderProfitDate, "gain");
        }
  }


//+------------------------------------------------------------------+
//|  Verifica se está dentro do período para operar                  |
//+------------------------------------------------------------------+
bool isOnTime()
  {
   MqlDateTime startTime;
   MqlDateTime closingTime;
   MqlDateTime currentTime;

   TimeToStruct(StringToTime(start_time),startTime);
   TimeToStruct(StringToTime(closing_time), closingTime);
   TimeToStruct(TimeCurrent(),currentTime);

   datetime start = StringToTime(currentTime.year +"."+ currentTime.mon +"."+ currentTime.day+" "+startTime.hour + ":" + startTime.min);
   datetime closing = StringToTime(currentTime.year +"."+ currentTime.mon +"."+ currentTime.day+" "+closingTime.hour + ":" + closingTime.min);

//if(startTime.hour + startTime.min <= currentTime.hour + currentTime.min && currentTime.hour + currentTime.min <= closingTime.hour + closingTime.min)
   if(start >= closing)
     {
      Alert("A hora de início precisa ser menor que a hora de encerramento");
      Comment("A hora de início precisa ser menor que a hora de encerramento");
      return false;
     }
   if(start <= TimeCurrent() && TimeCurrent() <= closing)
     {
      Comment("Dentro do perído de operação");
      return true;
     }
   else
     {
      Comment("Fora do perído de operação");
      return false;
     }
   return false;
  }


//+------------------------------------------------------------------+
//| TIPO DE CONTA                                                    |
//+------------------------------------------------------------------+
void checkAccount()
  {
   ENUM_ACCOUNT_TRADE_MODE account_type=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string trade_mode;
   switch(account_type)
     {
      case  ACCOUNT_TRADE_MODE_DEMO:
         dataBaseName = "db_mmffd_demo.sqlite";
         break;
      case  ACCOUNT_TRADE_MODE_CONTEST:
         dataBaseName = "db_mmffd_concurso.sqlite";
         break;
      default:
         dataBaseName = "db_mmffd_real.sqlite";
         break;
     }

   if(accountBacktest && dataBaseName == "db_mmffd_demo.sqlite")
     {
      dataBaseName = "db_mmffd_backtest.sqlite";
      return;
     }
  }


//+------------------------------------------------------------------+
//|  DATA BASE                                                       |
//+------------------------------------------------------------------+
void openDataBase()
  {
//--- criamos ou abrimos um banco de dados na pasta compartilhada do terminal

   dataBaseConnection =DatabaseOpen(dataBaseName, DATABASE_OPEN_READWRITE | DATABASE_OPEN_CREATE |DATABASE_OPEN_COMMON);
   if(dataBaseConnection==INVALID_HANDLE)
     {
      Print("DB: ", dataBaseName, " open failed with code ", GetLastError());
      return;
     }

   Print("DB: ", dataBaseName, " estabelecido conexão");

  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void closeDataBase()
  {
   DatabaseClose(dataBaseConnection);
   Print("DB: ", dataBaseName, " finalizado conexão");
  }

//+------------------------------------------------------------------+
//| Inicial - constroi a tabela                                      |
//+------------------------------------------------------------------+
void BuilDataBase()
  {

   openDataBase();

//--- se a tabela existir, vamos exclui-la em caso de backtest
   if(dataBaseName == "db_mmffd_backtest.sqlite" && DatabaseTableExists(dataBaseConnection, "oder_control"))
     {
      //--- excluímos a tabela
      if(!DatabaseExecute(dataBaseConnection, "DROP TABLE oder_control"))
        {
         Print("Failed to drop table COMPANY with code ", GetLastError());
         DatabaseClose(dataBaseConnection);
         return;
        }
      else
        {
         Print("DB: ", dataBaseName, " Drop Table: oder_control");
        }
     }

//--- se a tabela oder_control não existir, criar ela
   if(!DatabaseTableExists(dataBaseConnection, "oder_control"))
     {
      //--- criamos a tabela oder_control
      if(!DatabaseExecute(dataBaseConnection, "CREATE TABLE oder_control("
                          "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                          "date_time      TEXT      NOT NULL,"
                          "timestamp      INT       NOT NULL,"
                          "order_type     CHAR(5)    NOT NULL);"))
        {
         Print("DB: ", dataBaseName, " create table failed with code ", GetLastError());
         closeDataBase();
         return;
        }
      else
        {
         Print("DB: ", dataBaseName, " Create Table: oder_control");
        }

     }
   closeDataBase();
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Insere no banco                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void insertData(datetime dt, string type)
  {

   openDataBase();
   string request_text = StringFormat("insert into oder_control (date_time,timestamp,order_type) values ('%s',%d,'%s');",""+dt,dt,type);

   int request=DatabaseExecute(dataBaseConnection, request_text);
   if(request==INVALID_HANDLE)
     {
      Print("DB: ", dataBaseName, " request failed with code ", GetLastError());
      closeDataBase();
      return;
     }
   closeDataBase();
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Buscas                                                           |
//+------------------------------------------------------------------+
void findAll()
  {
//--- preparamos uma nova consulta sobre a soma de salários

   openDataBase();
   int request=DatabasePrepare(dataBaseConnection, "SELECT * FROM oder_control");
   if(request==INVALID_HANDLE)
     {
      Print("DB: ", dataBaseName, " request failed with code ", GetLastError());
      DatabaseClose(dataBaseConnection);
      return;
     }
   while(DatabaseRead(request))
     {
      string dateTime;
      string type;
      DatabaseColumnText(request, 1, dateTime);
      DatabaseColumnText(request, 3, type);
      Print("Pesquisa Data: ", dateTime);
      Print("Pesquisa Tipo: ", type);
     }
//--- excluímos a consulta após ser usada
   DatabaseFinalize(request);
  }

//+------------------------------------------------------------------+

//Fazer um count das ordens com base na data sem a hora
int countByDate(string orderDatetime, string order_type)
  {

   openDataBase();
   string query = StringFormat("SELECT count(*) FROM oder_control WHERE substr(date_time,1,10) = substr('%s',1,10) AND order_type = '%s';",orderDatetime, order_type);
   int request=DatabasePrepare(dataBaseConnection, query);

   if(request==INVALID_HANDLE)
     {
      Print("DB: ", dataBaseName, " request failed with code ", GetLastError());
      DatabaseClose(dataBaseConnection);
      return -2;
     }

   int count = -1;
   while(DatabaseRead(request))
     {
      DatabaseColumnInteger(request, 0, count);
     }

   DatabaseFinalize(request);
   closeDataBase();

   return count;
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string findLastDate()
  {

   openDataBase();
   string query = "SELECT date_time FROM oder_control ORDER BY timestamp DESC LIMIT 1;";
   int request=DatabasePrepare(dataBaseConnection, query);

   if(request==INVALID_HANDLE)
     {
      Print("DB: ", dataBaseName, " request failed with code ", GetLastError());
      DatabaseClose(dataBaseConnection);
      return -2;
     }

   string date_time = "";
   while(DatabaseRead(request))
     {
      DatabaseColumnText(request, 0, date_time);
     }

   DatabaseFinalize(request);
   closeDataBase();

   return date_time;
  }


//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| TELEGRAM                                                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Envia mensagem ao telegram                                       |
//+------------------------------------------------------------------+
void sendChat(string msg)
  {
   int res = bot.SendMessage(user_id_telegram, msg);
   if(res != 0)
     {
      Print("Error: ",GetErrorDescription(res));
     }
   Comment("Bot enviando mensagem ", res);
   Print("Bot enviando mensagem ", res);
  }
//+------------------------------------------------------------------+
