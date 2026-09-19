--------------------------------------------------------------------------------
-- SCRIPT 2 — TABLES DE JOURNALISATION, CONFLITS, COMPATIBILITE, TRAVAIL
-- Package PKG_SCHEMA_SYNC
-- A exécuter dans le schéma technique SYNC_ADMIN, après le Script 1.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1. SYNC_RUN_HEADER
--
-- Rôle    : une ligne par exécution de SYNC_ALL ou SYNC_TABLE. Porte le statut
--           GLOBAL du run, agrégé à partir des statuts par table dans SYNC_LOG.
-- Ajout par rapport au cahier des charges initial : le CDC ne prévoyait qu'une
--           table SYNC_LOG avec RUN_ID comme simple identifiant. Le modèle a
--           besoin d'une table d'en-tête séparée car : (a) un run peut couvrir
--           plusieurs tables avec des statuts différents (une table en SUCCESS,
--           une autre en FAILED) et il faut un statut de SYNTHÈSE distinct du
--           détail par table pour répondre à GET_RUN_STATUS(p_run_id) de façon
--           univoque ; (b) le statut PARTIAL n'a de sens qu'au niveau du run
--           (arrêt anticipé suite à STOP_ON_ERROR), jamais au niveau d'une
--           table individuelle déjà commitée. A VALIDER : cet ajout n'était
--           pas explicitement demandé, je le signale donc clairement ici.
-- Perf    : une seule ligne par run, aucun impact volumétrique notable.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_RUN_HEADER (
    RUN_ID              NUMBER          NOT NULL,

    -- 'SYNC_ALL', 'SYNC_TABLE' ou 'SYNC_TABLES' : trace le point d'entrée utilisé
    -- pour ce run.
    RUN_TYPE            VARCHAR2(20)    NOT NULL,

    START_DATE          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    END_DATE            TIMESTAMP,

    -- IN_PROGRESS tant que le run n'est pas terminé (permet de détecter un
    -- run resté bloqué anormalement, ex. session tuée côté OS).
    -- SUCCESS                 : toutes les grappes traitées, aucun conflit.
    -- SUCCESS_WITH_CONFLICTS  : toutes les grappes traitées, au moins un
    --                           conflit journalisé dans SYNC_CONFLICT.
    -- PARTIAL                 : arrêt anticipé (STOP_ON_ERROR), au moins une
    --                           grappe commitée avant l'arrêt.
    -- FAILED                  : arrêt anticipé, aucune grappe commitée.
    STATUS              VARCHAR2(30)    DEFAULT 'IN_PROGRESS' NOT NULL,

    DRY_RUN             CHAR(1)         DEFAULT 'N' NOT NULL,
    ERROR_MODE          VARCHAR2(10)    DEFAULT 'CONTINUE' NOT NULL,

    TOTAL_TABLES        NUMBER          DEFAULT 0 NOT NULL,
    TABLES_SUCCESS      NUMBER          DEFAULT 0 NOT NULL,
    TABLES_CONFLICT     NUMBER          DEFAULT 0 NOT NULL,
    TABLES_FAILED       NUMBER          DEFAULT 0 NOT NULL,
    TABLES_EXCLUDED     NUMBER          DEFAULT 0 NOT NULL,  -- incompatibles ou cycle FK non déferrable

    EXECUTED_BY         VARCHAR2(128)   DEFAULT USER NOT NULL,

    CONSTRAINT PK_SYNC_RUN_HEADER PRIMARY KEY (RUN_ID),

    CONSTRAINT CK_SRH_RUN_TYPE
        CHECK (RUN_TYPE IN ('SYNC_ALL','SYNC_TABLE','SYNC_TABLES')),

    CONSTRAINT CK_SRH_STATUS
        CHECK (STATUS IN ('IN_PROGRESS','SUCCESS','SUCCESS_WITH_CONFLICTS','PARTIAL','FAILED')),

    CONSTRAINT CK_SRH_DRY_RUN
        CHECK (DRY_RUN IN ('Y','N')),

    CONSTRAINT CK_SRH_ERROR_MODE
        CHECK (ERROR_MODE IN ('CONTINUE','STOP'))
);

COMMENT ON TABLE SYNC_RUN_HEADER IS
    'Une ligne par execution de SYNC_ALL/SYNC_TABLE/SYNC_TABLES. Statut global agrege depuis SYNC_LOG.';


--------------------------------------------------------------------------------
-- 2. SYNC_LOG
--
-- Rôle    : détail par table pour un run donné. Une ligne = une table traitée
--           (ou tentée) dans le cadre du RUN_ID.
-- Risques : ERROR_MESSAGE et ERROR_BACKTRACE doivent TOUJOURS être renseignés
--           en cas d'exception, jamais d'exception avalée silencieusement
--           (WHEN OTHERS THEN NULL proscrit dans le package body).
-- Perf    : volumétrie = nb tables synchronisées x nb runs. Négligeable même
--           sur plusieurs années d'historique quotidien. Un index sur
--           (TABLE_NAME, START_DATE) permettra les requêtes d'historique
--           par table sans scanner tout le run.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_LOG (
    LOG_ID                  NUMBER          NOT NULL,
    RUN_ID                  NUMBER          NOT NULL,
    TABLE_NAME              VARCHAR2(128)   NOT NULL,

    START_DATE              TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    END_DATE                TIMESTAMP,

    -- Statut au niveau table uniquement. PARTIAL n'existe qu'au niveau run
    -- (SYNC_RUN_HEADER) : une table individuelle est soit allée au bout
    -- (SUCCESS / SUCCESS_WITH_CONFLICTS), soit a échoué (FAILED), soit n'a
    -- jamais démarré parce que le run s'est arrêté avant (pas de ligne créée
    -- dans ce cas, plutôt que IN_PROGRESS orphelin).
    STATUS                  VARCHAR2(30)    DEFAULT 'IN_PROGRESS' NOT NULL,

    -- Grappe FK à laquelle appartient la table pour ce run (traçabilité de
    -- l'ordonnancement calculé, utile en diagnostic).
    CLUSTER_ID              NUMBER,
    CLUSTER_ORDER           NUMBER,         -- position dans le tri topologique intra-grappe

    -- Mode d'application EFFECTIF pour cette table sur ce run
    -- (INSERT / UPDATE / INSERT_UPDATE). NULL pour les lignes de résolution
    -- explicitement sans contexte de mode (échec ré-inséré par l'appelant).
    SYNC_MODE               VARCHAR2(20),

    ROWS_INSERTED_A_TO_B    NUMBER          DEFAULT 0 NOT NULL,
    ROWS_INSERTED_B_TO_A    NUMBER          DEFAULT 0 NOT NULL,
    ROWS_UPDATED_A_TO_B     NUMBER          DEFAULT 0 NOT NULL,
    ROWS_UPDATED_B_TO_A     NUMBER          DEFAULT 0 NOT NULL,
    -- Pas de ROWS_DELETED_* : aucune suppression n'est jamais propagée en v1.

    CONFLICT_COUNT          NUMBER          DEFAULT 0 NOT NULL,
    ERROR_COUNT             NUMBER          DEFAULT 0 NOT NULL,
    ERROR_MESSAGE           VARCHAR2(4000),
    ERROR_BACKTRACE         CLOB,

    CONSTRAINT PK_SYNC_LOG PRIMARY KEY (LOG_ID),

    CONSTRAINT FK_SL_RUN
        FOREIGN KEY (RUN_ID)
        REFERENCES SYNC_RUN_HEADER (RUN_ID),

    CONSTRAINT CK_SL_STATUS
        CHECK (STATUS IN ('IN_PROGRESS','SUCCESS','SUCCESS_WITH_CONFLICTS','FAILED'))
);

CREATE SEQUENCE SYNC_LOG_ID_SEQ START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE INDEX IX_SYNC_LOG_TABLE_DATE ON SYNC_LOG (TABLE_NAME, START_DATE);
CREATE INDEX IX_SYNC_LOG_RUN ON SYNC_LOG (RUN_ID);

COMMENT ON TABLE SYNC_LOG IS
    'Detail par table pour un RUN_ID donne. Statut, volumetrie des operations, erreurs.';


--------------------------------------------------------------------------------
-- 3. SYNC_CONFLICT
--
-- Rôle    : une ligne par PK en conflit réel (modifiée des deux côtés depuis
--           le dernier run) ou en écart forcé (SYNC_DIRECTION à sens unique).
-- Risques : VALUE_A / VALUE_B stockent la ligne complète sérialisée en JSON
--           plutôt que colonne par colonne : nécessaire car le nombre et la
--           nature des colonnes synchronisées varient par table (modèle
--           générique). Attention : si la table contient des colonnes LOB
--           volumineuses, la sérialisation JSON complète peut être coûteuse
--           en espace CLOB — à surveiller, purge/rétention de SYNC_CONFLICT
--           à prévoir en exploitation (non traité dans ce script, à ajouter
--           en job de maintenance périodique).
-- Perf    : volumétrie proportionnelle au taux de conflit réel, normalement
--           très faible par rapport au volume total synchronisé.
--------------------------------------------------------------------------------
CREATE TABLE SYNC_CONFLICT (
    CONFLICT_ID         NUMBER          NOT NULL,
    RUN_ID               NUMBER          NOT NULL,
    TABLE_NAME           VARCHAR2(128)   NOT NULL,

    -- PK_HASH_KEY : SHA-256 hexadécimal (64 caractères) de la concaténation
    -- canonique des colonnes de clé. Le hachage (et non la concaténation
    -- brute) évite tout dépassement VARCHAR2 sur les clés composites longues.
    PK_HASH_KEY          VARCHAR2(64)    NOT NULL,
    PK_DISPLAY            VARCHAR2(4000),             -- représentation lisible "CLIENT_ID=10" pour audit humain

    VALUE_A               CLOB,           -- sérialisation JSON de la ligne côté A au moment du diagnostic
    VALUE_B               CLOB,           -- idem côté B

    -- Stratégie effectivement appliquée pour cette ligne :
    -- SOURCE_A_WINS / SOURCE_B_WINS / ERROR_ON_CONFLICT / DIRECTION_FORCED
    -- (ce dernier cas = SYNC_DIRECTION à sens unique, écart journalisé pour
    -- audit mais ce n'est pas un vrai conflit bidirectionnel).
    RESOLUTION_STRATEGY   VARCHAR2(30)    NOT NULL,

    -- 'A', 'B', ou NULL si ERROR_ON_CONFLICT (non résolu, en attente
    -- d'intervention manuelle).
    RESOLVED_SIDE         VARCHAR2(1),

    RESOLVED_DATE         TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT PK_SYNC_CONFLICT PRIMARY KEY (CONFLICT_ID),

    CONSTRAINT FK_SC_RUN
        FOREIGN KEY (RUN_ID)
        REFERENCES SYNC_RUN_HEADER (RUN_ID),

    CONSTRAINT CK_SC_RESOLUTION_STRATEGY
        CHECK (RESOLUTION_STRATEGY IN ('SOURCE_A_WINS','SOURCE_B_WINS','ERROR_ON_CONFLICT','DIRECTION_FORCED')),

    CONSTRAINT CK_SC_RESOLVED_SIDE
        CHECK (RESOLVED_SIDE IN ('A','B') OR RESOLVED_SIDE IS NULL)
);

CREATE SEQUENCE SYNC_CONFLICT_ID_SEQ START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE INDEX IX_SYNC_CONFLICT_TABLE ON SYNC_CONFLICT (TABLE_NAME, RESOLVED_DATE);
CREATE INDEX IX_SYNC_CONFLICT_RUN ON SYNC_CONFLICT (RUN_ID);

COMMENT ON TABLE SYNC_CONFLICT IS
    'Historique des conflits reels et des ecarts forces (sens unique), avec resolution appliquee.';


--------------------------------------------------------------------------------
-- 4. SYNC_COMPATIBILITY_REPORT
--
-- Rôle    : rapport persisté produit par CHECK_COMPATIBILITY, une ligne par
--           anomalie détectée (table absente d'un côté, type incompatible,
--           taille différente, PK manquante ou différente entre A et B...).
-- Risques : c'est la table qui matérialise la garde-fou du §18 du cahier des
--           charges : "ne pas lancer aveuglément la synchronisation" si les
--           structures diffèrent. SYNC_ALL doit interroger cette table (ou
--           relancer CHECK_COMPATIBILITY) avant de traiter une table, et
--           exclure automatiquement toute table avec au moins une anomalie
--           SEVERITY='BLOCKING' non résolue.
-- Perf    : recalculée à chaque appel de CHECK_COMPATIBILITY (pas de cache
--           long terme, car le DDL des tables métier peut évoluer entre deux
--           runs sans que SYNC_ADMIN en soit informé autrement).
--------------------------------------------------------------------------------
CREATE TABLE SYNC_COMPATIBILITY_REPORT (
    REPORT_ID        NUMBER          NOT NULL,
    CHECK_ID         NUMBER          NOT NULL,   -- regroupe toutes les lignes d'un même appel CHECK_COMPATIBILITY
    CHECK_DATE       TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,

    TABLE_NAME       VARCHAR2(128)   NOT NULL,
    COLUMN_NAME      VARCHAR2(128),              -- NULL si l'anomalie porte sur la table entière

    -- MISSING_IN_A / MISSING_IN_B     : table absente d'un côté
    -- TYPE_MISMATCH                   : type de données différent
    -- LENGTH_MISMATCH                 : taille/precision/scale différente
    -- NULLABLE_MISMATCH               : nullabilité différente
    -- PK_MISSING                      : aucune PK/UNIQUE ni SYNC_KEY_CONFIG
    -- PK_MISMATCH                     : clé différente entre A et B
    -- UNSUPPORTED_TYPE                : LONG/LONG RAW/objet/VARRAY/XMLType
    -- KEY_NOT_UNIQUE                  : clé configurée manuellement mais non unique en pratique
    -- FK_CYCLE_DEFERRABLE             : cycle FK détecté mais entièrement déferrable (accepté, WARNING)
    -- FK_CYCLE_NOT_DEFERRABLE         : cycle FK comportant une contrainte non déferrable (grappe exclue, BLOCKING)
    -- FK_PARENT_ENROLLED (v4)         : parent FK absent de SYNC_TABLE_CONFIG, auto-enrôlé (WARNING)
    -- FK_PARENT_DISABLED (v4)         : parent FK présent mais désactivé en config, jamais forcé (WARNING)
    -- PARENT_BACKFILLED (v5)          : parent re-inséré dans B depuis A (backfill ORA-02291) (WARNING)
    -- FK_CHILD_RETRIED (v5)           : table enfant retentée après backfill du parent (WARNING)
    -- FK_CYCLE_HANDLED_BY_DISABLE (v5): cycle FK traité par désactivation temporaire des FK sur B (WARNING)
    -- TABLE_CREATED_IN_B (v5)         : table active absente de B, créée depuis les métadonnées A (WARNING)
    -- PARENT_BACKFILL_FAILED (v5)     : backfill impossible (parent absent de A, table absente de B...) (BLOCKING)
    -- FK_REPAIR_FAILED (v5)           : échec de réparation (désactivation/réactivation FK du cycle) (BLOCKING)
    ISSUE_TYPE       VARCHAR2(30)    NOT NULL,

    -- BLOCKING : la table est automatiquement exclue du run tant que
    --            l'anomalie n'est pas corrigée.
    -- WARNING  : la table reste synchronisable mais l'anomalie est signalée
    --            (ex. colonne surnuméraire d'un côté, exclue par ailleurs
    --            via SYNC_COLUMN_CONFIG).
    SEVERITY         VARCHAR2(10)    NOT NULL,

    DETAIL_A         VARCHAR2(4000),
    DETAIL_B         VARCHAR2(4000),

    CONSTRAINT PK_SYNC_COMPAT_REPORT PRIMARY KEY (REPORT_ID),

    CONSTRAINT CK_SCR_ISSUE_TYPE
        CHECK (ISSUE_TYPE IN (
            'MISSING_IN_A','MISSING_IN_B','TYPE_MISMATCH','LENGTH_MISMATCH',
            'NULLABLE_MISMATCH','PK_MISSING','PK_MISMATCH','UNSUPPORTED_TYPE',
            'KEY_NOT_UNIQUE','FK_CYCLE_DEFERRABLE','FK_CYCLE_NOT_DEFERRABLE',
            'FK_PARENT_ENROLLED','FK_PARENT_DISABLED',
            'PARENT_BACKFILLED','FK_CHILD_RETRIED','FK_CYCLE_HANDLED_BY_DISABLE',
            'TABLE_CREATED_IN_B','PARENT_BACKFILL_FAILED','FK_REPAIR_FAILED'
        )),

    CONSTRAINT CK_SCR_SEVERITY
        CHECK (SEVERITY IN ('BLOCKING','WARNING'))
);

CREATE SEQUENCE SYNC_COMPAT_REPORT_ID_SEQ START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SYNC_COMPAT_CHECK_ID_SEQ START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE INDEX IX_SYNC_COMPAT_CHECK ON SYNC_COMPATIBILITY_REPORT (CHECK_ID);
CREATE INDEX IX_SYNC_COMPAT_TABLE ON SYNC_COMPATIBILITY_REPORT (TABLE_NAME, CHECK_DATE);

COMMENT ON TABLE SYNC_COMPATIBILITY_REPORT IS
    'Rapport persiste des anomalies de structure detectees par CHECK_COMPATIBILITY. BLOCKING = table exclue du run.';


--------------------------------------------------------------------------------
-- 5. Tables de travail (Global Temporary Tables)
--
-- Rôle    : supportent la stratégie de diagnostic décrite en architecture :
--           un hash de ligne par clé est calculé de CHAQUE côté et rapatrié
--           localement (pour B, via SYNC_LINK_B) dans ces GTT, PLUTÔT que de
--           faire une jointure distribuée coûteuse entre A et B en direct.
--           Seules les clés dont le hash diffère (ou n'existe que d'un côté)
--           déclenchent ensuite un rapatriement des colonnes complètes.
-- Choix   : ON COMMIT PRESERVE ROWS, et NON DELETE ROWS. Justification :
--           la stratégie transactionnelle retenue commite PAR GRAPPE, donc
--           plusieurs commits peuvent survenir AU SEIN d'un même run/session
--           avant que les tables de travail de la table suivante ne soient
--           nécessaires. PRESERVE ROWS évite que le contenu ne soit purgé au
--           premier commit de grappe. En contrepartie, le package DOIT purger
--           explicitement (DELETE ... WHERE RUN_ID = ...) les lignes d'un
--           RUN_ID donné une fois la table traitée, pour éviter toute
--           accumulation ou collision avec un run suivant dans la même
--           session (peu probable en usage batch mais à ne pas négliger).
-- Perf    : GTT = pas de génération de redo pour les données (uniquement pour
--           les blocs undo), pas de contention inter-sessions (segment privé
--           par session). Index locaux sur PK_HASH_KEY indispensables dès
--           que les tables synchronisées dépassent quelques dizaines de
--           milliers de lignes.
--------------------------------------------------------------------------------

CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_HASH_A (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,  -- SHA-256 hexadécimal de la clé canonique
    ROW_HASH        VARCHAR2(64)    NOT NULL   -- SHA-256 hexadécimal de la ligne canonique
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWHA_LOOKUP ON SYNC_WORK_HASH_A (RUN_ID, TABLE_NAME, PK_HASH_KEY);

CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_HASH_B (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,  -- SHA-256 hexadécimal de la clé canonique
    ROW_HASH        VARCHAR2(64)    NOT NULL   -- SHA-256 hexadécimal de la ligne canonique
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWHB_LOOKUP ON SYNC_WORK_HASH_B (RUN_ID, TABLE_NAME, PK_HASH_KEY);

COMMENT ON TABLE SYNC_WORK_HASH_A IS
    'GTT de travail : paires (cle, hash de ligne) rapatriees localement pour le cote A, par run.';
COMMENT ON TABLE SYNC_WORK_HASH_B IS
    'GTT de travail : paires (cle, hash de ligne) rapatriees localement (via SYNC_LINK_B) pour le cote B, par run.';


CREATE GLOBAL TEMPORARY TABLE SYNC_WORK_DIFF (
    RUN_ID          NUMBER          NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    PK_HASH_KEY     VARCHAR2(64)    NOT NULL,  -- SHA-256 hexadécimal de la clé canonique

    -- Classification issue de la comparaison SYNC_WORK_HASH_A / SYNC_WORK_HASH_B :
    -- INSERT_TO_A / INSERT_TO_B : présente d'un seul côté, à ajouter de l'autre
    -- UPDATE_TO_A / UPDATE_TO_B : présente des deux côtés, hash différent,
    --                             résolution déterminée (SOURCE_x_WINS ou
    --                             direction forcée), sens de propagation retenu
    -- CONFLICT                  : présente des deux côtés, hash différent,
    --                             BIDIRECTIONAL + ERROR_ON_CONFLICT -> non
    --                             appliqué, tracé dans SYNC_CONFLICT uniquement
    DIFF_TYPE       VARCHAR2(20)    NOT NULL,

    -- Sens réellement appliqué lors de la phase MERGE. NULL pour CONFLICT
    -- non résolu (ERROR_ON_CONFLICT).
    DIRECTION       VARCHAR2(10)
) ON COMMIT PRESERVE ROWS;

CREATE INDEX IX_SWD_LOOKUP ON SYNC_WORK_DIFF (RUN_ID, TABLE_NAME, DIFF_TYPE);

COMMENT ON TABLE SYNC_WORK_DIFF IS
    'GTT de travail : classification par cle apres comparaison des hash A/B, avant application des MERGE.';

--------------------------------------------------------------------------------
-- Fin Script 2
--------------------------------------------------------------------------------
