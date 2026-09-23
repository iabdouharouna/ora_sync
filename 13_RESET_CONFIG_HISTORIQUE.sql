-- \===========================================================================
-- SCRIPT 13 — REMISE À ZÉRO DES TABLES DE CONFIGURATION ET D'HISTORIQUE
-- \===========================================================================
-- Objet      : purger l'intégralité de la CONFIGURATION (SYNC_TABLE_CONFIG,
--              SYNC_COLUMN_CONFIG, SYNC_KEY_CONFIG) et de l'HISTORIQUE
--              (SYNC_RUN_HEADER, SYNC_LOG, SYNC_CONFLICT,
--              SYNC_COMPATIBILITY_REPORT), puis remettre TOUTES les séquences
--              à 1 (prochain RUN_ID = 1).
--
-- CONSERVÉE  : SYNC_RUN_OPTION (options d'exécution v5) — jamais modifiée.
--
-- NOTE GTT   : les tables de travail SYNC_WORK_HASH_A/B et SYNC_WORK_DIFF
--              sont des tables temporaires globales DE SESSION : elles se
--              vident toutes seules, rien à faire ici.
--
-- ⚠ DESTRUCTIF : supprime TOUTES les données de configuration et
--   d'historique. À n'exécuter qu'en fenêtre de maintenance, après avoir
--   vérifié le besoin (l'inventaire « AVANT » est imprimé avant la purge).
--
-- Lancement  :
--     python setup_project.py sql 13_RESET_CONFIG_HISTORIQUE.sql
--     (ou SQL*Plus :    SET SERVEROUTPUT ON ;
--                       @13_RESET_CONFIG_HISTORIQUE.sql)
-- ===========================================================================
SET SERVEROUTPUT ON

PROMPT
PROMPT *****************************************************************
PROMPT * SCRIPT 13 - REMISE A ZERO (config + historique + sequences)   *
PROMPT * DESTRUCTIF : a executer uniquement en fenetre de maintenance  *
PROMPT * SYNC_RUN_OPTION est CONSERVEE (jamais modifiee)               *
PROMPT *****************************************************************
PROMPT

-- ============================================================================
-- ÉTAPE 1 — Inventaire AVANT (état à purger ; SYNC_RUN_OPTION en repère)
-- ============================================================================
SELECT 'SYNC_TABLE_CONFIG'           AS OBJET, COUNT(*) AS NB FROM SYNC_TABLE_CONFIG
UNION ALL SELECT 'SYNC_COLUMN_CONFIG', COUNT(*) FROM SYNC_COLUMN_CONFIG
UNION ALL SELECT 'SYNC_KEY_CONFIG',     COUNT(*) FROM SYNC_KEY_CONFIG
UNION ALL SELECT 'SYNC_RUN_HEADER',     COUNT(*) FROM SYNC_RUN_HEADER
UNION ALL SELECT 'SYNC_LOG',            COUNT(*) FROM SYNC_LOG
UNION ALL SELECT 'SYNC_CONFLICT',       COUNT(*) FROM SYNC_CONFLICT
UNION ALL SELECT 'SYNC_COMPATIBILITY_REPORT', COUNT(*) FROM SYNC_COMPATIBILITY_REPORT
UNION ALL SELECT 'SYNC_RUN_OPTION (CONSERVEE)', COUNT(*) FROM SYNC_RUN_OPTION;

-- ============================================================================
-- ÉTAPE 2 — Purge (ordre FK : enfants avant parents)
-- ============================================================================
-- 2.1 Historique : les tables de détail référencent SYNC_RUN_HEADER (RUN_ID).
DELETE FROM SYNC_LOG;
DELETE FROM SYNC_CONFLICT;
DELETE FROM SYNC_COMPATIBILITY_REPORT;
DELETE FROM SYNC_RUN_HEADER;

-- 2.2 Configuration : SYNC_COLUMN_CONFIG / SYNC_KEY_CONFIG référencent
--     SYNC_TABLE_CONFIG (TABLE_NAME).
DELETE FROM SYNC_COLUMN_CONFIG;
DELETE FROM SYNC_KEY_CONFIG;
DELETE FROM SYNC_TABLE_CONFIG;

-- 2.3 Validation définitive de la purge.
--     NB : les ALTER SEQUENCE de l'étape 3 étant du DDL (commit implicite),
--     le COMMIT ci-dessous verrouille la cohérence purge / point de reprise.
COMMIT;
PROMPT Purge effectuee et COMMIT. SYNC_RUN_OPTION non touchee.

-- ============================================================================
-- ÉTAPE 3 — Remise des séquences à 1 (prochain RUN_ID / LOG_ID / ... = 1)
-- ============================================================================
-- Association séquence -> table :
--   SYNC_RUN_ID_SEQ          -> SYNC_RUN_HEADER.RUN_ID
--   SYNC_LOG_ID_SEQ          -> SYNC_LOG.LOG_ID
--   SYNC_CONFLICT_ID_SEQ     -> SYNC_CONFLICT.CONFLICT_ID
--   SYNC_COMPAT_REPORT_ID_SEQ-> SYNC_COMPATIBILITY_REPORT.REPORT_ID
--   SYNC_COMPAT_CHECK_ID_SEQ -> SYNC_COMPATIBILITY_REPORT.CHECK_ID
DECLARE
    v_n NUMBER;
    v_seq VARCHAR2(128);
BEGIN
    FOR r IN (SELECT 'SYNC_RUN_ID_SEQ'           AS seq_name FROM DUAL
              UNION ALL SELECT 'SYNC_LOG_ID_SEQ' FROM DUAL
              UNION ALL SELECT 'SYNC_CONFLICT_ID_SEQ' FROM DUAL
              UNION ALL SELECT 'SYNC_COMPAT_REPORT_ID_SEQ'  FROM DUAL
              UNION ALL SELECT 'SYNC_COMPAT_CHECK_ID_SEQ'   FROM DUAL) LOOP
        v_seq := r.seq_name;
        SELECT COUNT(*) INTO v_n
          FROM user_sequences
         WHERE sequence_name = v_seq;

        IF v_n = 1 THEN
            EXECUTE IMMEDIATE 'ALTER SEQUENCE "' || v_seq || '" RESTART START WITH 1';
            DBMS_OUTPUT.PUT_LINE('sequence ' || v_seq || ' remise a 1');
        ELSE
            DBMS_OUTPUT.PUT_LINE('sequence ' || v_seq || ' ABSENTE - ignoree');
        END IF;
    END LOOP;
    COMMIT;
END;
/

-- ============================================================================
-- ÉTAPE 4 — Bilan APRÈS (tout doit être à 0 ; séquences à 1 ; options intactes)
-- ============================================================================
SELECT 'SYNC_TABLE_CONFIG'           AS OBJET, COUNT(*) AS NB FROM SYNC_TABLE_CONFIG
UNION ALL SELECT 'SYNC_COLUMN_CONFIG', COUNT(*) FROM SYNC_COLUMN_CONFIG
UNION ALL SELECT 'SYNC_KEY_CONFIG',     COUNT(*) FROM SYNC_KEY_CONFIG
UNION ALL SELECT 'SYNC_RUN_HEADER',     COUNT(*) FROM SYNC_RUN_HEADER
UNION ALL SELECT 'SYNC_LOG',            COUNT(*) FROM SYNC_LOG
UNION ALL SELECT 'SYNC_CONFLICT',       COUNT(*) FROM SYNC_CONFLICT
UNION ALL SELECT 'SYNC_COMPATIBILITY_REPORT', COUNT(*) FROM SYNC_COMPATIBILITY_REPORT
UNION ALL SELECT 'SYNC_RUN_OPTION (CONSERVEE)', COUNT(*) FROM SYNC_RUN_OPTION;

SELECT sequence_name, last_number
  FROM user_sequences
 WHERE sequence_name LIKE 'SYNC\_%' ESCAPE '\'
 ORDER BY 1;

PROMPT
PROMPT Remise a zero terminee. Prochain run : RUN_ID = 1.
PROMPT Rappel : SYNC_RUN_OPTION conservee telle quelle.
PROMPT