
--1. Descobrir qual Banco de Dados está sofrendo mais
--Desperdício de RAM com queries de uso único.
SELECT 
    ISNULL(DB_NAME(st.dbid), 'Contexto Não Identificado (Ad-hoc)') AS [Banco de Dados],
    COUNT(*) AS [Qtd Planos Inúteis],
    SUM(CAST(cp.size_in_bytes AS BIGINT)) / 1024 / 1024 AS [Espaço Desperdiçado (MB)]
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
WHERE cp.objtype = 'Adhoc' 
  AND cp.usecounts = 1
GROUP BY st.dbid
ORDER BY [Espaço Desperdiçado (MB)] DESC;


--Descobrir o Texto das Queries (As Culpadas)
SELECT TOP 50
    ISNULL(DB_NAME(st.dbid), 'N/A') AS [Banco de Dados],
    cp.size_in_bytes / 1024 AS [Tamanho do Plano (KB)],
    st.text AS [Texto da Query (Monstro)]
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
WHERE cp.objtype = 'Adhoc' 
  AND cp.usecounts = 1
ORDER BY cp.size_in_bytes DESC;


--1. Ativar o "Optimize for Ad Hoc Workloads" (Recomendado e Imediato)
--Esta é uma configuração nativa do SQL Server projetada especificamente para este cenário. Quando ativada, na primeira vez que uma query ad-hoc é executada, o SQL Server armazena apenas um stub (um cabeçalho minúsculo) em vez do plano completo. O plano completo só será instanciado se a query for executada uma segunda vez.
--Isso costuma reduzir drasticamente o tamanho do cache de queries Ad-Hoc instantaneamente sem quebrar nada no sistema.

-- Se necessário
--EXEC sp_configure 'show advanced options', 1;
--RECONFIGURE;
--GO

--EXEC sp_configure 'optimize for ad hoc workloads', 1;
--RECONFIGURE;
--GO