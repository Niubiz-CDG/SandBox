/* =========================================================================
   Suma de 20 columnas de valores para TODOS los comercios.
   Vista: [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] (transaccional por producto)

   Version estatica de columnas_sel_finanzas.sql. Misma salida exacta, sin SQL
   dinamico: los nombres de las 20 columnas estan verificados contra la vista,
   asi que no hace falta resolverlos contra INFORMATION_SCHEMA en tiempo de
   corrida ni avisar faltantes.

   Salida (formato largo, una fila por comercio x columna con valor):
        periodo | codigo_comercio | columna | suma

   Cual de las dos usar:
     - esta        -> para correr y leer. Se edita a mano, el plan se ve en
                      SSMS sin tener que imprimir el SQL generado.
     - la dinamica -> cuando la lista de columnas cambia seguido, o cuando no
                      se sabe como estan escritos los nombres en la vista
                      (resuelve espacios / guiones bajos sola).

   Para cambiar el alcance hay que tocar DOS lugares: la lista de SUM(...) y el
   IN del UNPIVOT. Tienen que quedar identicos; si se agrega una columna en uno
   solo, el motor avisa (columna no encontrada) y no da un resultado silencioso
   y mal.

   Motor Azure Synapse: sin APPLY ni VALUES en el FROM. El UNPIVOT estatico si
   esta soportado.
   ========================================================================= */

SET NOCOUNT ON;

/* -------------------------------------------------------------------------
   PARAMETROS -- van como literales, no como variables, a proposito.
   Incrustar el periodo como constante permite la eliminacion de particiones /
   segmentos; con una variable el motor estima a ciegas y tiende a escanear
   todo. Editar directamente en el WHERE de abajo:

     f.Periodo = 202608          -> el periodo a correr (borrar la linea = todos)
     f.Fuente NOT IN ('V+')      -> fuentes a excluir (o cambiar a IN para incluir)
     ABS(u.suma) > 0             -> 0 descarta solo los ceros; 0.005 descarta
                                    ademas redondeos y centavos residuales
   ------------------------------------------------------------------------- */

SELECT
      u.Periodo AS periodo
   -- , u.codigo_comercio
    , u.columna
    , u.suma
FROM (
        /* a) agregado: una fila por periodo x comercio, 20 medidas.
              El TRY_CAST a bigint no es decorativo: en esta vista
              CodigoComercio NO es numerico (por eso el repo joinea siempre con
              CAST(a.CodigoComercio AS BIGINT), ver base_renta_x_segmento.sql:563
              y otros 13 queries). Va TRY_ y no CAST para que un codigo con
              basura no tumbe la corrida: cae como NULL y sale como una fila
              mas, facil de detectar en el resultado.

              El CAST a decimal(38,8) de cada suma no es cosmetico: el UNPIVOT
              exige que TODAS las columnas del IN tengan el mismo tipo, y en
              esta vista conviven decimal y float. */
        SELECT
              f.Periodo
         --   , TRY_CAST(f.CodigoComercio AS bigint)          AS codigo_comercio

            , CAST(SUM(f.[CTTOT])       AS decimal(38,8))   AS [CTTOT]
            , CAST(SUM(f.[CVTOT])       AS decimal(38,8))   AS [CVTOT]
            , CAST(SUM(f.[CTCEN])       AS decimal(38,8))   AS [CTCEN]
            , CAST(SUM(f.[CTCEI])       AS decimal(38,8))   AS [CTCEI]
            , CAST(SUM(f.[CTDN])        AS decimal(38,8))   AS [CTDN]
            , CAST(SUM(f.[CTDI])        AS decimal(38,8))   AS [CTDI]
            , CAST(SUM(f.[CTCMN])       AS decimal(38,8))   AS [CTCMN]
            , CAST(SUM(f.[CTCMI])       AS decimal(38,8))   AS [CTCMI]
            , CAST(SUM(f.[CVCEN])       AS decimal(38,8))   AS [CVCEN]
            , CAST(SUM(f.[CVCEI])       AS decimal(38,8))   AS [CVCEI]
            , CAST(SUM(f.[CVDN])        AS decimal(38,8))   AS [CVDN]
            , CAST(SUM(f.[CVDI])        AS decimal(38,8))   AS [CVDI]
            , CAST(SUM(f.[CVCMN])       AS decimal(38,8))   AS [CVCMN]
            , CAST(SUM(f.[CVCMI])       AS decimal(38,8))   AS [CVCMI]
            , CAST(SUM(f.[Com Total])   AS decimal(38,8))   AS [Com Total]
            , CAST(SUM(f.[Com Vsnt1L])  AS decimal(38,8))   AS [Com Vsnt1L]
            , CAST(SUM(f.[Com Emi Tot]) AS decimal(38,8))   AS [Com Emi Tot]
            , CAST(SUM(f.[Com Emi Loc]) AS decimal(38,8))   AS [Com Emi Loc]
            , CAST(SUM(f.[Com Emi For]) AS decimal(38,8))   AS [Com Emi For]
            , CAST(SUM(f.[Com Vsnt])    AS decimal(38,8))   AS [Com Vsnt]
        FROM [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] AS f
        WHERE f.Periodo = 202608
          AND (f.Fuente IS NULL OR f.Fuente NOT IN ('V+'))
        GROUP BY
              f.Periodo
            --, TRY_CAST(f.CodigoComercio AS bigint)
     ) AS a
/* b) volteo a formato largo. Va sobre el agregado (20 valores por comercio),
      no sobre el detalle, asi que no cuesta practicamente nada.

      Sin ISNULL(...,0) a proposito: el UNPIVOT descarta los NULL solo, asi que
      las medidas sin movimiento se caen antes del filtro y no ocupan fila. */
UNPIVOT (
        suma FOR columna IN (
              [CTTOT]
            , [CVTOT]
            , [CTCEN]
            , [CTCEI]
            , [CTDN]
            , [CTDI]
            , [CTCMN]
            , [CTCMI]
            , [CVCEN]
            , [CVCEI]
            , [CVDN]
            , [CVDI]
            , [CVCMN]
            , [CVCMI]
            , [Com Total]
            , [Com Vsnt1L]
            , [Com Emi Tot]
            , [Com Emi Loc]
            , [Com Emi For]
            , [Com Vsnt]
        )
) AS u
WHERE ABS(u.suma) > 0;


/* -------------------------------------------------------------------------
   NOTAS

   1. Volumen: 20 filas por comercio como tope (menos, porque los ceros y los
      NULL se descartan). Baja a la grilla sin problema; no hace falta el
      Results to File que si pide todos_los_codigos_finanzas.sql.

   2. Codigo patrocinado: esta version usa CodigoComercio plano. Si hay que
      aplicar la regla del P&L (los patrocinados de Vendemas PF, RUC
      20602370497, se reportan bajo su codigo patrocinado), reemplazar las dos
      apariciones de TRY_CAST(f.CodigoComercio AS bigint) -- SELECT y GROUP BY,
      tienen que quedar iguales -- por:

        TRY_CAST(CASE WHEN f.Fuente = 'Niubiz' AND f.RUC IN ('20602370497')
                      THEN f.CodigoPatrocinado ELSE f.CodigoComercio END AS bigint)

      o usar columnas_sel_finanzas.sql con @cod_patrocinado = 1.

   3. Acotar a una lista de comercios: agregar al WHERE del agregado

        AND TRY_CAST(f.CodigoComercio AS bigint) IN (650167573, 651008205)

   4. Si se quiere el formato ancho (una fila por comercio, 20 columnas) en vez
      del largo: borrar el bloque UNPIVOT completo y el SELECT externo, y dejar
      el agregado del medio como query. El largo esta por default porque es el
      formato que compara directo contra todos_los_codigo_awss.sql.

   5. Comparar contra todos_los_codigo_awss.sql. OJO con dos de estas columnas:
      CTTOT y CVTOT cambiaron de nombre en la migracion (FIN CTTOT / CVTOT <->
      AWS brpv_ct_tot / brpv_cv_tot), no siguen la regla general del prefijo:

        fin['key'] = fin['columna'].str.lower()
        awz['key'] = awz['columna'].str.lower().str.replace('^brpv_', '', regex=True)
        sin_par = set(fin['key']) ^ set(awz['key'])   # revisar ESTO primero

   6. Codigos NULL: el TRY_CAST devuelve NULL para codigos vacios o no
      convertibles a bigint, y esas filas se agrupan en un unico
      codigo_comercio = NULL. NO se filtran a proposito: si ese grupo trae
      importes, es un hallazgo de calidad de datos.

   7. Para pivotear despues en pandas:
        df.pivot_table(index='columna', columns='codigo_comercio',
                       values='suma', aggfunc='sum', fill_value=0)
   ------------------------------------------------------------------------- */
