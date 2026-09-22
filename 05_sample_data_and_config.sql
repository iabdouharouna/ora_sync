--------------------------------------------------------------------------------
-- SCRIPT 5 — TABLES METIER D'EXEMPLE ET CONFIGURATION
--
-- A exécuter en TROIS temps, sur TROIS connexions différentes :
--   (1) connecté en SCHEMA_A : bloc "PARTIE A"
--   (2) connecté en SCHEMA_B (ou via la base distante) : bloc "PARTIE B"
--   (3) connecté en SYNC_ADMIN : bloc "PARTIE CONFIG" + grants
--
-- Prérequis (une seule fois, à exécuter avec un compte privilégié : SYS) :
--   GRANT EXECUTE ON DBMS_CRYPTO TO SYNC_ADMIN;
-- Nécessaire au hachage des colonnes LOB (chemin lent DBMS_CRYPTO, décision
-- v2) : le package s'exécute sous le schéma SYNC_ADMIN, qui doit disposer de
-- l'autorisation d'appeler DBMS_CRYPTO.HASH. Sans ce grant, toute table
-- contenant un LOB échoue au run avec ORA-00904 "DBMS_CRYPTO"."HASH".
--
-- Jeu d'exemple repris du cahier des charges initial : CLIENT, PRODUIT,
-- COMMANDE, COMMANDE_LIGNE, avec un cas de clé composite (COMMANDE_LIGNE)
-- et une chaîne de dépendances FK CLIENT -> COMMANDE -> COMMANDE_LIGNE
-- (PRODUIT est référencé par COMMANDE_LIGNE mais n'a pas de dépendance
-- entrante : bon exemple de tri topologique à plus de deux niveaux).
--------------------------------------------------------------------------------


--================================================================================
-- PARTIE A — a executer connecte en SCHEMA_A
--================================================================================

CREATE TABLE CLIENT (
    CLIENT_ID       NUMBER          NOT NULL,
    NOM             VARCHAR2(100)   NOT NULL,
    EMAIL           VARCHAR2(200),
    DATE_CREATION   DATE            DEFAULT SYSDATE,
    NOTES           CLOB,                           -- volontairement un LOB dans le jeu de test
    CONSTRAINT PK_CLIENT PRIMARY KEY (CLIENT_ID)
);

CREATE TABLE PRODUIT (
    PRODUIT_ID      NUMBER          NOT NULL,
    LIBELLE         VARCHAR2(200)   NOT NULL,
    PRIX_UNITAIRE   NUMBER(10,2)    NOT NULL,
    CONSTRAINT PK_PRODUIT PRIMARY KEY (PRODUIT_ID)
);

CREATE TABLE COMMANDE (
    COMMANDE_ID     NUMBER          NOT NULL,
    CLIENT_ID       NUMBER          NOT NULL,
    DATE_COMMANDE   DATE            DEFAULT SYSDATE NOT NULL,
    STATUT          VARCHAR2(20)    DEFAULT 'EN_COURS' NOT NULL,
    CONSTRAINT PK_COMMANDE PRIMARY KEY (COMMANDE_ID),
    CONSTRAINT FK_COMMANDE_CLIENT FOREIGN KEY (CLIENT_ID) REFERENCES CLIENT (CLIENT_ID)
);

-- Clé composite volontaire, pour tester la synchronisation multi-colonnes.
CREATE TABLE COMMANDE_LIGNE (
    COMMANDE_ID     NUMBER          NOT NULL,
    LIGNE_ID        NUMBER          NOT NULL,
    PRODUIT_ID      NUMBER          NOT NULL,
    QUANTITE        NUMBER          NOT NULL,
    CONSTRAINT PK_COMMANDE_LIGNE PRIMARY KEY (COMMANDE_ID, LIGNE_ID),
    CONSTRAINT FK_CL_COMMANDE FOREIGN KEY (COMMANDE_ID) REFERENCES COMMANDE (COMMANDE_ID),
    CONSTRAINT FK_CL_PRODUIT  FOREIGN KEY (PRODUIT_ID)  REFERENCES PRODUIT (PRODUIT_ID)
);

-- Jeu de données initial côté A — IDEMPOTENT : chaque ligne n'est insérée que
-- si sa clé est absente. Recharger « sample » sur un environnement déjà peuplé
-- (ou synchronisé) ne réinitialise donc JAMAIS les données existantes et ne
-- déclenche plus d'ORA-00001 (PK violée) en second passage.
INSERT INTO CLIENT (CLIENT_ID, NOM, EMAIL)
SELECT 1, 'Jean Dupont', 'jean.dupont@example.com' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM CLIENT WHERE CLIENT_ID = 1);

INSERT INTO CLIENT (CLIENT_ID, NOM, EMAIL)
SELECT 2, 'Marie Curie', 'marie.curie@example.com' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM CLIENT WHERE CLIENT_ID = 2);

INSERT INTO PRODUIT (PRODUIT_ID, LIBELLE, PRIX_UNITAIRE)
SELECT 100, 'Clavier mecanique', 79.90 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM PRODUIT WHERE PRODUIT_ID = 100);

INSERT INTO PRODUIT (PRODUIT_ID, LIBELLE, PRIX_UNITAIRE)
SELECT 101, 'Souris sans fil', 29.90 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM PRODUIT WHERE PRODUIT_ID = 101);

INSERT INTO COMMANDE (COMMANDE_ID, CLIENT_ID, STATUT)
SELECT 1000, 1, 'EN_COURS' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM COMMANDE WHERE COMMANDE_ID = 1000);

INSERT INTO COMMANDE_LIGNE (COMMANDE_ID, LIGNE_ID, PRODUIT_ID, QUANTITE)
SELECT 1000, 1, 100, 2 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM COMMANDE_LIGNE WHERE COMMANDE_ID = 1000 AND LIGNE_ID = 1);
COMMIT;

-- Grants nécessaires au compte technique SYNC_ADMIN (décision validée :
-- grants larges sur les deux schémas plutôt que ciblés table par table).
GRANT SELECT, INSERT, UPDATE ON CLIENT          TO SYNC_ADMIN;
GRANT SELECT, INSERT, UPDATE ON PRODUIT         TO SYNC_ADMIN;
GRANT SELECT, INSERT, UPDATE ON COMMANDE        TO SYNC_ADMIN;
GRANT SELECT, INSERT, UPDATE ON COMMANDE_LIGNE  TO SYNC_ADMIN;


--================================================================================
-- PARTIE B — a executer connecte en SCHEMA_B (structure identique à A)
--================================================================================

CREATE TABLE CLIENT (
    CLIENT_ID       NUMBER          NOT NULL,
    NOM             VARCHAR2(100)   NOT NULL,
    EMAIL           VARCHAR2(200),
    DATE_CREATION   DATE            DEFAULT SYSDATE,
    NOTES           CLOB,
    CONSTRAINT PK_CLIENT PRIMARY KEY (CLIENT_ID)
);

CREATE TABLE PRODUIT (
    PRODUIT_ID      NUMBER          NOT NULL,
    LIBELLE         VARCHAR2(200)   NOT NULL,
    PRIX_UNITAIRE   NUMBER(10,2)    NOT NULL,
    CONSTRAINT PK_PRODUIT PRIMARY KEY (PRODUIT_ID)
);

CREATE TABLE COMMANDE (
    COMMANDE_ID     NUMBER          NOT NULL,
    CLIENT_ID       NUMBER          NOT NULL,
    DATE_COMMANDE   DATE            DEFAULT SYSDATE NOT NULL,
    STATUT          VARCHAR2(20)    DEFAULT 'EN_COURS' NOT NULL,
    CONSTRAINT PK_COMMANDE PRIMARY KEY (COMMANDE_ID),
    CONSTRAINT FK_COMMANDE_CLIENT FOREIGN KEY (CLIENT_ID) REFERENCES CLIENT (CLIENT_ID)
);

CREATE TABLE COMMANDE_LIGNE (
    COMMANDE_ID     NUMBER          NOT NULL,
    LIGNE_ID        NUMBER          NOT NULL,
    PRODUIT_ID      NUMBER          NOT NULL,
    QUANTITE        NUMBER          NOT NULL,
    CONSTRAINT PK_COMMANDE_LIGNE PRIMARY KEY (COMMANDE_ID, LIGNE_ID),
    CONSTRAINT FK_CL_COMMANDE FOREIGN KEY (COMMANDE_ID) REFERENCES COMMANDE (COMMANDE_ID),
    CONSTRAINT FK_CL_PRODUIT  FOREIGN KEY (PRODUIT_ID)  REFERENCES PRODUIT (PRODUIT_ID)
);

-- Jeu de données initial côté B : volontairement DIFFERENT de A pour
-- observer un premier run non trivial (insertions dans les deux sens,
-- CLIENT_ID=2 identique des deux côtés sert de témoin "déjà synchronisé").
-- Idempotent comme côté A : insertion uniquement si la clé est absente.
INSERT INTO CLIENT (CLIENT_ID, NOM, EMAIL)
SELECT 2, 'Marie Curie', 'marie.curie@example.com' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM CLIENT WHERE CLIENT_ID = 2);

INSERT INTO CLIENT (CLIENT_ID, NOM, EMAIL)
SELECT 3, 'Ada Lovelace', 'ada.lovelace@example.com' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM CLIENT WHERE CLIENT_ID = 3);

INSERT INTO PRODUIT (PRODUIT_ID, LIBELLE, PRIX_UNITAIRE)
SELECT 100, 'Clavier mecanique', 79.90 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM PRODUIT WHERE PRODUIT_ID = 100);
COMMIT;

-- Sur l'instance hébergeant SCHEMA_B, SYNC_ADMIN n'a PAS de compte local
-- (accès exclusivement via SYNC_LINK_B, cf. Option 1 validée) : le grant se
-- fait donc vers l'utilisateur DEFINE PAR LE DB LINK (souvent nommé de
-- façon symétrique, ex. SYNC_ADMIN_REMOTE ou un compte applicatif dédié —
-- à adapter selon l'utilisateur réellement utilisé par SYNC_LINK_B).
GRANT SELECT, INSERT, UPDATE ON CLIENT          TO <UTILISATEUR_UTILISE_PAR_SYNC_LINK_B>;
GRANT SELECT, INSERT, UPDATE ON PRODUIT         TO <UTILISATEUR_UTILISE_PAR_SYNC_LINK_B>;
GRANT SELECT, INSERT, UPDATE ON COMMANDE        TO <UTILISATEUR_UTILISE_PAR_SYNC_LINK_B>;
GRANT SELECT, INSERT, UPDATE ON COMMANDE_LIGNE  TO <UTILISATEUR_UTILISE_PAR_SYNC_LINK_B>;


--================================================================================
-- PARTIE CONFIG — a executer connecte en SYNC_ADMIN
--================================================================================

-- Ordre d'insertion sans importance ici (pas de FK entre tables de config
-- portant sur TABLE_NAME les unes vers les autres au moment du chargement
-- initial, la FK de SYNC_COLUMN_CONFIG/SYNC_KEY_CONFIG vers SYNC_TABLE_CONFIG
-- impose seulement que la ligne SYNC_TABLE_CONFIG existe AVANT).

-- Idempotence (rechargement « sample ») : la configuration déjà posée — y
-- compris un réglage d'exploitation personnalisé — n'est jamais écrasée.
INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
SELECT 'CLIENT', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 10 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'CLIENT');

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
SELECT 'PRODUIT', 'Y', 'BIDIRECTIONAL', 'ERROR_ON_CONFLICT', 10 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'PRODUIT');

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
SELECT 'COMMANDE', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 20 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'COMMANDE');

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, CONFLICT_STRATEGY, PRIORITY)
SELECT 'COMMANDE_LIGNE', 'Y', 'BIDIRECTIONAL', 'SOURCE_A_WINS', 20 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = 'COMMANDE_LIGNE');

-- Exemple de colonne exclue : DATE_CREATION ne doit jamais être écrasée
-- (horodatage de création propre à chaque environnement).
INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
SELECT 'CLIENT', 'DATE_CREATION', 'N' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_COLUMN_CONFIG
                   WHERE TABLE_NAME = 'CLIENT' AND COLUMN_NAME = 'DATE_CREATION');

COMMIT;
