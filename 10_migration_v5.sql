--------------------------------------------------------------------------------
-- SCRIPT 10 — MIGRATION V5 (auto-reparation FK, cycles, auto-creation)
--
-- A exécuter dans SYNC_ADMIN, AVANT de recompiler le package (Script 4) et
-- les tests (Script 7). Idempotent : peut être relancé sans dommage.
--
-- Ressources modifiées :
--   1. Table SYNC_RUN_OPTION (v5) : options globales de comportement du run
--      (AUTO_BACKFILL_PARENTS, MAX_FK_RETRY, CYCLE_HANDLING,
--      AUTO_CREATE_MISSING_TABLE), créée si absente puis valeurs par défaut.
--   2. Contrainte CK_SCR_ISSUE_TYPE -> ajout des issue types v5 :
--      PARENT_BACKFILLED, FK_CHILD_RETRIED, FK_CYCLE_HANDLED_BY_DISABLE,
--      TABLE_CREATED_IN_B, PARENT_BACKFILL_FAILED, FK_REPAIR_FAILED.
--
-- Ordre de déploiement recommandé :
--    10_migration_v5.sql  puis  04 (recompile)  puis  07 (harnais)
--
-- NB : l'auto-réparation (backfill / désactivation des FK de cycle /
-- création de table dans B) nécessite les privilèges correspondants sur
-- SCHEMA_B pour le compte exécutant (cf. script de grants SYS associé).
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED;

--------------------------------------------------------------------------------
-- 1. CK_SCR_ISSUE_TYPE : contrainte au périmètre v5
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
        'KEY_NOT_UNIQUE','FK_CYCLE_DEFERRABLE','FK_CYCLE_NOT_DEFERRABLE',
        'FK_PARENT_ENROLLED','FK_PARENT_DISABLED',
        'PARENT_BACKFILLED','FK_CHILD_RETRIED','FK_CYCLE_HANDLED_BY_DISABLE',
        'TABLE_CREATED_IN_B','PARENT_BACKFILL_FAILED','FK_REPAIR_FAILED'
    ));

PROMPT => 1. CK_SCR_ISSUE_TYPE mise a jour (perimetre v5 : auto-reparation FK + cycles + auto-creation).


--------------------------------------------------------------------------------
-- 2. SYNC_RUN_OPTION : table des options globales de run (création + défauts)
--------------------------------------------------------------------------------
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM all_tables
    WHERE owner = USER AND table_name = 'SYNC_RUN_OPTION';

    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE '
            CREATE TABLE SYNC_RUN_OPTION (
                OPTION_NAME     VARCHAR2(64)    NOT NULL,
                OPTION_VALUE    VARCHAR2(256),
                UPDATED_DATE    TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
                UPDATED_BY      VARCHAR2(128)   DEFAULT USER NOT NULL,
                CONSTRAINT PK_SYNC_RUN_OPTION PRIMARY KEY (OPTION_NAME),
                CONSTRAINT CK_SRO_NAME
                    CHECK (OPTION_NAME IN (
                        ''AUTO_BACKFILL_PARENTS'',''MAX_FK_RETRY'',
                        ''CYCLE_HANDLING'',''AUTO_CREATE_MISSING_TABLE''
                    ))
            )';
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_OPTION : table creee.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_OPTION : table deja presente.');
    END IF;
END;
/

-- Valeurs par défaut (idempotent : uniquement les options MANQUANTES sont
-- ajoutées ; un réglage d'exploitation existant n'est jamais écrasé par un
-- re-déploiement — cf. l'intention "sans écraser un réglage existant").
MERGE INTO SYNC_RUN_OPTION t
USING (
    SELECT 'AUTO_BACKFILL_PARENTS'  AS option_name, 'Y'          AS option_value FROM DUAL UNION ALL
    SELECT 'MAX_FK_RETRY'           AS option_name, '3'          AS option_value FROM DUAL UNION ALL
    SELECT 'CYCLE_HANDLING'         AS option_name, 'DISABLE_FK' AS option_value FROM DUAL UNION ALL
    SELECT 'AUTO_CREATE_MISSING_TABLE' AS option_name, 'N'       AS option_value FROM DUAL
) s
ON (t.option_name = s.option_name)
WHEN NOT MATCHED THEN INSERT (option_name, option_value, updated_by)
    VALUES (s.option_name, s.option_value, 'SYNC_ADMIN');

COMMIT;

PROMPT => 2. SYNC_RUN_OPTION provisionnee (defauts v5).

PROMPT => Migration v5 terminee. Recompiler maintenant : 04_sync_package_body.sql
PROMPT => puis lancer : 07_test_harness.sql

--------------------------------------------------------------------------------
-- Fin Script 10
--------------------------------------------------------------------------------