/* =========================================================================
   Suma de TODAS las columnas de valores para TODOS los comercios de la vista.
   Vista: [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] (transaccional por producto)

   Salida (formato largo, una fila por comercio x columna con valor):
        periodo | codigo_comercio | columna | suma

   Gemelo de todos_los_codigo_awss.sql, que hace lo mismo contra
   rentabilidad.aws_silver_post_base_rentabilidad_puntoventa.

   Por que largo y no PIVOT: con todos los comercios el PIVOT por codigo daria
   decenas de miles de columnas (el motor topa en 1024). El pivoteo, si hace
   falta, se hace en Excel/pandas sobre este resultado.

   Motor Azure Synapse: no soporta APPLY ni el constructor VALUES en el FROM.
   El volteo va con UNPIVOT dinamico, armado desde INFORMATION_SCHEMA.

   OJO -- volumen de salida: filas = (#comercios con movimiento) x (#columnas
   con valor <> 0). Correr primero con @modo = 0 para dimensionar, y bajar el
   resultado a archivo (SSMS: Results to File / notebook a parquet), NO a la
   grilla.
   ========================================================================= */

SET NOCOUNT ON;

/* ----------------------------- parametros ----------------------------- */
DECLARE @periodo         int           = 202608;  -- NULL = todos los periodos (escaneo completo, mucho mas lento)
DECLARE @modo            tinyint       = 1;       -- 0 = solo dimensionar (no baja datos) | 1 = traer datos
DECLARE @min_abs         decimal(38,8) = 0;       -- descarta |suma| <= este valor (0 = descarta solo los ceros)
DECLARE @top_comercios   int           = NULL;    -- NULL = todos; un numero limita la corrida (util para probar)
DECLARE @ordenar         bit           = 0;       -- 0 = sin ORDER BY (mucho mas rapido en salidas grandes)
DECLARE @filtro_codigos  nvarchar(max) = NULL;    -- opcional: '650167573,651008205,...' (solo numeros, sin comillas)
DECLARE @listar_columnas bit           = 0;       -- 1 = devuelve la lista de columnas que va a sumar (ver nota 2)
DECLARE @cod_patrocinado bit           = 0;       -- 1 = resuelve CodigoPatrocinado como en el P&L | 0 = CodigoComercio plano
DECLARE @fuentes         nvarchar(max) = N'''V+''';   -- ej: '''Niubiz'',''Procesamiento'''
DECLARE @excluir_fuentes bit = 1;             -- 1 = NOT IN | 0 = IN

/* Expresion del codigo de comercio.
   El TRY_CAST a bigint no es decorativo: en esta vista CodigoComercio NO es
   numerico (por eso el repo joinea siempre con CAST(a.CodigoComercio AS BIGINT),
   ver base_renta_x_segmento.sql:563 y otros 13 queries). Va TRY_ y no CAST para
   que un codigo con basura no tumbe la corrida: cae como NULL y sale como una
   fila mas, facil de detectar en el resultado.
   Con @cod_patrocinado = 1 se aplica la regla del P&L: los comercios
   patrocinados de Vendemas PF (RUC 20602370497) se reportan bajo su codigo
   patrocinado. Si la tabla AWS no aplica esa regla, poner 0 y volver a comparar. */
DECLARE @expr_codigo nvarchar(400) =
    N'TRY_CAST('
    + CASE WHEN @cod_patrocinado = 1
           THEN N'(CASE WHEN f.Fuente = ''Niubiz'' AND f.RUC IN (''20602370497'') THEN f.CodigoPatrocinado ELSE f.CodigoComercio END)'
           ELSE N'f.CodigoComercio' END
    + N' AS bigint)';

/* ------------------------ variables de armado ------------------------- */
DECLARE @lista_sumas nvarchar(max);   -- CAST(SUM(f.[col]) AS decimal(38,8)) AS [col], ...
DECLARE @lista_cols  nvarchar(max);   -- [col1], [col2], ...   -> IN del UNPIVOT
DECLARE @n_cols      int;
DECLARE @where       nvarchar(max) = N'';
DECLARE @top         nvarchar(50)  = N'';
DECLARE @sql         nvarchar(max);


/* 1) WHERE literal (no parametrizado a proposito).
      Incrustar el periodo como constante permite la eliminacion de particiones
      /segmentos; el patron "(@periodo IS NULL OR Periodo = @periodo)" obliga
      al motor a escanear todo. */
IF @periodo IS NOT NULL
    SET @where = N'WHERE f.Periodo = ' + CAST(@periodo AS nvarchar(10));

IF @filtro_codigos IS NOT NULL AND LEN(@filtro_codigos) > 0
    SET @where = @where
               + CASE WHEN LEN(@where) = 0 THEN N'WHERE ' ELSE N' AND ' END
               + @expr_codigo + N' IN (' + @filtro_codigos + N')';

IF @fuentes IS NOT NULL AND LEN(@fuentes) > 0
    SET @where = @where
               + CASE WHEN LEN(@where) = 0 THEN N'WHERE ' ELSE N' AND ' END
               + CASE WHEN @excluir_fuentes = 1
                      THEN N'(f.Fuente IS NULL OR f.Fuente NOT IN (' + @fuentes + N'))'
                      ELSE N'f.Fuente IN (' + @fuentes + N')' END;

IF @top_comercios IS NOT NULL
    SET @top = N'TOP (' + CAST(@top_comercios AS nvarchar(10)) + N') ';

/* =========================================================================
   2) columnas de valor (metadata, no toca la vista de hechos)
   -------------------------------------------------------------------------
   Diferencia importante vs todos_los_codigo_awss.sql: alla el filtro es
   DATA_TYPE IN ('decimal','numeric') porque la tabla AWS tipa todo asi. Esta
   vista NO necesariamente: varias medidas del stack de rentabilidad vienen
   como float. Por eso aca se aceptan todos los tipos numericos y las llaves /
   dimensiones se excluyen POR NOMBRE.

   Si aparece una dimension numerica nueva en la vista, se colaria como si
   fuera una medida: para eso esta el control de @listar_columnas.
   ========================================================================= */

SELECT @lista_sumas = STRING_AGG(
           CAST('CAST(SUM(f.' + QUOTENAME(c.COLUMN_NAME) + ') AS decimal(38,8)) AS '
                + QUOTENAME(c.COLUMN_NAME) AS nvarchar(max)),
           ',' + CHAR(13) + CHAR(10) + '                    ')
           WITHIN GROUP (ORDER BY c.ORDINAL_POSITION)
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_SCHEMA = 'Finanzas'
  AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
  AND c.DATA_TYPE IN ('decimal','numeric','float','real','money','smallmoney',
                      'int','bigint','smallint','tinyint')
  AND c.COLUMN_NAME NOT IN ('Periodo','RUC','CodigoComercio','CodigoPatrocinado',
                            'MccInt','NumeroDocumento','TipoDocumento');

SELECT @lista_cols = STRING_AGG(
           CAST(QUOTENAME(c.COLUMN_NAME) AS nvarchar(max)),
           ',' + CHAR(13) + CHAR(10) + '            ')
           WITHIN GROUP (ORDER BY c.ORDINAL_POSITION),
       @n_cols = COUNT(*)
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_SCHEMA = 'Finanzas'
  AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
  AND c.DATA_TYPE IN ('decimal','numeric','float','real','money','smallmoney',
                      'int','bigint','smallint','tinyint')
  AND c.COLUMN_NAME NOT IN ('Periodo','RUC','CodigoComercio','CodigoPatrocinado',
                            'MccInt','NumeroDocumento','TipoDocumento');

/* red de seguridad: si el filtro de tipos no devolvio nada, cortar aca con un
   mensaje claro en vez de fallar dentro del SQL dinamico. */
IF @lista_sumas IS NULL
BEGIN
    RAISERROR('No se encontraron columnas numericas en Finanzas.v_ss_Base_Renta_NBZ_VMAS con el filtro actual. Revisar TABLE_SCHEMA/TABLE_NAME y la lista de DATA_TYPE.', 16, 1);
END

/* control: que columnas se van a sumar. Dejar en 1 la primera corrida para
   confirmar que no se colo ninguna dimension; despues apagarlo. */
IF @listar_columnas = 1
BEGIN
    SELECT
          c.ORDINAL_POSITION AS orden
        , c.COLUMN_NAME      AS columna
        , c.DATA_TYPE        AS tipo
    FROM INFORMATION_SCHEMA.COLUMNS AS c
    WHERE c.TABLE_SCHEMA = 'Finanzas'
      AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
      AND c.DATA_TYPE IN ('decimal','numeric','float','real','money','smallmoney',
                          'int','bigint','smallint','tinyint')
      AND c.COLUMN_NAME NOT IN ('Periodo','RUC','CodigoComercio','CodigoPatrocinado',
                                'MccInt','NumeroDocumento','TipoDocumento')
    ORDER BY c.ORDINAL_POSITION;
END

/* ============================ MODO 0: dimensionar =======================
   Un solo scan sobre la llave para saber cuantas filas saldrian antes de
   lanzar la corrida grande. El tope teorico asume todas las columnas con
   valor; el real es bastante menor porque los NULL/ceros se descartan. */
IF @modo = 0
BEGIN
    SET @sql = N'
SELECT
      COUNT_BIG(DISTINCT ' + @expr_codigo + N')            AS comercios
    , @n_cols                                              AS columnas_valor
    , COUNT_BIG(DISTINCT ' + @expr_codigo + N') * @n_cols  AS filas_tope_teorico
FROM [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] AS f
' + @where + N';';

    EXEC sp_executesql @sql, N'@n_cols int', @n_cols = @n_cols;
END

/* ============================ MODO 1: datos ============================
   Un solo scan de la vista:
     a) GROUP BY periodo, comercio con las N sumas  -> #comercios filas
     b) UNPIVOT sobre ese agregado (no sobre el detalle) -> formato largo

   Sin ISNULL(...,0) a proposito: el UNPIVOT descarta los NULL solo, asi que
   las medidas sin movimiento se caen antes del filtro y no cuestan nada. */
ELSE
BEGIN
    SET @sql = N'
SELECT
      u.Periodo AS periodo
    , u.codigo_comercio
    , u.columna
    , u.suma
FROM (
        SELECT ' + @top + N'
              f.Periodo
            , ' + @expr_codigo + N' AS codigo_comercio
            , ' + @lista_sumas + N'
        FROM [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] AS f
        ' + @where + N'
        GROUP BY f.Periodo, ' + @expr_codigo
        + CASE WHEN @top_comercios IS NULL THEN N''
               ELSE N'
        ORDER BY ' + @expr_codigo END + N'
     ) AS a
UNPIVOT (
        suma FOR columna IN (
            ' + @lista_cols + N'
        )
) AS u
WHERE ABS(u.suma) > @min_abs'
+ CASE WHEN @ordenar = 1 THEN N'
ORDER BY u.codigo_comercio, u.columna' ELSE N'' END + N';';

    -- PRINT LEFT(@sql, 4000);   -- descomentar para inspeccionar el SQL generado

    EXEC sp_executesql @sql, N'@min_abs decimal(38,8)', @min_abs = @min_abs;
END


/* -------------------------------------------------------------------------
   NOTAS DE USO / RENDIMIENTO

   1. Secuencia recomendada:
        @modo = 0                        -> ver cuantas filas salen
        @modo = 1, @top_comercios = 500  -> validar formato y tiempos
        @modo = 1, @top_comercios = NULL -> corrida completa a archivo

   2. @listar_columnas = 1 devuelve la lista exacta de columnas que se van a
      sumar. Vale la pena mirarla la primera vez: el filtro de esta vista es
      por tipo numerico + exclusion por nombre (no como en AWS, donde alcanza
      con decimal/numeric), asi que una dimension numerica no listada en el
      NOT IN se colaria como si fuera una medida. Si aparece alguna, agregarla
      al NOT IN de los tres bloques del paso 2.

   3. Palancas para achicar la salida, de mayor a menor impacto:
        - @min_abs = 0.005  descarta redondeos/centavos residuales
        - @filtro_codigos   acota a una lista puntual
        - @ordenar = 0      evita ordenar millones de filas (default)

   4. Lo caro es el GROUP BY sobre el detalle; el UNPIVOT ya trabaja sobre el
      agregado. Ampliar @periodo a NULL multiplica el costo por la cantidad de
      periodos de la vista: hacerlo solo si de verdad se necesita historia.

   5. Codigos NULL: el TRY_CAST devuelve NULL para codigos vacios o no
      convertibles a bigint, y esas filas se agrupan en un unico
      codigo_comercio = NULL. NO se filtran a proposito: si ese grupo trae
      importes, es un hallazgo de calidad de datos. Para aislarlo:

        SELECT * FROM (<este resultado>) WHERE codigo_comercio IS NULL

   6. Comparar contra todos_los_codigo_awss.sql. OJO: los nombres de columna
      no se parean con una sola regla.
        - La mayoria de las medidas: AWS = 'brpv_' + minuscula del nombre FIN
          (VI_TRX_FOR_6393101VARNP  <->  brpv_vi_trx_for_6393101varnp).
        - Pero varios agregados cambiaron de nombre en la migracion
          (FIN voltot / txstot / CVTOT / CTTOT  <->  AWS brpv_vol_tot /
          brpv_txs_tot / brpv_cv_tot / brpv_ct_tot).
      La regla del prefijo cubre el grueso; el resto se parea a mano. Los
      nombres que queden sin par son parte del hallazgo, no ruido:

        fin['key'] = fin['columna'].str.lower()
        awz['key'] = awz['columna'].str.lower().str.replace('^brpv_', '', regex=True)
        sin_par = set(fin['key']) ^ set(awz['key'])   # revisar ESTO primero

   7. Grano: esta vista es transaccional por producto y la de AWS es por punto
      de venta. No importa para este query porque ambos agregan a
      periodo x comercio, pero si importa si algun dia se compara fila a fila.

   8. Para pivotear despues en pandas:
        df.pivot_table(index='columna', columns='codigo_comercio',
                       values='suma', aggfunc='sum', fill_value=0)
   ------------------------------------------------------------------------- */
