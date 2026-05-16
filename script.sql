SET NOCOUNT ON;

-- =========================================================================
-- 1. LIMPEZA DE TABELAS TEMPORÁRIAS
-- =========================================================================
IF OBJECT_ID('tempdb..#Baselines') IS NOT NULL DROP TABLE #Baselines;
IF OBJECT_ID('tempdb..#ValoresAtuais') IS NOT NULL DROP TABLE #ValoresAtuais;
IF OBJECT_ID('tempdb..#StaleStatsDetails') IS NOT NULL DROP TABLE #StaleStatsDetails;

-- =========================================================================
-- 2. TABELA BASE (MÉTRICAS, CENÁRIOS E PESOS)
-- =========================================================================
CREATE TABLE #Baselines (
    ID INT, Metrica VARCHAR(100), Unidade VARCHAR(25),
    Cenario_Ruim VARCHAR(50), Cenario_Bom VARCHAR(50), Cenario_Otimo VARCHAR(50), Peso INT,
    Descricao VARCHAR(800)
);

INSERT INTO #Baselines VALUES
(1, 'Latência de Disco (Leitura)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 3, 'Mede o tempo para ler dados. Impacto: Lentidão geral do banco. Ruim: Consultas demoradas. Ótimo: Respostas ágeis de I/O.'),
(2, 'Latência de Disco (Escrita)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 3, 'Mede o tempo para gravar dados. Impacto: Lentidão em Inserts/Updates. Ruim: Gargalo em transações. Ótimo: Escritas rápidas.'),
(3, 'Page Life Expectancy (PLE)', 'segundos', '< 300 seg', '300 a 1000 seg', '> 1000 seg', 4, 'Tempo que uma página fica na RAM antes de ir pro disco. Ruim: Pressão de memória (falta de RAM). Ótimo: Cache retendo dados bem.'),
(4, 'Buffer Cache Hit Ratio', '%', '< 95%', '95% a 98%', '> 99%', 1, '% de dados lidos da RAM em vez do disco. Ruim: Disco sendo muito exigido. Ótimo: A maioria das leituras ocorre direto na memória.'),
(5, 'Uso de CPU (Instantâneo)', '%', '> 80%', '50% a 80%', '< 50%', 3, 'Consumo atual do processador. Ruim: Travamentos, filas e lentidão sistêmica (risco alto). Ótimo: Servidor trabalhando com folga.'),
(6, 'Signal Waits % (Fila CPU)', '%', '> 25%', '10% a 25%', '< 10%', 2, 'Tempo na fila da CPU. Ruim: Processos prontos aguardando liberação do processador (CPU insuficiente). Ótimo: Execução imediata.'),
(7, 'User Connections (Total)', 'Conexões', 'N/A', 'N/A', 'N/A', 0, 'Total de conexões ativas. Informativo: ajuda a entender o volume de acessos simultâneos no momento (Não gera pontuação).'),
(8, 'Memory Grants Pending', 'Processos', '> 5', '1 a 5', '0', 4, 'Processos aguardando RAM livre para executar. Ruim: Lentidão severa em queries aguardando recursos. Ótimo: RAM suficiente.'),
(9, 'Deadlocks/sec', 'Ocorrências/s', '> 2', '1 a 2', '0', 3, 'Processos que se bloqueiam mutuamente. Ruim: Erros na aplicação e transações canceladas (vítimas). Ótimo: Concorrência saudável.'),
(10, 'TempDB: Espaço Ocupado', '%', '> 90%', '70% a 90%', '< 70%', 3, '% de uso do TempDB. Ruim: Se bater 100%, o servidor SQL paralisa. Ótimo: Espaço de sobra para ordenações e temp tables.'),
(11, 'TempDB: Fila (PAGELATCH)', 'Processos', '> 5', '1 a 5', '0', 3, 'Concorrência interna de arquivos do TempDB. Ruim: Lentidão em picos de acesso. Ótimo: Arquivos bem configurados e divididos.'),
(12, 'Cost Threshold for Parallelism', 'Valor', '<= 5', '6 a 49', '>= 50', 3, 'Custo para paralelizar uma query. Ruim: Padrão (5) faz queries simples gastarem toda CPU. Ótimo: CPU usada só para queries pesadas.'),
(13, 'Identity Columns (Risco Estouro)', 'Uso Máx %', '> 80%', '50% a 80%', '< 50%', 5, 'Risco de colunas ID chegarem ao limite numérico (ex: INT). Ruim: Se bater 100%, impossível inserir dados na tabela (crash). Ótimo: Limites seguros.'),
(14, 'Estatísticas Desatualizadas', 'Tabelas', '> 10', '1 a 10', '0', 4, 'Qtd de tabelas com estatísticas defasadas. Ruim: O SQL usa planos ruins (Scans lentos ao invés de Seeks). Ótimo: Índices usados de forma inteligente.'),
(15, 'Virtual Log Files (VLFs)', 'Qtd Máx/DB', '> 1000', '100 a 1000', '< 100', 3, 'Fragmentação do arquivo de LOG. Ruim: Backups demorados e lentidão extrema ao iniciar a base/restore. Ótimo: Log consolidado.'),
(16, 'Plan Cache Bloat (Ad-Hoc)', '% RAM Cache', '> 30%', '10% a 30%', '< 10%', 4, 'Desperdício de RAM com queries Ad-Hoc. Ruim: Queries "descartáveis" roubando RAM de dados em cache. Ótimo: Reuso eficiente de planos.');

-- =========================================================================
-- 3. CAPTURA DOS VALORES EM TEMPO REAL
-- =========================================================================
CREATE TABLE #ValoresAtuais (ID INT, ValorAtual NUMERIC(10,2), Pontos INT DEFAULT 0);
CREATE TABLE #StaleStatsDetails (DatabaseName NVARCHAR(128), SchemaName NVARCHAR(128), TableName NVARCHAR(128), StatName NVARCHAR(128), ModCount BIGINT);

-- Variáveis da versão anterior
DECLARE @AvgReadLatency NUMERIC(10,2), @AvgWriteLatency NUMERIC(10,2), @PageLifeExpectancy BIGINT;
DECLARE @BufferCacheHitRatio NUMERIC(10,2), @CpuUtilizacao NUMERIC(10,2), @SignalWaitsPercent NUMERIC(10,2);
DECLARE @UserConnections INT, @MemoryGrants INT, @Deadlocks INT, @TempdbTotalMB NUMERIC(10,2);
DECLARE @TempdbFreeMB NUMERIC(10,2), @TempdbUsedPercent NUMERIC(10,2), @TempdbPagelatch INT;
-- Novas variáveis
DECLARE @CostThreshold INT, @MaxIdentityPercent NUMERIC(10,2) = 0;
DECLARE @StaleStatsCount INT = 0, @MaxVLFCount INT = 0, @AdHocPercent NUMERIC(10,2) = 0;

-- 3.1 Capturas base (I/O, RAM, CPU, Travamentos)
SELECT @AvgReadLatency = AVG(io_stall_read_ms / CASE WHEN num_of_reads = 0 THEN 1 ELSE num_of_reads END), @AvgWriteLatency = AVG(io_stall_write_ms / CASE WHEN num_of_writes = 0 THEN 1 ELSE num_of_writes END) FROM sys.dm_io_virtual_file_stats(NULL, NULL);
SELECT @PageLifeExpectancy = cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy';
SELECT @BufferCacheHitRatio = (a.cntr_value * 1.0 / CASE WHEN b.cntr_value = 0 THEN 1 ELSE b.cntr_value END) * 100.0 FROM sys.dm_os_performance_counters a JOIN sys.dm_os_performance_counters b ON a.object_name = b.object_name WHERE a.object_name LIKE '%Buffer Manager%' AND a.counter_name = 'Buffer cache hit ratio' AND b.counter_name = 'Buffer cache hit ratio base';
SELECT TOP 1 @CpuUtilizacao = 100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') FROM (SELECT CAST(record AS XML) AS record, timestamp FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE '%<SystemHealth>%') AS x ORDER BY timestamp DESC;
SELECT @SignalWaitsPercent = (SUM(signal_wait_time_ms) * 100.0 / CASE WHEN SUM(wait_time_ms) = 0 THEN 1 ELSE SUM(wait_time_ms) END) FROM sys.dm_os_wait_stats;
SELECT @UserConnections = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;
SELECT @MemoryGrants = cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Memory Grants Pending';
SELECT @Deadlocks = cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Locks%' AND counter_name = 'Number of Deadlocks/sec' AND instance_name = '_Total';
CREATE TABLE #TempDBSpace (FreePageCount BIGINT); INSERT INTO #TempDBSpace EXEC('USE tempdb; SELECT SUM(unallocated_extent_page_count) FROM sys.dm_db_file_space_usage'); SELECT @TempdbFreeMB = FreePageCount * 8.0 / 1024.0 FROM #TempDBSpace; SELECT @TempdbTotalMB = SUM(size) * 8.0 / 1024.0 FROM tempdb.sys.database_files WHERE type = 0; SET @TempdbUsedPercent = 100.0 - ((@TempdbFreeMB / CASE WHEN @TempdbTotalMB = 0 THEN 1 ELSE @TempdbTotalMB END) * 100.0); DROP TABLE #TempDBSpace;
SELECT @TempdbPagelatch = COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'PAGELATCH_%' AND resource_description LIKE '2:%';

-- 3.2 Novas Métricas Arquiteturais

-- Configuração de Paralelismo
SELECT @CostThreshold = CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'cost threshold for parallelism';

-- Risco de Estouro Matemático (Identity Columns)
SELECT @MaxIdentityPercent = ISNULL(MAX(
    CASE
        WHEN t.name = 'tinyint' THEN (CAST(last_value AS NUMERIC(38,2)) / 255.0) * 100
        WHEN t.name = 'smallint' THEN (CAST(last_value AS NUMERIC(38,2)) / 32767.0) * 100
        WHEN t.name = 'int' THEN (CAST(last_value AS NUMERIC(38,2)) / 2147483647.0) * 100
        WHEN t.name = 'bigint' THEN (CAST(last_value AS NUMERIC(38,2)) / 9223372036854775807.0) * 100
        ELSE 0
    END), 0)
FROM sys.identity_columns ic
JOIN sys.types t ON ic.system_type_id = t.system_type_id
WHERE last_value IS NOT NULL;

-- Estatísticas Defasadas (> 10.000 modificações) em TODOS os bancos de usuário
EXEC sp_MSforeachdb '
BEGIN TRY
    USE [?];
    IF DB_ID(''?'') > 4 AND DATABASEPROPERTYEX(''?'', ''Status'') = ''ONLINE''
    BEGIN
        INSERT INTO #StaleStatsDetails (DatabaseName, SchemaName, TableName, StatName, ModCount)
        SELECT 
            ''?'',
            OBJECT_SCHEMA_NAME(stat.object_id),
            OBJECT_NAME(stat.object_id),
            stat.name,
            sp.modification_counter
        FROM sys.stats AS stat
        CROSS APPLY sys.dm_db_stats_properties(stat.object_id, stat.stats_id) AS sp
        WHERE sp.modification_counter > 10000
          AND OBJECTPROPERTY(stat.object_id, ''IsMSShipped'') = 0;
    END
END TRY
BEGIN CATCH
    -- Ignora bancos com problemas de permissão ou inacessíveis
END CATCH
';

SELECT @StaleStatsCount = COUNT(DISTINCT CONCAT(DatabaseName, '.', SchemaName, '.', TableName)) 
FROM #StaleStatsDetails;

-- Excesso de VLFs (Testa se a DMV existe no servidor atual)
IF OBJECT_ID('sys.dm_db_log_info') IS NOT NULL
BEGIN
    SELECT @MaxVLFCount = ISNULL(MAX(vlf_count), 0)
    FROM (
        SELECT COUNT(l.database_id) AS vlf_count
        FROM sys.databases s
        CROSS APPLY sys.dm_db_log_info(s.database_id) l
        GROUP BY s.database_id
    ) AS vlf;
END

-- Plan Cache Bloat (Desperdício de memória com Single-use Ad-hoc queries)
SELECT @AdHocPercent = ISNULL((SUM(CASE WHEN objtype = 'Adhoc' AND usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) * 100.0) /
                       NULLIF(SUM(CAST(size_in_bytes AS BIGINT)), 0), 0)
FROM sys.dm_exec_cached_plans;

-- =========================================================================
-- 4. ATRIBUIÇÃO DOS PONTOS
-- =========================================================================
INSERT INTO #ValoresAtuais (ID, ValorAtual) VALUES 
(1, ISNULL(@AvgReadLatency,0)), (2, ISNULL(@AvgWriteLatency,0)), (3, ISNULL(@PageLifeExpectancy,0)), 
(4, ISNULL(@BufferCacheHitRatio,0)), (5, ISNULL(@CpuUtilizacao,0)), (6, ISNULL(@SignalWaitsPercent,0)), 
(7, ISNULL(@UserConnections,0)), (8, ISNULL(@MemoryGrants,0)), (9, ISNULL(@Deadlocks,0)),
(10, ISNULL(@TempdbUsedPercent,0)), (11, ISNULL(@TempdbPagelatch,0)),
(12, ISNULL(@CostThreshold,0)), (13, ISNULL(@MaxIdentityPercent,0)), (14, ISNULL(@StaleStatsCount,0)),
(15, ISNULL(@MaxVLFCount,0)), (16, ISNULL(@AdHocPercent,0));

UPDATE v SET v.Pontos = 
    CASE 
        WHEN b.ID IN (1,2) THEN CASE WHEN v.ValorAtual <= 5 THEN 100 WHEN v.ValorAtual <= 15 THEN 50 ELSE 0 END
        WHEN b.ID = 3 THEN CASE WHEN v.ValorAtual >= 1000 THEN 100 WHEN v.ValorAtual >= 300 THEN 50 ELSE 0 END
        WHEN b.ID = 4 THEN CASE WHEN v.ValorAtual >= 99 THEN 100 WHEN v.ValorAtual >= 95 THEN 50 ELSE 0 END
        WHEN b.ID = 5 THEN CASE WHEN v.ValorAtual <= 50 THEN 100 WHEN v.ValorAtual <= 80 THEN 50 ELSE 0 END
        WHEN b.ID = 6 THEN CASE WHEN v.ValorAtual <= 10 THEN 100 WHEN v.ValorAtual <= 25 THEN 50 ELSE 0 END
        WHEN b.ID = 8 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 5 THEN 50 ELSE 0 END
        WHEN b.ID = 9 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 2 THEN 50 ELSE 0 END
        WHEN b.ID = 10 THEN CASE WHEN v.ValorAtual <= 70 THEN 100 WHEN v.ValorAtual <= 90 THEN 50 ELSE 0 END
        WHEN b.ID = 11 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 5 THEN 50 ELSE 0 END
        WHEN b.ID = 12 THEN CASE WHEN v.ValorAtual >= 50 THEN 100 WHEN v.ValorAtual >= 6 THEN 50 ELSE 0 END
        WHEN b.ID = 13 THEN CASE WHEN v.ValorAtual <= 50 THEN 100 WHEN v.ValorAtual <= 80 THEN 50 ELSE 0 END
        WHEN b.ID = 14 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 10 THEN 50 ELSE 0 END
        WHEN b.ID = 15 THEN CASE WHEN v.ValorAtual <= 100 THEN 100 WHEN v.ValorAtual <= 1000 THEN 50 ELSE 0 END
        WHEN b.ID = 16 THEN CASE WHEN v.ValorAtual <= 10 THEN 100 WHEN v.ValorAtual <= 30 THEN 50 ELSE 0 END
        ELSE 0 
    END
FROM #ValoresAtuais v JOIN #Baselines b ON v.ID = b.ID;

-- =========================================================================
-- 5. RELATÓRIOS FINAIS
-- =========================================================================

SELECT 
    b.Metrica AS [Métrica Monitorada],
    CONCAT(v.ValorAtual, ' ', b.Unidade) AS [Medição Atual],
    CASE 
        WHEN b.Peso = 0 THEN '🔹 Informativo'
        WHEN v.Pontos = 100 THEN '🟢 ÓTIMO'
        WHEN v.Pontos = 50 THEN '🟡 BOM'
        WHEN v.Pontos = 0 THEN '🔴 RUIM'
    END AS [Status], 
    b.Descricao AS [Significado e Impacto],
    b.Peso AS [Peso (Importância)]
FROM #Baselines b JOIN #ValoresAtuais v ON b.ID = v.ID
ORDER BY b.ID;

SELECT 
    CAST(SUM(v.Pontos * b.Peso) / SUM(b.Peso) AS INT) AS [Score Geral], 
    CASE 
        WHEN SUM(v.Pontos * b.Peso) / SUM(b.Peso) >= 85 THEN '🏆 SERVIDOR EXCELENTE! Operando com máxima eficiência e folga.'
        WHEN SUM(v.Pontos * b.Peso) / SUM(b.Peso) >= 60 THEN '⚠️ SERVIDOR SAUDÁVEL. Porém, com alguns alertas que precisam de atenção.'
        ELSE '🚨 ESTADO CRÍTICO! O servidor apresenta distorções sistêmicas severas.'
    END AS [Diagnóstico] 
FROM #Baselines b JOIN #ValoresAtuais v ON b.ID = v.ID
WHERE b.Peso > 0;

-- =========================================================================
-- 6. DETALHAMENTO DE ALERTAS ESPECÍFICOS (ESTATÍSTICAS DESATUALIZADAS)
-- =========================================================================
IF EXISTS (SELECT 1 FROM #StaleStatsDetails)
BEGIN
    SELECT 
        DatabaseName AS [Banco de Dados],
        SchemaName AS [Esquema],
        TableName AS [Tabela],
        StatName AS [Estatística Desatualizada],
        ModCount AS [Qtd de Modificações (Linhas Alteradas)]
    FROM #StaleStatsDetails
    ORDER BY ModCount DESC, DatabaseName, TableName;
END
ELSE
BEGIN
    PRINT '>> Nenhuma estatística desatualizada (acima de 10.000 modificações) foi encontrada nos bancos de usuário.';
END

DROP TABLE #Baselines;
DROP TABLE #ValoresAtuais;
DROP TABLE #StaleStatsDetails;
