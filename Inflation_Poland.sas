/*Czyszczenie worka z poprzednich tabel tymczasowych options papersize=(7in 12in);*/
proc datasets noprint library=WORK kill; run; quit;

%let amount = 500;
/*Sciezka do csv - dane z rządowego portalu*/
%let path = 'https://api.dane.gov.pl/resources/28395,kwartalne-wskazniki-cen-towarow-i-usug-konsumpcyjnych-od-1995-roku/csv';
/*Definiowanie pliku tymczasowego z odpowiednim kodowaniem*/
filename csv temp ENCODING=UTF8;

proc http method="GET" url=&path out=csv;

proc import datafile = csv
 out = work.entry_table
 dbms = CSV;
 delimiter = ',';
run;

data entry_table;
 set entry_table;
 rename VAR3 = Typ_okres VAR5 = Kwartal VAR6 = Indeks_lancuchowy;
run;

/*Makro do wybrania odpowiednich wartosci z csv*/
%macro cleanData(condition, finName);
data tab_previous;
 set entry_table;
 Typ_okres = trim(COMPBL(lowcase(Typ_okres)));
run;

data &finName;
 set tab_previous;
 where Typ_okres contains(&condition);
run;

proc sort data = &finName;
 by Rok Kwartal;
run;
%mend;

%cleanData('analogiczny okres', tab_previous_year);
%cleanData('okres poprzedni', tab_previous_period);
%cleanData('grudzień roku poprzedniego', tab_dec_last_year);

/*Uśrednienia inflacji w ujęciu rocznym z poszczególnych kwartałów*/
proc sql;
 create table tab_inflation_by_year as
 select
 	Rok
 	,round(mean(Indeks_lancuchowy), .01) as Indeks_lancuchowy_cpi
 from tab_previous_year
 group by Rok
 order by rok
;quit;

data tab_dependent_index;
 retain id;
 set tab_inflation_by_year;
 id = _n_;
run;

proc sql noprint;
 select max(id) into: maxid from tab_dependent_index
;quit;

/*Obliczanie indeksu jednopodstawowego - poprzedni jednopodstawowy * obecny łańcuchowy*/
%macro createSingleBaseIndex(tab);
 %do i = 1 %to &maxId;
  %if &i = 1 %then %do;
   proc sql noprint;
    select indeks_lancuchowy_cpi into: valueIndex from &tab where id = 1;
   ;quit;
   
   proc sql;
    create table tab_single_base_index
    (
     id integer,
     Indeks_jednopodstawowy_cpi decimal
    )
   ;quit;
   
   proc sql;
    insert into tab_single_base_index (id, Indeks_jednopodstawowy_cpi) VALUES
    (&i, &valueIndex)
   ;quit;
  %end;
  %else %do;
   proc sql noprint;
    select indeks_jednopodstawowy_cpi into: preValBaseIndex from tab_single_base_index where 
    id = %eval(&i - 1)
   ;quit;
   
    proc sql noprint;
     select indeks_lancuchowy_cpi into: dependentIndex from &tab where 
     id = &i
   ;quit;
   
   proc sql;
    insert into tab_single_base_index (id, Indeks_jednopodstawowy_cpi) VALUES
    (&i, %sysfunc(round(%sysevalf((&preValBaseIndex * &dependentIndex)/100), .01)))
   ;quit;
  %end;
 %end;
 
 proc sort data=&tab;
 by id;
 run;
 
 proc sort data=tab_single_base_index;
 by id;
 run;
%mend;

%createSingleBaseIndex(tab_dependent_index);

data tab_inflation;
 merge tab_dependent_index tab_single_base_index;
 by id;
 id = id + 1;
run;

proc sql noprint;
 select min(rok) - 1 into: prevYear from tab_inflation
;quit;

proc sql;
 insert into tab_inflation(id, Rok, indeks_lancuchowy_cpi) VALUES
 (1, &prevYear, 100)
;quit;

data tab_inflation;
 set tab_inflation;
 Wartosc_w_poczatkowym_roku = &amount;
 Realna_sila_nabywcza = round(
 	(Wartosc_w_poczatkowym_roku / coalesce(Indeks_jednopodstawowy_cpi, Indeks_lancuchowy_cpi)) * 100, 0.1
 );
 Procent_sily_nabywczej = round((Realna_sila_nabywcza/Wartosc_w_poczatkowym_roku) * 100, 0.1);
 Utrata_wartosci = &amount - Realna_sila_nabywcza;
 if rok >= 2016 then flaga_500 = 1;
 else flaga_500 = 0;
run;

/*Tabela z podsumowanymi wynikami*/
proc sort data = tab_inflation;
by id;
run;

/*Badanie wplywu 500+ na srednia inflacje - poczatek programu w roku 2016*/
data tab_inflation_500;
 set tab_inflation;
 where flaga_500 = 1;
 keep Id Indeks_lancuchowy_cpi;
 rename id = id_rel_field_inflation;
run;

data tab_inflation_500;
 retain id;
 set tab_inflation_500;
 id = _n_;
run;

proc sql noprint;
 select max(id) into: maxid from tab_inflation_500
;quit;

%createSingleBaseIndex(tab_inflation_500);

data tab_inflation_500;
 merge tab_inflation_500 tab_single_base_index;
 by id;
 drop id indeks_lancuchowy_cpi;
 rename id_rel_field_inflation = id indeks_jednopodstawowy_cpi = indeks_jednopodstawowy_cpi_500;
run;

proc sort data = tab_inflation_500;
by id;
run;

data tab_inflation;
 merge tab_inflation tab_inflation_500;
 by id;
 If rok = 2015 then Realna_sila_nabywcza_500 = &amount;
 If rok = 2015 then Utrata_wartosci_500 = 0;
 If flaga_500 = 1 Then Realna_sila_nabywcza_500 = round((&amount/indeks_jednopodstawowy_cpi_500) * 100, 0.1);
 If flaga_500 = 1 Then Utrata_wartosci_500 = round(&amount - Realna_sila_nabywcza_500, 0.1);
run;

/*Eksport wykresy realnej wartości pieniądza*/
ods graphics on /width=800px reset=index imagename='Realna_sila_nabywcza_pieniadza' imagefmt=jpg;
ods listing gpath="/folders/myfolders/img/";
proc sgplot data=tab_inflation;
series x = Rok y = Realna_sila_nabywcza/lineattrs=(color=red)
	legendlabel="Realna siła nabywcza kwoty &amount(rok bazowy =&prevYear)"
	datalabel = Realna_sila_nabywcza;
series x = Rok y = Realna_sila_nabywcza_500/lineattrs=(color=blue pattern=dash)
	legendlabel="Realna siła nabywcza kwoty &amount po wprowdzeniu 500+(rok bazowy = 2015)"
	datalabel = Realna_sila_nabywcza_500;
YAXIS LABEL = 'Wartość w PLN' GRID VALUES = (0 TO 500 BY 50);
Title "Realna sila nabywcza pieniądza w poszczególnych latach";
run;
ods graphics off;
ods listing close;

data tab_inflation_chart;
set tab_inflation;
Indeks_lancuchowy_cpi_w = round((Indeks_lancuchowy_cpi/100 - 1)*100, .01);
run;

/*Eksport wykresy inflacji*/
ods graphics on /width=800px reset=index imagename='Inflacja' imagefmt=jpg;
ods listing gpath="/folders/myfolders/img/";
proc sgplot data=tab_inflation_chart;
series x = Rok y = Indeks_lancuchowy_cpi_w/legendlabel="Inflacja w poszczególnych latach"
	datalabel = Indeks_lancuchowy_cpi_w;
YAXIS LABEL = 'Inflacja w %';
XAXIS GRID VALUES = (1995 TO 2020 BY 5);
Title "Inflacja w poszczególnych latach";
run;
ods graphics off;
ods listing close;

proc sql noprint;
select max(id) into: maxId from tab_inflation;
;quit;

data tab_inflation_exp;
set tab_inflation;
where mod(id, 2) = 0 or id=1 or id = &maxId;
run;  

/*Eksport tabeli realnej wartości pieniądza*/
title "<h1>Realna wartość pieniądza</h1>";
ods graphics on / width=800px imagefmt=jpg imagemap=on imagename="Tabela_wartosc_pieniadza" border=off;
options printerpath=png nodate nonumber;
ods printer file="/folders/myfolders/img/Tabela_wartosc_pieniadza.jpg" style=barrettsblue;
proc print data=tab_inflation_exp(keep=Rok Realna_sila_nabywcza Realna_sila_nabywcza_500);
run;
ods printer close;