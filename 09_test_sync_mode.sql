--------------------------------------------------------------------------------
-- SCRIPT 9 — DEMONSTRATION MANUELLE DU MODE DE SYNCHRONISATION (SYNC_MODE)
--
-- Objectif : constater "de visu" la difference entre les trois modes
--            d'operation, sur un etat de depart IDENTIQUE rejoue avant chaque
--            mode :
--              INSERT        : seules les CREATIONS sont propagees
--              UPDATE        : seules les MISES A JOUR sont propagees
--              INSERT_UPDATE : creations ET mises a jour (defaut)
--
-- A executer connecte en SYNC_ADMIN sur FREEPDB1 :
--   sqlplus SYNC_ADMIN/<mot_de_passe>@localhost:1521/FREEPDB1
--   SQL> @09_test_sync_mode.sql
--
-- Prerequis : le paquet PKG_SCHEMA_SYNC doit etre compile (Scripts 3/4) et le
--             DB LINK SYNC_LINK_B doit exister. SYNC_ADMIN doit disposer de
--             DELETE sur SCHEMA_A.CLIENT pour le reset du jeu de test.
--
-- Jeu de donnees (IDs 9001+ pour ne pas toucher l'existant deja synchronise) :
--   9001 : present cote A UNIQUEMENT          -> doit apparaitre en mode INSERT
--   9002 : present des DEUX cotes, valeurs DIVERGENTES
--                                              -> resolu par SOURCE_A_WINS, donc
--                                                 doit apparaitre en mode UPDATE
--   9003 : present cote B UNIQUEMENT          -> doit apparaitre en mode INSERT
--
-- Lecture attendue, etat final A/B :
--   INSERT        : A = {9001, 9002(A)}, B = {9001, 9002(B), 9003}  9002 NON resolu
--   UPDATE        : A = {9001, 9002(A)}, B = {9002(A), 9003}        9001/9003 NON inseres
--   INSERT_UPDATE : A = {9001, 9002, 9003}, B = {9001, 9002, 9003}  9002 resolu (A gagne)
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 200
COLUMN cote     FORMAT A3
COLUMN a_nom    FORMAT A28
COLUMN b_nom    FORMAT A28
COLUMN etat     FORMAT A14
COLUMN table_name FORMAT A12


--------------------------------------------------------------------------------
-- 0. OUTIL DE RESET DU JEU DE TEST (rejoue l'etat de depart divergent)
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RESET_MODE_TEST IS
BEGIN
    DELETE FROM SCHEMA_A.CLIENT           WHERE CLIENT_ID IN (9001, 9002, 9003);
    DELETE FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID IN (9001, 9002, 9003);

    INSERT INTO SCHEMA_A.CLIENT (CLIENT_ID, NOM, EMAIL)
        VALUES (9001, 'Client 9001 SEULEMENT A', 'c9001@a.test');
    INSERT INTO SCHEMA_A.CLIENT (CLIENT_ID, NOM, EMAIL)
        VALUES (9002, 'Client 9002 SOURCE A',    'c9002@a.test');

    INSERT INTO SCHEMA_B.CLIENT@SYNC_LINK_B (CLIENT_ID, NOM, EMAIL)
        VALUES (9002, 'Client 9002 SOURCE B',    'c9002@b.test');
    INSERT INTO SCHEMA_B.CLIENT@SYNC_LINK_B (CLIENT_ID, NOM, EMAIL)
        VALUES (9003, 'Client 9003 SEULEMENT B', 'c9003@b.test');

    COMMIT;
END;
/
PROMPT >>> Outil RESET_MODE_TEST cree.


--------------------------------------------------------------------------------
-- REQUETES D'OBSERVATION (a relancer apres chaque run)
--------------------------------------------------------------------------------
-- Etat compare A / B sur le jeu de test :
--   'ABSENT de A' / 'ABSENT de B' / 'DIVERGENT' / 'IDENTIQUE'
--
-- SELECT NVL(a.CLIENT_ID, b.CLIENT_ID) AS client_id,
--        a.NOM AS a_nom,
--        b.NOM AS b_nom,
--        CASE
--            WHEN a.CLIENT_ID IS NULL THEN 'ABSENT de A'
--            WHEN b.CLIENT_ID IS NULL THEN 'ABSENT de B'
--            WHEN a.NOM = b.NOM AND NVL(a.EMAIL,'~') = NVL(b.EMAIL,'~') THEN 'IDENTIQUE'
--            ELSE 'DIVERGENT'
--        END AS etat
-- FROM   (SELECT * FROM SCHEMA_A.CLIENT WHERE CLIENT_ID >= 9001) a
-- FULL OUTER JOIN
--        (SELECT * FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID >= 9001) b
--   ON   b.CLIENT_ID = a.CLIENT_ID
-- ORDER BY 1;
--
-- Compteurs du dernier run CLIENT :
--
-- SELECT l.run_id, l.sync_mode, l.status,
--        l.rows_inserted_a_to_b AS ins_a_b, l.rows_inserted_b_to_a AS ins_b_a,
--        l.rows_updated_a_to_b  AS upd_a_b, l.rows_updated_b_to_a  AS upd_b_a,
--        l.conflict_count
-- FROM   SYNC_LOG l
-- WHERE  l.table_name = 'CLIENT'
-- ORDER BY l.run_id DESC FETCH FIRST 1 ROW ONLY;
--
-- Le composant SQL*Plus reportable est fourni en fin de fichier sous forme de
-- vue V_MODE_TEST (a utiliser dans les sections suivantes).


CREATE OR REPLACE VIEW V_MODE_TEST AS
SELECT NVL(a.CLIENT_ID, b.CLIENT_ID) AS client_id,
       a.NOM AS a_nom,
       b.NOM AS b_nom,
       CASE
           WHEN a.CLIENT_ID IS NULL THEN 'ABSENT de A'
           WHEN b.CLIENT_ID IS NULL THEN 'ABSENT de B'
           WHEN a.NOM = b.NOM AND NVL(a.EMAIL,'~') = NVL(b.EMAIL,'~') THEN 'IDENTIQUE'
           ELSE 'DIVERGENT'
       END AS etat
FROM   (SELECT CLIENT_ID, NOM, EMAIL FROM SCHEMA_A.CLIENT            WHERE CLIENT_ID >= 9001) a
FULL OUTER JOIN
       (SELECT CLIENT_ID, NOM, EMAIL FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID >= 9001) b
  ON   b.CLIENT_ID = a.CLIENT_ID;

CREATE OR REPLACE VIEW V_MODE_LAST_RUN AS
SELECT l.run_id, l.sync_mode, l.status,
       l.rows_inserted_a_to_b AS ins_a_b, l.rows_inserted_b_to_a AS ins_b_a,
       l.rows_updated_a_to_b  AS upd_a_b, l.rows_updated_b_to_a  AS upd_b_a,
       l.conflict_count
FROM   SYNC_LOG l
WHERE  l.table_name = 'CLIENT';
PROMPT >>> Vues V_MODE_TEST et V_MODE_LAST_RUN creees.



-- ############################################################################
-- SECTION 1 — MODE INSERT  (uniquement les creations)
-- ############################################################################
PROMPT
PROMPT ============================================================
PROMPT  SECTION 1 : MODE INSERT
PROMPT ============================================================
EXEC RESET_MODE_TEST;

PROMPT === Etat AVANT (attendu : 9001 A-seul, 9002 divergent, 9003 B-seul) ===
SELECT * FROM V_MODE_TEST;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE(
        'CLIENT',
        p_dry_run   => FALSE,
        p_sync_mode => PKG_SCHEMA_SYNC.C_SYNC_MODE_INSERT,
        p_run_id    => v_run_id);
    DBMS_OUTPUT.PUT_LINE('*** Run mode INSERT termine : run_id = ' || v_run_id);
END;
/

PROMPT === Etat APRES (attendu : 9001 et 9003 crees des deux cotes, 9002 DIVERGENT) ===
SELECT * FROM V_MODE_TEST;

PROMPT === Compteurs (attendu : ins_a_b=1, ins_b_a=1, upd_a_b=0, upd_b_a=0) ===
SELECT * FROM V_MODE_LAST_RUN ORDER BY run_id DESC FETCH FIRST 1 ROW ONLY;



-- ############################################################################
-- SECTION 2 — MODE UPDATE  (uniquement les mises a jour)
-- ############################################################################
PROMPT
PROMPT ============================================================
PROMPT  SECTION 2 : MODE UPDATE
PROMPT ============================================================
EXEC RESET_MODE_TEST;

PROMPT === Etat AVANT (attendu : 9001 A-seul, 9002 divergent, 9003 B-seul) ===
SELECT * FROM V_MODE_TEST;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE(
        'CLIENT',
        p_dry_run   => FALSE,
        p_sync_mode => PKG_SCHEMA_SYNC.C_SYNC_MODE_UPDATE,
        p_run_id    => v_run_id);
    DBMS_OUTPUT.PUT_LINE('*** Run mode UPDATE termine : run_id = ' || v_run_id);
END;
/

PROMPT === Etat APRES (attendu : 9002 IDENTIQUE, 9001 reste A-seul, 9003 reste B-seul) ===
SELECT * FROM V_MODE_TEST;

PROMPT === Compteurs (attendu : ins_a_b=0, ins_b_a=0, upd_a_b=1, upd_b_a=0) ===
SELECT * FROM V_MODE_LAST_RUN ORDER BY run_id DESC FETCH FIRST 1 ROW ONLY;



-- ############################################################################
-- SECTION 3 — MODE INSERT_UPDATE  (defaut : creations + mises a jour)
-- ############################################################################
PROMPT
PROMPT ============================================================
PROMPT  SECTION 3 : MODE INSERT_UPDATE
PROMPT ============================================================
EXEC RESET_MODE_TEST;

PROMPT === Etat AVANT (attendu : 9001 A-seul, 9002 divergent, 9003 B-seul) ===
SELECT * FROM V_MODE_TEST;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE(
        'CLIENT',
        p_dry_run   => FALSE,
        p_sync_mode => PKG_SCHEMA_SYNC.C_SYNC_MODE_INSERT_UPDATE,
        p_run_id    => v_run_id);
    DBMS_OUTPUT.PUT_LINE('*** Run mode INSERT_UPDATE termine : run_id = ' || v_run_id);
END;
/

PROMPT === Etat APRES (attendu : 9001/9002/9003 IDENTIQUES des deux cotes) ===
SELECT * FROM V_MODE_TEST;

PROMPT === Compteurs (attendu : ins_a_b=1, ins_b_a=1, upd_a_b=1, upd_b_a=0) ===
SELECT * FROM V_MODE_LAST_RUN ORDER BY run_id DESC FETCH FIRST 1 ROW ONLY;



-- ############################################################################
-- SECTION 4 — MODE PERSISTE EN CONFIGURATION (SYNC_TABLE_CONFIG.SYNC_MODE)
--             Aucun p_sync_mode : le mode vient de la config de la table.
-- ############################################################################
PROMPT
PROMPT ============================================================
PROMPT  SECTION 4 : MODE PAR TABLE (sans override de run)
PROMPT ============================================================
EXEC RESET_MODE_TEST;

PROMPT === On force le mode par table a UPDATE pour CLIENT ===
UPDATE SYNC_TABLE_CONFIG SET SYNC_MODE = 'UPDATE' WHERE TABLE_NAME = 'CLIENT';
COMMIT;
SELECT TABLE_NAME, SYNC_MODE FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'CLIENT';

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => FALSE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('*** Run sans override (mode config = UPDATE) : run_id = ' || v_run_id);
END;
/

PROMPT === Etat APRES (attendu : identique a la Section 2 = comportement UPDATE) ===
SELECT * FROM V_MODE_TEST;

PROMPT === Restauration du mode par defaut de la configuration ===
UPDATE SYNC_TABLE_CONFIG SET SYNC_MODE = 'INSERT_UPDATE' WHERE TABLE_NAME = 'CLIENT';
COMMIT;
SELECT TABLE_NAME, SYNC_MODE FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'CLIENT';



-- ############################################################################
-- REMISE A L'ETAT DE DEPART (facultatif — laisse le jeu de test divergent
-- pour permettre de rejouer le fichier depuis le debut)
-- ############################################################################
PROMPT
PROMPT ============================================================
PROMPT  REMISE A L'ETAT INITIAL DU JEU DE TEST
PROMPT ============================================================
EXEC RESET_MODE_TEST;
SELECT * FROM V_MODE_TEST;

PROMPT
PROMPT ============================================================
PROMPT  FIN SCRIPT 9
PROMPT ============================================================
