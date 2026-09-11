--------------------------------------------------------------------------------
-- SCRIPT 3 — SPECIFICATION DU PACKAGE PKG_SCHEMA_SYNC
-- A exécuter dans le schéma technique SYNC_ADMIN, après les Scripts 1 et 2.
--
-- Rappel des décisions d'architecture qui conditionnent cette spécification :
--   - SCHEMA_A = schéma local (même instance que SYNC_ADMIN, via synonymes/grants)
--   - SCHEMA_B = schéma distant, accédé exclusivement via le DB LINK SYNC_LINK_B
--   - Ces deux points d'ancrage sont FIXES (pas de paramètre p_schema_a/p_schema_b
--     à l'appel : cf. décision validée, évite qu'un appelant redirige
--     accidentellement la synchro vers d'autres schémas). Le nom exact des
--     schémas et du DB LINK est porté par des constantes de package (section
--     "Constantes d'environnement" ci-dessous), à adapter à l'installation.
--   - Aucune suppression n'est jamais propagée (SYNC_DELETE verrouillé à 'N').
--   - GENERATE_MERGE et INIT ne font PAS partie de l'API publique (retirés,
--     cf. décisions validées).
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_SCHEMA_SYNC AUTHID DEFINER AS

    --------------------------------------------------------------------------
    -- CONSTANTES D'ENVIRONNEMENT
    --
    -- A adapter obligatoirement à l'installation cible avant compilation.
    -- Volontairement en dur ici (et non en table de config) : ce sont des
    -- paramètres d'INFRASTRUCTURE (schéma/lien), pas des paramètres
    -- FONCTIONNELS de synchronisation — les modifier suppose une opération
    -- de ré-installation consciente, pas un simple UPDATE de table en
    -- production.
    --------------------------------------------------------------------------
    C_SCHEMA_A          CONSTANT VARCHAR2(128) := 'SCHEMA_A';
    C_SCHEMA_B          CONSTANT VARCHAR2(128) := 'SCHEMA_B';
    C_DB_LINK_B         CONSTANT VARCHAR2(128) := 'SYNC_LINK_B';

    --------------------------------------------------------------------------
    -- CONSTANTES FONCTIONNELLES
    --
    -- Exposées publiquement pour que l'appelant (et le code du package
    -- lui-même) ne manipule jamais de chaîne littérale en dur : évite les
    -- fautes de frappe silencieuses ('CONTINU' au lieu de 'CONTINUE' ne
    -- lèverait qu'une erreur de CHECK constraint tardive, PKG_SCHEMA_SYNC.
    -- C_ERROR_MODE_CONTINUE lève une erreur de compilation immédiate si mal
    -- orthographié).
    --------------------------------------------------------------------------

    -- Modes d'erreur (p_error_mode de SYNC_ALL)
    C_ERROR_MODE_CONTINUE      CONSTANT VARCHAR2(10) := 'CONTINUE';
    C_ERROR_MODE_STOP          CONSTANT VARCHAR2(10) := 'STOP';

    -- Statuts de run (SYNC_RUN_HEADER.STATUS)
    C_STATUS_IN_PROGRESS       CONSTANT VARCHAR2(30) := 'IN_PROGRESS';
    C_STATUS_SUCCESS           CONSTANT VARCHAR2(30) := 'SUCCESS';
    C_STATUS_SUCCESS_CONFLICTS CONSTANT VARCHAR2(30) := 'SUCCESS_WITH_CONFLICTS';
    C_STATUS_PARTIAL           CONSTANT VARCHAR2(30) := 'PARTIAL';
    C_STATUS_FAILED            CONSTANT VARCHAR2(30) := 'FAILED';

    -- Sens de synchronisation (SYNC_TABLE_CONFIG.SYNC_DIRECTION)
    C_DIRECTION_BIDIRECTIONAL  CONSTANT VARCHAR2(20) := 'BIDIRECTIONAL';
    C_DIRECTION_A_TO_B         CONSTANT VARCHAR2(20) := 'A_TO_B';
    C_DIRECTION_B_TO_A         CONSTANT VARCHAR2(20) := 'B_TO_A';
    C_DIRECTION_DISABLED       CONSTANT VARCHAR2(20) := 'DISABLED';

    -- Stratégies de résolution de conflit (SYNC_TABLE_CONFIG.CONFLICT_STRATEGY)
    -- NB : LAST_UPDATE_WINS volontairement absente (retirée du périmètre v1).
    C_CONFLICT_SOURCE_A_WINS       CONSTANT VARCHAR2(20) := 'SOURCE_A_WINS';
    C_CONFLICT_SOURCE_B_WINS       CONSTANT VARCHAR2(20) := 'SOURCE_B_WINS';
    C_CONFLICT_ERROR_ON_CONFLICT   CONSTANT VARCHAR2(20) := 'ERROR_ON_CONFLICT';

    -- Sévérité des anomalies de compatibilité (SYNC_COMPATIBILITY_REPORT.SEVERITY)
    C_SEVERITY_BLOCKING         CONSTANT VARCHAR2(10) := 'BLOCKING';
    C_SEVERITY_WARNING          CONSTANT VARCHAR2(10) := 'WARNING';


    --------------------------------------------------------------------------
    -- EXCEPTIONS PUBLIQUES
    --
    -- Plage -20000 à -20999 réservée à RAISE_APPLICATION_ERROR selon les
    -- conventions Oracle standard. Déclarées ici pour permettre à l'appelant
    -- de les intercepter nommément plutôt que par test de SQLCODE en dur.
    --------------------------------------------------------------------------

    -- Un des deux schémas (ou le DB LINK) est inaccessible ou n'existe pas.
    E_SCHEMA_NOT_ACCESSIBLE     EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_SCHEMA_NOT_ACCESSIBLE, -20001);

    -- La table demandée n'existe pas dans SYNC_TABLE_CONFIG, ou y est
    -- désactivée (ENABLED='N' / SYNC_DIRECTION='DISABLED') alors qu'un appel
    -- explicite SYNC_TABLE a été fait dessus.
    E_TABLE_NOT_CONFIGURED      EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_TABLE_NOT_CONFIGURED, -20002);

    -- Incompatibilité de structure BLOCKING détectée : la table ne peut pas
    -- être synchronisée tant que l'anomalie n'est pas corrigée. Voir
    -- SYNC_COMPATIBILITY_REPORT pour le détail.
    E_INCOMPATIBLE_STRUCTURE    EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_INCOMPATIBLE_STRUCTURE, -20003);

    -- Aucune clé de correspondance exploitable (ni PK/UNIQUE Oracle, ni
    -- SYNC_KEY_CONFIG, ou clé configurée mais non unique en pratique).
    E_NO_USABLE_KEY              EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_NO_USABLE_KEY, -20004);

    -- Cycle de dépendances FK détecté et non déferrable : la/les tables
    -- concernées sont automatiquement exclues du run (log en warning), cette
    -- exception n'est levée que si l'appelant force explicitement une seule
    -- table (SYNC_TABLE) appartenant à un cycle non résolu.
    E_FK_CYCLE_DETECTED           EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_FK_CYCLE_DETECTED, -20005);

    -- p_run_id inconnu passé à GET_RUN_STATUS.
    E_RUN_NOT_FOUND               EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_RUN_NOT_FOUND, -20006);


    --------------------------------------------------------------------------
    -- API PUBLIQUE
    --------------------------------------------------------------------------

    ----------------------------------------------------------------------
    -- SYNC_ALL
    --
    -- Synchronise toutes les tables actives de SYNC_TABLE_CONFIG
    -- (ENABLED='Y' et SYNC_DIRECTION != 'DISABLED'), dans l'ordre des
    -- grappes FK calculé dynamiquement.
    --
    -- Paramètres :
    --   p_dry_run     : TRUE = aucune écriture, uniquement diagnostic et
    --                   journalisation des opérations qui AURAIENT été
    --                   effectuées (SYNC_LOG et SYNC_WORK_DIFF renseignés,
    --                   aucun MERGE/INSERT/UPDATE réellement exécuté sur
    --                   les tables métier).
    --   p_error_mode  : C_ERROR_MODE_CONTINUE (défaut) ou C_ERROR_MODE_STOP.
    --                   En STOP, l'échec d'une grappe interrompt le
    --                   traitement des grappes suivantes ; les grappes déjà
    --                   commitées AVANT l'échec restent commitées (pas de
    --                   rollback global).
    --   p_run_id      : identifiant du run généré (SYNC_RUN_ID_SEQ), à
    --                   utiliser ensuite avec GET_RUN_STATUS.
    --
    -- Risque documenté : en cas d'exception non gérée en dehors de la boucle
    -- de traitement des grappes (erreur structurelle avant même le début du
    -- run, ex. schéma inaccessible), le run est marqué FAILED et l'exception
    -- est propagée à l'appelant après journalisation — jamais avalée.
    ----------------------------------------------------------------------
    PROCEDURE SYNC_ALL (
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_run_id        OUT NUMBER
    );

    ----------------------------------------------------------------------
    -- SYNC_TABLE
    --
    -- Synchronise une seule table, identifiée par son nom logique tel que
    -- déclaré dans SYNC_TABLE_CONFIG.TABLE_NAME. Utile pour un rattrapage
    -- ciblé ou un test unitaire, sans exécuter l'ensemble du périmètre.
    --
    -- Important : SYNC_TABLE respecte quand même l'appartenance de la table
    -- à une grappe FK. Si la table appartient à une grappe de plusieurs
    -- tables, SYNC_TABLE ne traite QUE la table demandée (pas les autres
    -- membres de sa grappe) — c'est un choix délibéré pour un rattrapage
    -- ciblé, mais cela peut introduire une incohérence FK transitoire si les
    -- autres tables de la grappe ne sont pas synchronisées en parallèle.
    -- A UTILISER AVEC PRUDENCE sur des tables fortement couplées ; préférer
    -- SYNC_ALL pour un traitement cohérent de grappe complète.
    --
    -- Lève E_TABLE_NOT_CONFIGURED si p_table_name n'existe pas dans
    -- SYNC_TABLE_CONFIG ou y est désactivée.
    ----------------------------------------------------------------------
    PROCEDURE SYNC_TABLE (
        p_table_name    IN  VARCHAR2,
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_run_id        OUT NUMBER
    );

    ----------------------------------------------------------------------
    -- CHECK_COMPATIBILITY
    --
    -- Compare les métadonnées (colonnes, types, tailles, précision, scale,
    -- nullable, clés) entre SCHEMA_A et SCHEMA_B pour une table donnée, ou
    -- pour toutes les tables de SYNC_TABLE_CONFIG si p_table_name est NULL.
    -- Persiste le résultat dans SYNC_COMPATIBILITY_REPORT (pas de fonction
    -- pipelined, cf. décision validée) et retourne l'identifiant du contrôle
    -- (p_check_id) permettant de retrouver les lignes correspondantes.
    --
    -- SYNC_ALL invoque systématiquement CHECK_COMPATIBILITY en tout début
    -- de run et exclut automatiquement toute table présentant au moins une
    -- anomalie SEVERITY=C_SEVERITY_BLOCKING (log explicite, la table n'est
    -- ni SUCCESS ni FAILED : elle est EXCLUDED, comptabilisée dans
    -- SYNC_RUN_HEADER.TABLES_EXCLUDED).
    --
    -- p_has_blocking_issues : sortie pratique pour un appel isolé (hors
    -- SYNC_ALL), évite à l'appelant de requêter SYNC_COMPATIBILITY_REPORT
    -- juste pour savoir s'il peut lancer une synchronisation en confiance.
    ----------------------------------------------------------------------
    PROCEDURE CHECK_COMPATIBILITY (
        p_table_name            IN  VARCHAR2 DEFAULT NULL,
        p_check_id              OUT NUMBER,
        p_has_blocking_issues   OUT BOOLEAN
    );

    ----------------------------------------------------------------------
    -- GET_RUN_STATUS
    --
    -- Restitue la synthèse d'un run (SYNC_RUN_HEADER) et le détail par
    -- table (SYNC_LOG) sous forme de deux curseurs ouverts, à consommer par
    -- l'appelant. Ne recalcule rien : lit uniquement les tables persistées
    -- (cf. décision validée "table de rapport persistée").
    --
    -- Lève E_RUN_NOT_FOUND si p_run_id ne correspond à aucun SYNC_RUN_HEADER.
    ----------------------------------------------------------------------
    PROCEDURE GET_RUN_STATUS (
        p_run_id            IN  NUMBER,
        p_header_cursor      OUT SYS_REFCURSOR,   -- une ligne : SYNC_RUN_HEADER du run
        p_detail_cursor      OUT SYS_REFCURSOR    -- N lignes : SYNC_LOG par table du run
    );

END PKG_SCHEMA_SYNC;
/

SHOW ERRORS PACKAGE PKG_SCHEMA_SYNC;

--------------------------------------------------------------------------------
-- Fin Script 3
--------------------------------------------------------------------------------
