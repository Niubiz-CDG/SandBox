/* =========================================================================
   Suma de un SUBCONJUNTO de columnas de valores para TODOS los comercios.
   Vista: [Finanzas].[v_ss_Base_Renta_NBZ_VMAS] (transaccional por producto)

   Variante de todos_los_codigos_finanzas.sql: identica en estructura, salida y
   parametros, pero en vez de barrer todas las columnas numericas suma solo las
   que estan en @cols_pedidas (comisiones + CT/CV).

   Salida (formato largo, una fila por comercio x columna con valor):
        periodo | codigo_comercio | columna | suma

   Diferencia de fondo vs el query completo: alla las columnas salen de un
   filtro por DATA_TYPE + exclusion por nombre; aca salen de una lista fija.
   Eso invierte el riesgo: ya no se cuela una dimension numerica, pero SI se
   puede pedir un nombre que no existe en la vista. Por eso @avisar_faltantes
   viene en 1 y devuelve las que no se pudieron resolver (ver nota 2).

   El match de nombres es tolerante: ignora mayusculas, espacios, guiones y
   guiones bajos. Asi 'Com Emi For', 'ComEmiFor' y 'com_emi_for' resuelven a la
   misma columna real de la vista, sea cual sea la forma en que este escrita.

   Motor Azure Synapse: no soporta APPLY ni el constructor VALUES en el FROM.
   El volteo va con UNPIVOT dinamico, armado desde INFORMATION_SCHEMA.
   ========================================================================= */

SET NOCOUNT ON;

/* ----------------------------- parametros ----------------------------- */
DECLARE @periodo          int           = 202608;  -- NULL = todos los periodos (escaneo completo, mucho mas lento)
DECLARE @modo             tinyint       = 1;       -- 0 = solo dimensionar (no baja datos) | 1 = traer datos
DECLARE @min_abs          decimal(38,8) = 0;       -- descarta |suma| <= este valor (0 = descarta solo los ceros)
DECLARE @top_comercios    int           = NULL;    -- NULL = todos; un numero limita la corrida (util para probar)
DECLARE @ordenar          bit           = 0;       -- 0 = sin ORDER BY (mucho mas rapido en salidas grandes)
DECLARE @filtro_codigos   nvarchar(max) = NULL;    -- opcional: '650167573,651008205,...' (solo numeros, sin comillas)
DECLARE @listar_columnas  bit           = 1;       -- 1 = devuelve la lista de columnas que va a sumar
DECLARE @avisar_faltantes bit           = 1;       -- 1 = avisa las columnas pedidas que no existen / no son numericas
DECLARE @cod_patrocinado  bit           = 0;       -- 1 = resuelve CodigoPatrocinado como en el P&L | 0 = CodigoComercio plano
DECLARE @fuentes          nvarchar(max) = N'''V+''';   -- ej: '''Niubiz'',''Procesamiento'''
DECLARE @excluir_fuentes  bit           = 1;       -- 1 = NOT IN | 0 = IN

/* Columnas a sumar. Una por linea, separadas por coma; los espacios internos,
   guiones y guiones bajos se ignoran al parear contra la vista. Agregar o
   quitar aca es el unico cambio necesario para cambiar el alcance. */
DECLARE @cols_pedidas nvarchar(max) = N'
      Com Emi For
    , Com Emi Loc
    , Com Emi Tot
    , Com Total
    , Com Vsnt
    , Com Vsnt1L
    , CTCEI
    , CTCEN
    , CTCMI
    , CTCMN
    , CTDI
    , CTDN
    , CTTOT
    , CVCEI
    , CVCEN
    , CVCMI
    , CVCMN
    , CVDI
    , CVDN
    , CVTOT
';

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
DECLARE @n_pedidas   int;
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
   Se parte de @cols_pedidas y se resuelve cada nombre contra la vista con la
   clave normalizada (minusculas, sin espacios / guiones / guiones bajos). Se
   toma el nombre REAL de INFORMATION_SCHEMA, no el escrito arriba: el alias
   del SELECT y el IN del UNPIVOT tienen que coincidir exacto.

   El filtro por DATA_TYPE se mantiene como red: si alguna de las pedidas no
   fuera numerica, la suma reventaria adentro del SQL dinamico con un error
   opaco. Asi queda afuera y se reporta en el bloque de faltantes.
   ========================================================================= */

SELECT @n_pedidas = COUNT(*)
FROM STRING_SPLIT(@cols_pedidas, ',') AS s
WHERE LEN(LTRIM(RTRIM(s.value))) > 0;

SELECT @lista_sumas = STRING_AGG(
           CAST('CAST(SUM(f.' + QUOTENAME(x.COLUMN_NAME) + ') AS decimal(38,8)) AS '
                + QUOTENAME(x.COLUMN_NAME) AS nvarchar(max)),
           ',' + CHAR(13) + CHAR(10) + '                    ')
           WITHIN GROUP (ORDER BY x.ORDINAL_POSITION)
     , @lista_cols = STRING_AGG(
           CAST(QUOTENAME(x.COLUMN_NAME) AS nvarchar(max)),
           ',' + CHAR(13) + CHAR(10) + '            ')
           WITHIN GROUP (ORDER BY x.ORDINAL_POSITION)
     , @n_cols = COUNT(*)
FROM (
        SELECT DISTINCT c.COLUMN_NAME, c.ORDINAL_POSITION
        FROM INFORMATION_SCHEMA.COLUMNS AS c
        INNER JOIN STRING_SPLIT(@cols_pedidas, ',') AS s
                ON REPLACE(REPLACE(REPLACE(LOWER(LTRIM(RTRIM(s.value))), ' ', ''), '_', ''), '-', '')
                 = REPLACE(REPLACE(REPLACE(LOWER(c.COLUMN_NAME),          ' ', ''), '_', ''), '-', '')
        WHERE c.TABLE_SCHEMA = 'Finanzas'
          AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
          AND c.DATA_TYPE IN ('decimal','numeric','float','real','money','smallmoney',
                              'int','bigint','smallint','tinyint')
     ) AS x;

/* red de seguridad: si no resolvio ninguna, cortar aca con un mensaje claro en
   vez de fallar adentro del SQL dinamico. */
IF @lista_sumas IS NULL
BEGIN
    RAISERROR('Ninguna de las columnas de @cols_pedidas existe como columna numerica en Finanzas.v_ss_Base_Renta_NBZ_VMAS. Correr todos_los_codigos_finanzas.sql con @listar_columnas = 1 para ver los nombres reales de la vista.', 16, 1);
END

/* control 1: que columnas se van a sumar (nombre real + tipo). */
IF @listar_columnas = 1
BEGIN
    SELECT DISTINCT
          c.ORDINAL_POSITION AS orden
        , c.COLUMN_NAME      AS columna
        , c.DATA_TYPE        AS tipo
    FROM INFORMATION_SCHEMA.COLUMNS AS c
    INNER JOIN STRING_SPLIT(@cols_pedidas, ',') AS s
            ON REPLACE(REPLACE(REPLACE(LOWER(LTRIM(RTRIM(s.value))), ' ', ''), '_', ''), '-', '')
             = REPLACE(REPLACE(REPLACE(LOWER(c.COLUMN_NAME),          ' ', ''), '_', ''), '-', '')
    WHERE c.TABLE_SCHEMA = 'Finanzas'
      AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
      AND c.DATA_TYPE IN ('decimal','numeric','float','real','money','smallmoney',
                          'int','bigint','smallint','tinyint')
    ORDER BY c.ORDINAL_POSITION;
END

/* control 2: columnas pedidas que quedaron afuera, con el motivo.
   'no existe en la vista'       -> el nombre no aparece en INFORMATION_SCHEMA
   'existe pero no es numerica'  -> aparece, pero con un tipo que no se suma */
IF @avisar_faltantes = 1 AND @n_cols < @n_pedidas
BEGIN
    SELECT
          LTRIM(RTRIM(s.value)) AS columna_pedida
        , CASE WHEN c.COLUMN_NAME IS NULL
               THEN 'no existe en la vista'
               ELSE 'existe pero no es numerica (' + c.DATA_TYPE + ')' END AS motivo
    FROM STRING_SPLIT(@cols_pedidas, ',') AS s
    LEFT JOIN INFORMATION_SCHEMA.COLUMNS AS c
           ON c.TABLE_SCHEMA = 'Finanzas'
          AND c.TABLE_NAME   = 'v_ss_Base_Renta_NBZ_VMAS'
          AND REPLACE(REPLACE(REPLACE(LOWER(LTRIM(RTRIM(s.value))), ' ', ''), '_', ''), '-', '')
            = REPLACE(REPLACE(REPLACE(LOWER(c.COLUMN_NAME),          ' ', ''), '_', ''), '-', '')
    WHERE LEN(LTRIM(RTRIM(s.value))) > 0
      AND (c.COLUMN_NAME IS NULL
           OR c.DATA_TYPE NOT IN ('decimal','numeric','float','real','money','smallmoney',
                                  'int','bigint','smallint','tinyint'));
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
        @modo = 1, @top_comercios = NULL -> corrida completa

      Con 20 columnas la salida es chica comparada con el query completo (20
      filas por comercio como tope), asi que en general se puede bajar a la
      grilla sin necesidad de Results to File.

   2. Los nombres de @cols_pedidas estan escritos tal como llegaron
      ('Com Emi For', 'CTCEI', ...). Si en la vista estan sin espacios o con
      guion bajo, el match normalizado igual los resuelve y no hay que tocar
      nada. Lo que SI conviene mirar en la primera corrida es el bloque de
      faltantes: si alguna sale como 'no existe en la vista', el nombre real
      difiere en algo mas que espacios/guiones (abreviatura distinta, sufijo,
      etc.) y hay que corregirla en la lista. Para ver los nombres reales,
      correr todos_los_codigos_finanzas.sql con @listar_columnas = 1.

   3. Un caso a tener presente con el match tolerante: si la vista tuviera dos
      columnas que normalizan igual ('Com Emi For' y 'ComEmiFor'), entran las
      dos y salen como dos filas distintas. El DISTINCT es sobre el nombre
      real, no sobre la clave normalizada, a proposito: mejor verlas y decidir
      que perder una en silencio.

   4. Palancas para achicar la salida, de mayor a menor impacto:
        - @min_abs = 0.005  descarta redondeos/centavos residuales
        - @filtro_codigos   acota a una lista puntual
        - @ordenar = 0      evita ordenar millones de filas (default)

   5. Lo caro sigue siendo el GROUP BY sobre el detalle, y eso no baja mucho
      por pedir menos columnas: el scan de la vista es el mismo. La ganancia de
      esta version esta en el tamano de la salida, no en el tiempo del query.

   6. Comparar contra todos_los_codigo_awss.sql. De esta lista, CTTOT y CVTOT
      son justamente dos de las que cambiaron de nombre en la migracion
      (FIN CVTOT / CTTOT <-> AWS brpv_cv_tot / brpv_ct_tot); el resto deberia
      parear con la regla del prefijo:

        fin['key'] = fin['columna'].str.lower()
        awz['key'] = awz['columna'].str.lower().str.replace('^brpv_', '', regex=True)
        sin_par = set(fin['key']) ^ set(awz['key'])   # revisar ESTO primero

   7. Para pivotear despues en pandas:
        df.pivot_table(index='columna', columns='codigo_comercio',
                       values='suma', aggfunc='sum', fill_value=0)
   ------------------------------------------------------------------------- */
