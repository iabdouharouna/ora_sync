--------------------------------------------------------------------------------
-- SCRIPT 3 — SPECIFICATION DU PACKAGE PKG_SCHEMA_SYNC
-- A exécuter dans le schéma technique SYNC_ADMIN, après les Scripts 1 et 2.
--
-- Rappel des décisions d'architecture qui conditionnent cette spécification :
--   - SCHEMA_A = schéma local (même instance que SYNC_ADMIN, via synonymes/grants)
--   - SCHEMA_B = accédé via le DB LINK SYNC_LINK_B s'il est sur une instance
--     distincte, ou directement en local (grants directs, sans DB LINK) si
--     SCHEMA_A et SCHEMA_B partagent la même instance (C_DB_LINK_B = NULL
--     dans ce second cas, cf. section "Constantes d'environnement")
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

    -- C_DB_LINK_B : valeur PAR DEFAUT du nom de DB LINK utilisé pour accéder
    -- à SCHEMA_B, appliquée à l'initialisation de chaque session (cf. section
    -- d'initialisation en fin de PACKAGE BODY). Cette valeur par défaut reste
    -- un paramètre de compilation (modifier le comportement "par défaut"
    -- suppose toujours une ré-installation), MAIS elle peut désormais être
    -- SURCHARGEE A L'EXECUTION, sans recompilation, via :
    --   - PKG_SCHEMA_SYNC.SET_DB_LINK(p_db_link) : valable pour le reste de
    --     la SESSION Oracle courante (variable de package, pas une table) ;
    --   - le paramètre p_db_link, optionnel, de SYNC_ALL / SYNC_TABLE /
    --     CHECK_COMPATIBILITY : équivalent à un appel SET_DB_LINK juste avant,
    --     pratique pour un ajustement ponctuel en un seul appel.
    --   - Renseigner un nom (ex. 'SYNC_LINK_B') si SCHEMA_A et SCHEMA_B sont
    --     sur DEUX INSTANCES DISTINCTES.
    --   - NULL si SCHEMA_A et SCHEMA_B sont sur LA MÊME instance : toutes les
    --     références à SCHEMA_B en SQL dynamique omettent alors le suffixe
    --     '@...' (cf. fonctions privées b_link_suffix / b_table_ref dans le
    --     corps du package). SYNC_ADMIN doit dans ce cas disposer de grants
    --     locaux directs sur SCHEMA_B, exactement comme sur SCHEMA_A.
    --     Bénéfice induit : plus aucune transaction distribuée (2PC) ni
    --     risque de session in-doubt, la grappe entière restant purement
    --     locale à l'instance.
    -- ATTENTION (portée session) : SET_DB_LINK modifie une variable de
    -- package, dont la durée de vie est celle de la SESSION Oracle (pas de
    -- l'appel). Sur un pool de connexions partagé entre plusieurs contextes
    -- logiques, un SET_DB_LINK effectué par un appelant reste actif pour les
    -- appels suivants dans la MEME session tant qu'il n'est pas changé à
    -- nouveau — comportement voulu (le configurer une fois, pas à chaque
    -- appel), mais à garder en tête dans ce cas de figure.
    -- INSTALLATION COURANTE : SCHEMA_A, SCHEMA_B et SYNC_ADMIN sont colocalisés
    -- sur UNE MÊME instance (TPWCPROPRY) -> C_DB_LINK_B = NULL (mode "même
    -- instance" décrit ci-dessus, aucun suffixe '@...', aucune transaction
    -- distribuée). Remettre 'SYNC_LINK_B' (ou tout autre nom de lien) exige
    -- une ré-compilation consciente si les deux schémas étaient séparés.
    -- NB : ne PAS utiliser ici le DB LINK PUBLIC SYNC_LINK_B existant sur
    -- l'instance, qui est un lien partagé rattaché à un AUTRE compte
    -- (PCARDIMPFE) et n'a aucun rapport avec SCHEMA_B.
    C_DB_LINK_B         CONSTANT VARCHAR2(128) := NULL;  -- NULL = même instance

    -- Sentinelle utilisée comme valeur par défaut du paramètre p_db_link de
    -- SYNC_ALL / SYNC_TABLE / CHECK_COMPATIBILITY. Nécessaire car NULL a déjà
    -- un sens fonctionnel ("pas de DB LINK, même instance") : il faut donc un
    -- marqueur DISTINCT de NULL pour représenter "paramètre non renseigné,
    -- ne rien changer à la valeur courante". Ne jamais utiliser cette chaîne
    -- comme nom de DB LINK réel (improbable, mais à éviter explicitement).
    C_DB_LINK_KEEP_CURRENT  CONSTANT VARCHAR2(30) := '$$KEEP_CURRENT_DB_LINK$$';

    -- Sentinelle du paramètre p_sync_mode de SYNC_ALL / SYNC_TABLE /
    -- SYNC_TABLES ("mode non renseigné : utiliser le SYNC_MODE de chaque table").
    -- Distincte des trois modes fonctionnels ci-dessous, cf. C_DB_LINK_KEEP_CURRENT
    -- pour la même justification (NULL ne peut pas servir de sentinelle ici car il
    -- n'a pas de sens fonctionnel particulier).
    C_SYNC_MODE_KEEP_CURRENT  CONSTANT VARCHAR2(30) := '$$KEEP_CURRENT_SYNC_MODE$$';

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

    -- Mode des opérations appliquées (SYNC_TABLE_CONFIG.SYNC_MODE, ou
    -- p_sync_mode en override ponctuel de run) :
    --   INSERT  : seules les insertions sont appliquées.
    --   UPDATE  : seules les mises à jour sont appliquées.
    --   INSERT_UPDATE : les deux (comportement historique, défaut).
    C_SYNC_MODE_INSERT         CONSTANT VARCHAR2(20) := 'INSERT';
    C_SYNC_MODE_UPDATE         CONSTANT VARCHAR2(20) := 'UPDATE';
    C_SYNC_MODE_INSERT_UPDATE  CONSTANT VARCHAR2(20) := 'INSERT_UPDATE';

    -- Stratégies de résolution de conflit (SYNC_TABLE_CONFIG.CONFLICT_STRATEGY)
    -- NB : LAST_UPDATE_WINS volontairement absente (retirée du périmètre v1).
    C_CONFLICT_SOURCE_A_WINS       CONSTANT VARCHAR2(20) := 'SOURCE_A_WINS';
    C_CONFLICT_SOURCE_B_WINS       CONSTANT VARCHAR2(20) := 'SOURCE_B_WINS';
    C_CONFLICT_ERROR_ON_CONFLICT   CONSTANT VARCHAR2(20) := 'ERROR_ON_CONFLICT';

    -- Sévérité des anomalies de compatibilité (SYNC_COMPATIBILITY_REPORT.SEVERITY)
    C_SEVERITY_BLOCKING         CONSTANT VARCHAR2(10) := 'BLOCKING';
    C_SEVERITY_WARNING          CONSTANT VARCHAR2(10) := 'WARNING';

    -- Types d'anomalie liés aux cycles FK (SYNC_COMPATIBILITY_REPORT.ISSUE_TYPE)
    -- FK_CYCLE_DEFERRABLE     : cycle accepté, contraintes différées (WARNING)
    -- FK_CYCLE_NOT_DEFERRABLE : cycle non déferrable, grappe exclue (BLOCKING)
    C_ISSUE_FK_CYCLE_DEFERRABLE     CONSTANT VARCHAR2(30) := 'FK_CYCLE_DEFERRABLE';
    C_ISSUE_FK_CYCLE_NOT_DEFERRABLE CONSTANT VARCHAR2(30) := 'FK_CYCLE_NOT_DEFERRABLE';

    -- Types d'anomalie liés à la lignée FK hors périmètre configuré (v4) :
    -- FK_PARENT_ENROLLED : parent FK absent de SYNC_TABLE_CONFIG, enrôlé
    --                      automatiquement avec la lignée de ses ancêtres (WARNING)
    -- FK_PARENT_DISABLED : parent FK présent mais désactivé (ENABLED='N' ou
    --                      SYNC_DIRECTION='DISABLED'). Jamais forcé : l'ordre
    --                      parent -> enfant n'est pas garanti (WARNING)
    C_ISSUE_FK_PARENT_ENROLLED      CONSTANT VARCHAR2(30) := 'FK_PARENT_ENROLLED';
    C_ISSUE_FK_PARENT_DISABLED      CONSTANT VARCHAR2(30) := 'FK_PARENT_DISABLED';

    -- Types d'anomalie liés à l'auto-réparation FK dans SCHEMA_B (v5) :
    -- PARENT_BACKFILLED      : parent absent de B, re-inséré depuis A après un
    --                          ORA-02291 sur l'enfant (WARNING)
    -- FK_CHILD_RETRIED       : table enfant retentée après backfill (WARNING)
    -- FK_CYCLE_HANDLED_BY_DISABLE : cycle FK non déferrable, FK temporairement
    --                          désactivées côté B puis réactivées (WARNING)
    -- TABLE_CREATED_IN_B     : table active absente de B, créée en DDL depuis
    --                          les métadonnées de A (WARNING)
    -- PARENT_BACKFILL_FAILED : backfill impossible (parent indisponible dans A,
    --                          table parente absente de B...) (BLOCKING)
    -- FK_REPAIR_FAILED       : échec de réparation (désactivation/réactivation
    --                          d'une FK de cycle côté B) (BLOCKING)
    C_ISSUE_PARENT_BACKFILLED          CONSTANT VARCHAR2(30) := 'PARENT_BACKFILLED';
    C_ISSUE_FK_CHILD_RETRIED           CONSTANT VARCHAR2(30) := 'FK_CHILD_RETRIED';
    C_ISSUE_FK_CYCLE_HANDLED_BY_DISABLE CONSTANT VARCHAR2(30) := 'FK_CYCLE_HANDLED_BY_DISABLE';
    C_ISSUE_TABLE_CREATED_IN_B         CONSTANT VARCHAR2(30) := 'TABLE_CREATED_IN_B';
    C_ISSUE_PARENT_BACKFILL_FAILED     CONSTANT VARCHAR2(30) := 'PARENT_BACKFILL_FAILED';
    C_ISSUE_FK_REPAIR_FAILED           CONSTANT VARCHAR2(30) := 'FK_REPAIR_FAILED';

    -- Options globales de comportement du run (SYNC_RUN_OPTION)
    -- AUTO_BACKFILL_PARENTS    : 'Y'/'N' — backfill des parents manquants (v5)
    -- MAX_FK_RETRY             : nombre maximal de tentatives enfant après backfill
    -- CYCLE_HANDLING           : 'DISABLE_FK' (défaut, désactiv. temporaire des FK) / 'BLOCK'
    -- AUTO_CREATE_MISSING_TABLE: 'Y'/'N' — création automatique d'une table
    --                            active absente de SCHEMA_B (défaut 'N')
    C_OPT_AUTO_BACKFILL_PARENTS    CONSTANT VARCHAR2(64) := 'AUTO_BACKFILL_PARENTS';
    C_OPT_MAX_FK_RETRY             CONSTANT VARCHAR2(64) := 'MAX_FK_RETRY';
    C_OPT_CYCLE_HANDLING           CONSTANT VARCHAR2(64) := 'CYCLE_HANDLING';
    C_OPT_AUTO_CREATE_MISSING_TABLE CONSTANT VARCHAR2(64) := 'AUTO_CREATE_MISSING_TABLE';


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

    -- Paramètre d'appel invalide (p_error_mode hors CONTINUE/STOP,
    -- p_db_link non vide mais ne passant pas DBMS_ASSERT, p_keep_days <= 0...).
    E_INVALID_PARAMETER           EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_INVALID_PARAMETER, -20011);

    -- DDL à distance non supporté (v5, limite connue) : l'auto-réparation
    -- (auto-création d'une table dans SCHEMA_B, désactivation/réactivation
    -- d'une FK de cycle) exécute du DDL côté SCHEMA_B. Or un DDL ne peut pas
    -- traverser un DB LINK en PL/SQL natif : EXECUTE IMMEDIATE ne dispose
    -- d'aucune clause "AT <lien>" (syntaxe introuvable en 19c comme en 21c),
    -- et aucun mécanisme Oracle standard ne le permet. La branche distante
    -- de exec_ddl_at_b lève donc cette erreur, sans jamais exécuter partiellement
    -- le DDL. En pratique : passez C_DB_LINK_B / SET_DB_LINK à NULL (mode même
    -- instance), où l'auto-réparation fonctionne intégralement.
    E_REMOTE_DDL_UNSUPPORTED      EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_REMOTE_DDL_UNSUPPORTED, -20012);


    --------------------------------------------------------------------------
    -- API PUBLIQUE
    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- Type public de liste de tables logiques (noms dans SYNC_TABLE_CONFIG.
    -- TABLE_NAME), utilisé par SYNC_TABLES et par la surcharge LIST de
    -- CHECK_COMPATIBILITY.
    --------------------------------------------------------------------------
    TYPE t_tab_name_list IS TABLE OF VARCHAR2(128);

    ----------------------------------------------------------------------
    -- SET_DB_LINK
    --
    -- Rôle : définit, pour le reste de la SESSION Oracle courante, le nom du
    -- DB LINK utilisé pour accéder à SCHEMA_B — sans recompilation du
    -- package. Remplace la valeur par défaut C_DB_LINK_B tant que la session
    -- reste ouverte ou qu'un nouvel appel à SET_DB_LINK ne la change pas.
    --
    -- Paramètres :
    --   p_db_link : nom du DB LINK à utiliser (ex. 'SYNC_LINK_B_TEST'), ou
    --               NULL pour forcer explicitement le mode "même instance"
    --               (aucun DB LINK, accès local direct à SCHEMA_B).
    --
    -- A appeler une seule fois en début de session/job avant tout SYNC_ALL /
    -- SYNC_TABLE / CHECK_COMPATIBILITY si la valeur par défaut C_DB_LINK_B
    -- ne convient pas pour cet environnement. Sans appel à SET_DB_LINK (ni
    -- p_db_link renseigné sur les appels ci-dessous), la valeur compilée
    -- C_DB_LINK_B s'applique.
    ----------------------------------------------------------------------
    PROCEDURE SET_DB_LINK (
        p_db_link IN VARCHAR2
    );

    ----------------------------------------------------------------------
    -- GET_DB_LINK
    --
    -- Rôle : retourne la valeur ACTUELLEMENT active (pour la session en
    -- cours) du nom de DB LINK utilisé pour accéder à SCHEMA_B — NULL si le
    -- mode "même instance" est actif. Utile pour vérifier l'état courant
    -- avant un appel, ou à des fins de diagnostic/test.
    ----------------------------------------------------------------------
    FUNCTION GET_DB_LINK RETURN VARCHAR2;

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
    --   p_db_link     : optionnel. Si renseigné (différent de la sentinelle
    --                   C_DB_LINK_KEEP_CURRENT), équivaut à appeler
    --                   SET_DB_LINK(p_db_link) juste avant ce run — pratique
    --                   pour un ajustement ponctuel en un seul appel plutôt
    --                   que deux. Laissé à sa valeur par défaut, la valeur
    --                   actuellement définie pour la session (C_DB_LINK_B
    --                   par défaut, ou toute valeur déjà fixée par un appel
    --                   SET_DB_LINK précédent) s'applique sans changement.
    --   p_run_id      : identifiant du run généré (SYNC_RUN_ID_SEQ), à
    --                   utiliser ensuite avec GET_RUN_STATUS.
    --   p_sync_mode   : optionnel. Si renseigné (différent de la sentinelle
    --                   C_SYNC_MODE_KEEP_CURRENT), applique CE mode (INSERT /
    --                   UPDATE / INSERT_UPDATE) à TOUTES les tables du run, en
    --                   ignorant leur SYNC_MODE de configuration (sans
    --                   persistance : la colonne SYNC_TABLE_CONFIG.SYNC_MODE
    --                   n'est pas modifiée). Laissé à sa valeur par défaut,
    --                   chaque table suit son SYNC_MODE configuré.
    --
    -- Risque documenté : en cas d'exception non gérée en dehors de la boucle
    -- de traitement des grappes (erreur structurelle avant même le début du
    -- run, ex. schéma inaccessible), le run est marqué FAILED et l'exception
    -- est propagée à l'appelant après journalisation — jamais avalée.
    ----------------------------------------------------------------------
    PROCEDURE SYNC_ALL (
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_run_id        OUT NUMBER,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT
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
    --
    -- p_db_link : cf. SYNC_ALL — optionnel, override ponctuel équivalent à
    -- SET_DB_LINK(p_db_link) avant ce run.
    -- p_sync_mode : cf. SYNC_ALL — optionnel, override ponctuel du mode
    -- SYNC_MODE configuré pour cette table (sans persistance).
    ----------------------------------------------------------------------
    PROCEDURE SYNC_TABLE (
        p_table_name    IN  VARCHAR2,
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_run_id        OUT NUMBER,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT
    );

    ----------------------------------------------------------------------
    -- SYNC_TABLES
    --
    -- Synchronise une LISTE de tables (type public t_tab_name_list), avec
    -- RÉSOLUTION IMPLICITE DES DÉPENDANCES FK : l'ensemble exécuté = tables
    -- demandées ∪ fermeture transitive de leurs tables PARENTES (ancêtres
    -- via les contraintes FK de SCHEMA_A). Depuis la v4, les parents ABSENTS
    -- de SYNC_TABLE_CONFIG sont enrôlés AUTOMATIQUEMENT (enrôlement de la
    -- lignée complète, cf. CHECK_COMPATIBILITY) ; les parents PRÉSENTS MAIS
    -- DÉSACTIVÉS (ENABLED='N' ou SYNC_DIRECTION='DISABLED') ne sont jamais
    -- forcés : signalés WARNING (FK_PARENT_DISABLED), ils restent hors du
    -- périmètre exécuté.
    --
    -- Pourquoi : éviter ORA-02291 ("parent key not found") lors des
    -- insertions — insérer un enfant sans avoir synchronisé son parent peut
    -- violer la FK — et garantir un ordre topologique cohérent (parent avant
    -- enfant), exactement comme SYNC_ALL mais restreint au sous-ensemble.
    --
    -- Seuls les PARENTS sont ajoutés (pas les enfants) : la demande concerne
    -- un rattrapage ciblé, élargir aux descendants modifierait le périmètre
    -- au-delà de l'intention de l'appelant.
    --
    -- L'ensemble final est ensuite traité exactement comme SYNC_ALL :
    -- CHECK_COMPATIBILITY sur le sous-ensemble (un seul CHECK_ID), exclusion
    -- des tables BLOCKING, grappes FK / tri topologique / priorité moyenne,
    -- validation par grappe. RUN_TYPE de l'en-tête = 'SYNC_TABLES' ;
    -- TOTAL_TABLES/TABLES_EXCLUDED portent sur l'ensemble exécuté (demandées
    -- + parents), afin que le compte du run reste cohérent avec ce qui a
    -- réellement été traité.
    --
    -- Lève E_TABLE_NOT_CONFIGURED si une table de la liste n'existe pas dans
    -- SYNC_TABLE_CONFIG ou y est désactivée, et E_INVALID_PARAMETER si la
    -- liste est vide ou si p_sync_mode est inconnu.
    --
    -- p_dry_run / p_error_mode / p_db_link / p_sync_mode : cf. SYNC_ALL.
    ----------------------------------------------------------------------
    PROCEDURE SYNC_TABLES (
        p_table_list    IN  t_tab_name_list,
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT,
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
    --
    -- p_db_link : cf. SYNC_ALL — optionnel, override ponctuel équivalent à
    -- SET_DB_LINK(p_db_link) avant ce contrôle.
    --
    -- v4 (surcharge p_table_name = NULL uniquement) : le contrôle enrôle
    -- automatiquement la LIGNÉE FK des tables actives — fermeture transitive
    -- côté SCHEMA_A — puis valide chaque ancêtre dans le MÊME CHECK_ID et
    -- PERSISTE l'enrôlement (COMMIT). Les parents absents sont ajoutés à
    -- SYNC_TABLE_CONFIG (profil AUTO_FK_LINEAGE, direction héritée de
    -- l'enfant, WARNING FK_PARENT_ENROLLED) ; les parents présents mais
    -- désactivés sont signalés sans forçage (WARNING FK_PARENT_DISABLED).
    -- Les surcharges mono-table et LISTE restent NON mutantes.
    ----------------------------------------------------------------------
    PROCEDURE CHECK_COMPATIBILITY (
        p_table_name            IN  VARCHAR2 DEFAULT NULL,
        p_db_link               IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_check_id              OUT NUMBER,
        p_has_blocking_issues   OUT BOOLEAN
    );

    ----------------------------------------------------------------------
    -- CHECK_COMPATIBILITY (surcharge LISTE)
    --
    -- Même contrôle, restreint à une LISTE explicite de tables (type public
    -- t_tab_name_list). Un seul CHECK_ID regroupe les anomalies des tables de
    -- la liste. Le contrôle porte sur les tables données TELLES QUELLES
    -- (aucune exigence d'activation dans SYNC_TABLE_CONFIG : utile pour
    -- pré-valider une table même non encore configurée).
    --
    -- p_db_link : cf. SYNC_ALL — optionnel, override ponctuel équivalent à
    -- SET_DB_LINK(p_db_link) avant ce contrôle.
    ----------------------------------------------------------------------
    PROCEDURE CHECK_COMPATIBILITY (
        p_table_list            IN  t_tab_name_list,
        p_db_link               IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
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

    ----------------------------------------------------------------------
    -- PURGE_HISTORY
    --
    -- Rôle : purge de maintenance des tables d'audit dont la volumétrie
    --        croît avec le nombre de runs : SYNC_CONFLICT,
    --        SYNC_COMPATIBILITY_REPORT et SYNC_LOG+SYNC_RUN_HEADER.
    --        Inspiré de la limite signalée dans le Script 2 ("purge/rétention
    --        à prévoir en exploitation"), ici automatisée.
    --
    -- Paramètres :
    --   p_keep_days : âge (jours) en-deçà duquel les enregistrements sont
    --                 CONSERVÉS ; tout ce qui est strictement antérieur à
    --                 (SYSTIMESTAMP - p_keep_days) est supprimé.
    --                 p_keep_days <= 0 est rejeté (E_INVALID_PARAMETER) :
    --                 une suppression totale doit être une décision explicite
    --                 hors de ce mode de maintenance.
    --
    -- Base de purge : SYNC_CONFLICT  -> RESOLVED_DATE
    --                 SYNC_COMPATIBILITY_REPORT -> CHECK_DATE
    --                 SYNC_LOG       -> START_DATE (puis SYNC_RUN_HEADER dont
    --                                   plus aucune ligne SYNC_LOG ne dépend)
    --
    -- Exemple : PURGE_HISTORY(90) supprime tout ce qui précède les 90
    -- derniers jours.
    ----------------------------------------------------------------------
    PROCEDURE PURGE_HISTORY (
        p_keep_days IN NUMBER
    );

    ----------------------------------------------------------------------
    -- SET_RUN_OPTION / GET_RUN_OPTION (v5)
    --
    -- Lecture/écriture des options globales de comportement du run
    -- (table SYNC_RUN_OPTION) :
    --    AUTO_BACKFILL_PARENTS     : 'Y'/'N' — backfill des parents manquants
    --    MAX_FK_RETRY              : nombre maximal de tentatives enfant après backfill
    --    CYCLE_HANDLING            : 'DISABLE_FK' / 'BLOCK'
    --    AUTO_CREATE_MISSING_TABLE : 'Y'/'N' — auto-création d'une table
    --                                active absente de SCHEMA_B (défaut 'N')
    --
    -- SET_RUN_OPTION valide le nom ET la valeur (E_INVALID_PARAMETER sinon) :
    --      AUTO_BACKFILL_PARENTS / AUTO_CREATE_MISSING_TABLE : 'Y' ou 'N'
    --      CYCLE_HANDLING  : 'DISABLE_FK' ou 'BLOCK'
    --      MAX_FK_RETRY    : entier positif (1..9999999999)
    -- La contrainte CK_SRO_VALUE applique la même règle en base ("défense en
    -- profondeur"). GET_RUN_OPTION renvoie la valeur courante, ou NULL si
    -- l'option/champ est vide.
    ----------------------------------------------------------------------
    PROCEDURE SET_RUN_OPTION (
        p_option_name  IN VARCHAR2,
        p_option_value IN VARCHAR2
    );

    FUNCTION GET_RUN_OPTION (p_option_name IN VARCHAR2) RETURN VARCHAR2;

    ----------------------------------------------------------------------
    -- SECTION « ÉTAT D'ÉCART SCHÉMA (STATS) » — v6
    --
    -- Offre un état des écarts de volumétrie entre SCHEMA_A et SCHEMA_B à
    -- l'échelle du schéma, établi à partir des statistiques Oracle
    -- (NUM_ROWS de l'optimiseur, niveau table), dont la fraîcheur est
    -- garantie par une collecte EXPLICITE préalable des stats sur les deux
    -- schémas (jobs DBMS_SCHEDULER lancés par SUBMIT_STATS_JOBS,
    -- surveillés par ARE_STATS_JOBS_DONE / WAIT_FOR_STATS_JOBS).
    --
    -- Périmètre  : tables de base (TEMP='N') présentes dans les DEUX schémas.
    -- NB (limite assumée, documentée) : NUM_ROWS est une ESTIMATION de
    -- l'optimiseur, pas un COUNT(*) exact — l'écart rapporté est donc
    -- « statistique », pas une photo de la donnée à l'instant T.
    --
    -- Workflow type (asynchrone, hors pic d'activité) :
    --   1) SUBMIT_STATS_JOBS  -> 2 jobs de collecte lancés en arrière-plan ;
    --   2) WAIT_FOR_STATS_JOBS (ou sondage ARE_STATS_JOBS_DONE) ;
    --   3) REPORT_COUNTS_GAP  -> rapport persistant (SYNC_STATS_GAP et
    --      SYNC_STATS_GAP_DETAIL) + deux REF CURSOR (en-tête, détail) ; le
    --      dernier rapport reste aussi consultable via GET_LAST_GAP_ID.
    --   La purge d'anciens rapports est intégrée à PURGE_HISTORY.
    ----------------------------------------------------------------------

    -- GAP_FLAG (SYNC_STATS_GAP_DETAIL.GAP_FLAG) :
    --   DIFF          : comptes estimés différents (NUM_ROWS_A != NUM_ROWS_B)
    --   NO_STATS_A    : stats absentes côté A (NUM_ROWS_A NULL) — exclue du
    --                   calcul DIFF/TABLES_GAP, comptée dans le TOTAL/TABLES_
    --                   NO_STATS_* de l'en-tête
    --   NO_STATS_B    : idem côté B
    --   NO_STATS_BOTH : stats absentes des deux côtés
    C_GAP_FLAG_DIFF          CONSTANT VARCHAR2(13) := 'DIFF';
    C_GAP_FLAG_NO_STATS_A    CONSTANT VARCHAR2(13) := 'NO_STATS_A';
    C_GAP_FLAG_NO_STATS_B    CONSTANT VARCHAR2(13) := 'NO_STATS_B';
    C_GAP_FLAG_NO_STATS_BOTH CONSTANT VARCHAR2(13) := 'NO_STATS_BOTH';

    -- Statuts renvoyés par GET_STATS_JOB_STATUS / WAIT_FOR_STATS_JOBS :
    C_JOB_STATUS_SUCCEEDED   CONSTANT VARCHAR2(30) := 'SUCCEEDED';
    C_JOB_STATUS_RUNNING     CONSTANT VARCHAR2(30) := 'RUNNING';
    C_JOB_STATUS_SCHEDULED   CONSTANT VARCHAR2(30) := 'SCHEDULED';
    C_JOB_STATUS_FAILED      CONSTANT VARCHAR2(30) := 'FAILED';
    C_JOB_STATUS_NOT_FOUND   CONSTANT VARCHAR2(30) := 'NOT_FOUND';

    -- Levée par REPORT_COUNTS_GAP quand p_max_age_hours est renseigné et que
    -- les stats sont absentes ou trop anciennes de l'un des deux côtés.
    E_STATS_NOT_FRESH        EXCEPTION;
    PRAGMA EXCEPTION_INIT (E_STATS_NOT_FRESH, -20013);

    ----------------------------------------------------------------------
    -- SUBMIT_STATS_JOBS
    --
    -- Crée (si absent) puis LANCE immédiatement deux jobs DBMS_SCHEDULER
    -- de collecte des statistiques de schéma (GATHER_SCHEMA_STATS), un par
    -- côté. La collecte est ASYNCHRONE : la procédure retourne dès le
    -- lancement des jobs (auto_drop => TRUE : chaque job disparaît de
    -- USER_SCHEDULER_JOBS après son exécution, seuls les historiques de
    -- runs restent consultables).
    --
    -- Paramètres :
    --   p_schema_a   : schéma "côté A" (défaut : C_SCHEMA_A).
    --   p_schema_b   : schéma "côté B" (défaut : C_SCHEMA_B) — la collecte
    --                  v1 n'est supportée qu'en mode "même instance"
    --                  (C_DB_LINK_B NULL) : dans un déploiement multi-
    --                  instances, lancer la collecte des stats du schéma B
    --                  dans la session de suivi de B (le rapport, lui, sait
    --                  lire les stats distantes via le DB LINK).
    --   p_job_name_a / p_job_name_b : noms effectifs des jobs (à conserver
    --                  pour ARE_STATS_JOBS_DONE / WAIT_FOR_STATS_JOBS).
    --
    -- Privilèges requis (Script 15) : ANALYZE ANY, CREATE JOB, EXECUTE sur
    -- DBMS_STATS et DBMS_SCHEDULER.
    ----------------------------------------------------------------------
    PROCEDURE SUBMIT_STATS_JOBS (
        p_schema_a      IN  VARCHAR2 DEFAULT C_SCHEMA_A,
        p_schema_b      IN  VARCHAR2 DEFAULT C_SCHEMA_B,
        p_job_name_a    OUT VARCHAR2,
        p_job_name_b    OUT VARCHAR2
    );

    ----------------------------------------------------------------------
    -- GET_STATS_JOB_STATUS
    --
    -- Retourne l'état d'un job de collecte : SUCCEEDED / RUNNING / SCHEDULED /
    -- FAILED, ou NOT_FOUND si le job est inconnu (jamais lancé, ou historique
    -- de runs vidé). Après auto_drop, l'état est relu dans l'historique des
    -- runs (USER_SCHEDULER_JOB_RUN_DETAILS) : un job correctement terminé
    -- reste SUCCEEDED même s'il n'existe plus dans USER_SCHEDULER_JOBS.
    ----------------------------------------------------------------------
    FUNCTION GET_STATS_JOB_STATUS (
        p_job_name IN VARCHAR2
    ) RETURN VARCHAR2;

    ----------------------------------------------------------------------
    -- ARE_STATS_JOBS_DONE
    --
    -- TRUE si les DEUX collectes sont terminées avec succès (statut
    -- SUCCEEDED des deux côtés). Retourne FALSE tant qu'au moins l'une des
    -- deux est en cours, planifiée, en échec ou introuvable.
    ----------------------------------------------------------------------
    FUNCTION ARE_STATS_JOBS_DONE (
        p_job_name_a IN VARCHAR2,
        p_job_name_b IN VARCHAR2
    ) RETURN BOOLEAN;

    ----------------------------------------------------------------------
    -- WAIT_FOR_STATS_JOBS
    --
    -- Attend la fin des DEUX collectes en sondant ARE_STATS_JOBS_DONE à
    -- intervalle régulier (DBMS_LOCK.SLEEP, tous les 5 s), borné par
    -- p_timeout_sec — solution portable : DBMS_SCHEDULER.WAIT_FOR n'est pas
    -- disponible sur toutes les distributions Oracle.
    --
    -- Paramètres :
    --   p_job_name_a / p_job_name_b : noms rendus par SUBMIT_STATS_JOBS.
    --   p_timeout_sec   : temps d'attente maximal (défaut 3600 s) ; l'attente
    --                     s'interrompt plus tôt dès que les deux jobs sont
    --                     dans un état final (SUCCEEDED/FAILED/NOT_FOUND).
    --   p_all_succeeded : TRUE si les deux jobs se sont terminés en
    --                     SUCCEEDED ; FALSE sinon (échec ou dépassement du
    --                     délai — examiner GET_STATS_JOB_STATUS).
    ----------------------------------------------------------------------
    PROCEDURE WAIT_FOR_STATS_JOBS (
        p_job_name_a    IN  VARCHAR2,
        p_job_name_b    IN  VARCHAR2,
        p_timeout_sec   IN  NUMBER   DEFAULT 3600,
        p_all_succeeded OUT BOOLEAN
    );

    ----------------------------------------------------------------------
    -- REPORT_COUNTS_GAP
    --
    -- Génère le rapport d'écart de volumétrie A/B sur la base des stats
    -- COURANTES (à collecter en amont via SUBMIT_STATS_JOBS). Le rapport
    -- est PERSISTÉ (SYNC_STATS_GAP + SYNC_STATS_GAP_DETAIL, séquences
    -- dédiées) puis COMMITé — deux REF CURSOR sont rendus à l'appelant pour
    -- affichage immédiat (en-tête + détail), le rapport restant consultable
    -- ensuite via GET_LAST_GAP_ID / les tables.
    --
    -- Détermination des écarts (côtés A et B, niveau table — partition_name
    -- IS NULL, object_type = 'TABLE') :
    --   * tables présentes des DEUX côtés : périmètre du rapport (TOTAL) ;
    --   * NUM_ROWS A/B          : ALL_TAB_STATISTICS (estimation optimiseur) ;
    --   * DIFF  = ABS(A - B) ; DIFF_PCT = DIFF * 100 / GREATEST(A, B) ;
    --   * NUM_ROWS absent d'un côté : anomalie NO_STATS_* (hors calcul des
    --     écarts, comptée dans l'en-tête).
    -- Fraîcheur : p_max_age_hours non NULL et stats d'un côté absentes ou
    -- plus anciennes que (SYSTIMESTAMP - p_max_age_hours) -> E_STATS_NOT_FRESH.
    --
    -- Paramètres :
    --   p_schema_a / p_schema_b : schémas comparés (défauts C_SCHEMA_A/B).
    --   p_job_name_a / p_job_name_b : (optionnels) noms des jobs de collecte,
    --                  reportés dans l'en-tête pour traçabilité.
    --   p_max_age_hours : fraîcheur maximale acceptée des stats (optionnel).
    --   p_gap_id        : identifiant du rapport généré.
    --   p_header_cursor : ligne de SYNC_STATS_GAP (en-tête + totaux).
    --   p_detail_cursor : lignes de SYNC_STATS_GAP_DETAIL (anomalies
    --                     uniquement), triées DIFF DESC puis TABLE_NAME.
    ----------------------------------------------------------------------
    PROCEDURE REPORT_COUNTS_GAP (
        p_schema_a      IN  VARCHAR2 DEFAULT C_SCHEMA_A,
        p_schema_b      IN  VARCHAR2 DEFAULT C_SCHEMA_B,
        p_job_name_a    IN  VARCHAR2 DEFAULT NULL,
        p_job_name_b    IN  VARCHAR2 DEFAULT NULL,
        p_max_age_hours IN  NUMBER   DEFAULT NULL,
        p_gap_id        OUT NUMBER,
        p_header_cursor OUT SYS_REFCURSOR,
        p_detail_cursor OUT SYS_REFCURSOR
    );

    ----------------------------------------------------------------------
    -- GET_LAST_GAP_ID
    --
    -- Retourne le GAP_ID du rapport le plus récent (MAX de SYNC_STATS_GAP),
    -- ou NULL si aucun rapport n'a encore été généré. Permet de re-consulter
    -- à tout moment le dernier état d'écart sans le régénérer.
    ----------------------------------------------------------------------
    FUNCTION GET_LAST_GAP_ID RETURN NUMBER;

END PKG_SCHEMA_SYNC;
/

SHOW ERRORS PACKAGE PKG_SCHEMA_SYNC;

--------------------------------------------------------------------------------
-- Fin Script 3
--------------------------------------------------------------------------------