SET NOCOUNT ON;

-- =========================================================================
-- 1. LIMPEZA DE TABELAS TEMPORÁRIAS
-- =========================================================================
IF OBJECT_ID('tempdb..#Baselines') IS NOT NULL DROP TABLE #Baselines;
IF OBJECT_ID('tempdb..#ValoresAtuais') IS NOT NULL DROP TABLE #ValoresAtuais;
IF OBJECT_ID('tempdb..#StaleStatsDetails') IS NOT NULL DROP TABLE #StaleStatsDetails;
IF OBJECT_ID('tempdb..#IO_Snap1') IS NOT NULL DROP TABLE #IO_Snap1;
IF OBJECT_ID('tempdb..#IO_Snap2') IS NOT NULL DROP TABLE #IO_Snap2;
IF OBJECT_ID('tempdb..#IdentityRisk') IS NOT NULL DROP TABLE #IdentityRisk;

-- =========================================================================
-- 2. TABELA BASE (MÉTRICAS, CENÁRIOS E PESOS)
-- =========================================================================
CREATE TABLE #Baselines (
    ID INT, Metrica VARCHAR(100), Unidade VARCHAR(25),
    Cenario_Ruim VARCHAR(50), Cenario_Bom VARCHAR(50), Cenario_Otimo VARCHAR(50), Peso INT,
    Descricao VARCHAR(800)
);

INSERT INTO #Baselines VALUES
(1, 'Latência Disco Acumulada (Leitura)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 1, 'Média histórica desde o último restart. Ruim: Histórico de I/O lento. Ótimo: I/O historicamente rápido.'),
(2, 'Latência Disco Acumulada (Escrita)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 1, 'Média histórica desde o último restart. Ruim: Histórico de gravação lenta. Ótimo: Gravações historicamente rápidas.'),
(3, 'Latência Disco Tempo Real (Leitura)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 4, 'Desempenho exato do I/O de leitura nos últimos 5 segundos. Ruim: Gargalo de I/O ocorrendo AGORA.'),
(4, 'Latência Disco Tempo Real (Escrita)', 'ms', '> 15 ms', '5 a 15 ms', '< 5 ms', 4, 'Desempenho exato do I/O de escrita nos últimos 5 segundos. Ruim: Gargalo de gravação ocorrendo AGORA.'),
(5, 'Page Life Expectancy (PLE - NUMA)', 'segundos', '< 300 seg', '300 a 1000 seg', '> 1000 seg', 4, 'Menor tempo de retenção de página entre os nós NUMA. Ruim: Pressão de memória isolada ou global.'),
(6, 'Buffer Cache Hit Ratio', '%', '< 95%', '95% a 98%', '> 99%', 1, '% de dados lidos da RAM em vez do disco. Ruim: Disco sendo muito exigido.'),
(7, 'Uso de CPU (Instantâneo)', '%', '> 80%', '50% a 80%', '< 50%', 3, 'Consumo atual do processador.'),
(8, 'Signal Waits % (Fila CPU)', '%', '> 25%', '10% a 25%', '< 10%', 2, 'Tempo na fila da CPU. Ruim: CPU insuficiente para a demanda.'),
(9, 'User Connections (Total)', 'Conexões', 'N/A', 'N/A', 'N/A', 0, 'Total de conexões ativas.'),
(10, 'Memory Grants Pending', 'Processos', '> 5', '1 a 5', '0', 4, 'Processos aguardando RAM livre para executar.'),
(11, 'Deadlocks/sec', 'Ocorrências/s', '> 2', '1 a 2', '0', 3, 'Processos que se bloqueiam mutuamente.'),
(12, 'TempDB: Espaço Ocupado', '%', '> 90%', '70% a 90%', '< 70%', 3, '% de uso do TempDB. Ruim: Risco de paralisação.'),
(13, 'TempDB: Fila (PAGELATCH)', 'Processos', '> 5', '1 a 5', '0', 3, 'Concorrência interna de arquivos do TempDB.'),
(14, 'Cost Threshold for Parallelism', 'Valor', '<= 5', '6 a 49', '>= 50', 3, 'Custo para paralelizar uma query.'),
(15, 'Identity Columns (Risco Global)', 'Uso Máx %', '> 80%', '50% a 80%', '< 50%', 5, 'Risco de colunas ID chegarem ao limite numérico em QUALQUER banco de usuário.'),
(16, 'Estatísticas Desatualizadas', 'Tabelas', '> 10', '1 a 10', '0', 4, 'Qtd de tabelas com estatísticas defasadas (> 10k mod).'),
(17, 'Virtual Log Files (VLFs)', 'Qtd Máx/DB', '> 1000', '100 a 1000', '< 100', 3, 'Fragmentação máxima do arquivo de LOG encontrada.'),
(18, 'Plan Cache Bloat (Ad-Hoc)', '% RAM Cache', '> 30%', '10% a 30%', '< 10%', 3, 'Desperdício de RAM com queries de uso único.');

-- =========================================================================
-- 3. CAPTURA DOS VALORES EM TEMPO REAL
-- =========================================================================
CREATE TABLE #ValoresAtuais (ID INT, ValorAtual NUMERIC(10,2), Pontos INT DEFAULT 0);
CREATE TABLE #StaleStatsDetails (DatabaseName NVARCHAR(128), SchemaName NVARCHAR(128), TableName NVARCHAR(128), StatName NVARCHAR(128), ModCount BIGINT);
CREATE TABLE #IdentityRisk (DatabaseName NVARCHAR(128), TableName NVARCHAR(128), ColumnName NVARCHAR(128), DataType NVARCHAR(128), MaxPercent NUMERIC(10,2));

DECLARE @AvgReadLatency_Acumulado NUMERIC(10,2), @AvgWriteLatency_Acumulado NUMERIC(10,2);
DECLARE @AvgReadLatency_RT NUMERIC(10,2) = 0, @AvgWriteLatency_RT NUMERIC(10,2) = 0;
DECLARE @PageLifeExpectancy BIGINT, @BufferCacheHitRatio NUMERIC(10,2), @CpuUtilizacao NUMERIC(10,2), @SignalWaitsPercent NUMERIC(10,2);
DECLARE @UserConnections INT, @MemoryGrants INT, @Deadlocks INT, @TempdbTotalMB NUMERIC(10,2), @TempdbFreeMB NUMERIC(10,2), @TempdbUsedPercent NUMERIC(10,2), @TempdbPagelatch INT;
DECLARE @CostThreshold INT, @MaxIdentityPercent NUMERIC(10,2) = 0, @StaleStatsCount INT = 0, @MaxVLFCount INT = 0, @AdHocPercent NUMERIC(10,2) = 0;
DECLARE @SQL NVARCHAR(MAX), @DBName NVARCHAR(128);

-- 3.1 I/O Acumulado
SELECT @AvgReadLatency_Acumulado = AVG(io_stall_read_ms / CASE WHEN num_of_reads = 0 THEN 1 ELSE num_of_reads END), 
       @AvgWriteLatency_Acumulado = AVG(io_stall_write_ms / CASE WHEN num_of_writes = 0 THEN 1 ELSE num_of_writes END) 
FROM sys.dm_io_virtual_file_stats(NULL, NULL);

-- 3.2 I/O Tempo Real (Snapshot duplo)
SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms INTO #IO_Snap1 FROM sys.dm_io_virtual_file_stats(NULL, NULL);
WAITFOR DELAY '00:00:05'; -- Aguarda 5 segundos para medição real
SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms INTO #IO_Snap2 FROM sys.dm_io_virtual_file_stats(NULL, NULL);

SELECT 
    @AvgReadLatency_RT = ISNULL(AVG(CASE WHEN (s2.num_of_reads - s1.num_of_reads) = 0 THEN 0 ELSE CAST((s2.io_stall_read_ms - s1.io_stall_read_ms) AS NUMERIC(10,2)) / (s2.num_of_reads - s1.num_of_reads) END), 0),
    @AvgWriteLatency_RT = ISNULL(AVG(CASE WHEN (s2.num_of_writes - s1.num_of_writes) = 0 THEN 0 ELSE CAST((s2.io_stall_write_ms - s1.io_stall_write_ms) AS NUMERIC(10,2)) / (s2.num_of_writes - s1.num_of_writes) END), 0)
FROM #IO_Snap2 s2 JOIN #IO_Snap1 s1 ON s2.database_id = s1.database_id AND s2.file_id = s1.file_id
WHERE (s2.num_of_reads - s1.num_of_reads) > 0 OR (s2.num_of_writes - s1.num_of_writes) > 0;

-- 3.3 CPU, RAM e Travamentos (Corrigido PLE para NUMA nodes)
SELECT @PageLifeExpectancy = ISNULL(MIN(cntr_value), 0) FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Buffer Node%' AND counter_name = 'Page life expectancy';
SELECT @BufferCacheHitRatio = (a.cntr_value * 1.0 / CASE WHEN b.cntr_value = 0 THEN 1 ELSE b.cntr_value END) * 100.0 FROM sys.dm_os_performance_counters a JOIN sys.dm_os_performance_counters b ON a.object_name = b.object_name WHERE a.object_name LIKE '%Buffer Manager%' AND a.counter_name = 'Buffer cache hit ratio' AND b.counter_name = 'Buffer cache hit ratio base';
SELECT TOP 1 @CpuUtilizacao = 100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') FROM (SELECT CAST(record AS XML) AS record, timestamp FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE '%<SystemHealth>%') AS x ORDER BY timestamp DESC;
SELECT @SignalWaitsPercent = (SUM(signal_wait_time_ms) * 100.0 / CASE WHEN SUM(wait_time_ms) = 0 THEN 1 ELSE SUM(wait_time_ms) END) FROM sys.dm_os_wait_stats;
SELECT @UserConnections = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;
SELECT @MemoryGrants = cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Memory Grants Pending';
SELECT @Deadlocks = cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Locks%' AND counter_name = 'Number of Deadlocks/sec' AND instance_name = '_Total';

CREATE TABLE #TempDBSpace (FreePageCount BIGINT); INSERT INTO #TempDBSpace EXEC('USE tempdb; SELECT SUM(unallocated_extent_page_count) FROM sys.dm_db_file_space_usage'); 
SELECT @TempdbFreeMB = FreePageCount * 8.0 / 1024.0 FROM #TempDBSpace; SELECT @TempdbTotalMB = SUM(size) * 8.0 / 1024.0 FROM tempdb.sys.database_files WHERE type = 0; 
SET @TempdbUsedPercent = 100.0 - ((@TempdbFreeMB / CASE WHEN @TempdbTotalMB = 0 THEN 1 ELSE @TempdbTotalMB END) * 100.0); DROP TABLE #TempDBSpace;
SELECT @TempdbPagelatch = COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'PAGELATCH_%' AND resource_description LIKE '2:%';

-- 3.4 Métricas Arquiteturais
SELECT @CostThreshold = CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'cost threshold for parallelism';
SELECT @AdHocPercent = ISNULL((SUM(CASE WHEN objtype = 'Adhoc' AND usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) * 100.0) / NULLIF(SUM(CAST(size_in_bytes AS BIGINT)), 0), 0) FROM sys.dm_exec_cached_plans;

-- VLF (Checagem de versão compatível com sys.dm_db_log_info)
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
BEGIN
    SELECT @MaxVLFCount = ISNULL(MAX(vlf_count), 0)
    FROM (SELECT COUNT(l.database_id) AS vlf_count FROM sys.databases s CROSS APPLY sys.dm_db_log_info(s.database_id) l GROUP BY s.database_id) AS vlf;
END

-- 3.5 Cursor para Bancos de Usuário (Estatísticas e Identity Global)
DECLARE curDB CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';
OPEN curDB; FETCH NEXT FROM curDB INTO @DBName;
WHILE @@FETCH_STATUS = 0 
BEGIN
    -- Estatísticas desatualizadas
    SET @SQL = N'USE [' + @DBName + N'];
    INSERT INTO #StaleStatsDetails (DatabaseName, SchemaName, TableName, StatName, ModCount)
    SELECT ''' + @DBName + N''', OBJECT_SCHEMA_NAME(stat.object_id), OBJECT_NAME(stat.object_id), stat.name, sp.modification_counter
    FROM sys.stats AS stat CROSS APPLY sys.dm_db_stats_properties(stat.object_id, stat.stats_id) AS sp
    WHERE sp.modification_counter > 10000 AND OBJECTPROPERTY(stat.object_id, ''IsMSShipped'') = 0;';
    EXEC sp_executesql @SQL;

    -- Identity Columns Risco Máximo
    SET @SQL = N'USE [' + @DBName + N'];
    INSERT INTO #IdentityRisk (DatabaseName, TableName, ColumnName, DataType, MaxPercent)
    SELECT ''' + @DBName + N''', OBJECT_NAME(ic.object_id), ic.name, t.name,
    CASE 
        WHEN t.name = ''tinyint'' THEN (CAST(last_value AS NUMERIC(38,2)) / 255.0) * 100
        WHEN t.name = ''smallint'' THEN (CAST(last_value AS NUMERIC(38,2)) / 32767.0) * 100
        WHEN t.name = ''int'' THEN (CAST(last_value AS NUMERIC(38,2)) / 2147483647.0) * 100
        WHEN t.name = ''bigint'' THEN (CAST(last_value AS NUMERIC(38,2)) / 9223372036854775807.0) * 100 ELSE 0 END
    FROM sys.identity_columns ic JOIN sys.types t ON ic.system_type_id = t.system_type_id WHERE last_value IS NOT NULL;';
    EXEC sp_executesql @SQL;

    FETCH NEXT FROM curDB INTO @DBName;
END
CLOSE curDB; DEALLOCATE curDB;

SELECT @StaleStatsCount = COUNT(DISTINCT CONCAT(DatabaseName, '.', SchemaName, '.', TableName)) FROM #StaleStatsDetails;
SELECT @MaxIdentityPercent = ISNULL(MAX(MaxPercent), 0) FROM #IdentityRisk;

-- =========================================================================
-- 4. ATRIBUIÇÃO DOS PONTOS
-- =========================================================================
INSERT INTO #ValoresAtuais (ID, ValorAtual) VALUES 
(1, ISNULL(@AvgReadLatency_Acumulado,0)), (2, ISNULL(@AvgWriteLatency_Acumulado,0)), 
(3, ISNULL(@AvgReadLatency_RT,0)), (4, ISNULL(@AvgWriteLatency_RT,0)), 
(5, ISNULL(@PageLifeExpectancy,0)), (6, ISNULL(@BufferCacheHitRatio,0)), 
(7, ISNULL(@CpuUtilizacao,0)), (8, ISNULL(@SignalWaitsPercent,0)), 
(9, ISNULL(@UserConnections,0)), (10, ISNULL(@MemoryGrants,0)), 
(11, ISNULL(@Deadlocks,0)), (12, ISNULL(@TempdbUsedPercent,0)), 
(13, ISNULL(@TempdbPagelatch,0)), (14, ISNULL(@CostThreshold,0)), 
(15, ISNULL(@MaxIdentityPercent,0)), (16, ISNULL(@StaleStatsCount,0)),
(17, ISNULL(@MaxVLFCount,0)), (18, ISNULL(@AdHocPercent,0));

UPDATE v SET v.Pontos = 
    CASE 
        WHEN b.ID IN (1,2,3,4) THEN CASE WHEN v.ValorAtual <= 5 THEN 100 WHEN v.ValorAtual <= 15 THEN 50 ELSE 0 END
        WHEN b.ID = 5 THEN CASE WHEN v.ValorAtual >= 1000 THEN 100 WHEN v.ValorAtual >= 300 THEN 50 ELSE 0 END
        WHEN b.ID = 6 THEN CASE WHEN v.ValorAtual >= 99 THEN 100 WHEN v.ValorAtual >= 95 THEN 50 ELSE 0 END
        WHEN b.ID = 7 THEN CASE WHEN v.ValorAtual <= 50 THEN 100 WHEN v.ValorAtual <= 80 THEN 50 ELSE 0 END
        WHEN b.ID = 8 THEN CASE WHEN v.ValorAtual <= 10 THEN 100 WHEN v.ValorAtual <= 25 THEN 50 ELSE 0 END
        WHEN b.ID = 10 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 5 THEN 50 ELSE 0 END
        WHEN b.ID = 11 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 2 THEN 50 ELSE 0 END
        WHEN b.ID = 12 THEN CASE WHEN v.ValorAtual <= 70 THEN 100 WHEN v.ValorAtual <= 90 THEN 50 ELSE 0 END
        WHEN b.ID = 13 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 5 THEN 50 ELSE 0 END
        WHEN b.ID = 14 THEN CASE WHEN v.ValorAtual >= 50 THEN 100 WHEN v.ValorAtual >= 6 THEN 50 ELSE 0 END
        WHEN b.ID = 15 THEN CASE WHEN v.ValorAtual <= 50 THEN 100 WHEN v.ValorAtual <= 80 THEN 50 ELSE 0 END
        WHEN b.ID = 16 THEN CASE WHEN v.ValorAtual = 0 THEN 100 WHEN v.ValorAtual <= 10 THEN 50 ELSE 0 END
        WHEN b.ID = 17 THEN CASE WHEN v.ValorAtual <= 100 THEN 100 WHEN v.ValorAtual <= 1000 THEN 50 ELSE 0 END
        WHEN b.ID = 18 THEN CASE WHEN v.ValorAtual <= 10 THEN 100 WHEN v.ValorAtual <= 30 THEN 50 ELSE 0 END
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

-- Detalhamento de Identity Crítico (Acima de 80%)
IF EXISTS (SELECT 1 FROM #IdentityRisk WHERE MaxPercent > 80)
BEGIN
    SELECT DatabaseName AS [Banco], TableName AS [Tabela], ColumnName AS [Coluna], DataType AS [Tipo], MaxPercent AS [Uso %]
    FROM #IdentityRisk WHERE MaxPercent > 80 ORDER BY MaxPercent DESC;
END

-- Detalhamento de Estatísticas Desatualizadas
IF EXISTS (SELECT 1 FROM #StaleStatsDetails)
BEGIN
    SELECT DatabaseName AS [Banco de Dados], SchemaName AS [Esquema], TableName AS [Tabela], StatName AS [Estatística Desatualizada], ModCount AS [Qtd de Modificações]
    FROM #StaleStatsDetails ORDER BY ModCount DESC, DatabaseName, TableName;
END

DROP TABLE #Baselines; DROP TABLE #ValoresAtuais; DROP TABLE #StaleStatsDetails;
DROP TABLE #IO_Snap1; DROP TABLE #IO_Snap2; DROP TABLE #IdentityRisk;
