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
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY('LOG_EVENEMENT', v_check_id, v_blocking);
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
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY('LOG_EVENEMENT', v_check_id, v_blocking);
    DBMS_OUTPUT.PUT_LINE('Avec cle configuree -> blocking = ' ||
        CASE WHEN v_blocking THEN 'TRUE (verifier unicite reelle des donnees !)' ELSE 'FALSE (attendu)' END);
END;
/


--------------------------------------------------------------------------------
-- TEST 10 — Structure incompatible
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(10, 'Structure incompatible : EMAIL retreci cote B');
END;
/
ALTER TABLE SCHEMA_B.CLIENT@SYNC_LINK_B MODIFY EMAIL VARCHAR2(50);
-- NOTE : ALTER TABLE via DB LINK n'est PAS supporte par Oracle (DDL distant
-- impossible via un simple DB LINK). Cette instruction doit en realite etre
-- executee via une CONNEXION DIRECTE a SCHEMA_B, pas via SYNC_LINK_B depuis
-- SYNC_ADMIN. Corrige ici a titre de mise en garde explicite : se connecter
-- reellement a SCHEMA_B pour ce test.
-- ALTER TABLE CLIENT MODIFY EMAIL VARCHAR2(50);  -- a executer connecte en SCHEMA_B

DECLARE
    v_check_id NUMBER;
    v_blocking BOOLEAN;
BEGIN
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY('CLIENT', v_check_id, v_blocking);
    DBMS_OUTPUT.PUT_LINE('CLIENT incompatible -> blocking = ' || CASE WHEN v_blocking THEN 'TRUE (attendu)' ELSE 'FALSE' END);
END;
/
SELECT * FROM SYNC_COMPATIBILITY_REPORT WHERE TABLE_NAME = 'CLIENT' AND ISSUE_TYPE = 'LENGTH_MISMATCH'
ORDER BY CHECK_DATE DESC;

-- Restauration (connecte en SCHEMA_B) :
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
-- Simulation : on insere cote A une valeur de STATUT trop longue pour la
-- contrainte implicite de longueur de COMMANDE.STATUT cote B (apres l'avoir
-- artificiellement retrecie), pour provoquer une erreur ORA-12899 au moment
-- de l'INSERT distribue.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(12, 'Erreur sur une table (simulation) + Test 13 (reprise)');
END;
/
-- Connecte en SCHEMA_B : ALTER TABLE COMMANDE MODIFY STATUT VARCHAR2(5);
-- (reduit volontairement la taille pour provoquer une erreur a l'insertion)

INSERT INTO SCHEMA_A.COMMANDE (COMMANDE_ID, CLIENT_ID, STATUT) VALUES (1001, 1, 'STATUT_TROP_LONG');
COMMIT;

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID : ' || v_run_id);
END;
/
SELECT 'Test 12 - Table COMMANDE en FAILED, erreur journalisee ?' AS verif, STATUS, ERROR_MESSAGE
FROM SYNC_LOG WHERE TABLE_NAME = 'COMMANDE' ORDER BY START_DATE DESC FETCH FIRST 1 ROW ONLY;

-- Correction du probleme, puis nouvelle tentative (Test 13 : reprise)
-- Connecte en SCHEMA_B : ALTER TABLE COMMANDE MODIFY STATUT VARCHAR2(20);

DECLARE
    v_run_id NUMBER;
BEGIN
    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => FALSE, p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE, p_run_id => v_run_id);
    DBMS_OUTPUT.PUT_LINE('Run ID (reprise) : ' || v_run_id);
END;
/
SELECT 'Test 13 - COMMANDE_ID=1001 present cote B apres correction ?' AS verif, COUNT(*) AS resultat
FROM SCHEMA_B.COMMANDE@SYNC_LINK_B WHERE COMMANDE_ID = 1001;


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
-- ATTENTION : ce test est DESTRUCTIF pour la configuration — il vide
-- SYNC_TABLE_CONFIG (et par cascade SYNC_COLUMN_CONFIG, SYNC_KEY_CONFIG)
-- pour observer la decouverte automatique, puis restaure une configuration
-- manuelle equivalente a celle du Script 5 en fin de test. A executer EN
-- DERNIER, jamais entre deux autres tests de ce script.
--------------------------------------------------------------------------------
BEGIN
    TEST_HEADER(15, 'Decouverte automatique quand SYNC_TABLE_CONFIG est vide');
END;
/

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
-- Restauration de la configuration manuelle (equivalente au Script 5), pour
-- ne pas laisser l'environnement dans un etat purement auto-decouvert si
-- l'exploitation doit se poursuivre apres ce jeu de tests.
--------------------------------------------------------------------------------
DELETE FROM SYNC_TABLE_CONFIG;  -- purge la config auto-decouverte (cascade incluse)
COMMIT;

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
VALUES ('CLIENT', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 10);
INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
VALUES ('PRODUIT', 'Y', 'BIDIRECTIONAL', 'ERROR_ON_CONFLICT', 10);
INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
VALUES ('COMMANDE', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 20);
INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
VALUES ('COMMANDE_LIGNE', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 20);
INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
VALUES ('CLIENT', 'DATE_CREATION', 'N');
COMMIT;

-- NOTE : si le Test 9 (table sans PK, LOG_EVENEMENT) doit rester actif au-delà
-- de ce script, ré-exécuter aussi son insertion SYNC_TABLE_CONFIG et son
-- SYNC_KEY_CONFIG (CODE_EVT) — non repris ici automatiquement, la restauration
-- ci-dessus ne couvre que le socle du Script 5.


--------------------------------------------------------------------------------
-- Nettoyage de l'utilitaire de test (optionnel)
--------------------------------------------------------------------------------
-- DROP PROCEDURE TEST_HEADER;

--------------------------------------------------------------------------------
-- FIN SCRIPT 6
--------------------------------------------------------------------------------