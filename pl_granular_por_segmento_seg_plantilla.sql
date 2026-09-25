/* =========================================================================
   P&L agregado por Periodo x Fuente x Segmento
   -------------------------------------------------------------------------
   Base: 02_dominio/pnl/pl_granular/P_L__Granular_por_Comercio.sql (misma
   estructura de 3 etapas y mismas formulas de todas las lineas del P&L).
   Cambios respecto al granular:
     - Dimensiones: solo Periodo, Fuente, Segmento (sin comercio, RUC,
       grupo economico, MCC, cosechas, calendario ni producto).
     - Sin filtro #IDs por grupo economico. En su lugar hay un parametro
       opcional @Grupo_Economico: si se declara un valor se consulta solo ese
       grupo; si queda en NULL el filtro no se aplica (todos los comercios).
     - Sin cruce con v_DimProductos. Las lineas que filtraban por la vkey
       de la dimension de productos (2.1.2, 2.1.4, 2.1.5, 2.1.7,
       2.1.11 a 2.1.17) usan ahora vkey_pl, la misma vkey normalizada del
       granular calculada solo con columnas de la base (ver nota 1).
     - Segmento: la segmentacion de 90_adhoc/Cierre/PnL Operativo Plantilla.sql
       (CTEs SEMGN / SEMGNRUC), con tablas deduplicadas (1 fila por llave):
           1) SEGMENTO_BAIN por codigo de comercio (a.CodigoComercio),
              Fuente = 'N'
           2) SEGMENTO_BAIN por RUC real de la base (a.RUC) contra
              NRO_DOCUMENTO, Fuente = 'N', excluyendo NRO_DOCUMENTO
              '20555530090'
           3) sin match -> '9.Financial Inst.'
       Se toma el primero que exista, en ese orden. Diferencias vs la version
       todos_los_codigos_FINANZAS (pl_granular_por_segmento.sql): el RUC es
       a.RUC y no LEFT(codigo,11); no hay fallback a Fuente 'V'; el default
       es '9.Financial Inst.' y no '7.Procesamiento'.
       OJO: la Plantilla usa SELECT DISTINCT con varias columnas (fecha_alta,
       grupo, cluster...), por lo que si un codigo/RUC tiene mas de una fila
       en V_SEGMENTO_FINANZAS la Plantilla DUPLICA importes. Aqui se deduplica
       con MAX, asi que los totales pueden ser menores que los de la Plantilla
       en esos casos (los de aqui son los correctos).
     - Se quitan los indicadores "Desposicionado" (ventanas por grupo
       economico): sin grupo economico no aplican.
     - Corregidos dos typos del original: [3.1.21.- CPDummy ...] en Stage 2
       y el DROP de #Produto.

   Optimizaciones para Synapse dedicado (EngineEdition = 6):
     - @Periodo_Min/@Periodo_Max como int: con float la columna Periodo se
       convertia implicitamente y el filtro dejaba de ser directo.
     - Temporales con CTAS + HEAP en vez de SELECT INTO (que crea columnstore,
       caro de escribir para pocas filas y ~300 columnas).
     - Segmentacion en 2 temporales (codigo y RUC), deduplicadas.
     - CREATE STATISTICS sobre las llaves de las temporales: Synapse NO crea
       estadisticas automaticas en temporales, y sin ellas el optimizador no
       sabe que son chicas (riesgo de redistribuir la base en cada join).
       REPLICATE no es opcion: los temporales solo admiten HASH/ROUND_ROBIN.
     - Llave de comercio, RUC y vkey_pl se calculan una sola vez por
       fila en una subconsulta sobre la base, y el filtro de periodo/fuente va
       dentro de esa subconsulta.

   NOTA 1 - validar una vez: el granular solo sumaba esas lineas 2.1.x si la
   vkey existia en v_DimProductos (LEFT JOIN). Sin el cruce, una vkey de la
   base que NO este en la dimension ahora si suma. Revisar que esto devuelva
   vacio para el periodo:

     SELECT DISTINCT b.CodProductoNBO + '-' + b.CodSubProductoNBO AS vkey
     FROM [Finanzas].v_ss_Base_Renta_NBZ_VMAS AS b
     WHERE b.Periodo = 202605
       AND b.CodProductoNBO + '-' + b.CodSubProductoNBO IN
           ('VT-1','VT-4','VT-6','VL-1','VD-0','VD-1','VF-1','VF-2','VF-3',
            'VV-1','VV-2','VV-3','VP-0','PS-CP','VT-2','VT-3','VT-5',
            'VD-2','VD-3','VD-4','VD-5','VD-6','VD-7','VD-8','VD-9','MC-4')
       AND b.CodProductoNBO + '-' + b.CodSubProductoNBO NOT IN
           (SELECT CodProducto + '-' + CodSubProducto FROM [Finanzas].[v_DimProductos]);
   ========================================================================= */

DECLARE @TipoPL varchar(2) = 'PL'
DECLARE @G_Afil varchar(2) = 'Si'
DECLARE @IRND varchar(2) = 'No'
DECLARE @Tasa_IRND float = 0.4035
DECLARE @Periodo_Min int = 202608
DECLARE @Periodo_Max int = 202608
DECLARE @Cod_Patrocinado varchar(2) = 'No'   -- 'Si' = segmenta Vendemas PF (RUC 20602370497) por CodigoPatrocinado | 'No' = CodigoComercio plano (igual que PnL Operativo Plantilla.sql)
DECLARE @Excluir_VMas varchar(2) = 'No'      -- 'Si' = excluye Fuente 'V+' | 'No' = todas las fuentes (igual que PnL Operativo Plantilla.sql)
-- Filtro opcional de universo. NULL = sin filtro (todos los grupos economicos).
-- Si se declara, debe ser el nombre tal como viene en el campo Grupo_Economico
-- de [BI_Data].[V_SEGMENTO_FINANZAS]. Se resuelve DESPUES del join de segmento
-- (misma prelacion que Segmento: codigo de comercio primero, luego RUC), por lo
-- que NO reduce el scan de la vista base: la corrida tarda casi lo mismo.
DECLARE @Grupo_Economico varchar(200) = NULL  -- ej. 'RENIEC'
DECLARE @Factor_IRND float = CASE WHEN @IRND = 'Si' THEN (1+@Tasa_IRND)/1.30 ELSE 1 END  --Optimizacion: factor IRND pre-calculado
DECLARE @Factor_TipoPL int  = CASE WHEN @TipoPL = 'FC' THEN 0 ELSE 1 END               --Optimizacion: factor TipoPL pre-calculado

IF OBJECT_ID('tempdb..#Seg_Codigo','U')   IS NOT NULL DROP TABLE #Seg_Codigo;
IF OBJECT_ID('tempdb..#Seg_RUC','U')      IS NOT NULL DROP TABLE #Seg_RUC;
IF OBJECT_ID('tempdb..#PL_Granular','U')  IS NOT NULL DROP TABLE #PL_Granular;
IF OBJECT_ID('tempdb..#PL_Subtotals','U') IS NOT NULL DROP TABLE #PL_Subtotals;

-- ===========================================================
-- Segmentacion (misma logica que PnL Operativo Plantilla.sql: SEMGN / SEMGNRUC)
-- Una fila por llave: GROUP BY + MAX, para que el JOIN no duplique importes
-- si V_SEGMENTO_FINANZAS repite la llave.
-- ===========================================================
-- SEMGN: segmento por codigo de comercio, Fuente = 'N'
CREATE TABLE #Seg_Codigo
WITH (DISTRIBUTION = HASH(Codigo_Comercio_Seg), HEAP)
AS
SELECT
	TRY_CAST(Codigo_Comercio AS bigint)                  AS Codigo_Comercio_Seg,
	MAX(SEGMENTO_BAIN)                                   AS Seg_N,
	MAX(Grupo_Economico)                                 AS Grupo_N
FROM [BI_Data].[V_SEGMENTO_FINANZAS]
WHERE Fuente = 'N'
  AND TRY_CAST(Codigo_Comercio AS bigint) IS NOT NULL
GROUP BY TRY_CAST(Codigo_Comercio AS bigint);

-- SEMGNRUC: segmento por RUC (NRO_DOCUMENTO), Fuente = 'N', sin 20555530090
CREATE TABLE #Seg_RUC
WITH (DISTRIBUTION = HASH(Nro_Documento_Seg), HEAP)
AS
SELECT DISTINCT
	TRY_CAST(Nro_Documento AS bigint)                    AS Nro_Documento_Seg,
	MAX(SEGMENTO_BAIN)                                   AS Seg_RUC_N,
	MAX(Grupo_Economico)                                 AS Grupo_RUC_N
FROM [BI_Data].[V_SEGMENTO_FINANZAS]
WHERE Fuente = 'N'
  --AND Nro_Documento <> '20555530090'
  AND TRY_CAST(Nro_Documento AS bigint) IS NOT NULL
GROUP BY TRY_CAST(Nro_Documento AS bigint);

-- Synapse no crea estadisticas automaticas en temporales
CREATE STATISTICS st_seg_codigo ON #Seg_Codigo (Codigo_Comercio_Seg) WITH FULLSCAN;
CREATE STATISTICS st_seg_ruc    ON #Seg_RUC    (Nro_Documento_Seg)   WITH FULLSCAN;

-- ===========================================================
-- Stage 1: Aggregate granular P&L columns from base view once
-- ===========================================================
CREATE TABLE #PL_Granular
WITH (DISTRIBUTION = ROUND_ROBIN, HEAP)
AS
SELECT * FROM (
SELECT
	a.Periodo,
	a.Fuente,
	CASE
		WHEN a.fuente = 'V+' THEN '10.Vendemas'
		WHEN sc.Seg_N     IS NOT NULL THEN sc.Seg_N
		WHEN sr.Seg_RUC_N IS NOT NULL THEN sr.Seg_RUC_N
	ELSE NULL END AS Segmento,
[Volumen Niubiz] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN voltot ELSE 0 END,0)),
[Volumen VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN voltot ELSE 0 END,0)),
[Volumen Niubiz+VendeMas] = SUM(COALESCE(CASE WHEN a.ruc <> '20602370497' AND a.fuente not IN ('V+') THEN voltot ELSE 0 END,0))+SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN voltot ELSE 0 END,0)),

[Transacciones Niubiz] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN txstot ELSE 0 END,0)),
[Transacciones VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN txstot ELSE 0 END,0)),
[Transacciones Niubiz+VendeMas] = SUM(COALESCE(CASE WHEN a.ruc <> '20602370497' AND a.fuente not IN ('V+') THEN txstot ELSE 0 END,0))+SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN txstot ELSE 0 END,0)),

[Comision Total Niubiz] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN CTTOT ELSE 0 END,0)),
[Comision Total VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CTTOT ELSE 0 END,0)),
[Comision Total Niubiz+VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN CTTOT ELSE 0 END,0))+SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CVTOT ELSE 0 END,0)),

[Comision Adquirente Niubiz] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN CVTOT ELSE 0 END,0)),
[Comision Adquirente VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CVTOT ELSE 0 END,0)),
[Comision Adquirente Niubiz+VendeMas] = SUM(COALESCE(CASE WHEN a.Fuente <> 'V+' THEN CVTOT ELSE 0 END,0))+ SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CVTOT ELSE 0 END,0)),

[Transacciones SVA Data] = SUM(COALESCE(TransaccionesData,0))+SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN txstot ELSE 0 END,0)),
[Numero de POS SVA a Cobrar] = SUM(COALESCE(POSCobrar,0)),
[Volumen SVA Data] = SUM(COALESCE(Tarjetas,0))+SUM(COALESCE(CASE WHEN a.Fuente = 'V+' AND a.ukey IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN voltot ELSE 0 END,0)),
------------------------------------------------------------
------------------------------------------------------------
[Transacciones SAS Post] = SUM(COALESCE(Trx_SAS_Pos,0)),
[Transacciones SAS Pre] = SUM(COALESCE(Trx_SAS_Pre,0)),
------------------------------------------------------------
------------------------------------------------------------
[Movimiento] = SUM(COALESCE(CASE WHEN a.ruc ='20602370497' AND a.fuente not IN ('V+') THEN 0 ELSE a.Movimiento END,0)),
[Estado] = SUM(COALESCE(CASE WHEN a.ruc ='20602370497' AND a.fuente not IN ('V+') THEN 0 ELSE a.Estado END,0)),
[Codigos] = SUM(COALESCE(CASE WHEN a.ruc ='20602370497' AND a.fuente not IN ('V+') THEN 0 ELSE 1 END,0)),
------------------------------------------------------------
------------------------------------------------------------
[1.1.1.- Ing. Com. Niubiz] = SUM(COALESCE(CASE WHEN a.ukey IN ('PRESTAMOS','RECARGAS Y SERVICIOS') or a.fuente='V+' THEN 0 ELSE CVTOT END,0)),
[1.1.2.- Ing. Com. Vendemas] = SUM(COALESCE(CASE WHEN a.fuente='V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CTTOT ELSE 0 END,0)),
[1.1.3.- Ing. Gobierno] = SUM(COALESCE([Ingreso Gobierno],0)),
[1.1.4.- Fee Transporte] = SUM(COALESCE([FeeTransporte],0)),
-- MODIFICADO (2026-04-20): Ajuste Foraneo ahora es NEGATIVO (costo).
-- En PnL Operativo se suma positivamente como ingreso [Ajuste Foraneo].
[1.1.5.- Ajuste Foraneo] =
	-(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393217VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393217VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393218VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393218VARP] END,0))),
[1.1.6.- Ing. Cobro Pago]= 

	case 
		when periodo <= 202509 then 0 --modificado 27.05
		when periodo > 202509 and periodo <= 202606 then sum(coalesce([Gasto_CobroPagos],0))
	else 
		sum(coalesce([cp_ing_cobro_pago],0)) END,

-- MODIFICADO (2026-04-20): Costo Pago Adquirentes movido a seccion 1.1 (ingresos, negativo).
-- En PnL Operativo aparece como columna separada positiva [Costo Pago Adquirentes].
[1.1.7.- Costo Pago Adquirentes] = -(SUM(COALESCE(CASE WHEN a.fuente='V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CTTOT ELSE 0 END,0))-SUM(COALESCE(CASE WHEN a.fuente='V+' AND a.ukey NOT IN ('PRESTAMOS','RECARGAS Y SERVICIOS') THEN CVTOT ELSE 0 END,0))),
-- MODIFICADO (2026-04-20): Ing. Vendomatica movido a seccion 1.1. En PnL Operativo estaba en seccion 3 ([Ing. Vendomatica]).
[1.1.8.- Ing. Vendomatica] = SUM(COALESCE([Ingreso Trxs Vendomatica],0)),
[1.1.9.- Ing. Incentivo Campana] = sum(coalesce([cp_ing_incentivo_campana],0)),

------------------------------------------------------------
------------------------------------------------------------
[1.2.1.- Autenticación VbV MPI] = SUM(COALESCE([Cost Autenticacion],0))* @Factor_IRND,
[1.2.2.- Autenticación VbV VISA] = SUM(COALESCE([Cost VerifiedbyVisa],0))* @Factor_IRND,
[1.2.3.- Costo Pago Adquirentes] = 0,
[1.2.4.- Cuota MC Fijo Foraneo] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393288FIJONP] END,0))* @Factor_IRND,
[1.2.5.- Cuota MC Fijo Nacional] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393289FIJONP] END,0))* @Factor_IRND,
[1.2.6.- Cuota MC Fijo Total] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_TOT_6393257FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_TOT_6393279FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393250FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393251FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393252FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393253FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393276FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393283FIJONP] END,0)))* @Factor_IRND,
[1.2.7.1.- Cuota MC Ticket Foraneo] = 
	(SUM(COALESCE([TRX_MC_FOR_1],0))+
	SUM(COALESCE([TRX_MC_FOR_5_Menos],0))+
	SUM(COALESCE([TRX_MC_FOR_5],0))+
	SUM(COALESCE([TRX_MC_FOR_1_5],0))+
	SUM(COALESCE([TRX_MC_FOR_5_25],0))+
	SUM(COALESCE([TRX_MC_FOR_25],0)))* @Factor_IRND,
[1.2.7.2.- Cuota MC Ticket Nacional] = 
	(SUM(COALESCE([TRX_MC_NAC_1],0))+
	SUM(COALESCE([TRX_MC_NAC_1_5],0))+
	SUM(COALESCE([TRX_MC_NAC_5_25],0))+
	SUM(COALESCE([TRX_MC_NAC_25_100],0))+
	SUM(COALESCE([TRX_MC_NAC_5_10],0))+
	SUM(COALESCE([TRX_MC_NAC_10_25],0))+
	SUM(COALESCE([TRX_MC_NAC_100],0))+
	SUM(COALESCE([TRX_MC_NAC_25],0)))* @Factor_IRND,
[1.2.8.1.1.- Cuota MC Var Foraneo Volumen USD] = 
(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_USD_6393266VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.1.2.- Cuota MC Var Foraneo Volumen PEN] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_PEN_6393266VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.1.3.- Cuota MC Var Foraneo Volumen Otros CP] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_P_6393333VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.1.4.- Cuota MC Var Foraneo Volumen Otros CNP] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_NP_6393255VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.1.5.- Cuota MC Var Foraneo Volumen Otros] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_6393266VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_6393284VARNP] END,0)))* @Factor_IRND,
[1.2.8.2.1.- Cuota MC Var Foraneo Transacciones Autor. y Liq.] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393271VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393273VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393284VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393278VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.2.2.- Cuota MC Var Foraneo Transacciones Otros CNP] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393255VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.8.2.3.- Cuota MC Var Foraneo Transacciones Otros] =
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393254VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393268VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393277VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393283VARNP] END,0)))* @Factor_IRND,
[1.2.8.3.- Cuota MC Var Foraneo Performance] =
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393259VARP] END,0))+ --TPE-Autorizacion (Exceso de Reintentos)
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393273VARP] END,0))+ --Trx Liquidadas sin Aprobación de Autorización
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393283VARP] END,0))+ --Disputas, validacion de fondos y direccion
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393286VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393255VARP] END,0))+ --CVC transacciones no autenticadas
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_NP_6393255VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_NP_6393256VARP] END,0)))* @Factor_IRND,
[1.2.8.3.1- Cuota MC Var Foraneo Performance Otros CNP] =
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393286VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_NP_6393255VARP] END,0))+ --CVC transacciones no autenticadas
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_NP_6393255VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_NP_6393256VARP] END,0)))* @Factor_IRND,
[1.2.8.3.2- Cuota MC Var Foraneo Performance Otros] =
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_FOR_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393259VARP] END,0))+ --TPE-Autorizacion (Exceso de Reintentos)
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393273VARP] END,0))+ --Trx Liquidadas sin Aprobación de Autorización
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_FOR_6393283VARP] END,0)))* @Factor_IRND, --Disputas, validacion de fondos y direccion
[1.2.9.1.1.- Cuota MC Var Nacional Volumen Directo] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_CRE_NAC_6393280VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_DEB_NAC_6393269VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 WHEN a.Periodo <= 202412 THEN [MC_VOL_NAC_6393270VARNP] ELSE 0 END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.9.1.2.- Cuota MC Var Nacional Volumen Otros CP] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_P_6393332VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.9.1.3.- Cuota MC Var Nacional Volumen Otros CNP] = (SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_NP_6393255VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.9.1.4.- Cuota MC Var Nacional Volumen Otros] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 WHEN a.Periodo <= 202412 THEN 0 ELSE [MC_VOL_NAC_6393270VARNP] END,0))+ --Volumen Pre-Autorizacion 7 Liquidación en Moneda No Local
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_6393275VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_6393285VARNP] END,0)))* @Factor_IRND,	---nuevo 11.03.26
[1.2.9.2.- Cuota MC Var Nacional Transacciones] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393254VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393267VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393272VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393274VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393285VARNP] END,0)))* @Factor_IRND,
[1.2.9.3.- Cuota MC Var Nacional Performance] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_NP_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_6393255VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_NAC_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393258VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_6393283VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_NP_6393255VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_NP_6393256VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_NAC_NP_6393287VARP] END,0))
	)* @Factor_IRND,
[1.2.10.1.- Cuota MC Var Total Vol/Txs] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393282VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_VOL_TOT_6393283VARNP] END,0)))* @Factor_IRND,
[1.2.10.2.- Cuota MC Var Total Performance] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [MC_TRX_TOT_6393281VARP] END,0))* @Factor_IRND,
[1.2.11.1.- Cuota Reintentos Visa] = (SUM(COALESCE(CASE WHEN a.Periodo <= 202412 THEN 0 ELSE Gasto_Reintentos_VI END,0)))* @Factor_IRND,
[1.2.11.2.- Cuota Reintentos MC] = SUM(COALESCE([Gasto_Reintentos_MC],0))* @Factor_IRND,
[1.2.11.3.- Cuota Reintentos Legacy] = (SUM(COALESCE(CASE WHEN a.Periodo <= 202412 THEN GastoReintentos_Visa ELSE 0 END,0)))* @Factor_IRND,
[1.2.12.- Cuota Visa Fijo Foraneo] = 0,
[1.2.13.- Cuota Visa Fijo Nacional] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393102FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393102FIJOP] END,0)))* @Factor_IRND,
[1.2.14.- Cuota Visa Fijo Total] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_TOT_6393201FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_TOT_6393201FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393208FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393208FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393210FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393210FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393213FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393213FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393214FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393214FIJOP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393216FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393216FIJOP] END,0)))* @Factor_IRND,
[1.2.15.1.1- Cuota Visa Ticket Foraneo Otros CP] = 
	(SUM(COALESCE([TRX_VI_DEB_FOR_P_0_5],0))+SUM(COALESCE([TRX_VI_DEB_FOR_P_5_15],0))+SUM(COALESCE([TRX_VI_DEB_FOR_P_15_50],0))+
	SUM(COALESCE([TRX_VI_DEB_FOR_P_50_100],0))+SUM(COALESCE([TRX_VI_DEB_FOR_P_100_250],0))+SUM(COALESCE([TRX_VI_DEB_FOR_P_250],0))+
	SUM(COALESCE([TRX_VI_CRE_FOR_P_0_5],0))+SUM(COALESCE([TRX_VI_CRE_FOR_P_5_15],0))+SUM(COALESCE([TRX_VI_CRE_FOR_P_15_50],0))+
	SUM(COALESCE([TRX_VI_CRE_FOR_P_50_100],0))+SUM(COALESCE([TRX_VI_CRE_FOR_P_100_250],0))+SUM(COALESCE([TRX_VI_CRE_FOR_P_250],0)))* @Factor_IRND,
[1.2.15.1.2- Cuota Visa Ticket Foraneo Otros CNP] = 
	(SUM(COALESCE([TRX_VI_DEB_FOR_NP_0_5],0))+SUM(COALESCE([TRX_VI_DEB_FOR_NP_5_15],0))+SUM(COALESCE([TRX_VI_DEB_FOR_NP_15_50],0))+
	SUM(COALESCE([TRX_VI_DEB_FOR_NP_50_100],0))+SUM(COALESCE([TRX_VI_DEB_FOR_NP_100_250],0))+SUM(COALESCE([TRX_VI_DEB_FOR_NP_250],0))+
	SUM(COALESCE([TRX_VI_CRE_FOR_NP_0_5],0))+SUM(COALESCE([TRX_VI_CRE_FOR_NP_5_15],0))+SUM(COALESCE([TRX_VI_CRE_FOR_NP_15_50],0))+
	SUM(COALESCE([TRX_VI_CRE_FOR_NP_50_100],0))+SUM(COALESCE([TRX_VI_CRE_FOR_NP_100_250],0))+SUM(COALESCE([TRX_VI_CRE_FOR_NP_250],0)))* @Factor_IRND,
[1.2.15.2.1.- Cuota Visa Ticket Debito Otros CP] = --Nuevo
	(SUM(COALESCE([TRX_VI_DEB_NAC_P_0_2],0))+SUM(COALESCE([TRX_VI_DEB_NAC_P_2_5],0))+
	SUM(COALESCE([TRX_VI_DEB_NAC_P_5_15],0))+SUM(COALESCE([TRX_VI_DEB_NAC_P_15_50],0))+SUM(COALESCE([TRX_VI_DEB_NAC_P_50],0)))* @Factor_IRND,
[1.2.15.2.2.- Cuota Visa Ticket Debito Otros CNP] =  --Nuevo
	(SUM(COALESCE([TRX_VI_DEB_NAC_NP_0_2],0))+SUM(COALESCE([TRX_VI_DEB_NAC_NP_2_5],0))+
	SUM(COALESCE([TRX_VI_DEB_NAC_NP_5_15],0))+SUM(COALESCE([TRX_VI_DEB_NAC_NP_15_50],0))+SUM(COALESCE([TRX_VI_DEB_NAC_NP_50],0)))* @Factor_IRND,
[1.2.15.3.1.- Cuota Visa Ticket Credito Otros CP] = 
	(SUM(COALESCE([TRX_VI_CRE_NAC_P_0_2],0))+SUM(COALESCE([TRX_VI_CRE_NAC_P_2_5],0))+
	SUM(COALESCE([TRX_VI_CRE_NAC_P_5_15],0))+SUM(COALESCE([TRX_VI_CRE_NAC_P_15_50],0))+SUM(COALESCE([TRX_VI_CRE_NAC_P_50],0)))* @Factor_IRND,
[1.2.15.3.2.- Cuota Visa Ticket Credito Otros CNP] = 
	(SUM(COALESCE([TRX_VI_CRE_NAC_NP_0_2],0))+SUM(COALESCE([TRX_VI_CRE_NAC_NP_2_5],0))+
	SUM(COALESCE([TRX_VI_CRE_NAC_NP_5_15],0))+SUM(COALESCE([TRX_VI_CRE_NAC_NP_15_50],0))+SUM(COALESCE([TRX_VI_CRE_NAC_NP_50],0)))* @Factor_IRND,
[1.2.16.1.1.- Cuota Visa Var Foraneo Volumen PEN] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393241VARNP] END,0))* @Factor_IRND,
[1.2.16.1.2.- Cuota Visa Var Foraneo Volumen USD CNP] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393242VARNP] END,0))* @Factor_IRND,
[1.2.16.1.3.- Cuota Visa Var Foraneo Volumen USD] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393245VARNP] END,0))* @Factor_IRND,
[1.2.16.1.4.- Cuota Visa Var Foraneo Volumen Otros] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393103VARNP] END,0))* @Factor_IRND,
[1.2.16.2.- Cuota Visa Var Foraneo Transacciones] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393101VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393207VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393237VARNP] END,0)))* @Factor_IRND,
[1.2.16.3.- Cuota Visa Var Foraneo Performance] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393101VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393207VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393237VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393103VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393241VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393242VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393245VARP] END,0)))* @Factor_IRND,
[1.2.17.1.1.- Cuota Visa Var Nacional Volumen Debito] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_DEB_NAC_6393220VARNP] END,0))* @Factor_IRND,
[1.2.17.1.2.- Cuota Visa Var Nacional Volumen Credito] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_CRE_NAC_6393212VARNP] END,0))* @Factor_IRND,
[1.2.17.1.3.- Cuota Visa Var Nacional Volumen No Token] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_NAC_NP_6393329VARNP] END,0))* @Factor_IRND,
[1.2.17.2.- Cuota Visa Var Nacional Transacciones] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393202VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393236VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393238VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393240VARNP] END,0)))* @Factor_IRND,
[1.2.17.3.- Cuota Visa Var Nacional Performance] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393202VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393236VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393238VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393240VARP] END,0)))* @Factor_IRND,
[1.2.17.4.- Cuota Visa Var Nacional 4900 DASF Fijo] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_NAC_6393244VARNP] END,0)))* @Factor_IRND,
[1.2.17.5.- Cuota Visa Var Nacional 9311 DASF Fijo Debito] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_DEB_NAC_6393328VARNP] END,0))* @Factor_IRND,
[1.2.17.6.- Cuota Visa Var Nacional 9311 DASF Fijo Credito] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_CRE_NAC_6393328VARNP] END,0))* @Factor_IRND,
[1.2.18.1.- Cuota Visa Var Total Vol/Txs] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393216VARNP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393219VARNP] END,0)))* @Factor_IRND,
[1.2.18.2.- Cuota Visa Var Total Performance] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393216VARP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_6393219VARP] END,0)))* @Factor_IRND,
[1.2.18.3.- Cuota Visa Var Total Tokenizacion] = SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_TOT_NP_6393239VARNP] END,0))* @Factor_IRND,
[1.2.19.1.- Cuota Multas Visa] = SUM(COALESCE([Gasto_Cuotas_Multas_VI],0))* @Factor_IRND,
[1.2.19.2.- Cuota Multas MC] = SUM(COALESCE([Gasto_Cuotas_Multas_MC],0))* @Factor_IRND,
[1.2.20.1.- Cuota PIPF Visa] = SUM(COALESCE([Gasto_Cuotas_PIPF_VI],0))* @Factor_IRND,
[1.2.20.2.- Cuota PIPF MC] = SUM(COALESCE([Gasto_Cuotas_PIPF_MC],0))* @Factor_IRND,
[1.2.21.1.- Cuota Suscripciones Visa] = SUM(COALESCE([Gasto_Cuotas_Suscripciones_VI],0))* @Factor_IRND,
[1.2.21.2.- Cuota Suscripciones MC] = SUM(COALESCE([Gasto_Cuotas_Suscripciones_MC],0))* @Factor_IRND,
[1.2.22.1.- Cuota Fee Anual Visa] = SUM(COALESCE([Gasto_Cuotas_Fee_Anual_VI],0))* @Factor_IRND,
[1.2.22.2.- Cuota Fee Anual MC] = SUM(COALESCE([Gasto_Cuotas_Fee_Anual_MC],0))* @Factor_IRND,
------------------------------------------------------------
------------------------------------------------------------
[2.1.1.- Ing. Analytics] = SUM(COALESCE([CostoAnalytics],0)),
[2.1.2.- Ing. Criptograma] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-1') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-1') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-1') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-1') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-1') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
-- MODIFICADO (2026-04-20): Ing. Data agrega 'MC' a la lista de exclusion.
-- En PnL Operativo la lista es ('VD','VF','VP','VT','VV','VL') sin 'MC'.
[2.1.3.- Ing. Data] = --X--
	SUM(COALESCE(CASE WHEN a.codproductoNBO IN ('VD','VF','VP','VT','VV','VL','MC','PS') THEN 0 ELSE [iNGRESOStRANSACCIONESdATA] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductoNBO IN ('VD','VF','VP','VT','VV','VL','MC','PS') THEN 0 ELSE [iNGRESOSPOSaCTIVO] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductoNBO IN ('VD','VF','VP','VT','VV','VL','MC','PS') THEN 0 ELSE [iNGRESOStARJETAS] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductoNBO IN ('VD','VF','VP','VT','VV','VL','MC','PS') THEN 0 ELSE [iNGRESOSsETup] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductoNBO IN ('VD','VF','VP','VT','VV','VL','MC','PS') THEN 0 ELSE [oTROSiNGRESOS] END,0)),
[2.1.4.- Ing. Diners/Amex] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-4','VT-6') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-4','VT-6') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-4','VT-6') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-4','VT-6') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-4','VT-6') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.5.- Ing. Flotas] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VL-1') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VL-1') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VL-1') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VL-1') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VL-1') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.6.- Ing. Fraude] = SUM(COALESCE([iNGRESOSsOLUCIONESfRAUDE],0)),
[2.1.7.- Ing. P2P] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-0','VD-1') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-0','VD-1') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-0','VD-1') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-0','VD-1') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-0','VD-1') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.8.- Ing. Prestamos] = SUM(COALESCE(IngresosPrestamos,0)),
[2.1.9.- Ing. Recargas y Servicios] =
	CASE 
    WHEN a.Periodo < 202600 THEN 
        (
            sum(coalesce(IngresosRecargasServicios,0)) +
            sum(coalesce(case when a.CodProductoNBO + '-' + a.CodSubProductoNBO = 'VL-3' then [iNGRESOStRANSACCIONESdATA] else 0 end,0)) +
            sum(coalesce(case when a.CodProductoNBO + '-' + a.CodSubProductoNBO = 'VL-3' then [iNGRESOSPOSaCTIVO] else 0 end,0)) +
            sum(coalesce(case when a.CodProductoNBO + '-' + a.CodSubProductoNBO = 'VL-3' then [iNGRESOStARJETAS] else 0 end,0)) +
            sum(coalesce(case when a.CodProductoNBO + '-' + a.CodSubProductoNBO = 'VL-3' then [iNGRESOSsETup] else 0 end,0)) +
            sum(coalesce(case when a.CodProductoNBO + '-' + a.CodSubProductoNBO = 'VL-3' then [oTROSiNGRESOS] else 0 end,0)) -
            sum(coalesce(case when a.fuente = 'V+' then GastoRecargasServicios else 0 end,0))
        )

    ELSE 
        sum(coalesce(case when a.fuente = 'V+' then Ingreso_Vendemas_RYS else 0 end,0)) +
        sum(coalesce(case when a.fuente = 'Niubiz' then Ingreso_Niubiz_RYS else 0 end,0)) +
        sum(coalesce(case when a.fuente = 'Niubiz' then Ingreso_Vendemas_RYS else 0 end,0))

END,
[2.1.10.- Ing. Corresponsalia] = 
	SUM(COALESCE(CASE WHEN a.CodProductoNBO+'-'+ a.CodSubProductoNBO='VL-4' THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.CodProductoNBO+'-'+ a.CodSubProductoNBO='VL-4' THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.CodProductoNBO+'-'+ a.CodSubProductoNBO='VL-4' THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.CodProductoNBO+'-'+ a.CodSubProductoNBO='VL-4' THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.CodProductoNBO+'-'+ a.CodSubProductoNBO='VL-4' THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.11.- Ing. Soluciones Fidelizacion] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VF-2','VF-3','VF-1') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VF-2','VF-3','VF-1') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VF-2','VF-3','VF-1') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VF-2','VF-3','VF-1') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VF-2','VF-3','VF-1') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.12.- Ing. Soluciones Financieras] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VV-1','VV-2') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VV-1','VV-2') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VV-1','VV-2') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VV-1','VV-2') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VV-1','VV-2') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.13.- Ing. Soluciones Prestamos] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VP-0','PS-CP') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VP-0','PS-CP') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VP-0','PS-CP') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VP-0','PS-CP') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VP-0','PS-CP') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.14.- Ing. Soluciones Procesamiento] = 
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-2','VT-3','VT-5') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-2','VT-3','VT-5') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-2','VT-3','VT-5') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-2','VT-3','VT-5') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VT-2','VT-3','VT-5') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.15.- Ing. PushPayments] =
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-3','VD-4','VD-5','VD-6','VD-7','MC-4','VD-9') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-3','VD-4','VD-5','VD-6','VD-7','MC-4','VD-9') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-3','VD-4','VD-5','VD-6','VD-7','MC-4','VD-9') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-3','VD-4','VD-5','VD-6','VD-7','MC-4','VD-9') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl IN ('VD-3','VD-4','VD-5','VD-6','VD-7','MC-4','VD-9') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.16.- Ing. Giftcards]=
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VV-3') THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VV-3') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VV-3') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VV-3') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VV-3') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.17.- Ing. Pago de Deuda]=
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VD-8','VD-2')  THEN [iNGRESOStRANSACCIONESdATA] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VD-8','VD-2') THEN [iNGRESOSPOSaCTIVO] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VD-8','VD-2') THEN [iNGRESOStARJETAS] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VD-8','VD-2') THEN [iNGRESOSsETup] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.vkey_pl in ('VD-8','VD-2') THEN [oTROSiNGRESOS] ELSE 0 END,0)),
[2.1.18.- Ing. Funds Transfer] = sum(coalesce([cp_ing_funds_transfer],0)),
[2.1.19.- Ing. Marca Cerrada] = sum(coalesce([cp_ing_marca_cerrada],0)),
[2.1.20.- Ing. PIFO] = sum(coalesce([cp_ing_pifo],0)),
------------------------------------------------------------
------------------------------------------------------------
[2.2.1.- Cuotas MoneySend] = SUM(COALESCE([MC_VD0_VD1_6393310VARNP],0))* @Factor_IRND,
[2.2.2.- Cuotas VisaDirect P2P] = 
	(SUM(COALESCE([VI_VD0_VD1_6393225VARNP],0))+
	SUM(COALESCE([VI_VD0_VD1_6393312VARNP],0))+
	SUM(COALESCE([VI_VD0_VD1_6393310VARNP],0))+
	SUM(COALESCE([VI_VDA_6393310VarNP],0))+
	SUM(COALESCE([VI_VD0_6393310VarNP],0))
	)* @Factor_IRND,
[2.2.3.- Cuotas VisaDirect PP] = 
	(SUM(COALESCE([VI_VD2_6393311VARNP],0))+
	SUM(COALESCE([VI_VD3_6393309VARNP],0))+
	SUM(COALESCE([VI_VD4_6393307VARNP],0))+
	SUM(COALESCE([VI_VD5_6393306VARNP],0))+
	SUM(COALESCE([VI_VD6_6393308VARNP],0))+
	SUM(COALESCE([VI_VD7_6393308VARNP],0))+
	SUM(COALESCE([VI_VD9_6393336VarNP],0))
	)* @Factor_IRND,
[2.2.4.- Gasto Cupo] = SUM(COALESCE(costocupo,0)),
[2.2.5.- Gasto Flotas] = SUM(COALESCE([GastoFlotas],0)),
[2.2.6.- Gasto Recargas y Servicios] = 
	CASE 
	WHEN a.Periodo < 202600 THEN (sum(coalesce(case when a.fuente='V+' or a.codproductonbo+'-'+a.codsubproductonbo='VV-3' then 0 else [GastoRecargasServicios] end,0)))
	ELSE 
        sum(coalesce(case when a.fuente = 'V+' then Costo_Vendemas_RYS else 0 end,0)) +
        sum(coalesce(case when a.fuente = 'Niubiz' then Costo_Niubiz_RYS else 0 end,0)) +
        sum(coalesce(case when a.fuente = 'Niubiz' then Ingreso_Vendemas_RYS else 0 end,0))
	END,	
[2.2.7.- Gasto Giftcards]= SUM(COALESCE(CASE WHEN a.codproductonbo+'-'+a.codsubproductonbo ='VV-3' THEN [GastoRecargasServicios] ELSE 0 END,0)),
[2.2.8.- Costo Marca Cerrada]= sum(coalesce([cp_costo_marca_cerrada],0)),
------------------------------------------------------------
------------------------------------------------------------
[3.1.1.- Ing. Afiliaciones] = 
	SUM(COALESCE([Afiliacion REC],0))+
	SUM(COALESCE([Ing Afiliaciones],0)),
[3.1.2.- Ing. Agente Tercero] = SUM(COALESCE([Inc AgenteTercero],0)),
[3.1.3.- Ing. Alquiler] = 
	SUM(COALESCE([Alquiler Ingreso],0))+
	SUM(COALESCE([IngresoAlquilerEquipo],0)),
[3.1.4.- Ing. Antifraude] = SUM(COALESCE([Ing CyberSource],0)),
[3.1.5.1.- Ing. DCC Cobro al TH] = SUM(COALESCE([DCC_Ingreso],0)),
[3.1.5.2.- Dscto. DCC Comercio] = -SUM(COALESCE([DCC_Dscto],0)),
[3.1.6.- Ing. Envio de EECC] = 0,
[3.1.7.- Ing. Instalacion] = SUM(COALESCE([Instalacion Costo],0)),
[3.1.8.- Ing. Izipay] = SUM(COALESCE([IngresosIzipay],0)),
[3.1.9.- Ing. Linea 0800] = SUM(COALESCE([L0800 Ingreso],0)),
[3.1.10.- Ing. Membresia] = SUM(COALESCE([IngfeeMenbresia],0)),
[3.1.11.- Ing. Peajes] = 
	SUM(COALESCE(IngresosPeajes,0))+
	SUM(COALESCE([PeajesProcesam],0)),
[3.1.12.- Ing. por Manteminiento] = 
	SUM(COALESCE([Mantenimiento REC],0))+
	SUM(COALESCE([Ingreso por mantenimiento],0))+
	SUM(COALESCE([IngresosMantenimiento],0)),
[3.1.13.- Ing. Por renovación.] = 
	SUM(COALESCE([Ingreso por renovacion],0))+
	SUM(COALESCE([Ing Renovacion],0)),
[3.1.14.1.- Ing. Por reparacion] = SUM(COALESCE([Reparacion Accesorios],0)),
[3.1.14.2.- Ing. Por Robo POS] = SUM(COALESCE([Robos Ingreso],0)),
[3.1.15.- Ing. por Telepago] = SUM(COALESCE([Ingreso por transaccion],0)),
[3.1.16.- Ing. Pre autorizacion] = SUM(COALESCE([PreAutorizacion Ingreso],0)),
[3.1.17.- Otros Ing. de Serv. Adq.] = sum(coalesce([cp_otros_ing_de_serv_adq],0)),
[3.1.18.- Ing. Vendomatica] = 0,
[3.1.19.- Ing. Venta Poket] = SUM(COALESCE([Ingreso Poket],0)),
[3.1.20.- Ing. de Comision No Adquirente] = sum(coalesce([cp_ing_de_comision_no_adq],0)),

[2.1.21.- CP Dummy Servicios de Procesamiento] = sum(coalesce([cp_dummy_servicios_de_procesamiento],0)),
[3.1.21.- CP Dummy Otros Servicios Adquiriente] = sum(coalesce([cp_dummy_otros_servicios_adquiriente],0)),
[1.1.10.- CP Dummy Comision Adquirente] = sum(coalesce([cp_dummy_comision_adquirente],0)),
[1.1.11.- Ing. Cobropagos Legacy] = 
	case 
		when periodo <= 202509 then sum(coalesce([EECC Ingreso],0)) --modificado 27.05
	else 
		0 END,

------------------------------------------------------------
------------------------------------------------------------
[3.2.1.- Costo Linea 0800] = SUM(COALESCE([L0800 Costo],0)),
[3.2.2.1.- Gasto DCC Proveedor] = SUM(COALESCE([DCC_Fee],0)),
[3.2.2.2.- Gasto DCC Riesgo] = SUM(COALESCE([DCC_Risk],0)),
[3.2.3.- Gasto Devoluciones y Averias] = SUM(COALESCE([DevolucionesAverias],0)),
[3.2.4.- Gasto Poket] = SUM(COALESCE([Cost Poket],0)),
[3.2.5.1.- Gastos por afiliación Legacy] = 
	SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Afiliacion CPA CorporativoDCC] ELSE 0 END,0))+ 
	SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Afiliacion CPA VariableDCC] ELSE 0 END,0)),
[3.2.5.2.- Gastos por afiliación Real] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Gasto_Afiliacion_Real] ELSE 0 END,0)),
[3.2.5.3.- Gastos por afiliación Provision] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Gasto_Afiliacion_Provision] ELSE 0 END,0)),
[3.2.5.4.- Gastos por afiliación Extorno] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Gasto_Afiliacion_Extorno] ELSE 0 END,0)),
[3.2.6.- Gasto Digitacion y Monitoreo] = 
	SUM(COALESCE([Afiliacion CPA DigitMonit],0))+
	SUM(COALESCE([Digitacion_Monitoreo],0)),
[3.2.7.1.- Cuotas DCC Fija] = 
	SUM(COALESCE([DCC_Cuotas],0))+	
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393222FIJONP] END,0))+
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_TRX_FOR_6393222FIJOP] END,0)))* @Factor_IRND,
[3.2.7.2.- Cuotas DCC Variable] = 
	(SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393243VARNP] END,0))+												
	SUM(COALESCE(CASE WHEN a.codproductonbo = 'VD' THEN 0 ELSE [VI_VOL_FOR_6393243VARP] END,0)))* @Factor_IRND,
[3.2.8.- Gasto Call Center - CPA] =
	SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Cost_Call_Afil] ELSE 0 END,0)),
[3.2.9.1.- Gastos por afiliación - Multiagente Real] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Afiliacion Costo] ELSE 0 END,0)),
[3.2.9.2.- Gastos por afiliación - Multiagente Provision] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Afiliacion Habilitado Costo] ELSE 0 END,0)),
[3.2.9.3.- Gastos por afiliación - Multiagente Extorno] = SUM(COALESCE(CASE WHEN @G_Afil = 'Si' THEN [Afiliacion Generado Costo] ELSE 0 END,0)),
------------------------------------------------------------
------------------------------------------------------------
[4.1.1.- Gasto Alignet] = SUM(COALESCE([Costo Alignet],0)),
[4.1.2.- Gasto de EECC] = SUM(COALESCE([EECC Costo],0)),
[4.1.3.- Aporte Portafolio]=-SUM(COALESCE([IngresoAporteVISAPortafolio],0)),
[4.1.4.- Gasto Envio Poket] = SUM(COALESCE([Costo Envio Poket],0)),
[4.1.5.- Gasto Izipay] = SUM(COALESCE([GastosIzipay],0)),
[4.1.6.- Otros Gastos] = sum(coalesce([CP_otros_gastos],0)),
[4.1.7.- Refacturación de servicios] = 
	SUM(COALESCE([IngresoRefacturacionMKT],0))+
	SUM(COALESCE([IngresoRefacturacionServicios],0)),
[4.1.8.1.1.- Gasto Portafolio Codigo PDV] = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_PDV],0)),
[4.1.8.1.2.- Gasto Portafolio Codigo RET] = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_RET],0)),
[4.1.8.1.3.- Gasto Portafolio Codigo PRO] = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_PRO],0)),
[4.1.8.1.4.- Gasto Portafolio Codigo GRO] = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_GRO],0)),
[4.1.8.1.5.- Gasto Portafolio Codigo HOT] = SUM(COALESCE(CASE WHEN a.Periodo <= 202512 THEN [COSTO_PORTAFOLIO_CODIGOCOMERCIO_HOT] ELSE 0 END,0)),
[4.1.8.1.6.- Gasto Portafolio Codigo PS]  = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_PS],0)),
[4.1.8.1.7.- Gasto Portafolio Codigo TAW] = SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_TAW],0)),
[4.1.8.2.1.- Gasto Portafolio CUC PDV] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_PDV],0)),
[4.1.8.2.2.- Gasto Portafolio CUC RET] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_RET],0)),
[4.1.8.2.3.- Gasto Portafolio CUC PRO] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_PRO],0)),
[4.1.8.2.4.- Gasto Portafolio CUC GRO] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_GRO],0)),
[4.1.8.2.5.- Gasto Portafolio CUC HOT] = SUM(COALESCE(CASE WHEN a.Periodo <= 202512 THEN [COSTO_PORTAFOLIO_CUC_HOT] ELSE 0 END,0)),
[4.1.8.2.6.- Gasto Portafolio CUC PS] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_PS],0)),
[4.1.8.2.7.- Gasto Portafolio CUC TAW] = SUM(COALESCE([COSTO_PORTAFOLIO_CUC_TAW],0)),
[4.1.8.3.- Gasto Portafolio Publicidad] = SUM(COALESCE([Publicidad_Costo_Portafolio],0)), 
[4.1.8.4.- Gasto Portafolio Segmento] = 0,
------------------------------------------------------------
------------------------------------------------------------
[4.2.1.1.- Gasto de personal Gestion Empresa] = SUM(COALESCE([Gasto_CrossNiubiz],0)),
[4.2.1.2.- Gasto de personal Gestion Dominio] = SUM(COALESCE([Gasto_CrossUnidad],0)),
[4.2.1.3.- Gasto de personal Gestion Producto] = SUM(COALESCE([Gasto_CrossOnline],0)),
[4.2.1.4.- Gasto de personal Procesamiento] = SUM(COALESCE([personal_costo_procesamiento],0)),
[4.2.1.5.- Gasto de personal Adquirencia] = SUM(COALESCE([Personal Costo],0)),
[4.2.1.6.- Gasto de personal (Otros)] = SUM(COALESCE([Gasto_SIG],0)),
------------------------------------------------------------
------------------------------------------------------------
[4.3.1.- Gasto Chips] = SUM(COALESCE([Chips Costo],0)),
[4.3.2.- Gasto Contometros] = SUM(COALESCE([Cost Contometro],0)),
[4.3.3.1.- Gasto Instalacion por Ferias y Eventos]=SUM(COALESCE([Ferias y eventos],0)),
[4.3.3.2.- Gasto Instalacion por Impresion Laser]=SUM(COALESCE([Impr Laser],0)),
[4.3.3.3.- Gasto Instalacion Regular]=
	SUM(COALESCE(CASE WHEN (a.fuente='Niubiz' and a.periodo<>202405) THEN [OtrosRDP] ELSE 0 END,0))+
	SUM(COALESCE(CASE WHEN a.periodo >= 202401 THEN 0 ELSE [InstaDiariaExpress] END,0)),
[4.3.3.4.- Gasto Instalacion por Eventos Express]=SUM(COALESCE([InstaEventosExpress],0)),
[4.3.4.- Gasto Migraciones] = SUM(COALESCE([Cost Migraciones],0)),
[4.3.5.1.- Gasto Mntto ParquePOS Alquiler] = SUM(COALESCE([MPOS_RDP_Alquiler],0)),
[4.3.5.2.- Gasto Mntto ParquePOS Venta] = SUM(COALESCE([MPOS_RDP_Venta],0)),
[4.3.5.3.- Gasto Mntto ParquePOS Instalacion] = SUM(COALESCE(CASE WHEN a.periodo >= 202401 THEN [InstaDiariaExpress] ELSE 0 END,0)),
[4.3.5.4.- Gasto Mntto ParquePOS Laboratorio] = SUM(COALESCE([MRDP_Laboratorio],0)),
[4.3.5.5.- Gasto Mntto ParquePOS Llamada] = SUM(COALESCE([MRDP_Llamadas],0)),
[4.3.5.6.- Gasto Mntto ParquePOS Atenciones] = SUM(COALESCE([MRDP_Atenciones],0)),
[4.3.5.7.- Gasto Mntto ParquePOS Parque] = SUM(COALESCE([MRDP_Parque],0)),
[4.3.5.8.- Gasto Mntto ParquePOS Legacy] = SUM(COALESCE([MPOS_RDP],0)),
[4.3.6.- Gasto Recupero de POS] = SUM(COALESCE([Recupero Costo],0)),
[4.3.7.- Gasto Serv Integración] = SUM(COALESCE([Cost Tercerizado],0)),--PEDIR APERTURA
[4.3.8.- Gasto Suministros] = SUM(COALESCE([Suministro Costo],0)),
[4.3.9.1.- Gasto Telecarga Licencia TMS] = SUM(COALESCE([TELECARGA_LICENCIA_TMS_MONTO],0)), --nuevo
[4.3.9.2.- Gasto Telecarga EstateManager] = SUM(COALESCE([TELECARGA_ESTATEMANAGER_MONTO],0)), --nuevo
[4.3.9.3.- Gasto Telecarga Ontetime] = SUM(COALESCE([TELECARGA_ONTETIME_MONTO],0)), --nuevo
------------------------------------------------------------
------------------------------------------------------------
[4.4.1.- Costo Geopagos] = SUM(COALESCE([Monto_Geopagos],0)), --nuevo
[4.4.2.- Gasto Geopagos] = SUM(COALESCE([Cost Geopagos],0)),
------------------------------------------------------------
------------------------------------------------------------

[4.5.1.1.- Gasto Antifraude Cybersource] = (SUM(COALESCE([GastoCyberSource],0))+SUM(COALESCE([Cost CyberSource],0)))* @Factor_IRND,
[4.5.1.2.- Gasto Antifraude Amortizacion SAS] = 0,
[4.5.1.3.- Gasto por Decision Management CyberSource] = (SUM(COALESCE([Replugin],0)))* @Factor_IRND,
[4.5.2.- Gasto Antifraude SVA] = 0,
[4.5.3.- Gasto Canales] = SUM(COALESCE([GastoCanales],0)),
[4.5.4.- Gasto Canales SVA] = 0,
[4.5.5.1.- Gasto SAS Legacy] = SUM(COALESCE([CostoSAS],0)),
[4.5.5.2.- Gasto SAS Pre] = SUM(COALESCE([Gasto_SAS_Pre],0)),
[4.5.5.3.- Gasto SAS Post] = SUM(COALESCE([Gasto_SAS_Post],0)),
[4.5.5.4.- Gasto SAS Pre y Post] = SUM(COALESCE([Gasto_SAS_Pre_Post],0)),
[4.5.6.- Gasto SAS SVA] = 0,
[4.5.7.- Registro MPI] = SUM(COALESCE([CostPlugIN],0)), --COSTO MPI 0.02
[4.5.8.- Renovación MPI] = 0,

------------------------------------------------------------
------------------------------------------------------------
[4.6.1.1.- Gasto Antifraude Amortizacion SAS] = SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [GastoAmortizacionSAS] END,0)),
[4.6.1.2.- Otros Gastos de Amortizaciones] = SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [Costo Amortizaciones] END,0)),
[4.6.2.- Gasto Depreciación Activa] = 
	SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [DepreciacionActiva] END,0))+
	SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [Depreciacion Costo] END,0)),
------------------------------------------------------------
------------------------------------------------------------
[4.7.1.- Gasto Controversias] = SUM(COALESCE([GastoControversiasAsumidas],0)),
------------------------------------------------------------
------------------------------------------------------------
[4.8.1.- Gasto Call Center] = SUM(COALESCE([GastoPostVenta],0)) + SUM(COALESCE([Visitas Costo],0)) , 
[4.8.2.- Gasto Call Tecnico] = SUM(COALESCE([Gasto_CallCenter_Pool],0)),
[4.8.3.- Gasto de visitas] = 0,
------------------------------------------------------------
------------------------------------------------------------
[4.9.1.- Gasto Contracargo] = SUM(COALESCE(CASE WHEN a.fuente ='V+' AND a.Periodo <= 202409 THEN [Incobrable] ELSE [ContraCargo] END,0)), --CONSULTAR REPROCESO
[4.9.2.- Gasto Incobrables] = SUM(COALESCE(CASE WHEN a.fuente ='V+' AND a.Periodo <= 202409 THEN [ContraCargo] ELSE [Incobrable] END,0)), --CONSULTAR REPROCESO
------------------------------------------------------------
------------------------------------------------------------
[5.1.1.- Gasto Agente Tercero] = SUM(COALESCE([Cost AgenteTercero],0)),
------------------------------------------------------------
------------------------------------------------------------
[5.2.1.- Aporte Visa] = SUM(COALESCE([IngresoAporteVISAMKT],0)),
[5.2.2.- Gasto de MKT] =
	SUM(COALESCE([Publicidad Costo],0))+
	SUM(COALESCE([Publicidad_Costo_MKT],0))+
	SUM(COALESCE([COSTO_PORTAFOLIO_CODIGOCOMERCIO_HOT],0))+ ---ENTRO en Validaciones para todos los periodos (cambio 16.02.26)
	SUM(COALESCE([COSTO_PORTAFOLIO_CUC_HOT],0))+ ---ENTRO en Validaciones para todos los periodos (cambio 16.02.26)
	SUM(COALESCE([Gasto_Portafolio_Segmento],0)),
------------------------------------------------------------
------------------------------------------------------------
[5.3.1.- Costo Invenio] = SUM(COALESCE([Monto_Invenio],0)), --nuevo
[5.3.2.- Costo Telefonica] = SUM(COALESCE([GastoNBOProcesamiento],0))* @Factor_TipoPL,
[5.3.3.- Gasto Telefonica SVA] = 0,
------------------------------------------------------------
------------------------------------------------------------
[5.4.1.- Gasto Personal Eventual] = 
	SUM(COALESCE([GastoEventualRemplazo],0))+ 
	SUM(COALESCE([GastoEventualRemplazo_Seg],0)), 
------------------------------------------------------------
------------------------------------------------------------
[5.5.1.1.- Gasto de Desarrollo de Operaciones] = SUM(COALESCE([Desarrollo_OPE],0)), --URSULA: OUTSOURCING TECNOLOGIA, OPERACIONES
[5.5.1.2.- Gasto de Desarrollo de Soporte Empresa] = SUM(COALESCE([Desarrollo_SOPORTE],0)), --JOSEFINA: DESAROLLOS CRM
[5.5.1.3.- Gasto de Desarrollo de Proyectos de Tecnologia] = SUM(COALESCE([Desarrollo_TEC],0)), --VARIOS: MESAS DE PROYECTOS
[5.5.1.4.- Gasto de Desarrollo de Servicio al Cliente] = SUM(COALESCE([Desarrollo_SSCC],0)), --MARCO BARRAGAN: MONITOREO Y SERVICIO AL CLIENTE
[5.5.1.5.- Gasto de Desarrollo (Otros)] = 
	SUM(COALESCE([Desarrollo Costo],0))+
	SUM(COALESCE([Cost Infraestructura],0))+
	SUM(COALESCE([Cost Licencia E-Core],0))+
	SUM(COALESCE([Cost Monitoreo],0))+
	SUM(COALESCE([Cost Soporte],0))+
	SUM(COALESCE([GastoProducto],0)),
[5.5.2.- Gasto Testing factory] = SUM(COALESCE([Testing Factory Costo],0)),
------------------------------------------------------------
------------------------------------------------------------
[5.6.1.- Gasto de Personal Middle] = SUM(COALESCE([Cost_Personal_Middle],0)), -- nuevo
------------------------------------------------------------
------------------------------------------------------------
[5.7.1.- Gasto Alquileres] = 
	SUM(COALESCE(CASE WHEN a.fuente='Niubiz' THEN 0 ELSE [OtrosRDP] END,0)),
------------------------------------------------------------
------------------------------------------------------------
[5.8.1.- Gasto Depreciación Baja] = 
--SUM(COALESCE(CASE WHEN @TipoPL = 'FC' OR h.Tipo NOT IN ('Presencial') THEN 0 ELSE [DepreciacionProvision] END,0)), --nuevo
SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [DepreciacionProvision] END,0)), --nuevo
[5.8.2.- Gasto Depreciación Inactiva] = 
--SUM(COALESCE(CASE WHEN @TipoPL = 'FC' OR h.Tipo NOT IN ('Presencial') THEN 0 ELSE [DepreciacionInactiva] END,0)), --nuevo
SUM(COALESCE(CASE WHEN @TipoPL = 'FC' THEN 0 ELSE [DepreciacionInactiva] END,0)) --nuevo
------------------------------------------------------------
------------------------------------------------------------
FROM (
	-- base filtrada + llaves calculadas una sola vez por fila
	SELECT
		b.*,
		TRIM(CASE WHEN b.RUC = '20517746046' THEN 'VL' WHEN b.Fuente <> 'V+' AND (b.CodProductoNBO IS NULL OR b.CodProductoNBO = '' OR b.CodProductoNBO = '0' OR b.CodSubProductoNBO = 'BP') THEN 'BS' WHEN b.Fuente = 'V+' AND (b.CodProductoNBO IS NULL OR b.CodProductoNBO = '' OR b.CodProductoNBO = '0' OR b.CodSubProductoNBO = 'PR') THEN 'PK' ELSE b.CodProductoNBO END)+'-'+TRIM(CASE WHEN b.RUC = '20517746046' THEN '5' WHEN (b.CodSubProductoNBO = '' AND b.CodProductoNBO <> '') OR b.CodSubProductoNBO = '20' THEN b.CodProductoNBO WHEN b.Fuente <> 'V+' AND (b.CodProductoNBO IS NULL OR b.CodProductoNBO = '' OR b.CodProductoNBO = '0') THEN 'BP' WHEN b.Fuente = 'V+' AND (b.CodProductoNBO IS NULL OR b.CodProductoNBO = '' OR b.CodProductoNBO = '0') THEN 'BA' WHEN b.Periodo >= 202401 AND b.CodProductoNBO+'-'+b.CodSubProductoNBO = 'VD-2' THEN '8' ELSE b.CodSubProductoNBO END) AS vkey_pl,
		TRY_CAST(CASE WHEN @Cod_Patrocinado = 'Si' AND b.Fuente = 'Niubiz' AND b.RUC IN ('20602370497') THEN b.CodigoPatrocinado ELSE b.CodigoComercio END AS bigint) AS cod_seg,
		TRY_CAST(b.RUC AS bigint) AS ruc_seg
	FROM [Finanzas].v_ss_Base_Renta_NBZ_VMAS AS b
	WHERE
			b.Periodo >= @Periodo_Min
		AND b.Periodo <= @Periodo_Max
		AND (@Excluir_VMas = 'No' OR b.Fuente IS NULL OR b.Fuente NOT IN ('V+'))
) AS a
LEFT JOIN #Seg_Codigo AS sc
ON sc.Codigo_Comercio_Seg = a.cod_seg
LEFT JOIN #Seg_RUC AS sr
ON sr.Nro_Documento_Seg = a.ruc_seg   -- RUC real de la base (como SEMGNRUC en la Plantilla)
-- @Grupo_Economico: si viene NULL la condicion se cumple para todas las filas y
-- no filtra nada. Si trae valor, se compara contra el grupo resuelto con la misma
-- prelacion que Segmento (sc = por codigo de comercio, sr = por RUC).
WHERE (@Grupo_Economico IS NULL OR (CASE
		WHEN sc.Grupo_N     IS NOT NULL THEN sc.Grupo_N
		WHEN sr.Grupo_RUC_N IS NOT NULL THEN sr.Grupo_RUC_N
	ELSE '-' END) = @Grupo_Economico)
GROUP BY
	a.Periodo,
	a.Fuente,
	CASE
	WHEN a.fuente = 'V+' THEN '10.Vendemas'
		WHEN sc.Seg_N     IS NOT NULL THEN sc.Seg_N
		WHEN sr.Seg_RUC_N IS NOT NULL THEN sr.Seg_RUC_N
	ELSE NULL END,
	sc.Seg_N,
	sr.Seg_RUC_N

) AS a;


IF OBJECT_ID('tempdb..#Seg_Codigo') IS NOT NULL DROP TABLE #Seg_Codigo;
IF OBJECT_ID('tempdb..#Seg_RUC')    IS NOT NULL DROP TABLE #Seg_RUC;

-- ===========================================================
-- Stage 2: Compute x.x.- subtotals as simple column additions
-- (no re-scan of base view - reads #PL_Granular, writes #PL_Subtotals)
-- ===========================================================
CREATE TABLE #PL_Subtotals
WITH (DISTRIBUTION = ROUND_ROBIN, HEAP)
AS
SELECT * FROM (
SELECT *,

[1.2.7.- Cuota MC Ticket] = [1.2.7.1.- Cuota MC Ticket Foraneo] + [1.2.7.2.- Cuota MC Ticket Nacional],
[1.2.8.- Cuota MC Var Foraneo] = 
	[1.2.8.1.1.- Cuota MC Var Foraneo Volumen USD] + [1.2.8.1.2.- Cuota MC Var Foraneo Volumen PEN] + 
	[1.2.8.1.3.- Cuota MC Var Foraneo Volumen Otros CP] + [1.2.8.1.4.- Cuota MC Var Foraneo Volumen Otros CNP] + 
	[1.2.8.1.5.- Cuota MC Var Foraneo Volumen Otros] + 
	[1.2.8.2.1.- Cuota MC Var Foraneo Transacciones Autor. y Liq.] + [1.2.8.2.2.- Cuota MC Var Foraneo Transacciones Otros CNP] + [1.2.8.2.3.- Cuota MC Var Foraneo Transacciones Otros] + 
	[1.2.8.3.- Cuota MC Var Foraneo Performance],
[1.2.8.1.- Cuota MC Var Foraneo Volumen] =
	[1.2.8.1.1.- Cuota MC Var Foraneo Volumen USD] + [1.2.8.1.2.- Cuota MC Var Foraneo Volumen PEN] + 
	[1.2.8.1.3.- Cuota MC Var Foraneo Volumen Otros CP] + [1.2.8.1.4.- Cuota MC Var Foraneo Volumen Otros CNP] + 
	[1.2.8.1.5.- Cuota MC Var Foraneo Volumen Otros],
[1.2.8.2.- Cuota MC Var Foraneo Transacciones] = 
	[1.2.8.2.1.- Cuota MC Var Foraneo Transacciones Autor. y Liq.] + 
	[1.2.8.2.2.- Cuota MC Var Foraneo Transacciones Otros CNP] + 
	[1.2.8.2.3.- Cuota MC Var Foraneo Transacciones Otros],
[1.2.9.- Cuota MC Var Nacional] = 
	[1.2.9.1.1.- Cuota MC Var Nacional Volumen Directo] + [1.2.9.1.2.- Cuota MC Var Nacional Volumen Otros CP] + 
	[1.2.9.1.3.- Cuota MC Var Nacional Volumen Otros CNP] + [1.2.9.1.4.- Cuota MC Var Nacional Volumen Otros] + 
	[1.2.9.2.- Cuota MC Var Nacional Transacciones] + 
	[1.2.9.3.- Cuota MC Var Nacional Performance],
[1.2.9.1.- Cuota MC Var Nacional Volumen] =
	[1.2.9.1.1.- Cuota MC Var Nacional Volumen Directo] + [1.2.9.1.2.- Cuota MC Var Nacional Volumen Otros CP] + 
	[1.2.9.1.3.- Cuota MC Var Nacional Volumen Otros CNP] + [1.2.9.1.4.- Cuota MC Var Nacional Volumen Otros],
[1.2.10.- Cuota MC Var Total] = [1.2.10.1.- Cuota MC Var Total Vol/Txs] + [1.2.10.2.- Cuota MC Var Total Performance],
[1.2.11.- Cuota Reintentos] = [1.2.11.1.- Cuota Reintentos Visa] + [1.2.11.2.- Cuota Reintentos MC] + [1.2.11.3.- Cuota Reintentos Legacy],
[1.2.15.- Cuota Visa Ticket] = 
	[1.2.15.1.1- Cuota Visa Ticket Foraneo Otros CP] + [1.2.15.1.2- Cuota Visa Ticket Foraneo Otros CNP] + 
	[1.2.15.2.1.- Cuota Visa Ticket Debito Otros CP] + [1.2.15.2.2.- Cuota Visa Ticket Debito Otros CNP] + 
	[1.2.15.3.1.- Cuota Visa Ticket Credito Otros CP] + [1.2.15.3.2.- Cuota Visa Ticket Credito Otros CNP],
[1.2.15.1.- Cuota Visa Ticket Foraneo] = [1.2.15.1.1- Cuota Visa Ticket Foraneo Otros CP] + [1.2.15.1.2- Cuota Visa Ticket Foraneo Otros CNP],
[1.2.15.2.- Cuota Visa Ticket Debito] = [1.2.15.2.1.- Cuota Visa Ticket Debito Otros CP] + [1.2.15.2.2.- Cuota Visa Ticket Debito Otros CNP],
[1.2.15.3.- Cuota Visa Ticket Credito] = [1.2.15.3.1.- Cuota Visa Ticket Credito Otros CP] + [1.2.15.3.2.- Cuota Visa Ticket Credito Otros CNP],
[1.2.16.- Cuota Visa Var Foraneo] = 
	[1.2.16.1.1.- Cuota Visa Var Foraneo Volumen PEN] + [1.2.16.1.2.- Cuota Visa Var Foraneo Volumen USD CNP] + 
	[1.2.16.1.3.- Cuota Visa Var Foraneo Volumen USD] + [1.2.16.1.4.- Cuota Visa Var Foraneo Volumen Otros] + 
	[1.2.16.2.- Cuota Visa Var Foraneo Transacciones] + [1.2.16.3.- Cuota Visa Var Foraneo Performance],
[1.2.16.1.- Cuota Visa Var Foraneo Volumen] = 
	[1.2.16.1.1.- Cuota Visa Var Foraneo Volumen PEN] + [1.2.16.1.2.- Cuota Visa Var Foraneo Volumen USD CNP] + 
	[1.2.16.1.3.- Cuota Visa Var Foraneo Volumen USD] + [1.2.16.1.4.- Cuota Visa Var Foraneo Volumen Otros],
[1.2.17.- Cuota Visa Var Nacional] = 
	[1.2.17.1.1.- Cuota Visa Var Nacional Volumen Debito] + [1.2.17.1.2.- Cuota Visa Var Nacional Volumen Credito] + [1.2.17.1.3.- Cuota Visa Var Nacional Volumen No Token] + 
	[1.2.17.2.- Cuota Visa Var Nacional Transacciones] + [1.2.17.3.- Cuota Visa Var Nacional Performance] + [1.2.17.4.- Cuota Visa Var Nacional 4900 DASF Fijo] + 
	[1.2.17.5.- Cuota Visa Var Nacional 9311 DASF Fijo Debito] + [1.2.17.6.- Cuota Visa Var Nacional 9311 DASF Fijo Credito],
[1.2.17.1.- Cuota Visa Var Nacional Volumen] = 
	[1.2.17.1.1.- Cuota Visa Var Nacional Volumen Debito] + [1.2.17.1.2.- Cuota Visa Var Nacional Volumen Credito] + [1.2.17.1.3.- Cuota Visa Var Nacional Volumen No Token],
[1.2.18.- Cuota Visa Var Total] = [1.2.18.1.- Cuota Visa Var Total Vol/Txs] + [1.2.18.2.- Cuota Visa Var Total Performance] + [1.2.18.3.- Cuota Visa Var Total Tokenizacion],
[1.2.19.- Cuota Multas] = [1.2.19.1.- Cuota Multas Visa] + [1.2.19.2.- Cuota Multas MC],
[1.2.20.- Cuota PIPF] = [1.2.20.1.- Cuota PIPF Visa] + [1.2.20.2.- Cuota PIPF MC],
[1.2.21.- Cuota Suscripciones] = [1.2.21.1.- Cuota Suscripciones Visa] + [1.2.21.2.- Cuota Suscripciones MC],
[1.2.22.- Cuota Fee Anual] = [1.2.22.1.- Cuota Fee Anual Visa] + [1.2.22.2.- Cuota Fee Anual MC],

[3.1.5.- Ing. DCC] = [3.1.5.1.- Ing. DCC Cobro al TH] + [3.1.5.2.- Dscto. DCC Comercio],
[3.1.14.- Ing. Por reparacion / Robo POS] = [3.1.14.1.- Ing. Por reparacion] + [3.1.14.2.- Ing. Por Robo POS],

[3.2.2.- Gasto DCC] = [3.2.2.1.- Gasto DCC Proveedor] + [3.2.2.2.- Gasto DCC Riesgo],
[3.2.5.- Gastos por afiliación] = 
	[3.2.5.1.- Gastos por afiliación Legacy] + [3.2.5.2.- Gastos por afiliación Real] + 
	[3.2.5.3.- Gastos por afiliación Provision] + [3.2.5.4.- Gastos por afiliación Extorno],
[3.2.7.- Cuotas DCC] = [3.2.7.1.- Cuotas DCC Fija] + [3.2.7.2.- Cuotas DCC Variable],
[3.2.9.- Gastos por afiliación - Multiagente] = 
	[3.2.9.1.- Gastos por afiliación - Multiagente Real] + [3.2.9.2.- Gastos por afiliación - Multiagente Provision] + [3.2.9.3.- Gastos por afiliación - Multiagente Extorno],

[4.1.8.- Gasto Portafolio] = 
	[4.1.8.1.1.- Gasto Portafolio Codigo PDV] + [4.1.8.1.2.- Gasto Portafolio Codigo RET] + [4.1.8.1.3.- Gasto Portafolio Codigo PRO] + 
	[4.1.8.1.4.- Gasto Portafolio Codigo GRO] + [4.1.8.1.5.- Gasto Portafolio Codigo HOT] + [4.1.8.1.6.- Gasto Portafolio Codigo PS] + [4.1.8.1.7.- Gasto Portafolio Codigo TAW] + 
	[4.1.8.2.1.- Gasto Portafolio CUC PDV] + [4.1.8.2.2.- Gasto Portafolio CUC RET] + [4.1.8.2.3.- Gasto Portafolio CUC PRO] + 
	[4.1.8.2.4.- Gasto Portafolio CUC GRO] + [4.1.8.2.5.- Gasto Portafolio CUC HOT] + [4.1.8.2.6.- Gasto Portafolio CUC PS] + [4.1.8.2.7.- Gasto Portafolio CUC TAW] + 
	[4.1.8.3.- Gasto Portafolio Publicidad] + [4.1.8.4.- Gasto Portafolio Segmento],
[4.1.8.1.- Gasto Portafolio Codigo]  = 
	[4.1.8.1.1.- Gasto Portafolio Codigo PDV] + [4.1.8.1.2.- Gasto Portafolio Codigo RET] + [4.1.8.1.3.- Gasto Portafolio Codigo PRO] + 
	[4.1.8.1.4.- Gasto Portafolio Codigo GRO] + [4.1.8.1.5.- Gasto Portafolio Codigo HOT] + [4.1.8.1.6.- Gasto Portafolio Codigo PS] + [4.1.8.1.7.- Gasto Portafolio Codigo TAW],
[4.1.8.2.- Gasto Portafolio CUC] = 
	[4.1.8.2.1.- Gasto Portafolio CUC PDV] + [4.1.8.2.2.- Gasto Portafolio CUC RET] + [4.1.8.2.3.- Gasto Portafolio CUC PRO] + 
	[4.1.8.2.4.- Gasto Portafolio CUC GRO] + [4.1.8.2.5.- Gasto Portafolio CUC HOT] + [4.1.8.2.6.- Gasto Portafolio CUC PS] + [4.1.8.2.7.- Gasto Portafolio CUC TAW],
[4.2.1.- Gasto de personal] = 
	[4.2.1.1.- Gasto de personal Gestion Empresa] + [4.2.1.2.- Gasto de personal Gestion Dominio] + [4.2.1.3.- Gasto de personal Gestion Producto] + 
	[4.2.1.4.- Gasto de personal Procesamiento] + [4.2.1.5.- Gasto de personal Adquirencia] + [4.2.1.6.- Gasto de personal (Otros)],

[4.3.3.- Gasto Instalacion] = 
	[4.3.3.1.- Gasto Instalacion por Ferias y Eventos] + [4.3.3.2.- Gasto Instalacion por Impresion Laser] + 
	[4.3.3.3.- Gasto Instalacion Regular] + [4.3.3.4.- Gasto Instalacion por Eventos Express],
[4.3.5.- Gasto Mntto ParquePOS] = 
	[4.3.5.1.- Gasto Mntto ParquePOS Alquiler] + [4.3.5.2.- Gasto Mntto ParquePOS Venta] + [4.3.5.3.- Gasto Mntto ParquePOS Instalacion] + [4.3.5.4.- Gasto Mntto ParquePOS Laboratorio] + 
	[4.3.5.5.- Gasto Mntto ParquePOS Llamada] + [4.3.5.6.- Gasto Mntto ParquePOS Atenciones] + [4.3.5.7.- Gasto Mntto ParquePOS Parque] + [4.3.5.8.- Gasto Mntto ParquePOS Legacy],
[4.3.9.- Gasto Telecarga] = 
	[4.3.9.1.- Gasto Telecarga Licencia TMS] + [4.3.9.2.- Gasto Telecarga EstateManager] + [4.3.9.3.- Gasto Telecarga Ontetime],

[4.5.1.- Gasto Antifraude] = [4.5.1.1.- Gasto Antifraude Cybersource] + [4.5.1.2.- Gasto Antifraude Amortizacion SAS] + [4.5.1.3.- Gasto por Decision Management CyberSource],
[4.5.5.- Gasto SAS] = [4.5.5.1.- Gasto SAS Legacy] + [4.5.5.2.- Gasto SAS Pre] + [4.5.5.3.- Gasto SAS Post] + [4.5.5.4.- Gasto SAS Pre y Post],

[4.6.1.- Gasto de Amortizaciones] = [4.6.1.1.- Gasto Antifraude Amortizacion SAS] + [4.6.1.2.- Otros Gastos de Amortizaciones],

[5.5.1.- Gasto de Desarrollo] = 
	[5.5.1.1.- Gasto de Desarrollo de Operaciones] + [5.5.1.2.- Gasto de Desarrollo de Soporte Empresa] + [5.5.1.3.- Gasto de Desarrollo de Proyectos de Tecnologia] + 
	[5.5.1.4.- Gasto de Desarrollo de Servicio al Cliente] + [5.5.1.5.- Gasto de Desarrollo (Otros)],

[1.1.- I.Operativo] =
	[1.1.1.- Ing. Com. Niubiz] + [1.1.2.- Ing. Com. Vendemas] + [1.1.3.- Ing. Gobierno] +
	[1.1.4.- Fee Transporte] + [1.1.5.- Ajuste Foraneo] + [1.1.6.- Ing. Cobro Pago] +
	[1.1.7.- Costo Pago Adquirentes] + [1.1.8.- Ing. Vendomatica] + [1.1.9.- Ing. Incentivo Campana]+
	[1.1.10.- CP Dummy Comision Adquirente] + [1.1.11.- Ing. Cobropagos Legacy],
[1.2.- C.Operativo] =
	[1.2.1.- Autenticación VbV MPI] + [1.2.2.- Autenticación VbV VISA] + [1.2.3.- Costo Pago Adquirentes] + 
	[1.2.4.- Cuota MC Fijo Foraneo] + [1.2.5.- Cuota MC Fijo Nacional] + [1.2.6.- Cuota MC Fijo Total] + 
	[1.2.7.1.- Cuota MC Ticket Foraneo] + [1.2.7.2.- Cuota MC Ticket Nacional] + 
	[1.2.8.1.1.- Cuota MC Var Foraneo Volumen USD] + [1.2.8.1.2.- Cuota MC Var Foraneo Volumen PEN] + 
	[1.2.8.1.3.- Cuota MC Var Foraneo Volumen Otros CP] + [1.2.8.1.4.- Cuota MC Var Foraneo Volumen Otros CNP] + 
	[1.2.8.1.5.- Cuota MC Var Foraneo Volumen Otros] + 
	[1.2.8.2.1.- Cuota MC Var Foraneo Transacciones Autor. y Liq.] + [1.2.8.2.2.- Cuota MC Var Foraneo Transacciones Otros CNP] + [1.2.8.2.3.- Cuota MC Var Foraneo Transacciones Otros] + 
	[1.2.8.3.1- Cuota MC Var Foraneo Performance Otros CNP] +
	[1.2.8.3.2- Cuota MC Var Foraneo Performance Otros] +
	[1.2.9.1.1.- Cuota MC Var Nacional Volumen Directo] + [1.2.9.1.2.- Cuota MC Var Nacional Volumen Otros CP] + 
	[1.2.9.1.3.- Cuota MC Var Nacional Volumen Otros CNP] + [1.2.9.1.4.- Cuota MC Var Nacional Volumen Otros] + 
	[1.2.9.2.- Cuota MC Var Nacional Transacciones] + [1.2.9.3.- Cuota MC Var Nacional Performance] + 
	[1.2.10.1.- Cuota MC Var Total Vol/Txs] + [1.2.10.2.- Cuota MC Var Total Performance] + 
	[1.2.11.1.- Cuota Reintentos Visa] + [1.2.11.2.- Cuota Reintentos MC] + [1.2.11.3.- Cuota Reintentos Legacy] + 
	[1.2.12.- Cuota Visa Fijo Foraneo] + [1.2.13.- Cuota Visa Fijo Nacional] + [1.2.14.- Cuota Visa Fijo Total] + 
	[1.2.15.1.1- Cuota Visa Ticket Foraneo Otros CP] + [1.2.15.1.2- Cuota Visa Ticket Foraneo Otros CNP] + 
	[1.2.15.2.1.- Cuota Visa Ticket Debito Otros CP] + [1.2.15.2.2.- Cuota Visa Ticket Debito Otros CNP] + 
	[1.2.15.3.1.- Cuota Visa Ticket Credito Otros CP] + [1.2.15.3.2.- Cuota Visa Ticket Credito Otros CNP] + 
	[1.2.16.1.1.- Cuota Visa Var Foraneo Volumen PEN] + [1.2.16.1.2.- Cuota Visa Var Foraneo Volumen USD CNP] + 
	[1.2.16.1.3.- Cuota Visa Var Foraneo Volumen USD] + [1.2.16.1.4.- Cuota Visa Var Foraneo Volumen Otros] + 
	[1.2.16.2.- Cuota Visa Var Foraneo Transacciones] + [1.2.16.3.- Cuota Visa Var Foraneo Performance] + 
	[1.2.17.1.1.- Cuota Visa Var Nacional Volumen Debito] + [1.2.17.1.2.- Cuota Visa Var Nacional Volumen Credito] + [1.2.17.1.3.- Cuota Visa Var Nacional Volumen No Token] + 
	[1.2.17.2.- Cuota Visa Var Nacional Transacciones] + [1.2.17.3.- Cuota Visa Var Nacional Performance] + [1.2.17.4.- Cuota Visa Var Nacional 4900 DASF Fijo] + 
	[1.2.17.5.- Cuota Visa Var Nacional 9311 DASF Fijo Debito] + [1.2.17.6.- Cuota Visa Var Nacional 9311 DASF Fijo Credito] + 
	[1.2.18.1.- Cuota Visa Var Total Vol/Txs] + [1.2.18.2.- Cuota Visa Var Total Performance] + [1.2.18.3.- Cuota Visa Var Total Tokenizacion] +
	[1.2.19.1.- Cuota Multas Visa] + [1.2.19.2.- Cuota Multas MC] + [1.2.20.1.- Cuota PIPF Visa] + [1.2.20.2.- Cuota PIPF MC] +
	[1.2.21.1.- Cuota Suscripciones Visa] + [1.2.21.2.- Cuota Suscripciones MC] + [1.2.22.1.- Cuota Fee Anual Visa] + [1.2.22.2.- Cuota Fee Anual MC],
[2.1.- I.Operativo] =
	[2.1.1.- Ing. Analytics] + [2.1.2.- Ing. Criptograma] + [2.1.3.- Ing. Data] +
	[2.1.4.- Ing. Diners/Amex] + [2.1.5.- Ing. Flotas] + [2.1.6.- Ing. Fraude] +
	[2.1.7.- Ing. P2P] + [2.1.8.- Ing. Prestamos] + [2.1.9.- Ing. Recargas y Servicios] +
	[2.1.10.- Ing. Corresponsalia] + [2.1.11.- Ing. Soluciones Fidelizacion] +
	[2.1.12.- Ing. Soluciones Financieras] + [2.1.13.- Ing. Soluciones Prestamos] +
	[2.1.14.- Ing. Soluciones Procesamiento] + [2.1.15.- Ing. PushPayments] +
	[2.1.16.- Ing. Giftcards] + [2.1.17.- Ing. Pago de Deuda]+
	[2.1.18.- Ing. Funds Transfer]+ [2.1.19.- Ing. Marca Cerrada]+
	[2.1.20.- Ing. PIFO]+
	[2.1.21.- CP Dummy Servicios de Procesamiento]
	,

[2.2.- C.Operativo] =
	[2.2.1.- Cuotas MoneySend] + [2.2.2.- Cuotas VisaDirect P2P] + [2.2.3.- Cuotas VisaDirect PP] +
	[2.2.4.- Gasto Cupo] + [2.2.5.- Gasto Flotas] + [2.2.6.- Gasto Recargas y Servicios] +
	[2.2.7.- Gasto Giftcards] + [2.2.8.- Costo Marca Cerrada],
[3.1.- I.Operativo] =
	[3.1.1.- Ing. Afiliaciones] + [3.1.2.- Ing. Agente Tercero] + [3.1.3.- Ing. Alquiler] +
	[3.1.4.- Ing. Antifraude] + [3.1.5.1.- Ing. DCC Cobro al TH] + [3.1.5.2.- Dscto. DCC Comercio] + [3.1.6.- Ing. Envio de EECC] +
	[3.1.7.- Ing. Instalacion] + [3.1.8.- Ing. Izipay] + [3.1.9.- Ing. Linea 0800] +
	[3.1.10.- Ing. Membresia] + [3.1.11.- Ing. Peajes] + [3.1.12.- Ing. por Manteminiento] +
	[3.1.13.- Ing. Por renovación.] + [3.1.14.1.- Ing. Por reparacion] + [3.1.14.2.- Ing. Por Robo POS] +
	[3.1.15.- Ing. por Telepago] + [3.1.16.- Ing. Pre autorizacion] +
	[3.1.17.- Otros Ing. de Serv. Adq.]+ [3.1.18.- Ing. Vendomatica]+
	[3.1.19.- Ing. Venta Poket] + [3.1.20.- Ing. de Comision No Adquirente]+
	[3.1.21.- CP Dummy Otros Servicios Adquiriente],
	
[3.2.- C.Operativo] =
	[3.2.1.- Costo Linea 0800] + [3.2.2.1.- Gasto DCC Proveedor] + [3.2.2.2.- Gasto DCC Riesgo] + 
	[3.2.3.- Gasto Devoluciones y Averias] + [3.2.4.- Gasto Poket] + 
	[3.2.5.1.- Gastos por afiliación Legacy] + [3.2.5.2.- Gastos por afiliación Real] + 
	[3.2.5.3.- Gastos por afiliación Provision] + [3.2.5.4.- Gastos por afiliación Extorno] + 
	[3.2.6.- Gasto Digitacion y Monitoreo] + 
	[3.2.7.1.- Cuotas DCC Fija] + [3.2.7.2.- Cuotas DCC Variable] + [3.2.8.- Gasto Call Center - CPA] + 
	[3.2.9.1.- Gastos por afiliación - Multiagente Real] + [3.2.9.2.- Gastos por afiliación - Multiagente Provision] + [3.2.9.3.- Gastos por afiliación - Multiagente Extorno],
[4.1.- G.Comercio] =
	[4.1.1.- Gasto Alignet] + [4.1.2.- Gasto de EECC] + [4.1.3.- Aporte Portafolio] +
	[4.1.4.- Gasto Envio Poket] + [4.1.5.- Gasto Izipay] + [4.1.6.- Otros Gastos] +
	[4.1.7.- Refacturación de servicios] + 
	[4.1.8.1.1.- Gasto Portafolio Codigo PDV] + [4.1.8.1.2.- Gasto Portafolio Codigo RET] + [4.1.8.1.3.- Gasto Portafolio Codigo PRO] + 
	[4.1.8.1.4.- Gasto Portafolio Codigo GRO] + [4.1.8.1.5.- Gasto Portafolio Codigo HOT] + [4.1.8.1.6.- Gasto Portafolio Codigo PS] + [4.1.8.1.7.- Gasto Portafolio Codigo TAW] + 
	[4.1.8.2.1.- Gasto Portafolio CUC PDV] + [4.1.8.2.2.- Gasto Portafolio CUC RET] + [4.1.8.2.3.- Gasto Portafolio CUC PRO] + 
	[4.1.8.2.4.- Gasto Portafolio CUC GRO] + [4.1.8.2.5.- Gasto Portafolio CUC HOT] + [4.1.8.2.6.- Gasto Portafolio CUC PS] + [4.1.8.2.7.- Gasto Portafolio CUC TAW] + 
	[4.1.8.3.- Gasto Portafolio Publicidad] + [4.1.8.4.- Gasto Portafolio Segmento],
[4.2.- G.Personal Front] = 
	[4.2.1.1.- Gasto de personal Gestion Empresa] + [4.2.1.2.- Gasto de personal Gestion Dominio] + [4.2.1.3.- Gasto de personal Gestion Producto] + 
	[4.2.1.4.- Gasto de personal Procesamiento] + [4.2.1.5.- Gasto de personal Adquirencia] + [4.2.1.6.- Gasto de personal (Otros)],
[4.3.- G.Operacion Sol] =
	[4.3.1.- Gasto Chips] + [4.3.2.- Gasto Contometros] + [4.3.3.1.- Gasto Instalacion por Ferias y Eventos] + [4.3.3.2.- Gasto Instalacion por Impresion Laser] + 
	[4.3.3.3.- Gasto Instalacion Regular] + [4.3.3.4.- Gasto Instalacion por Eventos Express] + [4.3.4.- Gasto Migraciones] + 
	[4.3.5.1.- Gasto Mntto ParquePOS Alquiler] + [4.3.5.2.- Gasto Mntto ParquePOS Venta] + [4.3.5.3.- Gasto Mntto ParquePOS Instalacion] + [4.3.5.4.- Gasto Mntto ParquePOS Laboratorio] + 
	[4.3.5.5.- Gasto Mntto ParquePOS Llamada] + [4.3.5.6.- Gasto Mntto ParquePOS Atenciones] + [4.3.5.7.- Gasto Mntto ParquePOS Parque] + [4.3.5.8.- Gasto Mntto ParquePOS Legacy] + 
	[4.3.6.- Gasto Recupero de POS] + [4.3.7.- Gasto Serv Integración] + [4.3.8.- Gasto Suministros] + 
	[4.3.9.1.- Gasto Telecarga Licencia TMS] + [4.3.9.2.- Gasto Telecarga EstateManager] + [4.3.9.3.- Gasto Telecarga Ontetime],
[4.4.- G.Procesamiento] = [4.4.1.- Costo Geopagos] + [4.4.2.- Gasto Geopagos],
[4.5.- G.Soporte EC] =
	[4.5.1.1.- Gasto Antifraude Cybersource] + [4.5.1.2.- Gasto Antifraude Amortizacion SAS] + [4.5.1.3.- Gasto por Decision Management CyberSource] + 
	[4.5.2.- Gasto Antifraude SVA] + [4.5.3.- Gasto Canales] + [4.5.4.- Gasto Canales SVA] + 
	[4.5.5.1.- Gasto SAS Legacy] + [4.5.5.2.- Gasto SAS Pre] + [4.5.5.3.- Gasto SAS Post] + [4.5.5.4.- Gasto SAS Pre y Post] + 
	[4.5.6.- Gasto SAS SVA] + [4.5.7.- Registro MPI] + [4.5.8.- Renovación MPI],
[4.6.- G.Dep y Amort] = [4.6.1.1.- Gasto Antifraude Amortizacion SAS] + [4.6.1.2.- Otros Gastos de Amortizaciones] + [4.6.2.- Gasto Depreciación Activa],
[4.7.- G.Controversias] = [4.7.1.- Gasto Controversias],
[4.8.- G.Call Center] = [4.8.1.- Gasto Call Center] + [4.8.2.- Gasto Call Tecnico] + [4.8.3.- Gasto de visitas],
[4.9.- G.Cob Dudosa] = [4.9.1.- Gasto Contracargo] + [4.9.2.- Gasto Incobrables],
[5.1.- G.Directo Asignado] = [5.1.1.- Gasto Agente Tercero],
[5.2.- G.Marketing] = [5.2.1.- Aporte Visa] + [5.2.2.- Gasto de MKT],
[5.3.- G.Procesamiento Fijo] = [5.3.1.- Costo Invenio] + [5.3.2.- Costo Telefonica] + [5.3.3.- Gasto Telefonica SVA],
[5.4.- G.Personal Eventual] = [5.4.1.- Gasto Personal Eventual],
[5.5.- G.Serv Tecnologia] = 
	[5.5.1.1.- Gasto de Desarrollo de Operaciones] + [5.5.1.2.- Gasto de Desarrollo de Soporte Empresa] + [5.5.1.3.- Gasto de Desarrollo de Proyectos de Tecnologia] + 
	[5.5.1.4.- Gasto de Desarrollo de Servicio al Cliente] + [5.5.1.5.- Gasto de Desarrollo (Otros)] + [5.5.2.- Gasto Testing factory],
[5.6.- G.Personal Back] = [5.6.1.- Gasto de Personal Middle],
[5.7.- G.Alquiler Almacenes] = [5.7.1.- Gasto Alquileres],
[5.8.- G.Dep y Amort] = [5.8.1.- Gasto Depreciación Baja] + [5.8.2.- Gasto Depreciación Inactiva]

FROM #PL_Granular
) AS a;

IF OBJECT_ID('tempdb..#PL_Granular') IS NOT NULL DROP TABLE #PL_Granular;

-- ===========================================================
-- Stage 3: Final output SELECT from #PL_Subtotals
-- ===========================================================

SELECT
	a.[Periodo],
	a.[Fuente],
	a.[Segmento],
	[Codigos],
	[Estado],
	[Movimiento],

	[Volumen Niubiz],
	[Volumen VendeMas],
	[Volumen Niubiz+VendeMas],

	[Transacciones Niubiz],
	[Transacciones VendeMas],
	[Transacciones Niubiz+VendeMas],

	[Comision Total Niubiz],
	[Comision Total VendeMas],
	[Comision Total Niubiz+VendeMas],

	[Comision Adquirente Niubiz],
	[Comision Adquirente VendeMas],
	[Comision Adquirente Niubiz+VendeMas],

	[Transacciones SVA Data],
	[Numero de POS SVA a Cobrar],
	[Volumen SVA Data],

	[Transacciones SAS Post],
	[Transacciones SAS Pre],

	[1.1.1.- Ing. Com. Niubiz],
	[1.1.2.- Ing. Com. Vendemas],
	[1.1.3.- Ing. Gobierno],
	[1.1.4.- Fee Transporte],
	[1.1.5.- Ajuste Foraneo],
	[1.1.6.- Ing. Cobro Pago],
	[1.1.7.- Costo Pago Adquirentes],
	[1.1.8.- Ing. Vendomatica],
	[1.1.9.- Ing. Incentivo Campana],
	[1.1.- I.Operativo],
	[1.2.1.- Autenticación VbV MPI],
	[1.2.2.- Autenticación VbV VISA],
	[1.2.3.- Costo Pago Adquirentes],
	[1.2.4.- Cuota MC Fijo Foraneo],
	[1.2.5.- Cuota MC Fijo Nacional],
	[1.2.6.- Cuota MC Fijo Total],
	[1.2.7.1.- Cuota MC Ticket Foraneo],
	[1.2.7.2.- Cuota MC Ticket Nacional],
	[1.2.7.- Cuota MC Ticket],
	[1.2.8.1.1.- Cuota MC Var Foraneo Volumen USD],
	[1.2.8.1.2.- Cuota MC Var Foraneo Volumen PEN],
	[1.2.8.1.3.- Cuota MC Var Foraneo Volumen Otros CP],
	[1.2.8.1.4.- Cuota MC Var Foraneo Volumen Otros CNP],
	[1.2.8.1.5.- Cuota MC Var Foraneo Volumen Otros],
	[1.2.8.1.- Cuota MC Var Foraneo Volumen],
	[1.2.8.2.1.- Cuota MC Var Foraneo Transacciones Autor. y Liq.],
	[1.2.8.2.2.- Cuota MC Var Foraneo Transacciones Otros CNP],
	[1.2.8.2.3.- Cuota MC Var Foraneo Transacciones Otros],
	[1.2.8.2.- Cuota MC Var Foraneo Transacciones],
	[1.2.8.3.1- Cuota MC Var Foraneo Performance Otros CNP] ,
	[1.2.8.3.2- Cuota MC Var Foraneo Performance Otros],
	[1.2.8.3.- Cuota MC Var Foraneo Performance],
	[1.2.8.- Cuota MC Var Foraneo],
	[1.2.9.1.1.- Cuota MC Var Nacional Volumen Directo],
	[1.2.9.1.2.- Cuota MC Var Nacional Volumen Otros CP],
	[1.2.9.1.3.- Cuota MC Var Nacional Volumen Otros CNP],
	[1.2.9.1.4.- Cuota MC Var Nacional Volumen Otros],
	[1.2.9.1.- Cuota MC Var Nacional Volumen],
	[1.2.9.2.- Cuota MC Var Nacional Transacciones],
	[1.2.9.3.- Cuota MC Var Nacional Performance],
	[1.2.9.- Cuota MC Var Nacional],
	[1.2.10.1.- Cuota MC Var Total Vol/Txs],
	[1.2.10.2.- Cuota MC Var Total Performance],
	[1.2.10.- Cuota MC Var Total],
	[1.2.11.1.- Cuota Reintentos Visa],
	[1.2.11.2.- Cuota Reintentos MC],
	[1.2.11.3.- Cuota Reintentos Legacy],
	[1.2.11.- Cuota Reintentos],
	[1.2.12.- Cuota Visa Fijo Foraneo],
	[1.2.13.- Cuota Visa Fijo Nacional],
	[1.2.14.- Cuota Visa Fijo Total],
	[1.2.15.1.- Cuota Visa Ticket Foraneo],
	[1.2.15.1.1- Cuota Visa Ticket Foraneo Otros CP] ,
	[1.2.15.1.2- Cuota Visa Ticket Foraneo Otros CNP] ,
	[1.2.15.2.- Cuota Visa Ticket Debito],
	[1.2.15.2.1.- Cuota Visa Ticket Debito Otros CP] ,
	[1.2.15.2.2.- Cuota Visa Ticket Debito Otros CNP] ,
	[1.2.15.3.- Cuota Visa Ticket Credito],
	[1.2.15.3.1.- Cuota Visa Ticket Credito Otros CP],
	[1.2.15.3.2.- Cuota Visa Ticket Credito Otros CNP] ,
	[1.2.15.- Cuota Visa Ticket],
	[1.2.16.1.1.- Cuota Visa Var Foraneo Volumen PEN],
	[1.2.16.1.2.- Cuota Visa Var Foraneo Volumen USD CNP],
	[1.2.16.1.3.- Cuota Visa Var Foraneo Volumen USD],
	[1.2.16.1.4.- Cuota Visa Var Foraneo Volumen Otros],
	[1.2.16.1.- Cuota Visa Var Foraneo Volumen],
	[1.2.16.2.- Cuota Visa Var Foraneo Transacciones],
	[1.2.16.3.- Cuota Visa Var Foraneo Performance],
	[1.2.16.- Cuota Visa Var Foraneo],
	[1.2.17.1.1.- Cuota Visa Var Nacional Volumen Debito],
	[1.2.17.1.2.- Cuota Visa Var Nacional Volumen Credito],
	[1.2.17.1.3.- Cuota Visa Var Nacional Volumen No Token],
	[1.2.17.1.- Cuota Visa Var Nacional Volumen],
	[1.2.17.2.- Cuota Visa Var Nacional Transacciones],
	[1.2.17.3.- Cuota Visa Var Nacional Performance],
	[1.2.17.4.- Cuota Visa Var Nacional 4900 DASF Fijo],
	[1.2.17.5.- Cuota Visa Var Nacional 9311 DASF Fijo Debito],
	[1.2.17.6.- Cuota Visa Var Nacional 9311 DASF Fijo Credito],
	[1.2.17.- Cuota Visa Var Nacional],
	[1.2.18.1.- Cuota Visa Var Total Vol/Txs],
	[1.2.18.2.- Cuota Visa Var Total Performance],
	[1.2.18.3.- Cuota Visa Var Total Tokenizacion],
	[1.2.18.- Cuota Visa Var Total],
	[1.2.19.1.- Cuota Multas Visa],
	[1.2.19.2.- Cuota Multas MC],
	[1.2.19.- Cuota Multas],
	[1.2.20.1.- Cuota PIPF Visa],
	[1.2.20.2.- Cuota PIPF MC],
	[1.2.20.- Cuota PIPF],
	[1.2.21.1.- Cuota Suscripciones Visa],
	[1.2.21.2.- Cuota Suscripciones MC],
	[1.2.21.- Cuota Suscripciones],
	[1.2.22.1.- Cuota Fee Anual Visa],
	[1.2.22.2.- Cuota Fee Anual MC],
	[1.2.22.- Cuota Fee Anual],
	[1.2.- C.Operativo],
	[1. Comisión Adquirente] = [1.1.- I.Operativo]-[1.2.- C.Operativo],
	[2.1.1.- Ing. Analytics],
	[2.1.2.- Ing. Criptograma],
	[2.1.3.- Ing. Data],
	[2.1.4.- Ing. Diners/Amex],
	[2.1.5.- Ing. Flotas],
	[2.1.6.- Ing. Fraude],
	[2.1.7.- Ing. P2P],
	[2.1.8.- Ing. Prestamos],
	[2.1.9.- Ing. Recargas y Servicios],
	[2.1.10.- Ing. Corresponsalia],
	[2.1.11.- Ing. Soluciones Fidelizacion],
	[2.1.12.- Ing. Soluciones Financieras],
	[2.1.13.- Ing. Soluciones Prestamos],
	[2.1.14.- Ing. Soluciones Procesamiento],
	[2.1.15.- Ing. PushPayments],
	[2.1.16.- Ing. Giftcards],
	[2.1.17.- Ing. Pago de Deuda],
	[2.1.18.- Ing. Funds Transfer],
	[2.1.19.- Ing. Marca Cerrada],
	[2.1.20.- Ing. PIFO],
	[2.1.- I.Operativo],
	[2.2.1.- Cuotas MoneySend],
	[2.2.2.- Cuotas VisaDirect P2P],
	[2.2.3.- Cuotas VisaDirect PP],
	[2.2.4.- Gasto Cupo],
	[2.2.5.- Gasto Flotas],
	[2.2.6.- Gasto Recargas y Servicios],
	[2.2.7.- Gasto Giftcards],
	[2.2.8.- Costo Marca Cerrada],
	[2.2.- C.Operativo],
	[2. Servicios de Procesamiento] = [2.1.- I.Operativo]-[2.2.- C.Operativo],
	[3.1.1.- Ing. Afiliaciones],
	[3.1.2.- Ing. Agente Tercero],
	[3.1.3.- Ing. Alquiler],
	[3.1.4.- Ing. Antifraude],
	[3.1.5.1.- Ing. DCC Cobro al TH],
	[3.1.5.2.- Dscto. DCC Comercio],
	[3.1.5.- Ing. DCC],
	[3.1.6.- Ing. Envio de EECC],
	[3.1.7.- Ing. Instalacion],
	[3.1.8.- Ing. Izipay],
	[3.1.9.- Ing. Linea 0800],
	[3.1.10.- Ing. Membresia],
	[3.1.11.- Ing. Peajes],
	[3.1.12.- Ing. por Manteminiento],
	[3.1.13.- Ing. Por renovación.],
	[3.1.14.1.- Ing. Por reparacion],
	[3.1.14.2.- Ing. Por Robo POS],
	[3.1.14.- Ing. Por reparacion / Robo POS],
	[3.1.15.- Ing. por Telepago],
	[3.1.16.- Ing. Pre autorizacion],
	[3.1.17.- Otros Ing. de Serv. Adq.],
	[3.1.18.- Ing. Vendomatica],
	[3.1.19.- Ing. Venta Poket],
	[3.1.20.- Ing. de Comision No Adquirente],
	[3.1.- I.Operativo],
	[3.2.1.- Costo Linea 0800],
	[3.2.2.1.- Gasto DCC Proveedor],
	[3.2.2.2.- Gasto DCC Riesgo],
	[3.2.2.- Gasto DCC],
	[3.2.3.- Gasto Devoluciones y Averias],
	[3.2.4.- Gasto Poket],
	[3.2.5.1.- Gastos por afiliación Legacy],
	[3.2.5.2.- Gastos por afiliación Real],
	[3.2.5.3.- Gastos por afiliación Provision],
	[3.2.5.4.- Gastos por afiliación Extorno],
	[3.2.5.- Gastos por afiliación],
	[3.2.6.- Gasto Digitacion y Monitoreo],
	[3.2.7.1.- Cuotas DCC Fija],
	[3.2.7.2.- Cuotas DCC Variable],
	[3.2.7.- Cuotas DCC],
	[3.2.8.- Gasto Call Center - CPA],
	[3.2.9.1.- Gastos por afiliación - Multiagente Real],
	[3.2.9.2.- Gastos por afiliación - Multiagente Provision],
	[3.2.9.3.- Gastos por afiliación - Multiagente Extorno],
	[3.2.9.- Gastos por afiliación - Multiagente],
	[3.2.- C.Operativo],
	[3. Otros Servicios Adquirente] = [3.1.- I.Operativo]-[3.2.- C.Operativo],
	[I.- MARGEN BRUTO]               = [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo],
	[I.- MARGEN BRUTO - Sin G.Afil.] = [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]+([3.2.5.- Gastos por afiliación]+[3.2.8.- Gasto Call Center - CPA]+[3.2.9.- Gastos por afiliación - Multiagente]),
	[4.1.1.- Gasto Alignet],
	[4.1.2.- Gasto de EECC],
	[4.1.3.- Aporte Portafolio],
	[4.1.4.- Gasto Envio Poket],
	[4.1.5.- Gasto Izipay],
	[4.1.6.- Otros Gastos],
	[4.1.7.- Refacturación de servicios],
	[4.1.8.1.1.- Gasto Portafolio Codigo PDV],
	[4.1.8.1.2.- Gasto Portafolio Codigo RET],
	[4.1.8.1.3.- Gasto Portafolio Codigo PRO],
	[4.1.8.1.4.- Gasto Portafolio Codigo GRO],
	[4.1.8.1.5.- Gasto Portafolio Codigo HOT],
	[4.1.8.1.6.- Gasto Portafolio Codigo PS],
	[4.1.8.1.7.- Gasto Portafolio Codigo TAW],
	[4.1.8.1.- Gasto Portafolio Codigo],
	[4.1.8.2.1.- Gasto Portafolio CUC PDV],
	[4.1.8.2.2.- Gasto Portafolio CUC RET],
	[4.1.8.2.3.- Gasto Portafolio CUC PRO],
	[4.1.8.2.4.- Gasto Portafolio CUC GRO],
	[4.1.8.2.5.- Gasto Portafolio CUC HOT],
	[4.1.8.2.6.- Gasto Portafolio CUC PS],
	[4.1.8.2.7.- Gasto Portafolio CUC TAW],
	[4.1.8.2.- Gasto Portafolio CUC],
	[4.1.8.3.- Gasto Portafolio Publicidad],
	[4.1.8.4.- Gasto Portafolio Segmento],
	[4.1.8.- Gasto Portafolio],
	[4.1.- G.Comercio],
	[4.2.1.1.- Gasto de personal Gestion Empresa],
	[4.2.1.2.- Gasto de personal Gestion Dominio],
	[4.2.1.3.- Gasto de personal Gestion Producto],
	[4.2.1.4.- Gasto de personal Procesamiento],
	[4.2.1.5.- Gasto de personal Adquirencia],
	[4.2.1.6.- Gasto de personal (Otros)],
	[4.2.1.- Gasto de personal],
	[4.2.- G.Personal Front],
	[4.3.1.- Gasto Chips],
	[4.3.2.- Gasto Contometros],
	[4.3.3.1.- Gasto Instalacion por Ferias y Eventos],
	[4.3.3.2.- Gasto Instalacion por Impresion Laser],
	[4.3.3.3.- Gasto Instalacion Regular],
	[4.3.3.4.- Gasto Instalacion por Eventos Express],
	[4.3.3.- Gasto Instalacion],
	[4.3.4.- Gasto Migraciones],
	[4.3.5.1.- Gasto Mntto ParquePOS Alquiler],
	[4.3.5.2.- Gasto Mntto ParquePOS Venta],
	[4.3.5.3.- Gasto Mntto ParquePOS Instalacion],
	[4.3.5.4.- Gasto Mntto ParquePOS Laboratorio],
	[4.3.5.5.- Gasto Mntto ParquePOS Llamada],
	[4.3.5.6.- Gasto Mntto ParquePOS Atenciones],
	[4.3.5.7.- Gasto Mntto ParquePOS Parque],
	[4.3.5.8.- Gasto Mntto ParquePOS Legacy],
	[4.3.5.- Gasto Mntto ParquePOS],
	[4.3.6.- Gasto Recupero de POS],
	[4.3.7.- Gasto Serv Integración],
	[4.3.8.- Gasto Suministros],
	[4.3.9.1.- Gasto Telecarga Licencia TMS],
	[4.3.9.2.- Gasto Telecarga EstateManager],
	[4.3.9.3.- Gasto Telecarga Ontetime],
	[4.3.9.- Gasto Telecarga],
	[4.3.- G.Operacion Sol],
	[4.4.1.- Costo Geopagos],
	[4.4.2.- Gasto Geopagos],
	[4.4.- G.Procesamiento],
	[4.5.1.1.- Gasto Antifraude Cybersource],
	[4.5.1.2.- Gasto Antifraude Amortizacion SAS],
	[4.5.1.3.- Gasto por Decision Management CyberSource],
	[4.5.1.- Gasto Antifraude],
	[4.5.2.- Gasto Antifraude SVA],
	[4.5.3.- Gasto Canales],
	[4.5.4.- Gasto Canales SVA],
	[4.5.5.1.- Gasto SAS Legacy],
	[4.5.5.2.- Gasto SAS Pre],
	[4.5.5.3.- Gasto SAS Post],
	[4.5.5.4.- Gasto SAS Pre y Post],
	[4.5.5.- Gasto SAS],
	[4.5.6.- Gasto SAS SVA],
	[4.5.7.- Registro MPI],
	[4.5.8.- Renovación MPI],
	[4.5.- G.Soporte EC],
	[4.6.1.1.- Gasto Antifraude Amortizacion SAS],
	[4.6.1.2.- Otros Gastos de Amortizaciones],
	[4.6.1.- Gasto de Amortizaciones],
	[4.6.2.- Gasto Depreciación Activa],
	[4.6.- G.Dep y Amort],
	[4.7.1.- Gasto Controversias],
	[4.7.- G.Controversias],
	[4.8.1.- Gasto Call Center],
	[4.8.2.- Gasto Call Tecnico],
	[4.8.3.- Gasto de visitas],
	[4.8.- G.Call Center],
	[4.9.1.- Gasto Contracargo],
	[4.9.2.- Gasto Incobrables],
	[4.9.- G.Cob Dudosa],
	[4.- Gto. Operativo] = [4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa],
	[II.- MARGEN CONTRIBUCION]               = [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa]),
	[II.- MARGEN CONTRIBUCION - Sin G.Afil.] = [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa])+([3.2.5.- Gastos por afiliación]+[3.2.8.- Gasto Call Center - CPA]+[3.2.9.- Gastos por afiliación - Multiagente]),
	[5.1.1.- Gasto Agente Tercero],
	[5.1.- G.Directo Asignado],
	[5.2.1.- Aporte Visa],
	[5.2.2.- Gasto de MKT],
	[5.2.- G.Marketing],
	[5.3.1.- Costo Invenio],
	[5.3.2.- Costo Telefonica],
	[5.3.3.- Gasto Telefonica SVA],
	[5.3.- G.Procesamiento Fijo],
	[5.4.1.- Gasto Personal Eventual],
	[5.4.- G.Personal Eventual],
	[5.5.1.1.- Gasto de Desarrollo de Operaciones],
	[5.5.1.2.- Gasto de Desarrollo de Soporte Empresa],
	[5.5.1.3.- Gasto de Desarrollo de Proyectos de Tecnologia],
	[5.5.1.4.- Gasto de Desarrollo de Servicio al Cliente],
	[5.5.1.5.- Gasto de Desarrollo (Otros)],
	[5.5.1.- Gasto de Desarrollo],
	[5.5.2.- Gasto Testing factory],
	[5.5.- G.Serv Tecnologia],
	[5.6.1.- Gasto de Personal Middle],
	[5.6.- G.Personal Back],
	[5.7.1.- Gasto Alquileres],
	[5.7.- G.Alquiler Almacenes],
	[5.8.1.- Gasto Depreciación Baja],
	[5.8.2.- Gasto Depreciación Inactiva],
	[5.8.- G.Dep y Amort],
	[5.- Gto. Directo Asignado] = [5.1.- G.Directo Asignado]+[5.2.- G.Marketing]+[5.3.- G.Procesamiento Fijo]+[5.4.- G.Personal Eventual]+[5.5.- G.Serv Tecnologia]+[5.6.- G.Personal Back]+[5.7.- G.Alquiler Almacenes]+[5.8.- G.Dep y Amort],
	[III.- MARGEN DIRECTO] =			   [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa])-([5.1.- G.Directo Asignado]+[5.2.- G.Marketing]+[5.3.- G.Procesamiento Fijo]+[5.4.- G.Personal Eventual]+[5.5.- G.Serv Tecnologia]+[5.6.- G.Personal Back]+[5.7.- G.Alquiler Almacenes]+[5.8.- G.Dep y Amort]),
	[III.- MARGEN DIRECTO - Sin G.Afil.] = [1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa])-([5.1.- G.Directo Asignado]+[5.2.- G.Marketing]+[5.3.- G.Procesamiento Fijo]+[5.4.- G.Personal Eventual]+[5.5.- G.Serv Tecnologia]+[5.6.- G.Personal Back]+[5.7.- G.Alquiler Almacenes]+[5.8.- G.Dep y Amort])+([3.2.5.- Gastos por afiliación]+[3.2.8.- Gasto Call Center - CPA]+[3.2.9.- Gastos por afiliación - Multiagente]),
	SIGN([Volumen Niubiz+VendeMas]) AS IndicadorVol,
	SIGN([Transacciones Niubiz+VendeMas]) AS IndicadorTxn,
	SIGN([1.1.- I.Operativo]+[2.1.- I.Operativo]+[3.1.- I.Operativo]) AS IndicadorIngOpe,
	SIGN([1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]) AS IndicadorMgBruto,
	SIGN([1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa])) AS IndicadorMgContribucion,
	SIGN([1.1.- I.Operativo]-[1.2.- C.Operativo]+[2.1.- I.Operativo]-[2.2.- C.Operativo]+[3.1.- I.Operativo]-[3.2.- C.Operativo]-([4.1.- G.Comercio]+[4.2.- G.Personal Front]+[4.3.- G.Operacion Sol]+[4.4.- G.Procesamiento]+[4.5.- G.Soporte EC]+[4.6.- G.Dep y Amort]+[4.7.- G.Controversias]+[4.8.- G.Call Center]+[4.9.- G.Cob Dudosa])-([5.1.- G.Directo Asignado]+[5.2.- G.Marketing]+[5.3.- G.Procesamiento Fijo]+[5.4.- G.Personal Eventual]+[5.5.- G.Serv Tecnologia]+[5.6.- G.Personal Back]+[5.7.- G.Alquiler Almacenes]+[5.8.- G.Dep y Amort])) AS IndicadorMgDirecto
FROM #PL_Subtotals AS a
ORDER BY a.[Periodo], a.[Fuente], a.[Segmento];

IF OBJECT_ID('tempdb..#PL_Subtotals') IS NOT NULL DROP TABLE #PL_Subtotals;

