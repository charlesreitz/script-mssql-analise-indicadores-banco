SELECT 
    s.name AS [Schema],
    t.name AS [Tabela],
    i.name AS [Indice],
    i.type_desc AS [Tipo_Indice],
    CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS [Fragmentacao_%],
    ps.page_count AS [Total_Paginas],
    -- Classificação solicitada baseado nas boas práticas de mercado
    CASE 
        WHEN ps.avg_fragmentation_in_percent > 30 THEN 'Ruim'
        WHEN ps.avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN 'Bom'
        ELSE 'Ótimo'
    END AS [Classificacao],
    -- Comando inteligente baseado no estado atual do índice
    CASE 
        WHEN ps.avg_fragmentation_in_percent > 30 
            THEN 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON ' + QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + ' REBUILD WITH (FILLFACTOR = 80);'
        WHEN ps.avg_fragmentation_in_percent BETWEEN 10 AND 30 
            THEN 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON ' + QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + ' REORGANIZE;'
        ELSE '-- Índice Saudável. Nenhuma ação necessária.'
    END AS [Comando_Manutencao]
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ps
INNER JOIN 
    sys.indexes AS i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
INNER JOIN 
    sys.tables AS t ON i.object_id = t.object_id
INNER JOIN 
    sys.schemas AS s ON t.schema_id = s.schema_id
WHERE 
    ps.page_count > 1000             -- Mantém o foco em tabelas relevantes (> ~8MB)
    AND i.index_id > 0               -- Ignora Heaps (tabelas sem índice)
ORDER BY 
    -- 1º Critério: Joga o que está 'Ruim' para o topo, depois 'Bom', depois 'Ótimo'
    CASE 
        WHEN ps.avg_fragmentation_in_percent > 30 THEN 1
        WHEN ps.avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN 2
        ELSE 3
    END ASC,
    -- 2º Critério: Dentro de cada grupo, as tabelas com MAIOR número de páginas vêm primeiro
    ps.page_count DESC;