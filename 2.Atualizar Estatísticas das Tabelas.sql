USE Protheus12; -- Define o banco de dados correto conforme o relatório
GO

SET NOCOUNT ON;

-- 1. Cria uma tabela temporária para armazenar as tabelas únicas que precisam de atualização
CREATE TABLE #TabelasDesatualizadas (NomeTabela VARCHAR(255));

-- 2. Insere a lista de tabelas extraídas e consolidadas do seu log
INSERT INTO #TabelasDesatualizadas (NomeTabela)
VALUES
('TOP_PARAM'), ('GXL010'), ('SG1010'), ('SD4010_TTAT_LOG'), ('SD3010'),
('SB2010'), ('XTU'), ('FCITEMPFAB'), ('SBZ010'), ('TPH_UPD'), ('SB9010'),
('CV3010'), ('SPC010'), ('MP_CUSTOM_METRICS_EXP'), ('CTK010'), ('SZ2010'),
('CQ3010'), ('T8R010'), ('integracao_erp_exon'), ('SYS_APP_PARAM'), ('SH6010'),
('SG2010'), ('CQ2010'), ('CQ1010'), ('SC6010'), ('ZA2010'), ('SX6010'),
('Z01010'), ('SD2010'), ('CTC010'), ('TOTVS_ADTDET'), ('SCK010'), ('SMO010'),
('SP8010'), ('SXH'), ('SCHDTSK'), ('CT2010'), ('CQ9010'), ('CQ0010'),
('RFE010'), ('CONDORNFSEADCON'), ('CD2010'), ('SRZ010'), ('V3N010'),
('CSB010'), ('SC2010'), ('SA8010'), ('SC9010'), ('integracao_webhook'),
('SRP010'), ('SFT010'), ('QLI010'), ('ZEO010'), ('SE1010'), ('SRC010'),
('ZEQ010'), ('SA1010'), ('CONDOREVENTOS'), ('F2D010'), ('CJ3010'),
('SC0010'), ('SGJ010'), ('ZET010'), ('CONDORLOGBLQ'), ('SD1010'),
('SC5010'), ('CONDORNFSECPROT'), ('SE2010'), ('SH3010'), ('CQ8010'),
('GW8010'), ('CONDORCBSIBS'), ('TOTVS_AUDIT'), ('FJV010'), ('SC7010'),
('XXE010'), ('Z7G010'), ('SPG010'), ('SX3X3101_TTAT_LOG'), ('SD4010'),
('RU1010'), ('CONDORXMLITENS'), ('ZEP010'), ('SN4010'), ('FWI010'),
('SPH010'), ('MARCHETTI_PK'), ('Z7B010'), ('GWM010'), ('RFH010'),
('CB8010'), ('AIF010'), ('SR4010'), ('RFG010'), ('SE5010'), ('ACY010'),
('C9M010'), ('CV8010'), ('MPMENU_I18N'), ('FW_TECHFINCTR'), ('FK7010'),
('CONDORCTECOMP'), ('T2I010'), ('RGB010'), ('CTF010'), ('T_SPARK_SD3_01'),
('CONDORCTEVPREST'), ('SRD010'), ('SE3010'), ('RU3010'), ('SX1010'),
('SF2010'), ('CU0010'), ('SCJ010'), ('SEA010'), ('SF1010'), ('FKA010'),
('CONDORXML'), ('SE8010'), ('MPUPDLOG'), ('CDG010'), ('C35010'),
('D3X010'), ('FK5010'), ('SYS_USR_ACCESS'), ('FKF010'), ('SF3010'),
('QDG010'), ('CV8010'), ('SCY010'), ('TQC010'), ('AO4010'), ('SA7010'),
('C2F010'), ('RGK010'), ('RH3010'), ('DBM010'), ('WF3010'), ('FI1010'),
('V8V010'), ('C30010'), ('CB7010'), ('T8G010'), ('V2Q010'), ('T2P010'),
('V2R010'), ('T2M010'), ('V2P010'), ('SB1010'), ('CL9010'), ('SCR010'),
('CKY010'), ('T2Q010'), ('V5J010'), ('SB6010'), ('GXG010'), ('T2O010'),
('SYS_RULES_TRANSACT'), ('XAM010'), ('CTS010'), ('GXH010'), ('FN7010'),
('CVA010'), ('V61010'), ('C8Z010'), ('GWH010'), ('QL5010'), ('V7U010'),
('GWG010'), ('GUN010'), ('RHR010'), ('F3K010'), ('C91010'), ('ZEG010'),
('QD0010'), ('T8E010'), ('SPF010'), ('TAFST2'), ('TAFXERP'), ('TOP_FIELD');

-- 3. Variáveis para o Cursor
DECLARE @TableName VARCHAR(255);
DECLARE @SQL NVARCHAR(MAX);

-- 4. Criação do Cursor para percorrer a lista de tabelas e executar o Update
DECLARE cur_Stats CURSOR FOR
SELECT DISTINCT NomeTabela FROM #TabelasDesatualizadas;

OPEN cur_Stats;
FETCH NEXT FROM cur_Stats INTO @TableName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Exibe no console a tabela atual (útil para acompanhar o progresso)
    PRINT 'Atualizando estatísticas da tabela: dbo.' + @TableName;

    -- Monta a query dinâmica. O WITH FULLSCAN lê toda a tabela para máxima precisão.
    -- O schema 'dbo' é fixado conforme o seu relatório.
    SET @SQL = 'UPDATE STATISTICS dbo.[' + @TableName + '] WITH FULLSCAN;';

    -- Executa o comando
    BEGIN TRY
        EXEC sp_executesql @SQL;
    END TRY
    BEGIN CATCH
        PRINT 'Erro ao atualizar a tabela: ' + @TableName + ' - ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM cur_Stats INTO @TableName;
END

CLOSE cur_Stats;
DEALLOCATE cur_Stats;

-- 5. Limpeza
DROP TABLE #TabelasDesatualizadas;
PRINT 'Atualização de estatísticas concluída.';
GO
