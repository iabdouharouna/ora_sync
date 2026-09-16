--------------------------------------------------------------------------------
-- SCRIPT 6 — JEU DE TESTS FONCTIONNELS
--
-- A exécuter connecté en SYNC_ADMIN, APRES les Scripts 1 à 5.
-- SET SERVEROUTPUT ON obligatoire (DBMS_OUTPUT utilisé pour le compte-rendu).
--
-- Nature de ce script : un test manuel guidé, pas un harnais d'assertions
-- automatisées (qui relèverait d'un framework dédié type utPLSQL, hors
-- périmètre demandé). Chaque scénario affiche l'état AVANT/APRES et un
-- verdict simple ; la lecture reste nécessaire pour valider le résultat.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED;

--------------------------------------------------------------------------------
-- Utilitaire de compte-rendu
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TEST_HEADER(p_num IN NUMBER, p_title IN VARCHAR2) IS
BEGIN
    DBMS_OUTPUT.PUT_LINE(CHR(10) || '========================================================');
    DBMS_OUTPUT.PUT_LINE('TEST ' || p_num || ' — ' || p_title);
    DBMS_OUTPUT.PUT_LINE('========================================================');
END;
/

--------------------------------------------------------------------------------
-- TEST 1 — Insertion A -> B
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(1, 'Insertion A -> B');
END;
/
-- Nouveau client uniquement côté A
INSERT INTO SCHEMA_A.CLIENT (CLIENT_ID, NOM, EMAIL) VALUES (10, 'Nouveau Client A', 'nca@example.com');
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => FALSE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID : ' || v_run_id);
END;
/
-- Vérification attendue : SCHEMA_B.CLIENT contient désormais CLIENT_ID=10
SELECT 'Test 1 - CLIENT_ID=10 present cote B ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID = 10;


--------------------------------------------------------------------------------
-- TEST 2 — Insertion B -> A
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(2, 'Insertion B -> A (Ada Lovelace, CLIENT_ID=3, deja presente cote B via Script 5)');
END;
/
DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => FALSE, p_run_id => v_run_id);
END;
/
SELECT 'Test 2 - CLIENT_ID=3 (Ada) present cote A ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 3;


--------------------------------------------------------------------------------
-- TEST 3 — Modification A -> B (table CLIENT, strategie SOURCE_A_WINS)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(3, 'Modification A -> B');
END;
/
UPDATE SCHEMA_A.CLIENT SET NOM = 'Jean Dupont (modifie cote A)' WHERE CLIENT_ID = 1;
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => FALSE, p_run_id => v_run_id);
END;
/
SELECT 'Test 3 - NOM cote B mis a jour ?' AS verif, NOM
FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID = 1;


--------------------------------------------------------------------------------
-- TEST 4 — Modification B -> A
--
-- CLIENT est configuree en SOURCE_A_WINS par defaut (Script 5) : pour
-- observer un flux B->A propre sans dependre d'un conflit, on bascule
-- temporairement la strategie sur SOURCE_B_WINS pour ce test, puis on la
-- restaure.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(4, 'Modification B -> A (bascule temporaire SOURCE_B_WINS)');
END;
/
UPDATE SYNC_TABLE_CONFIG SET CONFLICT_STRATEGY = 'SOURCE_B_WINS' WHERE TABLE_NAME = 'CLIENT';
COMMIT;

UPDATE SCHEMA_B.CLIENT@SYNC_LINK_B SET NOM = 'Marie Curie (modifie cote B)' WHERE CLIENT_ID = 2;
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => FALSE, p_run_id => v_run_id);
END;
/
SELECT 'Test 4 - NOM cote A mis a jour ?' AS verif, NOM
FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 2;

-- Restauration de la configuration nominale
UPDATE SYNC_TABLE_CONFIG SET CONFLICT_STRATEGY = 'SOURCE_A_WINS' WHERE TABLE_NAME = 'CLIENT';
COMMIT;


--------------------------------------------------------------------------------
-- TEST 5 — Suppression : comportement de "resurrection" documente et attendu
--
-- Rappel de la decision validee (SYNC_DELETE verrouillee a 'N', §1.1 des
-- echanges d'architecture) : une ligne supprimee d'un cote est TOUJOURS
-- reinseree au run suivant. Ce test verifie ce comportement EXPLICITEMENT,
-- ce n'est pas un bug.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(5, 'Suppression -> resurrection attendue (comportement documente)');
END;
/
DELETE FROM SCHEMA_B.PRODUIT@SYNC_LINK_B WHERE PRODUIT_ID = 100;
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('PRODUIT', p_dry_run => FALSE, p_run_id => v_run_id);
END;
/
SELECT 'Test 5 - PRODUIT_ID=100 reapparu cote B (comportement attendu) ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_B.PRODUIT@SYNC_LINK_B WHERE PRODUIT_ID = 100;


--------------------------------------------------------------------------------
-- TEST 6 — Conflit reel (table PRODUIT, ERROR_ON_CONFLICT)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(6, 'Conflit reel : modification concurrente des deux cotes');
END;
/
UPDATE SCHEMA_A.PRODUIT SET PRIX_UNITAIRE = 89.90 WHERE PRODUIT_ID = 101;
COMMIT;
-- PRODUIT_ID=101 n'existe pas encore cote B a ce stade (cf. Script 5) : on
-- l'insere manuellement cote B avec une valeur DIFFERENTE pour forcer un vrai
-- conflit des la premiere comparaison.
INSERT INTO SCHEMA_B.PRODUIT@SYNC_LINK_B (PRODUIT_ID, LIBELLE, PRIX_UNITAIRE) VALUES (101, 'Souris sans fil', 24.90);
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('PRODUIT', p_dry_run => FALSE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID : ' || v_run_id);
END;
/
SELECT 'Test 6 - Conflit journalise dans SYNC_CONFLICT ?' AS verif, COUNT(*) AS resultat
FROM SYNC_CONFLICT WHERE TABLE_NAME = 'PRODUIT' AND RESOLUTION_STRATEGY = 'ERROR_ON_CONFLICT';

SELECT 'Test 6 - PRIX_UNITAIRE cote A inchange (89.90) ?' AS verif, PRIX_UNITAIRE
FROM SCHEMA_A.PRODUIT WHERE PRODUIT_ID = 101;
SELECT 'Test 6 - PRIX_UNITAIRE cote B inchange (24.90) ?' AS verif, PRIX_UNITAIRE
FROM SCHEMA_B.PRODUIT@SYNC_LINK_B WHERE PRODUIT_ID = 101;


--------------------------------------------------------------------------------
-- TEST 7 — Cle composite (COMMANDE_LIGNE)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(7, 'Cle composite');
END;
/
INSERT INTO SCHEMA_A.COMMANDE_LIGNE (COMMANDE_ID, LIGNE_ID, PRODUIT_ID, QUANTITE) VALUES (1000, 2, 101, 1);
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    -- COMMANDE_LIGNE depend de COMMANDE (deja synchronisee) et PRODUIT :
    -- utilisation de SYNC_ALL ici plutot que SYNC_TABLE, pour respecter
    -- l'ordre FK complet de la grappe.
    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_run_id => v_run_id);
END;
/
SELECT 'Test 7 - Ligne composite (1000,2) presente cote B ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_B.COMMANDE_LIGNE@SYNC_LINK_B WHERE COMMANDE_ID = 1000 AND LIGNE_ID = 2;


--------------------------------------------------------------------------------
-- TEST 8 — Colonne exclue (CLIENT.DATE_CREATION)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(8, 'Colonne exclue : DATE_CREATION ne doit jamais etre synchronisee');
END;
/
SELECT 'Test 8 - DATE_CREATION cote A' AS verif, DATE_CREATION FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 1;
SELECT 'Test 8 - DATE_CREATION cote B (doit pouvoir differer sans etre "corrigee")' AS verif, DATE_CREATION
FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID = 1;
-- Un ecart persistant sur cette colonne, meme apres plusieurs runs, est le
-- resultat ATTENDU (exclusion de synchronisation), pas une anomalie.


--------------------------------------------------------------------------------
-- TEST 9 — Table sans PK (clé configurée manuellement)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(9, 'Table sans PK, cle configuree manuellement');
END;
/
-- A executer prealablement des deux cotes (SCHEMA_A puis SCHEMA_B) :
--   CREATE TABLE LOG_EVENEMENT (CODE_EVT VARCHAR2(20), LIBELLE VARCHAR2(200));
--   (pas de contrainte PK ni UNIQUE, volontairement)
--   INSERT INTO LOG_EVENEMENT VALUES ('EVT001', 'Ouverture session');
--   COMMIT;
-- Puis, connecte en SYNC_ADMIN :
INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
VALUES ('LOG_EVENEMENT', 'Y', 'BIDIRECTIONAL', 'ERROR_ON_CONFLICT', 100);
COMMIT;

DECLARE
    v_check_id NUMBER;
    v_blocking BOOLEAN;
BEGIN
    -- Sans SYNC_KEY_CONFIG : doit produire une anomalie PK_MISSING BLOCKING
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => 'LOG_EVENEMENT', p_check_id => v_check_id, p_has_blocking_issues => v_blocking);
    DBMS_OUTPUT.PUT_LINE('Sans cle configuree -> blocking = ' ||
        CASE WHEN v_blocking THEN 'TRUE (attendu)' ELSE 'FALSE (inattendu !)' END);
END;
/

-- Ajout d'une cle manuelle (CODE_EVT, en supposant son unicite reelle)
INSERT INTO SYNC_KEY_CONFIG (TABLE_NAME, COLUMN_NAME, KEY_POSITION) VALUES ('LOG_EVENEMENT', 'CODE_EVT', 1);
COMMIT;

DECLARE
    v_check_id NUMBER;
    v_blocking BOOLEAN;
BEGIN
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => 'LOG_EVENEMENT', p_check_id => v_check_id, p_has_blocking_issues => v_blocking);
    DBMS_OUTPUT.PUT_LINE('Avec cle configuree -> blocking = ' ||
        CASE WHEN v_blocking THEN 'TRUE (verifier unicite reelle des donnees !)' ELSE 'FALSE (attendu)' END);
END;
/


--------------------------------------------------------------------------------
-- TEST 10 — Structure incompatible
--
-- Etape manuelle PREALABLE (a executer connecte en SCHEMA_B, jamais via
-- le DB LINK : le DDL distant n'est pas supporte par Oracle) :
--     ALTER TABLE CLIENT MODIFY EMAIL VARCHAR2(50);
-- (retrecir EMAIL rend la structure B incompatible avec A)
--
-- Le script sonde la longueur reellement en vigueur des deux cotes puis
-- n'emet un verdict qu'en consequence : si l'ecart est en place,
-- CHECK_COMPATIBILITY doit remonter BLOCKING ; sinon il affiche un SKIP
-- (etape manuelle non appliquee) et s'arrete la pour le test 10.
------------------------------------------------------------------------
BEGIN
    TEST_HEADER(10, 'Structure incompatible : EMAIL retreci cote B');
END;
/
SELECT 'Test 10 - Longueur EMAIL cote A' AS verif, DATA_LENGTH FROM ALL_TAB_COLUMNS
WHERE OWNER = 'SCHEMA_A' AND TABLE_NAME = 'CLIENT' AND COLUMN_NAME = 'EMAIL'
UNION ALL
SELECT 'Test 10 - Longueur EMAIL cote B', DATA_LENGTH FROM ALL_TAB_COLUMNS@SYNC_LINK_B
WHERE OWNER = 'SCHEMA_B' AND TABLE_NAME = 'CLIENT' AND COLUMN_NAME = 'EMAIL';

DECLARE
    v_len_a     NUMBER;
    v_len_b     NUMBER;
    v_check_id  NUMBER;
    v_blocking  BOOLEAN;
BEGIN
    SELECT DATA_LENGTH INTO v_len_a FROM ALL_TAB_COLUMNS
     WHERE OWNER = 'SCHEMA_A' AND TABLE_NAME = 'CLIENT' AND COLUMN_NAME = 'EMAIL';
    SELECT DATA_LENGTH INTO v_len_b FROM ALL_TAB_COLUMNS@SYNC_LINK_B
     WHERE OWNER = 'SCHEMA_B' AND TABLE_NAME = 'CLIENT' AND COLUMN_NAME = 'EMAIL';

    IF v_len_b < v_len_a THEN
        PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => 'CLIENT', p_check_id => v_check_id, p_has_blocking_issues => v_blocking);
        IF v_blocking THEN
            DBMS_OUTPUT.PUT_LINE('OK - ecart de longueur detecte, blocking = TRUE (attendu).');
        ELSE
            DBMS_OUTPUT.PUT_LINE('ANOMALIE - ecart de longueur present mais blocking = FALSE.');
        END IF;
    ELSE
        DBMS_OUTPUT.PUT_LINE('SKIP - etape manuelle non appliquee (B.EMAIL pas retreci).');
    END IF;
END;
/
SELECT * FROM SYNC_COMPATIBILITY_REPORT WHERE TABLE_NAME = 'CLIENT' AND ISSUE_TYPE = 'LENGTH_MISMATCH'
ORDER BY CHECK_DATE DESC FETCH FIRST 1 ROW ONLY;

-- Restauration (connecte en SCHEMA_B), si l'etape manuelle a ete appliquee :
-- ALTER TABLE CLIENT MODIFY EMAIL VARCHAR2(200);


--------------------------------------------------------------------------------
-- TEST 11 — Mode DRY_RUN
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(11, 'Mode DRY_RUN : aucune ecriture reelle');
END;
/
INSERT INTO SCHEMA_A.CLIENT (CLIENT_ID, NOM) VALUES (99, 'Client Dry Run');
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID (dry run) : ' || v_run_id);
END;
/
SELECT 'Test 11 - CLIENT_ID=99 absent cote B (dry run, attendu) ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_B.CLIENT@SYNC_LINK_B WHERE CLIENT_ID = 99;
-- Nettoyage
DELETE FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 99;
COMMIT;


--------------------------------------------------------------------------------
-- TEST 12 — Erreur sur une table (simulation) + TEST 13 — Reprise après erreur
--
-- Etape manuelle PREALABLE (connecte en SCHEMA_B, pas via DB LINK) :
--     ALTER TABLE COMMANDE MODIFY STATUT VARCHAR2(5);
-- (retrecci volontairement pour provoquer un ORA-12899 a l'INSERT distribue)
--
-- Le script insere cote A une commande dont le STATUT ('STATUT_TROP_LONG',
-- 17 caracteres) depasse la largeur 5 retrecie, lance un SYNC_ALL en mode
-- CONTINUE, puis sonde la largeur reellement en vigueur cote B pour choisir
-- le verdict : si B.STATUT est retreci, COMMANDE doit etre en FAILED (erreur
-- journalisee) ; sinon le test est en SKIP (etape manuelle non appliquee, la
-- commande se synchronise normalement). Le Test 13 reprend ensuite avec une
-- nouvelle tentative apres correction de la largeur.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(12, 'Erreur sur une table (simulation) + Test 13 (reprise)');
END;
/

-- Insertion idempotente de la commande (le re-jeu du script ne doit pas
-- echouer sur une contrainte PK).
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM SCHEMA_A.COMMANDE WHERE COMMANDE_ID = 1001;
    IF v_cnt = 0 THEN
        INSERT INTO SCHEMA_A.COMMANDE (COMMANDE_ID, CLIENT_ID, STATUT) VALUES (1001, 1, 'STATUT_TROP_LONG');
        DBMS_OUTPUT.PUT_LINE('Commande 1001 inseree cote A.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Commande 1001 deja presente cote A (re-jeu).');
    END IF;
END;
/
COMMIT;

SELECT 'Test 12 - Largeur STATUT cote A' AS verif, DATA_LENGTH FROM ALL_TAB_COLUMNS
WHERE OWNER = 'SCHEMA_A' AND TABLE_NAME = 'COMMANDE' AND COLUMN_NAME = 'STATUT'
UNION ALL
SELECT 'Test 12 - Largeur STATUT cote B', DATA_LENGTH FROM ALL_TAB_COLUMNS@SYNC_LINK_B
WHERE OWNER = 'SCHEMA_B' AND TABLE_NAME = 'COMMANDE' AND COLUMN_NAME = 'STATUT';

DECLARE
    v_run_id   NUMBER;
    v_len_b    NUMBER;
BEGIN
    SELECT DATA_LENGTH INTO v_len_b FROM ALL_TAB_COLUMNS@SYNC_LINK_B
     WHERE OWNER = 'SCHEMA_B' AND TABLE_NAME = 'COMMANDE' AND COLUMN_NAME = 'STATUT';

    IF v_len_b < 17 THEN
        DBMS_OUTPUT.PUT_LINE('B.STATUT retreci (' || v_len_b || ') : le run suivant doit echouer sur COMMANDE.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('B.STATUT non retreci (' || v_len_b || ') : Test 12 en SKIP, COMMANDE devrait se synchroniser.');
    END IF;

    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID : ' || v_run_id);
END;
/

SELECT 'Test 12 + 13 - Derniere execution COMMANDE' AS verif, STATUS, ERROR_MESSAGE
FROM SYNC_LOG WHERE TABLE_NAME = 'COMMANDE' ORDER BY START_DATE DESC FETCH FIRST 1 ROW ONLY;

-- Phase de reprise (Test 13) : si l'etape manuelle de retrecissement a ete
-- appliquee au Test 12, il faut d'abord RESTAURER la largeur cote B :
--     ALTER TABLE COMMANDE MODIFY STATUT VARCHAR2(20);   -- connecte en SCHEMA_B
DECLARE
    v_len_b     NUMBER;
    v_run_id    NUMBER;
    v_final     NUMBER;
BEGIN
    SELECT DATA_LENGTH INTO v_len_b FROM ALL_TAB_COLUMNS@SYNC_LINK_B
     WHERE OWNER = 'SCHEMA_B' AND TABLE_NAME = 'COMMANDE' AND COLUMN_NAME = 'STATUT';

    IF v_len_b >= 17 THEN
        DBMS_OUTPUT.PUT_LINE('Reprise : largeur compatible (' || v_len_b || '), relance d''un SYNC_ALL.');
        PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE, p_run_id => v_run_id);
        DBMS_OUTPUT.PUT_LINE('Run ID (reprise) : ' || v_run_id);
    ELSE
        DBMS_OUTPUT.PUT_LINE('SKIP reprise : restaurer la largeur cote B (ALTER ... STATUT VARCHAR2(20)) puis relancer.');
    END IF;

    SELECT COUNT(*) INTO v_final FROM SCHEMA_B.COMMANDE@SYNC_LINK_B WHERE COMMANDE_ID = 1001;
    IF v_final > 0 THEN
        DBMS_OUTPUT.PUT_LINE('OK - COMMANDE_ID=1001 present cote B apres reprise.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ATTENTION - COMMANDE_ID=1001 toujours absent cote B (reprise non effectuee ?).');
    END IF;
END;
/


--------------------------------------------------------------------------------
-- TEST 14 — Deuxieme synchronisation sans changement (idempotence, §22)
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(14, 'Idempotence : deuxieme SYNC_ALL sans changement intermediaire');
END;
/
DECLARE
    v_run_id_1 NUMBER;
    v_run_id_2 NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_run_id => v_run_id_1);
    DBMS_OUTPUT.PUT_LINE('Premier run stabilisateur : ' || v_run_id_1);

    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_run_id => v_run_id_2);
    DBMS_OUTPUT.PUT_LINE('Deuxieme run (doit etre a vide) : ' || v_run_id_2);
END;
/
SELECT 'Test 14 - Total lignes ecrites au 2e run (doit etre 0)' AS verif,
       SUM(ROWS_INSERTED_A_TO_B + ROWS_INSERTED_B_TO_A + ROWS_UPDATED_A_TO_B + ROWS_UPDATED_B_TO_A) AS total
FROM SYNC_LOG
WHERE RUN_ID = (SELECT MAX(RUN_ID) FROM SYNC_RUN_HEADER);


--------------------------------------------------------------------------------
-- TEST 15 — Decouverte automatique des tables (SYNC_TABLE_CONFIG vide)
--
-- NON DESTRUCTIF (correctif v2) : avant de vider la configuration, un
-- instantane exact des trois tables de config (SYNC_TABLE_CONFIG,
-- SYNC_COLUMN_CONFIG, SYNC_KEY_CONFIG) est pris dans des tables temporaires
-- TMP_CFG_* ; la configuration est restauree a l'identique en fin de test
-- (tout ajout fait avant le test, y compris LOG_EVENEMENT du Test 9, est
-- preserve). A executer EN DERNIER de preference.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(15, 'Decouverte automatique quand SYNC_TABLE_CONFIG est vide');
END;
/

-- Snapshot de la configuration (DROP tolérant : tables absentes au 1er passage)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE TMP_CFG_T';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE TMP_CFG_C';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE TMP_CFG_K';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
CREATE TABLE TMP_CFG_T AS SELECT * FROM SYNC_TABLE_CONFIG;
CREATE TABLE TMP_CFG_C AS SELECT * FROM SYNC_COLUMN_CONFIG;
CREATE TABLE TMP_CFG_K AS SELECT * FROM SYNC_KEY_CONFIG;
COMMIT;

DELETE FROM SYNC_TABLE_CONFIG;  -- cascade sur SYNC_COLUMN_CONFIG et SYNC_KEY_CONFIG
COMMIT;

SELECT 'Test 15 - Configuration bien vide avant le run ?' AS verif, COUNT(*) AS resultat
FROM SYNC_TABLE_CONFIG;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID (decouverte automatique) : ' || v_run_id);
END;
/

SELECT 'Test 15 - Tables auto-decouvertes' AS verif, TABLE_NAME, SYNC_DIRECTION, CONFLICT_STRATEGY, UPDATED_BY
FROM SYNC_TABLE_CONFIG ORDER BY TABLE_NAME;

SELECT 'Test 15 - Toutes marquees AUTO_DISCOVERY ?' AS verif,
       COUNT(*) AS total_tables,
       SUM(CASE WHEN UPDATED_BY = 'AUTO_DISCOVERY' THEN 1 ELSE 0 END) AS auto_decouvertes
FROM SYNC_TABLE_CONFIG;

SELECT 'Test 15 - CLIENT synchronisee malgre configuration vide au depart ?' AS verif, STATUS
FROM SYNC_LOG WHERE TABLE_NAME = 'CLIENT' ORDER BY START_DATE DESC FETCH FIRST 1 ROW ONLY;

-- Point d'attention pedagogique : si LOG_EVENEMENT (creee au Test 9) existe
-- encore des deux cotes, elle est elle aussi auto-decouverte ici — mais sa
-- cle manuelle (SYNC_KEY_CONFIG) a ete perdue par la cascade du DELETE
-- ci-dessus. Elle devrait donc apparaitre EXCLUDED / BLOCKING (PK_MISSING)
-- dans SYNC_COMPATIBILITY_REPORT pour ce run : la decouverte automatique ne
-- devine jamais de cle, elle se contente de lister les tables communes.
SELECT 'Test 15 - LOG_EVENEMENT (si presente) exclue faute de cle ?' AS verif,
       TABLE_NAME, ISSUE_TYPE, SEVERITY
FROM SYNC_COMPATIBILITY_REPORT
WHERE TABLE_NAME = 'LOG_EVENEMENT' AND SEVERITY = 'BLOCKING'
ORDER BY CHECK_DATE DESC FETCH FIRST 1 ROW ONLY;

--------------------------------------------------------------------------------
-- Restauration EXACTE de la configuration d'origine (snapshot du debut du test).
--------------------------------------------------------------------------------
DELETE FROM SYNC_TABLE_CONFIG;  -- purge la config auto-decouverte (cascade incluse)
COMMIT;

INSERT INTO SYNC_TABLE_CONFIG SELECT * FROM TMP_CFG_T;
INSERT INTO SYNC_COLUMN_CONFIG SELECT * FROM TMP_CFG_C;
INSERT INTO SYNC_KEY_CONFIG SELECT * FROM TMP_CFG_K;
COMMIT;

DROP TABLE TMP_CFG_T PURGE;
DROP TABLE TMP_CFG_C PURGE;
DROP TABLE TMP_CFG_K PURGE;
COMMIT;


--------------------------------------------------------------------------------
-- TEST 16 — Configuration du DB LINK à l'exécution (SET_DB_LINK / GET_DB_LINK)
--
-- Démontre que la valeur du DB LINK peut être consultée et modifiée sans
-- recompilation, via SET_DB_LINK/GET_DB_LINK ou le paramètre p_db_link de
-- SYNC_ALL/SYNC_TABLE/CHECK_COMPATIBILITY.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(16, 'Configuration du DB LINK a l''execution (sans recompilation)');
END;
/

DECLARE
    v_current VARCHAR2(128);
BEGIN
    v_current := PKG_SCHEMA_SYNC.GET_DB_LINK;
    DBMS_OUTPUT.PUT_LINE('DB LINK actuellement actif (valeur compilee ou deja fixee) : ' ||
        NVL(v_current, '<NULL - meme instance>'));

    -- Round-trip : refixer explicitement la meme valeur via SET_DB_LINK et
    -- verifier que GET_DB_LINK la reflete bien.
    PKG_SCHEMA_SYNC.SET_DB_LINK(v_current);
    IF NVL(PKG_SCHEMA_SYNC.GET_DB_LINK, '<NULL>') = NVL(v_current, '<NULL>') THEN
        DBMS_OUTPUT.PUT_LINE('OK - SET_DB_LINK/GET_DB_LINK coherents apres round-trip.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ANOMALIE - valeur apres SET_DB_LINK differente de celle attendue.');
    END IF;
END;
/

-- Un appel SYNC_TABLE sans p_db_link (valeur par defaut = sentinelle
-- C_DB_LINK_KEEP_CURRENT) ne doit RIEN changer a la configuration courante :
DECLARE
    v_before  VARCHAR2(128) := PKG_SCHEMA_SYNC.GET_DB_LINK;
    v_after   VARCHAR2(128);
    v_run_id  NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE, p_run_id => v_run_id);
    v_after := PKG_SCHEMA_SYNC.GET_DB_LINK;
    IF NVL(v_before, '<NULL>') = NVL(v_after, '<NULL>') THEN
        DBMS_OUTPUT.PUT_LINE('OK - appel sans p_db_link : configuration inchangee.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ANOMALIE - la configuration a change sans que p_db_link soit fourni.');
    END IF;
END;
/

-- A l'inverse, passer p_db_link explicitement (meme avec la valeur deja
-- active) doit fonctionner sans erreur, et modifier reellement la valeur
-- si elle differe (a adapter avec un second DB LINK reel si disponible
-- dans l'environnement de test, pour valider un vrai changement de cible) :
DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE(
        p_table_name => 'CLIENT',
        p_dry_run    => TRUE,
        p_db_link    => PKG_SCHEMA_SYNC.GET_DB_LINK,  -- reaffirme la valeur courante
        p_run_id     => v_run_id
    );
    DBMS_OUTPUT.PUT_LINE('OK - appel avec p_db_link explicite accepte (run ' || v_run_id || ').');
END;
/


--------------------------------------------------------------------------------
-- Nettoyage de l'utilitaire de test (optionnel)
--------------------------------------------------------------------------------
-- DROP PROCEDURE TEST_HEADER;

--------------------------------------------------------------------------------
-- TEST 17 — SYNC_TABLES : synchronisation par liste + expansion implicite des
--            dépendances FK (parents uniquement).
--
-- On ne demande QUE COMMANDE_LIGNE. La résolution implicite doit remonter la
-- chaîne CLIENT <- COMMANDE <- COMMANDE_LIGNE et PRODUIT <- COMMANDE_LIGNE, et
-- donc exécuter les 4 tables, parents AVANT enfants (ordre topologique).
--------------------------------------------------------------------------------
DECLARE
    v_run_id   NUMBER;
    v_run_type VARCHAR2(20);
    v_total    NUMBER;
    v_status   VARCHAR2(30);
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLES(
        p_table_list => PKG_SCHEMA_SYNC.t_tab_name_list('COMMANDE_LIGNE'),
        p_dry_run    => TRUE,
        p_run_id     => v_run_id
    );
    DBMS_OUTPUT.PUT_LINE('Run ID (SYNC_TABLES) : ' || v_run_id);

    SELECT run_type, total_tables, status
      INTO v_run_type, v_total, v_status
      FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;

    DBMS_OUTPUT.PUT_LINE('RUN_TYPE attendu SYNC_TABLES -> ' || v_run_type);
    DBMS_OUTPUT.PUT_LINE('TOTAL_TABLES attendu 4 (1 demandee + 3 parents) -> ' || v_total);
    DBMS_OUTPUT.PUT_LINE('STATUS -> ' || v_status);
END;
/

SELECT 'Test 17 - Perimetre etendu (4 tables, parents implicites)' AS verif,
       TABLE_NAME, Cluster_Id, Cluster_Order, Status, Sync_Mode
FROM SYNC_LOG
WHERE RUN_ID = (SELECT MAX(RUN_ID) FROM SYNC_RUN_HEADER WHERE RUN_TYPE = 'SYNC_TABLES')
ORDER BY Cluster_Id, Cluster_Order, TABLE_NAME;

-- Les parents doivent apparaître AVANT leur enfant dans l'ordre topologique.
SELECT 'Test 17 - Parents traites avant COMMANDE_LIGNE ?' AS verif,
       MIN(CASE WHEN TABLE_NAME = 'COMMANDE_LIGNE' THEN Cluster_Order END) AS ordre_enfant,
       MAX(CASE WHEN TABLE_NAME IN ('CLIENT','COMMANDE','PRODUIT') THEN Cluster_Order END) AS ordre_parent_max
FROM SYNC_LOG
WHERE RUN_ID = (SELECT MAX(RUN_ID) FROM SYNC_RUN_HEADER WHERE RUN_TYPE = 'SYNC_TABLES');

--------------------------------------------------------------------------------
-- TEST 18 — Mode de synchronisation (SYNC_MODE par table + override de run).
--
-- 18a. Défaut de configuration : SYNC_TABLE sans p_sync_mode -> INSERT_UPDATE.
-- 18b. Override de run : p_sync_mode => 'INSERT' -> journalisé dans SYNC_LOG,
--      sans modification persistante de SYNC_TABLE_CONFIG.
--------------------------------------------------------------------------------
DECLARE
    v_run_id NUMBER;
    v_mode   VARCHAR2(20);
BEGIN
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE, p_run_id => v_run_id);
    SELECT SYNC_MODE INTO v_mode FROM SYNC_LOG
     WHERE RUN_ID = v_run_id AND TABLE_NAME = 'CLIENT' AND ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE('Test 18a - mode par defaut -> ' || NVL(v_mode, '<NULL>') || ' (attendu INSERT_UPDATE)');

    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE,
        p_sync_mode => PKG_SCHEMA_SYNC.C_SYNC_MODE_INSERT, p_run_id => v_run_id);
    SELECT SYNC_MODE INTO v_mode FROM SYNC_LOG
     WHERE RUN_ID = v_run_id AND TABLE_NAME = 'CLIENT' AND ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE('Test 18b - mode override run -> ' || NVL(v_mode, '<NULL>') || ' (attendu INSERT)');
END;
/

SELECT 'Test 18 - Override non persiste en configuration ?' AS verif,
       TABLE_NAME, SYNC_MODE
FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'CLIENT';

--------------------------------------------------------------------------------
-- FIN SCRIPT 6
--------------------------------------------------------------------------------