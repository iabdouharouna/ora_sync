-- ============================================================================
-- SCRIPT 14 — TABLES D'ÉTAT D'ÉCART SCHÉMA (STATS) — livrable v6
-- ============================================================================
-- Objet      : persistance de l'état des écarts de volumétrie entre SCHEMA_A
--              et SCHEMA_B, calculé par PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP sur
--              la base des statistiques Oracle (NUM_ROWS de l'optimiseur).
--
-- Deux tables (en-tête + détail, même patron que SYNC_RUN_HEADER/SYNC_LOG) :
--   * SYNC_STATS_GAP          : un rapport = une ligne (en-tête + totaux) ;
--   * SYNC_STATS_GAP_DETAIL   : UNIQUEMENT les anomalies — aucune ligne pour
--                               une table en écart nul. Contraintes GAP_FLAG :
--                               DIFF / NO_STATS_A / NO_STATS_B / NO_STATS_BOTH
--                               (constantes C_GAP_FLAG_* du package).
--
-- Chaque rapport dispose de ses séquences dédiées (GAP_ID, DETAIL_ID),
-- associées en FK (purge possible du détail sans toucher à l'en-tête... et
-- inversement la purge d'un en-tête entraîne celle de son détail : option
-- "ON DELETE CASCADE" écartée au profit d'une purge explicite en deux temps
-- dans PURGE_HISTORY, cf. Script 4).
--
-- À exécuter dans le schéma technique SYNC_ADMIN, après les Scripts 1 à 2
-- et avant le Script 15 (grants SYS) et la recompilation du package (03/04).
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================================
-- 1) En-tête de rapport
-- ============================================================================
CREATE TABLE SYNC_STATS_GAP (
    GAP_ID            NUMBER          NOT NULL,
    COLLECT_DATE      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    JOB_NAME_A        VARCHAR2(128),             -- job DBMS_SCHEDULER de collecte côté A (ou NULL si collecte externe)
    JOB_NAME_B        VARCHAR2(128),             -- idem côté B
    STATS_DATE_A      TIMESTAMP,                 -- MAX(LAST_ANALYZED) constaté côté A
    STATS_DATE_B      TIMESTAMP,                 -- idem côté B
    TOTAL_TABLES      NUMBER          DEFAULT 0 NOT NULL,        -- tables présentes des DEUX côtés
    TABLES_OK         NUMBER          DEFAULT 0 NOT NULL,        -- écart nul (même NUM_ROWS)
    TABLES_GAP        NUMBER          DEFAULT 0 NOT NULL,        -- écarts DIFF (NUM_ROWS différents)
    TABLES_NO_STATS_A NUMBER          DEFAULT 0 NOT NULL,        -- stats absentes côté A (exclues du calcul)
    TABLES_NO_STATS_B NUMBER          DEFAULT 0 NOT NULL,        -- idem côté B
    EXECUTED_BY       VARCHAR2(128)   DEFAULT USER NOT NULL,
    CONSTRAINT PK_SYNC_STATS_GAP PRIMARY KEY (GAP_ID)
);

COMMENT ON TABLE  SYNC_STATS_GAP IS
    'En-tete de rapport d''ecart de volumetrie A/B (stats Oracle, NUM_ROWS estime)';
COMMENT ON COLUMN SYNC_STATS_GAP.GAP_ID             IS 'Identifiant du rapport (SYNC_STATS_GAP_ID_SEQ)';
COMMENT ON COLUMN SYNC_STATS_GAP.COLLECT_DATE       IS 'Date de creation du rapport';
COMMENT ON COLUMN SYNC_STATS_GAP.JOB_NAME_A         IS 'Job DBMS_SCHEDULER de collecte des stats cote A (NULL = collecte externe)';
COMMENT ON COLUMN SYNC_STATS_GAP.JOB_NAME_B         IS 'Job DBMS_SCHEDULER de collecte des stats cote B (NULL = collecte externe)';
COMMENT ON COLUMN SYNC_STATS_GAP.STATS_DATE_A       IS 'MAX(LAST_ANALYZED) constate cote A a la generation du rapport';
COMMENT ON COLUMN SYNC_STATS_GAP.STATS_DATE_B       IS 'MAX(LAST_ANALYZED) constate cote B a la generation du rapport';
COMMENT ON COLUMN SYNC_STATS_GAP.TOTAL_TABLES       IS 'Tables de base presentes dans les DEUX schemas (perimetre du rapport)';
COMMENT ON COLUMN SYNC_STATS_GAP.TABLES_OK          IS 'Tables en ecart nul (comptes estimes identiques)';
COMMENT ON COLUMN SYNC_STATS_GAP.TABLES_GAP         IS 'Tables en ecart DIFF (comptes estimes differents)';
COMMENT ON COLUMN SYNC_STATS_GAP.TABLES_NO_STATS_A  IS 'Tables sans stats cote A (hors calcul, detail NO_STATS_*)';
COMMENT ON COLUMN SYNC_STATS_GAP.TABLES_NO_STATS_B  IS 'Tables sans stats cote B (hors calcul, detail NO_STATS_*)';
COMMENT ON COLUMN SYNC_STATS_GAP.EXECUTED_BY        IS 'Compte Oracle ayant genere le rapport';

-- ============================================================================
-- 2) Détail des anomalies (aucune ligne pour une table sans écart)
-- ============================================================================
CREATE TABLE SYNC_STATS_GAP_DETAIL (
    DETAIL_ID       NUMBER          NOT NULL,
    GAP_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    NUM_ROWS_A      NUMBER,                     -- NUM_ROWS côté A (NULL = stats absentes)
    NUM_ROWS_B      NUMBER,                     -- idem côté B
    DIFF            NUMBER,                     -- ABS(NUM_ROWS_A - NUM_ROWS_B), NULL si stats absentes
    DIFF_PCT        NUMBER,                     -- DIFF * 100 / GREATEST(NUM_ROWS_A, NUM_ROWS_B), arrondi 2 décimales
    LAST_ANALYZED_A TIMESTAMP,                  -- LAST_ANALYZED du niveau table côté A
    LAST_ANALYZED_B TIMESTAMP,                  -- idem côté B
    GAP_FLAG        VARCHAR2(13)    NOT NULL,   -- DIFF / NO_STATS_A / NO_STATS_B / NO_STATS_BOTH
    CONSTRAINT PK_SYNC_STATS_GAP_DETAIL PRIMARY KEY (DETAIL_ID),
    CONSTRAINT FK_SSGD_GAP FOREIGN KEY (GAP_ID)
        REFERENCES SYNC_STATS_GAP (GAP_ID),
    CONSTRAINT CK_SSGD_FLAG CHECK (GAP_FLAG IN
        ('DIFF', 'NO_STATS_A', 'NO_STATS_B', 'NO_STATS_BOTH'))
);

COMMENT ON TABLE  SYNC_STATS_GAP_DETAIL IS
    'Detail des anomalies d''ecart de volumetrie A/B (DIFF, NO_STATS_*)';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.DETAIL_ID       IS 'Identifiant de ligne (SYNC_STATS_GAP_DETAIL_ID_SEQ)';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.GAP_ID          IS 'Rapport parent (FK SYNC_STATS_GAP.GAP_ID)';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.TABLE_NAME      IS 'Table de base presente des deux cotes';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.NUM_ROWS_A      IS 'NUM_ROWS (estimation optimiseur) cote A, NULL si stats absentes';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.NUM_ROWS_B      IS 'NUM_ROWS (estimation optimiseur) cote B, NULL si stats absentes';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.DIFF            IS 'Ecart absolu de comptes estimes (NULL si stats absentes des deux cotes)';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.DIFF_PCT        IS 'Ecart relatif, base GREATEST(NUM_ROWS_A, NUM_ROWS_B)';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.LAST_ANALYZED_A IS 'Date de collecte des stats (niveau table) cote A';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.LAST_ANALYZED_B IS 'Date de collecte des stats (niveau table) cote B';
COMMENT ON COLUMN SYNC_STATS_GAP_DETAIL.GAP_FLAG        IS 'Nature de l''anomalie (DIFF/NO_STATS_A/NO_STATS_B/NO_STATS_BOTH)';

-- Index d'accès par rapport (le PK couvre DETAIL_ID ; l'accès par GAP_ID est
-- l'accès de travail — rapport, purge — d'où cet index dédié).
CREATE INDEX IX_SSGD_GAP_ID ON SYNC_STATS_GAP_DETAIL (GAP_ID);

-- -----------------------------------------------------------------------------
-- Mise à niveau idempotente (v6) : GAP_FLAG doit accueillir 'NO_STATS_BOTH'
-- (13 caractères). Le CREATE TABLE ci-dessus le déclare déjà en VARCHAR2(13) ;
-- l'ALTER qui suit est un NO-OP sur une base fraîche et LARGIT la colonne sur
-- une base où la v6 aurait été déployée avec VARCHAR2(12) (correctif). Le
-- CHECK CK_SSGD_FLAG reste inchangé (les valeurs légales sont identiques).
-- -----------------------------------------------------------------------------
ALTER TABLE SYNC_STATS_GAP_DETAIL MODIFY (GAP_FLAG VARCHAR2(13));

-- ============================================================================
-- 3) Séquences dédiées
-- ============================================================================
CREATE SEQUENCE SYNC_STATS_GAP_ID_SEQ
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE SYNC_STATS_GAP_DETAIL_ID_SEQ
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ============================================================================
-- 4) Inventaire final
-- ============================================================================
SELECT object_type, object_name, status
  FROM user_objects
 WHERE object_name LIKE 'SYNC\_STATS\_GAP\_%' ESCAPE '\'
 ORDER BY object_type, object_name;

SELECT sequence_name, last_number
  FROM user_sequences
 WHERE sequence_name LIKE 'SYNC\_STATS\_GAP\_%' ESCAPE '\'
 ORDER BY 1;

PROMPT => Script 14 termine : tables et sequences d'etat d'ecart creees.