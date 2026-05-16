USE Protheus12; -- Define o banco alvo
GO

SET NOCOUNT ON;

-- 1. Cria uma tabela temporária para armazenar as linhas do script que será gerado
IF OBJECT_ID('tempdb..#ScriptGerado') IS NOT NULL DROP TABLE #ScriptGerado;
CREATE TABLE #ScriptGerado (ID INT IDENTITY(1,1), Comando NVARCHAR(MAX));

-- 2. Cabeçalho do novo script
INSERT INTO #ScriptGerado (Comando) VALUES 
('-- ========================================================================='),
('-- SCRIPT DE MANUTENÇÃO AUTOMÁTICO (GERADO DINAMICAMENTE)'),
('-- Banco de Dados: ' + DB_NAME()),
('-- ========================================================================='),
('USE [' + DB_NAME() + '];'),
('GO'),
('SET NOCOUNT ON;'),
('');

-- =========================================================================
-- 3. GERADOR DE SCRIPT PARA REBUILD DE ÍNDICES FRAGMENTADOS
-- =========================================================================
INSERT INTO #ScriptGerado (Comando) VALUES 
('-- -------------------------------------------------------------------------'),
('-- 1. REBUILD DE ÍNDICES (>30% fragmentação e >1000 páginas)'),
('-- -------------------------------------------------------------------------');

INSERT INTO #ScriptGerado (Comando)
SELECT 
    'PRINT ''[ÍNDICES] Reconstruindo: ' + SCHEMA_NAME(o.schema_id) + '.' + o.name + ' (Índice: ' + i.name + ')'';' + CHAR(13) + CHAR(10) +
    'BEGIN TRY ' + 
    '   ALTER INDEX [' + i.name + '] ON [' + SCHEMA_NAME(o.schema_id) + '].[' + o.name + '] REBUILD; ' + 
    'END TRY ' + 
    'BEGIN CATCH ' + 
    '   PRINT ''Erro ao reconstruir: '' + ERROR_MESSAGE(); ' + 
    'END CATCH;' + CHAR(13) + CHAR(10)
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
JOIN sys.objects o ON ps.object_id = o.object_id
JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE ps.avg_fragmentation_in_percent > 30 
  AND ps.page_count > 1000 
  AND i.index_id > 0;

IF @@ROWCOUNT = 0
BEGIN
    INSERT INTO #ScriptGerado (Comando) VALUES ('-- NENHUM ÍNDICE COM ALTA FRAGMENTAÇÃO ENCONTRADO.');
END

-- =========================================================================
-- 4. GERADOR DE SCRIPT PARA ESTATÍSTICAS DESATUALIZADAS
-- =========================================================================
INSERT INTO #ScriptGerado (Comando) VALUES 
(''),
('-- -------------------------------------------------------------------------'),
('-- 2. UPDATE STATISTICS COM FULLSCAN (>10.000 modificações)'),
('-- -------------------------------------------------------------------------');

INSERT INTO #ScriptGerado (Comando)
SELECT 
    'PRINT ''[ESTATÍSTICAS] Atualizando: ' + SCHEMA_NAME(o.schema_id) + '.' + o.name + ' (Estatística: ' + s.name + ')'';' + CHAR(13) + CHAR(10) +
    'BEGIN TRY ' + 
    '   UPDATE STATISTICS [' + SCHEMA_NAME(o.schema_id) + '].[' + o.name + '] [' + s.name + '] WITH FULLSCAN; ' + 
    'END TRY ' + 
    'BEGIN CATCH ' + 
    '   PRINT ''Erro ao atualizar: '' + ERROR_MESSAGE(); ' + 
    'END CATCH;' + CHAR(13) + CHAR(10)
FROM sys.stats s
JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE sp.modification_counter > 10000
  AND o.is_ms_shipped = 0;

IF @@ROWCOUNT = 0
BEGIN
    INSERT INTO #ScriptGerado (Comando) VALUES ('-- NENHUMA ESTATÍSTICA DESATUALIZADA ENCONTRADA.');
END

INSERT INTO #ScriptGerado (Comando) VALUES 
(''),
('PRINT ''Manutenção concluída com sucesso!'';');

-- =========================================================================
-- 5. EXIBE O SCRIPT FINAL
-- =========================================================================
SELECT Comando AS [-- Copie todo este resultado e cole em uma nova aba de Query --]
FROM #ScriptGerado
ORDER BY ID;

-- 6. Limpeza
DROP TABLE #ScriptGerado;
