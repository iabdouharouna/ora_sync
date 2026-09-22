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
--   3. Contraintes PK_SRO_NAME + CK_SRO_VALUE sur SYNC_RUN_OPTION : le nom ET
--      la VALEUR sont validés en base ("défense en profondeur" — un réglage
--      hors périmètre persisté par une version antérieure du package est
--      réparé de façon idempotente avant l'ajout de CK_SRO_VALUE).
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
    v_cnt  NUMBER;
    v_wide NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM all_constraints
    WHERE owner = USER AND constraint_name = 'CK_SCR_ISSUE_TYPE';

    -- Idempotence renforcée (correctif v5.1) : ne pas drop/recreate une
    -- contrainte déjà au périmètre v5 — aucun gain, et fenêtre inutile où la
    -- table reste sans contrôle d'ISSUE_TYPE entre les deux étapes.
    SELECT COUNT(*) INTO v_wide
    FROM all_constraints
    WHERE owner = USER AND constraint_name = 'CK_SCR_ISSUE_TYPE'
      AND search_condition_vc LIKE '%FK_REPAIR_FAILED%';

    IF v_wide > 0 THEN
        DBMS_OUTPUT.PUT_LINE('CK_SCR_ISSUE_TYPE : deja au perimetre v5, aucune action.');
    ELSE
        IF v_cnt > 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE SYNC_COMPATIBILITY_REPORT DROP CONSTRAINT CK_SCR_ISSUE_TYPE';
            DBMS_OUTPUT.PUT_LINE('CK_SCR_ISSUE_TYPE : ancienne contrainte supprimee.');
        END IF;

        EXECUTE IMMEDIATE 'ALTER TABLE SYNC_COMPATIBILITY_REPORT ADD CONSTRAINT CK_SCR_ISSUE_TYPE CHECK (ISSUE_TYPE IN (
            ''MISSING_IN_A'',''MISSING_IN_B'',''TYPE_MISMATCH'',''LENGTH_MISMATCH'',
            ''NULLABLE_MISMATCH'',''PK_MISSING'',''PK_MISMATCH'',''UNSUPPORTED_TYPE'',
            ''KEY_NOT_UNIQUE'',''FK_CYCLE_DEFERRABLE'',''FK_CYCLE_NOT_DEFERRABLE'',
            ''FK_PARENT_ENROLLED'',''FK_PARENT_DISABLED'',
            ''PARENT_BACKFILLED'',''FK_CHILD_RETRIED'',''FK_CYCLE_HANDLED_BY_DISABLE'',
            ''TABLE_CREATED_IN_B'',''PARENT_BACKFILL_FAILED'',''FK_REPAIR_FAILED''
        ))';
        DBMS_OUTPUT.PUT_LINE('=> 1. CK_SCR_ISSUE_TYPE mise a jour (perimetre v5 : auto-reparation FK + cycles + auto-creation).');
    END IF;
END;
/


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
                    )),
                CONSTRAINT CK_SRO_VALUE
                    CHECK (
                        (OPTION_NAME = ''AUTO_BACKFILL_PARENTS''     AND OPTION_VALUE IN (''Y'',''N'')) OR
                        (OPTION_NAME = ''AUTO_CREATE_MISSING_TABLE'' AND OPTION_VALUE IN (''Y'',''N'')) OR
                        (OPTION_NAME = ''CYCLE_HANDLING''            AND OPTION_VALUE IN (''DISABLE_FK'',''BLOCK'')) OR
                        (OPTION_NAME = ''MAX_FK_RETRY''              AND REGEXP_LIKE(OPTION_VALUE, ''^[1-9][0-9]{0,9}$''))
                    )
            )';
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_OPTION : table creee.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('SYNC_RUN_OPTION : table deja presente.');
    END IF;
END;
/

-- Réparation idempotente : une VALEUR hors périmètre persistée par une
-- version antérieure du package (ex. CYCLE_HANDLING='BIDON') est remise à
-- sa valeur par défaut. Indispensable AVANT l'ajout de CK_SRO_VALUE : une
-- contrainte CHECK ne peut pas être créée si la table contient déjà une
-- valeur qui la violerait.
UPDATE SYNC_RUN_OPTION SET
    option_value = CASE option_name
        WHEN 'AUTO_BACKFILL_PARENTS'     THEN 'Y'
        WHEN 'AUTO_CREATE_MISSING_TABLE' THEN 'N'
        WHEN 'CYCLE_HANDLING'            THEN 'DISABLE_FK'
        WHEN 'MAX_FK_RETRY'              THEN '3'
    END,
    updated_date = SYSTIMESTAMP,
    updated_by   = 'SYNC_ADMIN'
WHERE (option_name = 'AUTO_BACKFILL_PARENTS'     AND option_value NOT IN ('Y', 'N'))
   OR (option_name = 'AUTO_CREATE_MISSING_TABLE' AND option_value NOT IN ('Y', 'N'))
   OR (option_name = 'CYCLE_HANDLING'            AND option_value NOT IN ('DISABLE_FK', 'BLOCK'))
   OR (option_name = 'MAX_FK_RETRY'              AND NOT REGEXP_LIKE(option_value, '^[1-9][0-9]{0,9}$'));

COMMIT;

-- Contrainte CK_SRO_VALUE (défense en profondeur) : validation des VALEURS
-- de SYNC_RUN_OPTION par option, en complément de CK_SRO_NAME sur les NOMS.
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM all_constraints
    WHERE owner = USER AND constraint_name = 'CK_SRO_VALUE';

    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE SYNC_RUN_OPTION ADD CONSTRAINT CK_SRO_VALUE CHECK (
            (OPTION_NAME = ''AUTO_BACKFILL_PARENTS''     AND OPTION_VALUE IN (''Y'',''N'')) OR
            (OPTION_NAME = ''AUTO_CREATE_MISSING_TABLE'' AND OPTION_VALUE IN (''Y'',''N'')) OR
            (OPTION_NAME = ''CYCLE_HANDLING''            AND OPTION_VALUE IN (''DISABLE_FK'',''BLOCK'')) OR
            (OPTION_NAME = ''MAX_FK_RETRY''              AND REGEXP_LIKE(OPTION_VALUE, ''^[1-9][0-9]{0,9}$''))
        )';
        DBMS_OUTPUT.PUT_LINE('CK_SRO_VALUE : contrainte ajoutee (validation des valeurs par option).');
    ELSE
        DBMS_OUTPUT.PUT_LINE('CK_SRO_VALUE : contrainte deja presente.');
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

PROMPT => 2. SYNC_RUN_OPTION provisionnee (defauts v5), valeurs assainies, CK_SRO_VALUE en place.

PROMPT => Migration v5 terminee. Recompiler maintenant : 04_sync_package_body.sql
PROMPT => puis lancer : 07_test_harness.sql

--------------------------------------------------------------------------------
-- Fin Script 10
--------------------------------------------------------------------------------