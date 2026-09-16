--------------------------------------------------------------------------------
-- SCRIPT 8 — MIGRATION V2 (pour installations issues des Scripts 1 à 6 déjà
--              déployées, ex. SYNC_ADMIN@freepdb1)
--
-- A exécuter dans SYNC_ADMIN, AVANT de recompiler le package (Script 4) et
-- les tests (Scripts 6/7). Idempotent : peut être relancé sans dommage.
--
-- Ressources modifiées :
--   1. Contrainte CK_SCR_ISSUE_TYPE  -> ajout de FK_CYCLE_DEFERRABLE et
--                                       FK_CYCLE_NOT_DEFERRABLE
--      (indispensable : le body v1 écrivait déjà 'FK_CYCLE_NOT_DEFERRABLE'
--       alors que la contrainte installée ne l'acceptait pas -> ORA-02290).
--   2. SYNC_CONFLICT.PK_HASH_KEY      -> VARCHAR2(64)  (clé désormais hashée)
--      ATTENTION : les enregistrements historiques créés par la v1 portent
--      l'ANCIENNE représentation (concaténation brute, potentiellement > 64).
--      Le MODIFY échoue (ORA-01441) si de tels enregistrements existent.
--      Deux options documentées ci-dessous : conserver l'historique en
--      archivant (RECOMMANDE) ou tronquer (mode "repartir propre").
--   3. Tables de travail (GTT SYNC_WORK_HASH_A/B, SYNC_WORK_DIFF) -> recréées
--      avec PK_HASH_KEY VARCHAR2(64). Aucune donnée persistante (segment
--      privé temporaire), la recréation est sans risque.
--   4. (v3 — idempotent) SYNC_TABLE_CONFIG.SYNC_MODE + contrainte,
--      SYNC_LOG.SYNC_MODE, et RUN_TYPE de SYNC_RUN_HEADER élargi à
--      'SYNC_TABLES' (nouvelle procédure SYNC_TABLES).
--
-- Ordre de déploiement recommandé :
--    08_migration_v2.sql  puis  04 (recompile)  puis  07 (harnais)
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED;

--------------------------------------------------------------------------------
-- 1. CK_SCR_ISSUE_TYPE : contrainte au périmètre v2
--------------------------------------------------------------------------------
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM all_constraints
    WHERE owner = USER AND constraint_name = 'CK_SCR_ISSUE_TYPE';

    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE SYNC_COMPATIBILITY_REPORT DROP CONSTRAINT CK_SCR_ISSUE_TYPE';
        DBMS_OUTPUT.PUT_LINE('CK_SCR_ISSUE_TYPE : ancienne contrainte supprimee.');
    END IF;
END;
/

ALTER TABLE SYNC_COMPATIBILITY_REPORT
    ADD CONSTRAINT CK_SCR_ISSUE_TYPE CHECK (ISSUE_TYPE IN (
        'MISSING_IN_A','MISSING_IN_B','TYPE_MISMATCH','LENGTH_MISMATCH',
        'NULLABLE_MISMATCH','PK_MISSING','PK_MISMATCH','UNSUPPORTED_TYPE',
        'KEY_NOT_UNIQUE','FK_CYCLE_DEFERRABLE','FK_CYCLE_NOT_DEFERRABLE'
    ));

PROMPT => 1. CK_SCR_ISSUE_TYPE mise a jour (perimetre v2).


--------------------------------------------------------------------------------
-- 2. SYNC_CONFLICT.PK_HASH_KEY -> VARCHAR2(64)
--------------------------------------------------------------------------------
DECLARE
    v_len NUMBER;
    v_cnt NUMBER;
    v_sml NUMBER;
BEGIN
    SELECT data_length INTO v_len
    FROM all_tab_columns
    WHERE owner = USER AND table_name = 'SYNC_CONFLICT' AND column_name = 'PK_HASH_KEY';

    IF v_len = 64 THEN
        DBMS_OUTPUT.PUT_LINE('SYNC_CONFLICT.PK_HASH_KEY : deja a 64, aucune action.');
    ELSE
        SELECT COUNT(*), MAX(LENGTH(pk_hash_key)) INTO v_cnt, v_sml FROM SYNC_CONFLICT;

        IF v_cnt = 0 OR v_sml <= 64 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE SYNC_CONFLICT MODIFY (PK_HASH_KEY VARCHAR2(64))';
            DBMS_OUTPUT.PUT_LINE('SYNC_CONFLICT.PK_HASH_KEY : reduit a VARCHAR2(64).');
        ELSE
            DBMS_OUTPUT.PUT_LINE('SYNC_CONFLICT.PK_HASH_KEY : ' || v_cnt || ' lignes historiques, cles jusqu''a '
                || v_sml || ' caracteres.');
            DBMS_OUTPUT.PUT_LINE('  -> MODIFY impossible sans perte (format v1 deprecie).');
            DBMS_OUTPUT.PUT_LINE('  Option A (RECOMMANDEE) - conserver l''historique : ');
            DBMS_OUTPUT.PUT_LINE('      CREATE TABLE SYNC_CONFLICT_V1 AS SELECT * FROM SYNC_CONFLICT;');
            DBMS_OUTPUT.PUT_LINE('      TRUNCATE TABLE SYNC_CONFLICT;');
            DBMS_OUTPUT.PUT_LINE('      puis relancer ce script.');
            DBMS_OUTPUT.PUT_LINE('  Option B (repartir propre, sans historique) : ');
            DBMS_OUTPUT.PUT_LINE('      TRUNCATE TABLE SYNC_CONFLICT;   puis relancer ce script.');
            RAISE_APPLICATION_ERROR(-20001, 'Migration SYNC_CONFLICT.PK_HASH_KEY bloque : tronquer/archiver d''abord.');
        END IF;
    END IF;
END;
/


--------------------------------------------------------------------------------
-- 3. Recréation des tables de travail avec PK_HASH_KEY VARCHAR2(64)
--------------------------------------------------------------------------------
DROP TABLE SYNC_WORK_HASH_A;
DROP TABLE SYNC_WORK_HASH_B;
DROP TABLE SYNC_WORK_DIFF;

CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_HASH_A (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,
    ROW_HASH        VARCHAR2(64)    NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWHA_LOOKUP ON SYNC_WORK_HASH_A (RUN_ID, TABLE_NAME, PK_HASH_KEY);

CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_HASH_B (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,
    ROW_HASH        VARCHAR2(64)    NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWHB_LOOKUP ON SYNC_WORK_HASH_B (RUN_ID, TABLE_NAME, PK_HASH_KEY);

CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_DIFF (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,
    DIFF_TYPE       VARCHAR2(20)    NOT NULL,
    DIRECTION       VARCHAR2(10)
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWD_LOOKUP ON SYNC_WORK_DIFF (RUN_ID, TABLE_NAME, DIFF_TYPE);

PROMPT => 3. Tables de travail recreees (PK_HASH_KEY VARCHAR2(64)).


--------------------------------------------------------------------------------
-- 4. (v3) SYNC_TABLE_CONFIG.SYNC_MODE, SYNC_LOG.SYNC_MODE, SYNC_RUN_HEADER.
--    RUN_TYPE elargi a 'SYNC_TABLES' — idempotent.
--------------------------------------------------------------------------------

-- 4.1 SYNC_TABLE_CONFIG.SYNC_MODE
DECLARE
    v_nb NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_nb
    FROM all_tab_columns
    WHERE owner = USER AND table_name = 'SYNC_TABLE_CONFIG' AND column_name = 'SYNC_MODE';

    IF v_nb = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE SYNC_TABLE_CONFIG ADD (SYNC_MODE VARCHAR2(20) DEFAULT ''INSERT_UPDATE'' NOT NULL)';
        DBMS_OUTPUT.PUT_LINE('SYNC_TABLE_CONFIG.SYNC_MODE : colonne ajoutee (defaut INSERT_UPDATE).');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_TABLE_CONFIG.SYNC_MODE : deja presente, aucune action.');
    END IF;

    SELECT COUNT(*) INTO v_nb
    FROM all_constraints
    WHERE owner = USER AND constraint_name = 'CK_STC_SYNC_MODE';

    IF v_nb = 0 THEN
        EXECUTE IMMEDIATE ('ALTER TABLE SYNC_TABLE_CONFIG ADD CONSTRAINT CK_STC_SYNC_MODE ' ||
                           'CHECK (SYNC_MODE IN (''INSERT'',''UPDATE'',''INSERT_UPDATE''))');
        DBMS_OUTPUT.PUT_LINE('SYNC_TABLE_CONFIG : CK_STC_SYNC_MODE ajoutee.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_TABLE_CONFIG : CK_STC_SYNC_MODE deja presente.');
    END IF;
END;
/

-- 4.2 SYNC_LOG.SYNC_MODE (traçabilité du mode effectif par table)
DECLARE
    v_nb NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_nb
    FROM all_tab_columns
    WHERE owner = USER AND table_name = 'SYNC_LOG' AND column_name = 'SYNC_MODE';

    IF v_nb = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE SYNC_LOG ADD (SYNC_MODE VARCHAR2(20))';
        DBMS_OUTPUT.PUT_LINE('SYNC_LOG.SYNC_MODE : colonne ajoutee.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_LOG.SYNC_MODE : deja presente, aucune action.');
    END IF;
END;
/

-- 4.3 CK_SRH_RUN_TYPE ellargi a 'SYNC_TABLES'
DECLARE
    v_nb NUMBER;
    v_ok NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_ok
    FROM all_cons_columns cc
    JOIN all_constraints c ON c.constraint_name = cc.constraint_name AND c.owner = cc.owner
    WHERE c.owner = USER AND c.constraint_name = 'CK_SRH_RUN_TYPE'
      AND cc.column_name = 'RUN_TYPE'
      AND cc.position = 1
      AND c.search_condition_vc LIKE '%SYNC_TABLES%';

    IF v_ok = 0 THEN
        SELECT COUNT(*) INTO v_nb
        FROM all_constraints
        WHERE owner = USER AND constraint_name = 'CK_SRH_RUN_TYPE';

        IF v_nb > 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE SYNC_RUN_HEADER DROP CONSTRAINT CK_SRH_RUN_TYPE';
        END IF;

        EXECUTE IMMEDIATE ('ALTER TABLE SYNC_RUN_HEADER ADD CONSTRAINT CK_SRH_RUN_TYPE ' ||
                           'CHECK (RUN_TYPE IN (''SYNC_ALL'',''SYNC_TABLE'',''SYNC_TABLES''))');
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_HEADER : CK_SRH_RUN_TYPE elargie a SYNC_TABLES.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_HEADER : CK_SRH_RUN_TYPE deja au perimetre SYNC_TABLES.');
    END IF;
END;
/

PROMPT => 4. Evolutions v3 appliquees (SYNC_MODE + RUN_TYPE).

PROMPT => Migration v2/v3 terminee. Recompiler maintenant : 04_sync_package_body.sql
PROMPT => puis lancer : 07_test_harness.sql

--------------------------------------------------------------------------------
-- Fin Script 8
--------------------------------------------------------------------------------