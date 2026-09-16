--------------------------------------------------------------------------------
-- SCRIPT 1 — TABLES DE CONFIGURATION
-- Package PKG_SCHEMA_SYNC
-- A exécuter dans le schéma technique SYNC_ADMIN
-- Prérequis : SYNC_ADMIN colocalisé avec l'instance de SCHEMA_A,
--             DB LINK SYNC_LINK_B déjà créé et pointant vers l'instance de SCHEMA_B
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1. SYNC_TABLE_CONFIG
--
-- Rôle    : liste pilote des tables jumelles à synchroniser, une ligne = une
--           table logique existant (ou devant exister) dans SCHEMA_A et SCHEMA_B.
-- Risques : c'est la table la plus sensible du modèle : toute erreur ici
--           (ENABLED='Y' sur une table incompatible, SYNC_DIRECTION incohérent)
--           impacte directement la production. Les CHECK constraints ci-dessous
--           empêchent les valeurs invalides mais ne remplacent pas une revue
--           humaine avant activation.
-- Perf    : lue une fois en début de run (SYNC_ALL) puis mise en cache PL/SQL
--           (collection) pour toute la durée du run ; pas de relecture répétée.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_TABLE_CONFIG (
    TABLE_NAME          VARCHAR2(128)   NOT NULL,

    ENABLED             CHAR(1)         DEFAULT 'Y' NOT NULL,

    -- SYNC_DELETE : conservée pour compatibilité de modèle et pour une v2
    -- future (mécanisme de détection de suppression par tombstone).
    -- Verrouillée à 'N' en v1 : aucune suppression n'est jamais propagée,
    -- une ligne absente d'un côté est systématiquement RÉINSÉRÉE, jamais
    -- utilisée comme preuve de suppression à répercuter.
    SYNC_DELETE         CHAR(1)         DEFAULT 'N' NOT NULL,

    -- BIDIRECTIONAL : les deux sens actifs, conflits possibles, stratégie
    --                 de résolution appliquée le cas échéant.
    -- A_TO_B / B_TO_A : sens unique, la cible est purement subordonnée à
    --                 la source ; tout écart est écrasé et journalisé dans
    --                 SYNC_CONFLICT avec RESOLUTION_STRATEGY='DIRECTION_FORCED'
    --                 à titre d'audit (ce n'est pas un vrai conflit).
    -- DISABLED       : ligne de config conservée mais ignorée par SYNC_ALL.
    SYNC_DIRECTION      VARCHAR2(20)    DEFAULT 'BIDIRECTIONAL' NOT NULL,

    -- Mode des opérations appliquées pour cette table :
    --   INSERT         : uniquement les insertions (INSERT_TO_A / INSERT_TO_B),
    --                   les mises à jour d'écarts existants sont ignorées.
    --   UPDATE         : uniquement les mises à jour (UPDATE_TO_A / UPDATE_TO_B),
    --                   les insertions de lignes nouvelles sont ignorées.
    --   INSERT_UPDATE  : les deux (comportement historique).
    -- NB : la classification (diagnostic, conflits) reste complète quel que soit
    -- le mode : seul l'APPLICATION est filtrée. Le mode par défaut peut être
    -- surchargé ponctuellement pour un run via p_sync_mode sur SYNC_ALL /
    -- SYNC_TABLE / SYNC_TABLES (sans persistance).
    SYNC_MODE           VARCHAR2(20)    DEFAULT 'INSERT_UPDATE' NOT NULL,

    -- Stratégie appliquée uniquement quand SYNC_DIRECTION='BIDIRECTIONAL'
    -- et qu'un conflit réel (modification des deux côtés) est détecté.
    -- LAST_UPDATE_WINS volontairement absente du périmètre v1 : elle
    -- suppose une colonne d'horodatage fiable et des horloges synchronisées
    -- entre les deux instances, ce qui n'est pas garanti ici.
    CONFLICT_STRATEGY   VARCHAR2(20)    DEFAULT 'ERROR_ON_CONFLICT' NOT NULL,

    -- Départage entre GRAPPES de tables (composantes connexes du graphe FK),
    -- jamais à l'intérieur d'une grappe : l'ordre intra-grappe est TOUJOURS
    -- déterminé par le tri topologique des FK, qui est prioritaire sur cette
    -- colonne. Plus la valeur est basse, plus la grappe contenant cette table
    -- est traitée tôt (l'ordre inter-grappes utilise la MOYENNE des PRIORITY
    -- des tables membres de chaque grappe).
    PRIORITY            NUMBER          DEFAULT 100 NOT NULL,

    CREATED_DATE        TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_DATE         TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_BY          VARCHAR2(128)   DEFAULT USER NOT NULL,

    CONSTRAINT PK_SYNC_TABLE_CONFIG PRIMARY KEY (TABLE_NAME),

    CONSTRAINT CK_STC_ENABLED
        CHECK (ENABLED IN ('Y','N')),

    -- Verrou volontaire : empêche toute activation de SYNC_DELETE tant que
    -- le mécanisme de détection de suppression (v2) n'existe pas. A retirer
    -- explicitement (migration de schéma) le jour où la v2 est implémentée.
    CONSTRAINT CK_STC_SYNC_DELETE
        CHECK (SYNC_DELETE = 'N'),

    CONSTRAINT CK_STC_DIRECTION
        CHECK (SYNC_DIRECTION IN ('BIDIRECTIONAL','A_TO_B','B_TO_A','DISABLED')),

    CONSTRAINT CK_STC_SYNC_MODE
        CHECK (SYNC_MODE IN ('INSERT','UPDATE','INSERT_UPDATE')),

    CONSTRAINT CK_STC_CONFLICT_STRATEGY
        CHECK (CONFLICT_STRATEGY IN ('SOURCE_A_WINS','SOURCE_B_WINS','ERROR_ON_CONFLICT')),

    CONSTRAINT CK_STC_PRIORITY
        CHECK (PRIORITY > 0)
);

COMMENT ON TABLE SYNC_TABLE_CONFIG IS
    'Configuration pilote des tables jumelles synchronisées entre SCHEMA_A et SCHEMA_B.';
COMMENT ON COLUMN SYNC_TABLE_CONFIG.SYNC_DELETE IS
    'Verrouillée a N en v1. Reservee a une v2 avec mecanisme de tombstone.';
COMMENT ON COLUMN SYNC_TABLE_CONFIG.PRIORITY IS
    'Ordonnancement INTER-grappes uniquement (moyenne par grappe). Sans effet intra-grappe : ordre FK prioritaire.';
COMMENT ON COLUMN SYNC_TABLE_CONFIG.SYNC_MODE IS
    'Operations appliquees pour la table : INSERT / UPDATE / INSERT_UPDATE (defaut). Surchargable par p_sync_mode au niveau du run.';


--------------------------------------------------------------------------------
-- 2. SYNC_COLUMN_CONFIG
--
-- Rôle    : liste des colonnes explicitement exclues de la comparaison et de
--           la synchronisation pour une table donnée (ex. colonnes techniques
--           applicatives type CREATED_AT, ROW_VERSION...).
-- Risques : une colonne de clé primaire exclue par erreur casserait le MERGE.
--           Contrôle applicatif (pas de CHECK SQL possible ici, la PK est
--           découverte dynamiquement au runtime) : le package DOIT valider
--           au démarrage de chaque run qu'aucune colonne de la PK effective
--           n'apparaît en SYNC_ENABLED='N' dans cette table, et rejeter la
--           table (avec log explicite) si c'est le cas plutôt que d'ignorer
--           silencieusement l'exclusion invalide.
-- Perf    : lue une fois par table en début de traitement, mise en cache.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_COLUMN_CONFIG (
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    COLUMN_NAME     VARCHAR2(128)   NOT NULL,

    -- N = colonne exclue de la comparaison ET du UPDATE/INSERT généré.
    -- Toute colonne de la table absente de SYNC_COLUMN_CONFIG est considérée
    -- SYNC_ENABLED='Y' par défaut (opt-out, pas opt-in) : ceci doit être
    -- documenté clairement pour l'opérateur qui ajoute une table.
    SYNC_ENABLED    CHAR(1)         DEFAULT 'Y' NOT NULL,

    CREATED_DATE    TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT PK_SYNC_COLUMN_CONFIG PRIMARY KEY (TABLE_NAME, COLUMN_NAME),

    CONSTRAINT CK_SCC_SYNC_ENABLED
        CHECK (SYNC_ENABLED IN ('Y','N')),

    CONSTRAINT FK_SCC_TABLE
        FOREIGN KEY (TABLE_NAME)
        REFERENCES SYNC_TABLE_CONFIG (TABLE_NAME)
        ON DELETE CASCADE
);

COMMENT ON TABLE SYNC_COLUMN_CONFIG IS
    'Colonnes explicitement exclues de la comparaison/synchronisation, par table. Opt-out : absence = incluse.';


--------------------------------------------------------------------------------
-- 3. SYNC_KEY_CONFIG
--
-- Rôle    : clé de correspondance explicite pour les tables SANS contrainte
--           PRIMARY KEY (ou UNIQUE) déclarée dans le dictionnaire Oracle.
--           Le package doit d'abord tenter la découverte automatique via
--           ALL_CONSTRAINTS (CONSTRAINT_TYPE='P', puis 'U' à défaut) ; cette
--           table n'intervient QUE si aucune clé n'est trouvée automatiquement,
--           ou si l'opérateur souhaite forcer explicitement une clé différente.
-- Risques : une clé configurée ici n'est PAS garantie unique par une contrainte
--           Oracle réelle. Le package DOIT vérifier l'unicité effective des
--           valeurs (COUNT(*) vs COUNT(DISTINCT ...)) avant le premier run sur
--           cette table, et refuser la synchronisation (log explicite) si
--           l'unicité n'est pas respectée en pratique.
-- Perf    : lue une fois par table sans PK/UNIQUE détectée, en début de run.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_KEY_CONFIG (
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    COLUMN_NAME     VARCHAR2(128)   NOT NULL,

    -- Ordre des colonnes dans la clé composite (1 = premier segment).
    -- Utilisé pour construire la condition ON (...) du MERGE dans un ordre
    -- déterministe et pour construire PK_HASH_KEY de façon reproductible
    -- entre A et B.
    KEY_POSITION    NUMBER          NOT NULL,

    CREATED_DATE    TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT PK_SYNC_KEY_CONFIG PRIMARY KEY (TABLE_NAME, COLUMN_NAME),

    CONSTRAINT UQ_SKC_POSITION
        UNIQUE (TABLE_NAME, KEY_POSITION),

    CONSTRAINT CK_SKC_POSITION
        CHECK (KEY_POSITION > 0),

    CONSTRAINT FK_SKC_TABLE
        FOREIGN KEY (TABLE_NAME)
        REFERENCES SYNC_TABLE_CONFIG (TABLE_NAME)
        ON DELETE CASCADE
);

COMMENT ON TABLE SYNC_KEY_CONFIG IS
    'Cle de correspondance explicite pour les tables sans PK/UNIQUE detectee automatiquement dans le dictionnaire.';


--------------------------------------------------------------------------------
-- Séquence technique pour l'identifiant de run (utilisée par SYNC_LOG,
-- créée ici plutôt que dans le Script 2 pour que la configuration soit
-- livrée en un bloc autonome et testable indépendamment du reste).
--------------------------------------------------------------------------------
CREATE SEQUENCE SYNC_RUN_ID_SEQ
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

--------------------------------------------------------------------------------
-- Fin Script 1
--------------------------------------------------------------------------------
