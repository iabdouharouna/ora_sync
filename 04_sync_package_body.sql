--------------------------------------------------------------------------------
-- SCRIPT 4 — CORPS DU PACKAGE PKG_SCHEMA_SYNC
-- Fichier fusionné et autonome : compilable directement.
-- Prérequis : Scripts 1 à 3 exécutés (tables, séquences, spécification),
--             constantes de spécification adaptées à l'installation
--             (C_SCHEMA_A, C_SCHEMA_B, C_DB_LINK_B).
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE BODY PKG_SCHEMA_SYNC AS

    --------------------------------------------------------------------------
    -- TYPES PRIVES
    --------------------------------------------------------------------------

    TYPE t_str_tab IS TABLE OF VARCHAR2(128) INDEX BY PLS_INTEGER;

    -- Une ligne = une colonne effectivement synchronisée (présente des deux
    -- côtés, non exclue par SYNC_COLUMN_CONFIG, type supporté).
    TYPE t_column_rec IS RECORD (
        column_name     VARCHAR2(128),
        data_type       VARCHAR2(128),
        data_length     NUMBER,
        data_precision  NUMBER,
        data_scale      NUMBER,
        nullable        VARCHAR2(1),
        is_lob          BOOLEAN
    );
    TYPE t_column_tab IS TABLE OF t_column_rec INDEX BY PLS_INTEGER;

    -- Index par nom de colonne : permet de retrouver le type/métadonnée d'une
    -- colonne (dont les colonnes de clé, cf. hachage canonique NLS-dependent)
    -- sans relire le dictionnaire.
    TYPE t_coltype_tab IS TABLE OF t_column_rec INDEX BY VARCHAR2(128);

    -- Une ligne = une colonne comparée entre A et B (CHECK_COMPATIBILITY /
    -- découverte des colonnes synchronisées).
    TYPE t_col_compare_rec IS RECORD (
        column_name         VARCHAR2(128),
        a_data_type         VARCHAR2(128),
        a_data_length       NUMBER,
        a_data_precision    NUMBER,
        a_data_scale        NUMBER,
        a_nullable          VARCHAR2(1),
        a_type_owner        VARCHAR2(128),
        b_data_type         VARCHAR2(128),
        b_data_length       NUMBER,
        b_data_precision    NUMBER,
        b_data_scale        NUMBER,
        b_nullable          VARCHAR2(1),
        b_type_owner        VARCHAR2(128)
    );
    TYPE t_col_compare_tab IS TABLE OF t_col_compare_rec INDEX BY PLS_INTEGER;

    -- Une arête du graphe FK (parent -> child), pour l'ordonnancement des grappes.
    TYPE t_fk_edge_rec IS RECORD (
        parent_table    VARCHAR2(128),  -- table référencée (traitée AVANT child en INSERT)
        child_table     VARCHAR2(128),  -- table portant la FK
        deferrable_flag VARCHAR2(14)    -- 'DEFERRABLE' / 'NOT DEFERRABLE'
    );
    TYPE t_fk_edge_tab IS TABLE OF t_fk_edge_rec INDEX BY PLS_INTEGER;

    -- Une arête FK complète (v5 : backfill et réparation de cycles) -> types
    --                                                               détaillés
    TYPE t_fk_ref_col IS RECORD (
        child_column    VARCHAR2(128),  -- colonne locale portant la FK
        parent_column   VARCHAR2(128)   -- colonne référencée chez le parent
    );
    TYPE t_fk_ref_col_tab IS TABLE OF t_fk_ref_col INDEX BY PLS_INTEGER;
    TYPE t_fk_ref_rec IS RECORD (
        constraint_name VARCHAR2(128),
        parent_table    VARCHAR2(128),  -- table référencée
        deferrable      VARCHAR2(14),   -- 'DEFERRABLE' / 'NOT DEFERRABLE'
        cols            t_fk_ref_col_tab,
        child_nullable  BOOLEAN         -- VRAI si TOUTES les colonnes locales de la FK sont NULLABLE
    );
    TYPE t_fk_ref_tab IS TABLE OF t_fk_ref_rec INDEX BY PLS_INTEGER;

    -- Table enregistrée comme visitée lors d'un parcours (backfill).
    TYPE t_presence_map IS TABLE OF NUMBER INDEX BY VARCHAR2(128);

    -- Une table ordonnée dans sa grappe FK (cluster_id + ordre topologique).
    TYPE t_cluster_table_rec IS RECORD (
        cluster_id  NUMBER,
        table_name  VARCHAR2(128),
        topo_order  NUMBER            -- ordre d'application (INSERT) au sein de la grappe
    );
    TYPE t_cluster_table_tab IS TABLE OF t_cluster_table_rec INDEX BY PLS_INTEGER;

    -- Métadonnées d'une grappe FK (priorité moyenne, deferrable, exclusion).
    TYPE t_cluster_meta_rec IS RECORD (
        cluster_id          NUMBER,
        avg_priority         NUMBER,
        requires_deferred    BOOLEAN,
        requires_cycle_disable BOOLEAN,   -- v5 : cycle non déferrable à traiter par DISABLE_FK
        excluded              BOOLEAN,
        exclusion_reason      VARCHAR2(4000)
    );
    TYPE t_cluster_meta_tab IS TABLE OF t_cluster_meta_rec INDEX BY PLS_INTEGER;

    -- Liste d'indices/numériques (tri des grappes, ordonnancement).
    TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    --------------------------------------------------------------------------
    -- CONSTANTES PRIVEES
    --------------------------------------------------------------------------

    -- Types explicitement non supportés (décision validée). Toute colonne de
    -- ce type est automatiquement exclue de la synchronisation et signalée
    -- en WARNING (pas BLOCKING : la table reste synchronisable sur ses
    -- autres colonnes) sauf si elle fait partie de la clé, auquel cas c'est
    -- BLOCKING (une clé ne peut pas reposer sur un type non comparable).
    C_UNSUPPORTED_TYPES CONSTANT SYS.ODCIVARCHAR2LIST :=
        SYS.ODCIVARCHAR2LIST('LONG', 'LONG RAW');
    -- NB : les types objet, VARRAY et XMLTYPE ne portent pas un DATA_TYPE
    -- litteral stable dans ALL_TAB_COLUMNS (DATA_TYPE='XMLTYPE' pour XMLType
    -- mais 'RAW'/nom du type objet pour les autres selon le cas) ; ils sont
    -- détectés séparément via TYPECODE dans ALL_TAB_COLUMNS/ALL_TYPES lors
    -- de la découverte des colonnes (cf. partie 2), pas par cette simple
    -- liste de noms.


    --------------------------------------------------------------------------
    -- VARIABLE DE PACKAGE (état de session)
    --
    -- g_db_link_b : valeur EFFECTIVE, pour la session Oracle courante, du nom
    -- de DB LINK utilisé pour accéder à SCHEMA_B (NULL = même instance,
    -- accès local direct). Initialisée à C_DB_LINK_B (valeur compilée) par
    -- la section d'initialisation du package body (tout en bas de ce
    -- fichier), puis modifiable à l'exécution via SET_DB_LINK ou le
    -- paramètre p_db_link de SYNC_ALL/SYNC_TABLE/CHECK_COMPATIBILITY — sans
    -- aucune recompilation. C'est CETTE variable que tout le reste du corps
    -- du package doit référencer, JAMAIS directement la constante
    -- C_DB_LINK_B (qui ne représente plus que la valeur par défaut au
    -- démarrage de la session).
    --------------------------------------------------------------------------
    g_db_link_b VARCHAR2(128) := C_DB_LINK_B;


    --------------------------------------------------------------------------
    -- DECLARATIONS FORWARD (v4)
    --
    -- build_fk_ancestors_raw et enroll_fk_lineage sont implémentés plus bas
    -- (partie "expansion / enrôlement de la lignée FK"), mais référencés DÈS
    -- compat_check_core et CHECK_COMPATIBILITY(NULL) : déclaration anticipée
    -- obligatoire en PL/SQL (définition plus bas, dans le même body).
    --------------------------------------------------------------------------
    FUNCTION build_fk_ancestors_raw(p_tables IN t_str_tab) RETURN t_str_tab;

    PROCEDURE enroll_fk_lineage(
        p_check_id      IN  NUMBER,
        p_ancestors     IN  t_str_tab,
        p_enrolled      OUT NUMBER
    );


    --------------------------------------------------------------------------
    -- sanitize_ident
    --
    -- Rôle    : point de passage OBLIGATOIRE pour tout identifiant (nom de
    --           schéma, table, colonne) injecté ensuite dans du SQL
    --           dynamique. Utilise DBMS_ASSERT.SIMPLE_SQL_NAME plutôt que
    --           SQL_OBJECT_NAME : ce dernier exige que l'appelant ait un
    --           privilège de visibilité direct sur l'objet nommé, ce qui
    --           n'est pas toujours vérifiable simplement pour un objet
    --           distant qualifié par DB LINK. SIMPLE_SQL_NAME garantit que
    --           la chaîne est un identifiant SQL syntaxiquement valide et
    --           sans caractère d'échappement/injection, ce qui est le risque
    --           réellement visé ici (les noms proviennent du dictionnaire
    --           Oracle ou de tables de configuration modifiables par des
    --           opérateurs, jamais directement d'un utilisateur final, mais
    --           on ne fait confiance à aucune des deux sources sans
    --           validation).
    -- Risques : NE PROTEGE PAS contre un nom syntaxiquement valide mais
    --           sémantiquement incorrect (ex. une table de config pointant
    --           vers la mauvaise table) — ce n'est pas son rôle. La
    --           validation d'EXISTENCE de l'objet est faite séparément par
    --           les fonctions de découverte de métadonnées (interrogation
    --           positive de ALL_TAB_COLUMNS), pas par sanitize_ident.
    --------------------------------------------------------------------------
    FUNCTION sanitize_ident(p_ident IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_ASSERT.SIMPLE_SQL_NAME(p_ident);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(
                -20010,
                'Identifiant SQL invalide ou potentiellement dangereux : [' || p_ident || ']'
            );
    END sanitize_ident;


    --------------------------------------------------------------------------
    -- sql_literal
    --
    -- Rôle : retourne la représentation SQL d'une constante littérale,
    --        quotes simples échappées comprises. Permet d'injecter des
    --        littéraux dans du SQL dynamique sans se battre avec l'échappement
    --        des apostrophes à la main (typiquement les chaînes NLS et les
    --        séparateurs '~~').
    --------------------------------------------------------------------------
    FUNCTION sql_literal(p_value IN VARCHAR2) RETURN VARCHAR2 IS
        v_q CHAR(1) := '''';
    BEGIN
        RETURN v_q || REPLACE(p_value, v_q, v_q || v_q) || v_q;
    END sql_literal;


    --------------------------------------------------------------------------
    -- get_col_type_map
    --
    -- Rôle : charge, pour une table locale (SCHEMA_A), une map colonne ->
    --        métadonnée (type, taille, précision, nullable, is_lob). Utilisée
    --        par le hachage canonique pour choisir le masque NLS par type.
    --        Le hachage d'une table donnée est généré à l'identique des deux
    --        côtés : les types A font référence, B est supposé structurellement
    --        identique (garanti par CHECK_COMPATIBILITY avant tout run).
    --------------------------------------------------------------------------
    FUNCTION get_col_type_map(p_table_name IN VARCHAR2) RETURN t_coltype_tab IS
        v_map t_coltype_tab;
        v_tab VARCHAR2(128) := sanitize_ident(p_table_name);
    BEGIN
        FOR c IN (
            SELECT column_name, data_type, data_length, data_precision, data_scale, nullable
            FROM ALL_TAB_COLUMNS
            WHERE owner = C_SCHEMA_A AND table_name = v_tab
        ) LOOP
            v_map(c.column_name).column_name    := c.column_name;
            v_map(c.column_name).data_type      := c.data_type;
            v_map(c.column_name).data_length    := c.data_length;
            v_map(c.column_name).data_precision := c.data_precision;
            v_map(c.column_name).data_scale     := c.data_scale;
            v_map(c.column_name).nullable       := c.nullable;
            v_map(c.column_name).is_lob         := c.data_type IN ('CLOB', 'BLOB', 'NCLOB');
        END LOOP;
        RETURN v_map;
    END get_col_type_map;


    --------------------------------------------------------------------------
    -- type_map_from_columns
    --
    -- Rôle : variante de get_col_type_map construite à partir d'une collection
    --        t_column_tab déjà en main (ex. p_columns de get_sync_columns) :
    --        évite une relecture du dictionnaire quand les métadonnées ont
    --        déjà été chargées.
    --------------------------------------------------------------------------
    FUNCTION type_map_from_columns(p_columns IN t_column_tab) RETURN t_coltype_tab IS
        v_map t_coltype_tab;
    BEGIN
        FOR i IN 1 .. p_columns.COUNT LOOP
            v_map(p_columns(i).column_name) := p_columns(i);
        END LOOP;
        RETURN v_map;
    END type_map_from_columns;


    --------------------------------------------------------------------------
    -- canonical_scalar_expr
    --
    -- Rôle : normalize une colonne scalaire en une chaîne REPRODUCTIBLE entre
    --        A et B, indépendante des paramètres NLS de session :
    --          - DATE                -> masque 'YYYY-MM-DD HH24:MI:SS'
    --          - TIMESTAMP*          -> masque avec fractions de seconde (et
    --                                    fuseau pour WITH TIME ZONE)
    --          - NUMBER/FLOAT        -> TM9 + NLS_NUMERIC_CHARACTERS forcé
    --          - RAW                 -> RAWTOHEX
    --          - VARCHAR2/CHAR/...   -> la colonne elle-même (non affectée par
    --                                    les paramètres numériques NLS)
    -- Tout autre type est rabattu sur TO_CHAR(colonne) en dernière chance.
    -- Permet de corriger la divergence spec/code v1 (le README promettait ces
    -- masques, le code utilisait un TO_CHAR nu, source de faux conflits).
    --------------------------------------------------------------------------
    FUNCTION canonical_scalar_expr(
        p_col    IN t_column_rec,
        p_prefix IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_col   VARCHAR2(140) := CASE WHEN p_prefix IS NOT NULL THEN p_prefix || '.' END
                                 || sanitize_ident(p_col.column_name);
        v_inner VARCHAR2(4000);
        v_typ   VARCHAR2(128) := p_col.data_type;
    BEGIN
        IF v_typ = 'DATE' THEN
            v_inner := 'TO_CHAR(' || v_col || ',' || sql_literal('YYYY-MM-DD HH24:MI:SS') || ')';
        ELSIF v_typ LIKE 'TIMESTAMP%' THEN
            IF v_typ LIKE '%TIME ZONE%' THEN
                v_inner := 'TO_CHAR(' || v_col || ',' || sql_literal('YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM') || ')';
            ELSE
                v_inner := 'TO_CHAR(' || v_col || ',' || sql_literal('YYYY-MM-DD HH24:MI:SS.FF9') || ')';
            END IF;
        ELSIF v_typ IN ('NUMBER', 'FLOAT', 'BINARY_FLOAT', 'BINARY_DOUBLE') THEN
            v_inner := 'TO_CHAR(' || v_col || ',' || sql_literal('TM9') || ',' ||
                       sql_literal('NLS_NUMERIC_CHARACTERS=''.,''') || ')';
        ELSIF v_typ LIKE 'RAW%' THEN
            v_inner := 'RAWTOHEX(' || v_col || ')';
        ELSE
            v_inner := v_col;
        END IF;

        -- NULL normalisé vers un sentinelle déterministe : une concaténation
        -- de clé/ligne ne doit JAMAIS devenir NULL globalement (sinon le hash
        -- serait NULL et la comparaison A/B conclurait à tort à l'égalité).
        RETURN 'NVL(' || v_inner || ',' || sql_literal('<NULL>') || ')';
    END canonical_scalar_expr;


    --------------------------------------------------------------------------
    -- lob_hash_expr
    --
    -- Rôle : retourne l'expression SQL produisant le hash SHA-256 d'une
    --        colonne LOB, en hexadécimal. STANDARD_HASH refuse les types LOB
    --        (documenté Oracle 23) : utilisation de DBMS_CRYPTO.HASH (valeur
    --        constante HASH_SH256 = 4, littéral injecté). Le CLOB est hasher
    --        par le moteur en une passe sans rapatriement applicatif.
    -- Traitement par type (intégration dans la concaténation CLOB de ligne) :
    --          - CLOB / NCLOB : colonne entrée directement dans la
    --            concaténation (le hash final porte sur le CLOB global) ;
    --          - BLOB         : ne peut pas entrer dans une concaténation
    --            CLOB -> hashé isolément en hex, puis la chaîne est injectée.
    -- Une valeur NULL produit le sentinelle '<NULL>' (le hash ne doit jamais
    -- devenir NULL, sinon la comparaison conclurait à tort à l'égalité).
    --------------------------------------------------------------------------
    FUNCTION lob_hash_expr(
        p_col    IN t_column_rec,
        p_prefix IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_col VARCHAR2(140) := CASE WHEN p_prefix IS NOT NULL THEN p_prefix || '.' END
                               || sanitize_ident(p_col.column_name);
    BEGIN
        IF p_col.data_type = 'BLOB' THEN
            RETURN 'CASE WHEN ' || v_col || ' IS NULL THEN ' || sql_literal('<NULL>') ||
                   ' ELSE TO_CLOB(RAWTOHEX(DBMS_CRYPTO.HASH(' || v_col || ',4))) END';
        ELSE
            RETURN 'CASE WHEN ' || v_col || ' IS NULL THEN ' || sql_literal('<NULL>') ||
                   ' ELSE TO_CLOB(' || v_col || ') END';
        END IF;
    END lob_hash_expr;


    --------------------------------------------------------------------------
    -- build_key_concat_expr
    --
    -- Rôle : construit la concaténation canonique (séparateur '~~') des
    --        colonnes de clé, NLS-safe par type. Base de la clé de
    --        correspondance (PK_HASH_KEY).
    -- p_as_clob=TRUE  : chaque morceau est enveloppé dans TO_CLOB, la
    --        concaténation résultante est un CLOB (utilisé dans l'aller-retour
    --        DBMS_CRYPTO quand la chaîne courte ne suffit plus). Dans le cas
    --        contraire (FALSE), les morceaux restent VARCHAR2 pour le chemin
    --        rapide STANDARD_HASH.
    --------------------------------------------------------------------------
    FUNCTION build_key_concat_expr(
        p_key_cols IN t_str_tab,
        p_types    IN t_coltype_tab,
        p_prefix   IN VARCHAR2,
        p_as_clob  IN BOOLEAN DEFAULT FALSE
    ) RETURN VARCHAR2 IS
        v_expr VARCHAR2(32000) := '';
        v_piece VARCHAR2(32000);
        v_col  t_column_rec;
        v_found BOOLEAN;
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_found := p_types.EXISTS(p_key_cols(i));
            IF v_found THEN
                v_col := p_types(p_key_cols(i));
            ELSE
                -- Défensif : une colonne de clé absente de la map retombe sur
                -- TO_CHAR nu (ne devrait pas arriver : la clé est toujours
                -- présente dans les colonnes synchronisées).
                v_col.column_name := p_key_cols(i);
                v_col.data_type   := 'VARCHAR2';
            END IF;

            v_piece := canonical_scalar_expr(v_col, p_prefix);
            IF p_as_clob THEN
                v_piece := 'TO_CLOB(' || v_piece || ')';
            END IF;

            v_expr := v_expr
                || CASE WHEN i > 1 THEN ' ||' || sql_literal('~~') || ' || ' END
                || v_piece;
        END LOOP;
        RETURN v_expr;
    END build_key_concat_expr;


    --------------------------------------------------------------------------
    -- approx_text_len
    --
    -- Rôle : borne supérieure (pessimiste mais légère) de la longueur texte
    --        produite par canonical_scalar_expr pour une colonne. Sert à
    --        choisir le chemin de hachage : la concaténation courte
    --        (VARCHAR2, limite 4000) est privilégiée quand c'est sûr, sinon
    --        on bascule sur la concaténation CLOB + DBMS_CRYPTO. Tout LOB
    --        renvoie volontairement 4000 pour forcer ce basculement.
    --------------------------------------------------------------------------
    FUNCTION approx_text_len(p_col IN t_column_rec) RETURN NUMBER IS
    BEGIN
        IF p_col.is_lob THEN
            RETURN 4000;
        ELSIF p_col.data_type IN ('NUMBER', 'FLOAT', 'BINARY_FLOAT', 'BINARY_DOUBLE') THEN
            RETURN NVL(p_col.data_precision, 38) + 3;
        ELSIF p_col.data_type = 'DATE' THEN
            RETURN 30;
        ELSIF p_col.data_type LIKE 'TIMESTAMP%' THEN
            RETURN 40;
        ELSIF p_col.data_type LIKE 'RAW%' THEN
            RETURN NVL(p_col.data_length, 32) * 2;
        ELSE
            RETURN NVL(p_col.data_length, 100);
        END IF;
    END approx_text_len;


    --------------------------------------------------------------------------
    -- build_key_hash_expr
    --
    -- Rôle : produit l'expression SQL finale de la clé de correspondance :
    --        SHA-256 hexadécimal (64 caractères) de la concaténation canonique
    --        des colonnes de clé, identique des deux côtés A/B.
    -- Double chemin (décision v2) :
    --          - concaténation courte (VARCHAR2 < 4000) : chemin rapide
    --            RAWTOHEX(STANDARD_HASH(...,'SHA256')) ;
    --          - sinon : concaténation CLOB + RAWTOHEX(DBMS_CRYPTO.HASH(c,4)),
    --            qui supprime la limite VARCHAR2(4000) frappant la v1 sur les
    --            clés composites longues (ORA-01489).
    --------------------------------------------------------------------------
    FUNCTION build_key_hash_expr(
        p_key_cols IN t_str_tab,
        p_types    IN t_coltype_tab,
        p_prefix   IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_concat VARCHAR2(32000);
        v_est    NUMBER := 0;
        v_col    t_column_rec;
        v_has    BOOLEAN;
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_has := p_types.EXISTS(p_key_cols(i));
            IF v_has THEN
                v_col := p_types(p_key_cols(i));
            ELSE
                v_col.column_name := p_key_cols(i);
                v_col.data_type   := 'VARCHAR2';
            END IF;
            v_est := v_est + approx_text_len(v_col) + 4;  -- + 4 = le séparateur '~~'
        END LOOP;

        IF v_est < 4000 THEN
            v_concat := build_key_concat_expr(p_key_cols, p_types, p_prefix, FALSE);
            RETURN 'RAWTOHEX(STANDARD_HASH(' || v_concat || ',' || sql_literal('SHA256') || '))';
        END IF;

        v_concat := build_key_concat_expr(p_key_cols, p_types, p_prefix, TRUE);
        RETURN 'RAWTOHEX(DBMS_CRYPTO.HASH(' || v_concat || ',4))';
    END build_key_hash_expr;


    --------------------------------------------------------------------------
    -- SET_DB_LINK  (procédure publique)
    --
    -- Rôle : permet de fixer g_db_link_b à l'exécution, sans recompilation.
    --        Cf. spécification (Script 3) pour la portée "session" de cet
    --        effet. Aucune validation de contenu autre que sanitize_ident,
    --        appliquée plus loin au moment de l'usage (b_link_suffix) plutôt
    --        qu'ici : SET_DB_LINK(NULL) doit rester possible sans lever
    --        d'erreur (NULL est une valeur valide, "même instance").
    --------------------------------------------------------------------------
    PROCEDURE SET_DB_LINK (p_db_link IN VARCHAR2) IS
    BEGIN
        g_db_link_b := p_db_link;
    END SET_DB_LINK;


    --------------------------------------------------------------------------
    -- GET_DB_LINK  (procédure publique)
    --------------------------------------------------------------------------
    FUNCTION GET_DB_LINK RETURN VARCHAR2 IS
    BEGIN
        RETURN g_db_link_b;
    END GET_DB_LINK;


    --------------------------------------------------------------------------
    -- apply_db_link_override
    --
    -- Rôle : petite fonction utilitaire privée appelée en tête de SYNC_ALL /
    --        SYNC_TABLE / CHECK_COMPATIBILITY : si l'appelant a renseigné
    --        p_db_link (valeur différente de la sentinelle
    --        C_DB_LINK_KEEP_CURRENT), applique SET_DB_LINK avec cette
    --        valeur ; sinon ne touche pas à g_db_link_b (garde la valeur de
    --        session en cours, elle-même initialisée à C_DB_LINK_B par
    --        défaut).
    --------------------------------------------------------------------------
    PROCEDURE apply_db_link_override(p_db_link IN VARCHAR2) IS
    BEGIN
        -- Attention NULL : "p_db_link != C_DB_LINK_KEEP_CURRENT" seul vaudrait
        -- NULL (donc FALSE dans un IF) quand l'appelant passe explicitement
        -- NULL pour forcer le mode "même instance" — l'override serait alors
        -- silencieusement ignoré, laissant g_db_link_b sur son ancienne
        -- valeur. D'où le test IS NULL explicite en première branche.
        IF p_db_link IS NULL OR p_db_link != C_DB_LINK_KEEP_CURRENT THEN
            SET_DB_LINK(p_db_link);
        END IF;
    END apply_db_link_override;


    --------------------------------------------------------------------------
    -- validate_common_params
    --
    -- Rôle : valide les paramètres communs d'entrée des procédures publiques
    --        SYNC_ALL / SYNC_TABLE. Correctif v2 : en v1, un p_error_mode
    --        inconnu n'était jamais rejeté — il retombait silencieusement dans
    --        le comportement par défaut (comparaison à C_ERROR_MODE_STOP
    --        toujours fausse), masquant une faute d'appel. De même, un
    --        p_db_link malformé n'était détecté qu'au premier usage SQL,
    --        souvent loin de l'appel fautif.
    -- Lève -20011 (E_INVALID_PARAMETER) sur p_error_mode hors périmètre, et
    --        laisse sanitize_ident rejeter (-20010) un p_db_link non
    --        conforme.
    --------------------------------------------------------------------------
    PROCEDURE validate_common_params(p_error_mode IN VARCHAR2, p_db_link IN VARCHAR2) IS
        v_check VARCHAR2(128);
    BEGIN
        IF p_error_mode NOT IN (C_ERROR_MODE_CONTINUE, C_ERROR_MODE_STOP) THEN
            RAISE_APPLICATION_ERROR(-20011,
                'Parametre p_error_mode invalide : [' || p_error_mode || '] (attendu : '
                || C_ERROR_MODE_CONTINUE || ' ou ' || C_ERROR_MODE_STOP || ')');
        END IF;

        IF p_db_link IS NOT NULL AND p_db_link != C_DB_LINK_KEEP_CURRENT THEN
            v_check := sanitize_ident(p_db_link);  -- lève -20010 si identifiant invalide
        END IF;
    END validate_common_params;


    --------------------------------------------------------------------------
    -- validate_sync_mode
    --
    -- Rôle : valide la valeur du paramètre p_sync_mode d'un run (sentinelle
    --        "garder le mode configuré par table" ou l'un des trois modes
    --        fonctionnels). Lève E_INVALID_PARAMETER (-20011) sinon. La
    --        valeur NULL est acceptée et traitée comme la sentinelle.
    --------------------------------------------------------------------------
    PROCEDURE validate_sync_mode(p_sync_mode IN VARCHAR2) IS
    BEGIN
        IF p_sync_mode IS NOT NULL AND p_sync_mode != C_SYNC_MODE_KEEP_CURRENT
           AND p_sync_mode NOT IN (C_SYNC_MODE_INSERT, C_SYNC_MODE_UPDATE, C_SYNC_MODE_INSERT_UPDATE) THEN
            RAISE_APPLICATION_ERROR(-20011,
                'Parametre p_sync_mode invalide : [' || p_sync_mode || '] (attendu : '
                || C_SYNC_MODE_INSERT || ', ' || C_SYNC_MODE_UPDATE || ' ou ' || C_SYNC_MODE_INSERT_UPDATE || ')');
        END IF;
    END validate_sync_mode;


    --------------------------------------------------------------------------
    -- b_link_suffix
    --
    -- Rôle : centralise la décision "faut-il qualifier les références à
    --        SCHEMA_B par @g_db_link_b ?". Point de configuration unique,
    --        modifiable à l'exécution (cf. SET_DB_LINK ci-dessus) :
    --        - SCHEMA_A et SCHEMA_B sur deux instances distinctes ->
    --          g_db_link_b renseigné (ex. 'SYNC_LINK_B') -> suffixe '@...'
    --          ajouté partout où SCHEMA_B est référencé en SQL dynamique.
    --        - SCHEMA_A et SCHEMA_B sur LA MÊME instance -> g_db_link_b à
    --          NULL -> aucun suffixe : SYNC_ADMIN doit alors disposer de
    --          grants locaux directs sur SCHEMA_B (SELECT/INSERT/UPDATE),
    --          exactement comme pour SCHEMA_A.
    -- Risque évité : ne JAMAIS appeler sanitize_ident(g_db_link_b) quand
    --        g_db_link_b est NULL — DBMS_ASSERT.SIMPLE_SQL_NAME lève une
    --        exception sur une entrée NULL (ORA-44003), d'où le test
    --        IS NOT NULL avant tout appel.
    -- Effet de bord notable (documenté, pas géré par ce package) : en mode
    --        "même instance" (g_db_link_b NULL), les transactions couvrant
    --        les deux schémas restent purement LOCALES : le risque de
    --        transaction distribuée (2PC) et de sessions in-doubt, qui
    --        n'existe qu'à travers un DB LINK, disparaît de fait.
    --------------------------------------------------------------------------
    FUNCTION b_link_suffix RETURN VARCHAR2 IS
    BEGIN
        IF g_db_link_b IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN '@' || sanitize_ident(g_db_link_b);
    END b_link_suffix;


    --------------------------------------------------------------------------
    -- b_table_ref
    --
    -- Rôle : raccourci pour construire la référence complète et sécurisée
    --        d'une table côté SCHEMA_B ("SCHEMA_B.TABLE" ou
    --        "SCHEMA_B.TABLE@SYNC_LINK_B" selon le mode d'installation),
    --        utilisé partout où le corps du package référence une table de
    --        SCHEMA_B dans du SQL dynamique. Remplace la construction
    --        manuelle répétée "sanitize_ident(C_SCHEMA_B) || '.' || v_table
    --        || '@' || sanitize_ident(C_DB_LINK_B)" qui supposait à tort un
    --        DB LINK toujours présent.
    --------------------------------------------------------------------------
    FUNCTION b_table_ref(p_table_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN sanitize_ident(C_SCHEMA_B) || '.' || sanitize_ident(p_table_name) || b_link_suffix;
    END b_table_ref;


    --------------------------------------------------------------------------
    -- get_primary_or_unique_key
    --
    -- Rôle    : découverte automatique de la clé de correspondance via le
    --           dictionnaire Oracle, côté SCHEMA_A (référence structurelle :
    --           on suppose des tables "jumelles", donc une clé valide côté A
    --           doit exister à l'identique côté B — la conformité réelle
    --           entre A et B est vérifiée séparément par CHECK_COMPATIBILITY,
    --           pas ici).
    -- Stratégie : priorité à la PRIMARY KEY (CONSTRAINT_TYPE='P'). A défaut,
    --           bascule sur la première contrainte UNIQUE trouvée
    --           (CONSTRAINT_TYPE='U'), triée par CONSTRAINT_NAME pour un
    --           comportement déterministe si plusieurs UNIQUE existent
    --           (cas ambigu, signalé séparément en WARNING par
    --           CHECK_COMPATIBILITY : le choix automatique n'est pas garanti
    --           correspondre à l'intention métier).
    -- Retour  : collection vide si aucune PK ni UNIQUE trouvée (l'appelant
    --           doit alors basculer sur SYNC_KEY_CONFIG, cf. get_effective_key).
    --------------------------------------------------------------------------
    -- Variante générique par propriétaire + DB LINK : permet de découvrir la
    -- clé également côté B (indispensable pour émettre PK_MISMATCH dans
    -- CHECK_COMPATIBILITY, cf. §3.5 du README, correctif v2).
    FUNCTION get_primary_or_unique_key_for_owner(
        p_owner      IN VARCHAR2,
        p_table_name IN VARCHAR2,
        p_db_link    IN VARCHAR2
    ) RETURN t_str_tab IS
        v_result        t_str_tab;
        v_constraint    VARCHAR2(128);
        v_link          VARCHAR2(128);
        v_sql           VARCHAR2(4000);
    BEGIN
        v_link := CASE WHEN p_db_link IS NOT NULL THEN '@' || sanitize_ident(p_db_link) END;

        -- Recherche PRIMARY KEY (une seule possible par table en Oracle)
        v_sql := 'SELECT constraint_name FROM ALL_CONSTRAINTS' || v_link
                 || ' WHERE owner = :o AND table_name = :t AND constraint_type = ''P'''
                 || '   AND status = ''ENABLED'' AND ROWNUM = 1';
        BEGIN
            EXECUTE IMMEDIATE v_sql INTO v_constraint USING p_owner, p_table_name;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_constraint := NULL;
        END;

        -- A défaut, première contrainte UNIQUE active, ordre déterministe
        IF v_constraint IS NULL THEN
            v_sql := 'SELECT constraint_name FROM (' ||
                     '  SELECT constraint_name FROM ALL_CONSTRAINTS' || v_link ||
                     '  WHERE owner = :o AND table_name = :t AND constraint_type = ''U'''
                     || '    AND status = ''ENABLED'' ORDER BY constraint_name)' ||
                     ' WHERE ROWNUM = 1';
            BEGIN
                EXECUTE IMMEDIATE v_sql INTO v_constraint USING p_owner, p_table_name;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN v_constraint := NULL;
            END;
        END IF;

        IF v_constraint IS NOT NULL THEN
            v_sql := 'SELECT column_name FROM ALL_CONS_COLUMNS' || v_link
                     || ' WHERE owner = :o AND table_name = :t AND constraint_name = :c'
                     || ' ORDER BY position';
            EXECUTE IMMEDIATE v_sql BULK COLLECT INTO v_result
                USING p_owner, p_table_name, v_constraint;
        END IF;

        RETURN v_result;  -- collection vide (non NULL, .COUNT=0) si rien trouvé
    END get_primary_or_unique_key_for_owner;

    FUNCTION get_primary_or_unique_key(p_table_name IN VARCHAR2) RETURN t_str_tab IS
    BEGIN
        RETURN get_primary_or_unique_key_for_owner(C_SCHEMA_A, p_table_name, NULL);
    END get_primary_or_unique_key;


    --------------------------------------------------------------------------
    -- get_configured_key
    --
    -- Rôle : lit la clé explicitement configurée dans SYNC_KEY_CONFIG,
    --        utilisée uniquement si get_primary_or_unique_key n'a rien
    --        trouvé, ou si un opérateur a explicitement configuré une clé
    --        pour forcer un comportement différent de la découverte
    --        automatique (cas volontairement permis : une PK technique
    --        auto-générée peut ne pas être le bon critère de correspondance
    --        fonctionnelle entre A et B, une clé métier explicite prime dans
    --        ce cas — c'est à l'opérateur de le décider via cette table).
    --------------------------------------------------------------------------
    FUNCTION get_configured_key(p_table_name IN VARCHAR2) RETURN t_str_tab IS
        v_result t_str_tab;
    BEGIN
        SELECT column_name
        BULK COLLECT INTO v_result
        FROM SYNC_KEY_CONFIG
        WHERE table_name = p_table_name
        ORDER BY key_position;

        RETURN v_result;
    END get_configured_key;


    --------------------------------------------------------------------------
    -- validate_key_uniqueness
    --
    -- Rôle    : ne s'applique QU'aux clés issues de SYNC_KEY_CONFIG (une
    --           PK/UNIQUE Oracle est par définition déjà garantie unique par
    --           le moteur, inutile de la revérifier). Une clé configurée
    --           manuellement n'a AUCUNE garantie d'unicité tant qu'elle n'a
    --           pas été vérifiée en pratique sur les données réelles.
    -- Méthode : COUNT(*) vs COUNT(DISTINCT clé hashée canonique) côté A ET
    --           côté B (les deux doivent être vérifiés indépendamment : la clé
    --           peut être unique côté A mais pas côté B, notamment si B
    --           contient des données historiques divergentes). Le hash (clé
    --           canonique) rend le comptage robuste aux clés composites
    --           longues (> 4000) et aux collisions de séparateur.
    -- Perf    : un COUNT(*) complet par table concernée, exécuté une seule
    --           fois par run (pas par ligne). Acceptable même sur plusieurs
    --           millions de lignes grâce à l'index sous-jacent si la clé
    --           configurée porte un index (fortement recommandé mais pas
    --           imposé techniquement — à signaler en WARNING dans
    --           CHECK_COMPATIBILITY si absent).
    --------------------------------------------------------------------------
    FUNCTION validate_key_uniqueness(
        p_table_name    IN VARCHAR2,
        p_key_cols      IN t_str_tab,
        p_owner         IN VARCHAR2,   -- C_SCHEMA_A ou C_SCHEMA_B
        p_db_link       IN VARCHAR2    -- NULL pour A (local), C_DB_LINK_B pour B
    ) RETURN BOOLEAN IS
        v_types         t_coltype_tab;
        v_key_hash_expr VARCHAR2(32000);
        v_sql           VARCHAR2(32000);
        v_total         NUMBER;
        v_distinct      NUMBER;
        v_table_ref     VARCHAR2(300);
    BEGIN
        v_types := get_col_type_map(p_table_name);
        v_key_hash_expr := build_key_hash_expr(p_key_cols, v_types, NULL);

        v_table_ref := sanitize_ident(p_owner) || '.' || sanitize_ident(p_table_name)
            || CASE WHEN p_db_link IS NOT NULL THEN '@' || sanitize_ident(p_db_link) END;

        v_sql := 'SELECT COUNT(*), COUNT(DISTINCT ' || v_key_hash_expr || ') FROM ' || v_table_ref;

        EXECUTE IMMEDIATE v_sql INTO v_total, v_distinct;

        RETURN (v_total = v_distinct);
    END validate_key_uniqueness;


    --------------------------------------------------------------------------
    -- get_effective_key
    --
    -- Rôle    : point d'entrée unique utilisé par le reste du package pour
    --           obtenir la clé de correspondance d'une table. Combine
    --           get_primary_or_unique_key et get_configured_key selon la
    --           priorité documentée, valide l'unicité effective si la clé
    --           vient de la configuration manuelle, et lève E_NO_USABLE_KEY
    --           si aucune clé exploitable n'est disponible.
    -- Risque  : une clé configurée manuellement qui échoue la vérification
    --           d'unicité est TOUJOURS rejetée (E_NO_USABLE_KEY), même si
    --           elle est explicitement configurée par un opérateur — on ne
    --           contourne jamais un contrôle d'unicité constaté faux, quelle
    --           que soit la configuration.
    --------------------------------------------------------------------------
    FUNCTION get_effective_key(p_table_name IN VARCHAR2) RETURN t_str_tab IS
        v_key           t_str_tab;
        v_from_config   BOOLEAN := FALSE;
    BEGIN
        v_key := get_primary_or_unique_key(p_table_name);

        IF v_key.COUNT = 0 THEN
            v_key := get_configured_key(p_table_name);
            v_from_config := TRUE;
        END IF;

        IF v_key.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(
                -20004,
                'Aucune cle de correspondance exploitable pour la table ' || p_table_name ||
                ' (ni PK/UNIQUE Oracle, ni SYNC_KEY_CONFIG).'
            );
        END IF;

        IF v_from_config THEN
            IF NOT validate_key_uniqueness(p_table_name, v_key, C_SCHEMA_A, NULL) THEN
                RAISE_APPLICATION_ERROR(
                    -20004,
                    'Cle configuree pour ' || p_table_name ||
                    ' non unique en pratique cote SCHEMA_A.'
                );
            END IF;
            IF NOT validate_key_uniqueness(p_table_name, v_key, C_SCHEMA_B, g_db_link_b) THEN
                RAISE_APPLICATION_ERROR(
                    -20004,
                    'Cle configuree pour ' || p_table_name ||
                    ' non unique en pratique cote SCHEMA_B.'
                );
            END IF;
        END IF;

        RETURN v_key;
    END get_effective_key;

    --------------------------------------------------------------------------
    -- table_exists : vérifie l'existence d'une table, locale ou distante.
    --------------------------------------------------------------------------
    FUNCTION table_exists(p_owner IN VARCHAR2, p_table_name IN VARCHAR2, p_db_link IN VARCHAR2) RETURN BOOLEAN IS
        v_sql   VARCHAR2(500);
        v_count NUMBER;
    BEGIN
        v_sql := 'SELECT COUNT(*) FROM ALL_TABLES'
            || CASE WHEN p_db_link IS NOT NULL THEN '@' || sanitize_ident(p_db_link) END
            || ' WHERE owner = :o AND table_name = :t';
        EXECUTE IMMEDIATE v_sql INTO v_count USING p_owner, p_table_name;
        RETURN v_count > 0;
    END table_exists;

    --------------------------------------------------------------------------
    -- get_column_comparison : FULL OUTER JOIN ALL_TAB_COLUMNS(A) / (B)@link.
    --------------------------------------------------------------------------
    FUNCTION get_column_comparison(p_table_name IN VARCHAR2) RETURN t_col_compare_tab IS
        v_result    t_col_compare_tab;
        v_sql       VARCHAR2(4000);
        v_table     VARCHAR2(128) := sanitize_ident(p_table_name);
    BEGIN
        v_sql :=
            'SELECT NVL(a.column_name, b.column_name), ' ||
            '       a.data_type, a.data_length, a.data_precision, a.data_scale, a.nullable, a.data_type_owner, ' ||
            '       b.data_type, b.data_length, b.data_precision, b.data_scale, b.nullable, b.data_type_owner ' ||
            'FROM (SELECT column_name, data_type, data_length, data_precision, data_scale, nullable, data_type_owner ' ||
            '      FROM ALL_TAB_COLUMNS WHERE owner = :owner_a AND table_name = :tbl) a ' ||
            'FULL OUTER JOIN ' ||
            '     (SELECT column_name, data_type, data_length, data_precision, data_scale, nullable, data_type_owner ' ||
            '      FROM ALL_TAB_COLUMNS' || b_link_suffix ||
            '      WHERE owner = :owner_b AND table_name = :tbl2) b ' ||
            'ON a.column_name = b.column_name';

        EXECUTE IMMEDIATE v_sql
            BULK COLLECT INTO v_result
            USING C_SCHEMA_A, v_table, C_SCHEMA_B, v_table;

        RETURN v_result;
    END get_column_comparison;

    --------------------------------------------------------------------------
    -- is_type_supported : LONG/LONG RAW/BFILE/XMLType/types utilisateur exclus.
    --------------------------------------------------------------------------
    FUNCTION is_type_supported(p_data_type IN VARCHAR2, p_type_owner IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF p_type_owner IS NOT NULL THEN
            RETURN FALSE;
        END IF;
        IF p_data_type IN ('LONG', 'LONG RAW', 'BFILE', 'XMLTYPE') THEN
            RETURN FALSE;
        END IF;
        RETURN TRUE;
    END is_type_supported;

    --------------------------------------------------------------------------
    -- insert_compat_report : centralise l'écriture dans SYNC_COMPATIBILITY_REPORT.
    --------------------------------------------------------------------------
    PROCEDURE insert_compat_report(
        p_check_id      IN NUMBER,
        p_table_name    IN VARCHAR2,
        p_column_name   IN VARCHAR2,
        p_issue_type    IN VARCHAR2,
        p_severity      IN VARCHAR2,
        p_detail_a      IN VARCHAR2,
        p_detail_b      IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO SYNC_COMPATIBILITY_REPORT (
            report_id, check_id, table_name, column_name,
            issue_type, severity, detail_a, detail_b
        ) VALUES (
            SYNC_COMPAT_REPORT_ID_SEQ.NEXTVAL, p_check_id, p_table_name, p_column_name,
            p_issue_type, p_severity, p_detail_a, p_detail_b
        );
    END insert_compat_report;

    --------------------------------------------------------------------------
    -- get_sync_columns : colonnes réellement synchronisées (opt-out + clé
    -- toujours incluse + type supporté). Suppose CHECK_COMPATIBILITY déjà
    -- exécutée sans anomalie BLOCKING pour cette table (contrôle fait par
    -- l'orchestrateur), reste défensive sur le filtrage de type.
    --------------------------------------------------------------------------
    FUNCTION get_sync_columns(p_table_name IN VARCHAR2, p_key_cols IN t_str_tab) RETURN t_column_tab IS
        v_compare   t_col_compare_tab;
        v_result    t_column_tab;
        v_excluded  t_str_tab;
        v_is_key    BOOLEAN;
        v_is_excl   BOOLEAN;
        v_idx       PLS_INTEGER := 0;
    BEGIN
        v_compare := get_column_comparison(p_table_name);

        SELECT column_name BULK COLLECT INTO v_excluded
        FROM SYNC_COLUMN_CONFIG
        WHERE table_name = p_table_name AND sync_enabled = 'N';

        FOR i IN 1 .. v_compare.COUNT LOOP
            IF v_compare(i).a_data_type IS NULL OR v_compare(i).b_data_type IS NULL THEN
                CONTINUE;
            END IF;

            IF NOT is_type_supported(v_compare(i).a_data_type, v_compare(i).a_type_owner) THEN
                CONTINUE;
            END IF;

            v_is_key := FALSE;
            FOR k IN 1 .. p_key_cols.COUNT LOOP
                IF p_key_cols(k) = v_compare(i).column_name THEN
                    v_is_key := TRUE;
                    EXIT;
                END IF;
            END LOOP;

            v_is_excl := FALSE;
            IF NOT v_is_key THEN
                FOR e IN 1 .. v_excluded.COUNT LOOP
                    IF v_excluded(e) = v_compare(i).column_name THEN
                        v_is_excl := TRUE;
                        EXIT;
                    END IF;
                END LOOP;
            END IF;

            IF NOT v_is_excl THEN
                v_idx := v_idx + 1;
                v_result(v_idx).column_name    := v_compare(i).column_name;
                v_result(v_idx).data_type      := v_compare(i).a_data_type;
                v_result(v_idx).data_length    := v_compare(i).a_data_length;
                v_result(v_idx).data_precision := v_compare(i).a_data_precision;
                v_result(v_idx).data_scale     := v_compare(i).a_data_scale;
                v_result(v_idx).nullable       := v_compare(i).a_nullable;
                v_result(v_idx).is_lob         := v_compare(i).a_data_type IN ('CLOB', 'BLOB', 'NCLOB');
            END IF;
        END LOOP;

        RETURN v_result;
    END get_sync_columns;

    --------------------------------------------------------------------------
    -- exec_ddl_at_b (privée, v5)
    --
    -- Rôle : exécuter un DDL côté SCHEMA_B.
    --
    --   * Mode MÊME INSTANCE (g_db_link_b IS NULL, cas de cette installation) :
    --     le DDL est exécuté localement, le nom de table étant déjà qualifié
    --     SCHEMA_B.<table> par l'appelant (cf. b_ddl_table_ref / v_tbl_ref).
    --     Le compte exécutant (SYNC_ADMIN) doit disposer des privilèges
    --     requis sur SCHEMA_B (CREATE / ALTER ANY TABLE, cf. script SYS
    --     09_sys_auto_repair_grants.sql).
    --
    --   * Mode DEUX INSTANCES (g_db_link_b IS NOT NULL) : LIMITE CONNUE,
    --     erreur explicite E_REMOTE_DDL_UNSUPPORTED (-20012).
    --     Un DDL ne peut pas traverser un DB LINK en PL/SQL natif :
    --       - EXECUTE IMMEDIATE ne dispose d'aucune clause "AT <lien>"
    --         (syntaxe documentée en 19c comme en 21c : dynamic_sql_stmt,
    --         INTO, USING, RETURNING uniquement) ;
    --       - aucun mécanisme Oracle standard ne permet d'émettre du DDL dans
    --         la session distante d'un compte de lien depuis PL/SQL.
    --     La levée est faite AVANT toute exécution : jamais de DDL partiel.
    --     Contournement : passer C_DB_LINK_B / SET_DB_LINK à NULL (même
    --     instance), où l'auto-réparation v5 fonctionne intégralement.
    --------------------------------------------------------------------------
    PROCEDURE exec_ddl_at_b(p_ddl IN VARCHAR2) IS
    BEGIN
        IF g_db_link_b IS NULL THEN
            EXECUTE IMMEDIATE p_ddl;
        ELSE
            RAISE E_REMOTE_DDL_UNSUPPORTED;
        END IF;
    END exec_ddl_at_b;

    --------------------------------------------------------------------------
    -- auto_create_table_in_b (privée, v5)
    --
    -- Rôle : créer dans SCHEMA_B, par DDL dérivé des métadonnées de SCHEMA_A
    --        (ALL_TAB_COLUMNS : types traduits, nullabilité, puis contrainte
    --        PRIMARY KEY si la table source en a une), une table active
    --        absente de B — service de CYCLE_HANDLING/AUTO_CREATE_MISSING_TABLE.
    --        Les colonnes exclues par SYNC_COLUMN_CONFIG (sync_enabled='N') et
    --        les types non supportés (LONG/LONG RAW, objets...) sont omis.
    --        Les contraintes FK ne sont jamais recréées : elles suivront la
    --        synchro suivante (backfill/ordre topologique).
    -- Lève : E_INCOMPATIBLE_STRUCTURE si la dérivation DDL échoue côté B.
    --------------------------------------------------------------------------
    PROCEDURE auto_create_table_in_b(p_table_name IN VARCHAR2) IS
        v_col_specs  VARCHAR2(32000) := '';
        v_type_spec  VARCHAR2(4000);
        v_char_used  VARCHAR2(1);
        v_tbl_ref    VARCHAR2(257);
        v_pk_name    VARCHAR2(128) := NULL;
        v_key        t_str_tab;
        v_pk_sql     VARCHAR2(32000);
        v_excluded   t_str_tab;
        v_skip       BOOLEAN;
    BEGIN
        SELECT column_name BULK COLLECT INTO v_excluded
        FROM SYNC_COLUMN_CONFIG
        WHERE table_name = p_table_name AND sync_enabled = 'N';

        FOR r IN (
            SELECT column_name, data_type, data_length, data_precision, data_scale,
                   nullable, char_used
            FROM ALL_TAB_COLUMNS
            WHERE owner = C_SCHEMA_A AND table_name = p_table_name
              AND data_type NOT IN ('LONG', 'LONG RAW')
              AND data_type IS NOT NULL
            ORDER BY column_id
        ) LOOP
            v_skip := FALSE;
            FOR e IN 1 .. v_excluded.COUNT LOOP
                IF v_excluded(e) = r.column_name THEN
                    v_skip := TRUE;
                    EXIT;
                END IF;
            END LOOP;
            IF v_skip THEN
                CONTINUE;
            END IF;

            v_type_spec := r.data_type;
            IF r.data_type IN ('VARCHAR2','VARCHAR','CHAR','NVARCHAR2','NCHAR') THEN
                v_type_spec := r.data_type || '(' || r.data_length;
                IF r.char_used = 'C' THEN
                    v_type_spec := v_type_spec || ' CHAR';
                END IF;
                v_type_spec := v_type_spec || ')';
            ELSIF r.data_type IN ('NUMBER') THEN
                IF r.data_precision IS NOT NULL THEN
                    v_type_spec := 'NUMBER(' || r.data_precision;
                    IF r.data_scale IS NOT NULL AND r.data_scale > 0 THEN
                        v_type_spec := v_type_spec || ',' || r.data_scale;
                    END IF;
                    v_type_spec := v_type_spec || ')';
                END IF;
            ELSIF r.data_type LIKE 'TIMESTAMP%' OR r.data_type LIKE 'INTERVAL%' THEN
                IF r.data_precision IS NOT NULL AND r.data_precision > 0 THEN
                    v_type_spec := r.data_type || '(' || r.data_precision || ')';
                END IF;
            END IF;

            v_col_specs := v_col_specs
                || CHR(10) || '  ' || r.column_name || ' ' || v_type_spec
                || CASE WHEN r.nullable = 'Y' THEN ' NULL' ELSE ' NOT NULL' END
                || ',';
        END LOOP;

        IF TRIM(',' FROM v_col_specs) IS NULL THEN
            RAISE E_INCOMPATIBLE_STRUCTURE;
        END IF;

        v_col_specs := SUBSTR(v_col_specs, 1, LENGTH(v_col_specs) - 1);
        IF g_db_link_b IS NULL THEN
            v_tbl_ref := C_SCHEMA_B || '.' || sanitize_ident(p_table_name);
        ELSE
            v_tbl_ref := sanitize_ident(p_table_name);
        END IF;

        exec_ddl_at_b('CREATE TABLE ' || v_tbl_ref || ' (' || v_col_specs || ')');

        -- Contrainte PRIMARY KEY, si la table source en a une. Un échec
        -- d'ajout (ex. nom de contrainte indisponible côté B) est NON fatal :
        -- la table est créée sans PK, la compatibilité le signalera (PK_MISSING).
        v_key := get_primary_or_unique_key(p_table_name);
        IF v_key.COUNT > 0 THEN
            BEGIN
                SELECT constraint_name INTO v_pk_name
                FROM ALL_CONSTRAINTS
                WHERE owner = C_SCHEMA_A AND table_name = p_table_name AND constraint_type = 'P'
                ORDER BY constraint_name
                FETCH FIRST 1 ROWS ONLY;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_pk_name := NULL;
            END;

            BEGIN
                v_pk_sql := 'ALTER TABLE ' || v_tbl_ref || ' ADD CONSTRAINT '
                    || NVL(v_pk_name, 'SYS_C_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS'))
                    || ' PRIMARY KEY (';
                FOR i IN 1 .. v_key.COUNT LOOP
                    v_pk_sql := v_pk_sql || (CASE WHEN i > 1 THEN ', ' ELSE '' END) || sanitize_ident(v_key(i));
                END LOOP;
                v_pk_sql := v_pk_sql || ')';
                exec_ddl_at_b(v_pk_sql);
            EXCEPTION
                WHEN OTHERS THEN
                    DECLARE
                        v_pk_sql2 VARCHAR2(32000);
                    BEGIN
                        IF v_pk_name IS NOT NULL THEN
                            v_pk_sql2 := 'ALTER TABLE ' || v_tbl_ref || ' ADD CONSTRAINT '
                                || 'SYS_C_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS')
                                || ' PRIMARY KEY (';
                            FOR i IN 1 .. v_key.COUNT LOOP
                                v_pk_sql2 := v_pk_sql2 || (CASE WHEN i > 1 THEN ', ' ELSE '' END) || sanitize_ident(v_key(i));
                            END LOOP;
                            v_pk_sql2 := v_pk_sql2 || ')';
                            exec_ddl_at_b(v_pk_sql2);
                        ELSE
                            DBMS_OUTPUT.PUT_LINE('auto_create_table_in_b : PK non ajoutee pour ' || p_table_name
                                || ' (' || SQLERRM || ')');
                        END IF;
                    END;
            END;
        END IF;

        DBMS_OUTPUT.PUT_LINE('auto_create_table_in_b : ' || p_table_name || ' creee dans SCHEMA_B');
    END auto_create_table_in_b;

    --------------------------------------------------------------------------
    -- compat_check_core (privée)
    --
    -- Rôle : cœur du contrôle de compatibilité, partagé par les deux
    --        surcharges publiques CHECK_COMPATIBILITY (nom unique, ou NULL
    --        pour tout le périmètre ; et liste explicite de tables). Boucle
    --        sur une collection de NOMS (p_table_names), génère un CHECK_ID
    --        unique, remplit SYNC_COMPATIBILITY_REPORT et retourne un flag
    --        "présence d'au moins une anomalie BLOCKING". Règles de sévérité
    --        résumées dans le corps ci-dessous (identique à la v1/v2).
    --
    -- v4 : paramètre p_enroll_fk — lorsque TRUE, EN TÊTE du contrôle, toute
    --        la lignée FK des tables de p_table_names (fermeture transitive
    --        côté SCHEMA_A) est vérifiée contre SYNC_TABLE_CONFIG et les
    --        parents absents sont enrôlés automatiquement (enroll_fk_lineage),
    --        chaque nouveau parent étant signalé (FK_PARENT_ENROLLED) et les
    --        parents présents mais désactivés signalés sans forçage
    --        (FK_PARENT_DISABLED), rattachés au MÊME CHECK_ID. p_table_names
    --        doit alors contenir la fermeture COMPLÈTE (seeds ∪ ancêtres) :
    --        le bouclage structurel ci-dessous valide aussi les parents
    --        nouvellement enrôlés. Le COMMIT reste à la charge de l'appelant.
    --------------------------------------------------------------------------
    PROCEDURE compat_check_core(
        p_table_names      IN t_str_tab,
        p_check_id         OUT NUMBER,
        p_has_blocking     OUT BOOLEAN,
        p_enroll_fk        IN BOOLEAN DEFAULT FALSE,
        p_allow_ddl        IN BOOLEAN DEFAULT FALSE
    ) IS
        v_check_id      NUMBER := SYNC_COMPAT_CHECK_ID_SEQ.NEXTVAL;
        v_blocking      BOOLEAN := FALSE;
        v_enrolled      NUMBER := 0;
        v_key           t_str_tab;
        v_key_b         t_str_tab;
        v_compare       t_col_compare_tab;
        v_is_key        BOOLEAN;
        v_from_config   BOOLEAN := FALSE;
        v_keys_equal    BOOLEAN := TRUE;
        v_detail_a      VARCHAR2(4000) := '';
        v_detail_b      VARCHAR2(4000) := '';
        v_cur_table     VARCHAR2(128);
    BEGIN
        -- v4 : enrôlement automatique de la lignée FK avant le contrôle
        -- structurel, rattaché au CHECK_ID généré ci-dessus.
        IF p_enroll_fk THEN
            enroll_fk_lineage(v_check_id, p_table_names, v_enrolled);
        END IF;

        FOR t_idx IN 1 .. p_table_names.COUNT LOOP
            v_cur_table := p_table_names(t_idx);

            IF NOT table_exists(C_SCHEMA_A, v_cur_table, NULL) THEN
                insert_compat_report(v_check_id, v_cur_table, NULL, 'MISSING_IN_A', C_SEVERITY_BLOCKING,
                    'Table absente', 'Table presente');
                v_blocking := TRUE;
                CONTINUE;
            END IF;

            IF NOT table_exists(C_SCHEMA_B, v_cur_table, g_db_link_b) THEN
                -- v5 : création automatique si l'option le permet et que le
                -- DDL est autorisé (run non sec, jamais en simple contrôle).
                IF p_allow_ddl AND NVL(get_run_option(C_OPT_AUTO_CREATE_MISSING_TABLE), 'N') = 'Y' THEN
                    BEGIN
                        auto_create_table_in_b(v_cur_table);
                        insert_compat_report(v_check_id, v_cur_table, NULL,
                            C_ISSUE_TABLE_CREATED_IN_B, C_SEVERITY_WARNING,
                            'Table absente de SCHEMA_B, creee depuis les metadonnees', 'Table creee');
                    EXCEPTION
                        WHEN OTHERS THEN
                            insert_compat_report(v_check_id, v_cur_table, NULL,
                                'MISSING_IN_B', C_SEVERITY_BLOCKING,
                                'Table absente (creation automatique impossible : ' || SQLERRM || ')', 'Table absente');
                            v_blocking := TRUE;
                    END;
                ELSE
                    insert_compat_report(v_check_id, v_cur_table, NULL,
                        'MISSING_IN_B', C_SEVERITY_BLOCKING,
                        'Table presente', 'Table absente');
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;
            END IF;

            ------------------------------------------------------------------
            -- Résolution explicite de la clé efficace (A), distincte de la
            -- découverte automatique (P puis U), puis SYNC_KEY_CONFIG.
            -- Corrige le défaut v1 qui rabattait TOUT échec sur PK_MISSING :
            -- une clé configurée non unique doit lever KEY_NOT_UNIQUE.
            ------------------------------------------------------------------
            v_key         := get_primary_or_unique_key(v_cur_table);
            v_from_config := (v_key.COUNT = 0);
            IF v_from_config THEN
                v_key := get_configured_key(v_cur_table);
            END IF;

            IF v_key.COUNT = 0 THEN
                insert_compat_report(v_check_id, v_cur_table, NULL, 'PK_MISSING', C_SEVERITY_BLOCKING,
                    'Aucune cle exploitable (ni PK/UNIQUE Oracle, ni SYNC_KEY_CONFIG)', NULL);
                v_blocking := TRUE;
                CONTINUE;
            END IF;

            IF v_from_config THEN
                IF NOT validate_key_uniqueness(v_cur_table, v_key, C_SCHEMA_A, NULL) THEN
                    insert_compat_report(v_check_id, v_cur_table, NULL, 'KEY_NOT_UNIQUE', C_SEVERITY_BLOCKING,
                        'Cle configuree non unique en pratique cote SCHEMA_A', NULL);
                    v_blocking := TRUE;
                    CONTINUE;
                ELSIF NOT validate_key_uniqueness(v_cur_table, v_key, C_SCHEMA_B, g_db_link_b) THEN
                    insert_compat_report(v_check_id, v_cur_table, NULL, 'KEY_NOT_UNIQUE', C_SEVERITY_BLOCKING,
                        'Cle configuree non unique en pratique cote SCHEMA_B', NULL);
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;
            END IF;

            ------------------------------------------------------------------
            -- Conformité de la clé entre A et B (PK_MISMATCH, absent de la v1)
            ------------------------------------------------------------------
            v_key_b := get_primary_or_unique_key_for_owner(C_SCHEMA_B, v_cur_table, g_db_link_b);

            v_keys_equal := TRUE;
            IF v_key.COUNT != v_key_b.COUNT THEN
                v_keys_equal := FALSE;
            ELSE
                FOR i IN 1 .. v_key.COUNT LOOP
                    IF v_key(i) != v_key_b(i) THEN
                        v_keys_equal := FALSE;
                        EXIT;
                    END IF;
                END LOOP;
            END IF;

            IF NOT v_keys_equal THEN
                v_detail_a := '';
                FOR i IN 1 .. v_key.COUNT LOOP
                    v_detail_a := v_detail_a || CASE WHEN i > 1 THEN ',' END || v_key(i);
                END LOOP;
                v_detail_b := '';
                FOR i IN 1 .. v_key_b.COUNT LOOP
                    v_detail_b := v_detail_b || CASE WHEN i > 1 THEN ',' END || v_key_b(i);
                END LOOP;

                IF v_key_b.COUNT = 0 THEN
                    -- B ne porte aucune contrainte de clé : la correspondance
                    -- reste possible via la clé A, simple signal d'attention.
                    insert_compat_report(v_check_id, v_cur_table, NULL, 'PK_MISMATCH', C_SEVERITY_WARNING,
                        'Cle en A : ' || v_detail_a || ' (B sans PK/UNIQUE)', v_detail_b);
                ELSE
                    insert_compat_report(v_check_id, v_cur_table, NULL, 'PK_MISMATCH', C_SEVERITY_BLOCKING,
                        'Cle en A : ' || v_detail_a, 'Cle en B : ' || v_detail_b);
                    v_blocking := TRUE;
                END IF;
            END IF;

            v_compare := get_column_comparison(v_cur_table);

            FOR i IN 1 .. v_compare.COUNT LOOP

                v_is_key := FALSE;
                FOR k IN 1 .. v_key.COUNT LOOP
                    IF v_key(k) = v_compare(i).column_name THEN
                        v_is_key := TRUE;
                    END IF;
                END LOOP;

                IF v_compare(i).a_data_type IS NULL THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'MISSING_IN_A', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        NULL, v_compare(i).b_data_type);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF v_compare(i).b_data_type IS NULL THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'MISSING_IN_B', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        v_compare(i).a_data_type, NULL);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF NOT is_type_supported(v_compare(i).a_data_type, v_compare(i).a_type_owner)
                   OR NOT is_type_supported(v_compare(i).b_data_type, v_compare(i).b_type_owner) THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'UNSUPPORTED_TYPE', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        v_compare(i).a_data_type, v_compare(i).b_data_type);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF v_compare(i).a_data_type != v_compare(i).b_data_type THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'TYPE_MISMATCH', C_SEVERITY_BLOCKING,
                        v_compare(i).a_data_type, v_compare(i).b_data_type);
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;

                IF NVL(v_compare(i).a_data_length, -1)     != NVL(v_compare(i).b_data_length, -1)
                   OR NVL(v_compare(i).a_data_precision, -1) != NVL(v_compare(i).b_data_precision, -1)
                   OR NVL(v_compare(i).a_data_scale, -1)     != NVL(v_compare(i).b_data_scale, -1) THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'LENGTH_MISMATCH', C_SEVERITY_BLOCKING,
                        v_compare(i).a_data_type || '(' || v_compare(i).a_data_length || ')',
                        v_compare(i).b_data_type || '(' || v_compare(i).b_data_length || ')');
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;

                IF NVL(v_compare(i).a_nullable, 'Y') != NVL(v_compare(i).b_nullable, 'Y') THEN
                    insert_compat_report(v_check_id, v_cur_table, v_compare(i).column_name,
                        'NULLABLE_MISMATCH', C_SEVERITY_WARNING,
                        v_compare(i).a_nullable, v_compare(i).b_nullable);
                END IF;

            END LOOP;

        END LOOP;

        p_check_id := v_check_id;
        p_has_blocking := v_blocking;
    END compat_check_core;

    --------------------------------------------------------------------------
    -- CHECK_COMPATIBILITY (procédures publiques) — cf. Script 3 pour la doc
    -- fonctionnelle complète. Deux surcharges :
    --   1) p_table_name : une table précise, ou NULL pour tout le périmètre
    --      configuré et actif (cas de SYNC_ALL) ;
    --   2) p_table_list : contrôle d'une LISTE EXPLICITE de tables
    --      (type public t_tab_name_list), sans exigence d'activation config —
    --      utile pour pré-valider. Même règles de sévérité, un CHECK_ID par
    --      appel.
    --------------------------------------------------------------------------
    PROCEDURE CHECK_COMPATIBILITY (
        p_table_name            IN  VARCHAR2 DEFAULT NULL,
        p_db_link               IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_check_id              OUT NUMBER,
        p_has_blocking_issues   OUT BOOLEAN
    ) IS
        v_names t_str_tab;
    BEGIN
        -- Correctif v2 : valider AVANT d'appliquer l'override (seule la
        -- validation de p_db_link nous intéresse ici).
        validate_common_params(C_ERROR_MODE_CONTINUE, p_db_link);
        apply_db_link_override(p_db_link);

        IF p_table_name IS NULL THEN
            SELECT table_name BULK COLLECT INTO v_names
            FROM SYNC_TABLE_CONFIG
            WHERE enabled = 'Y';

            -- v4 : fermeture COMPLÈTE de la lignée FK côté SCHEMA_A
            -- (seeds ∪ ancêtres). La surcharge NULL (contrôle autonome ET
            -- en-tête de SYNC_ALL) enrôle automatiquement les parents absents
            -- de SYNC_TABLE_CONFIG et PERSISTE cet enrôlement (COMMIT) ; les
            -- ancêtres ajoutés sont validés par le MÊME CHECK_ID que les
            -- seeds. La surcharge mono-table et la surcharge liste
            -- (pré-validation) restent non mutantes.
            IF v_names.COUNT > 0 THEN
                v_names := build_fk_ancestors_raw(v_names);
            END IF;
        ELSE
            v_names(1) := p_table_name;
        END IF;

        compat_check_core(v_names, p_check_id, p_has_blocking_issues,
            p_enroll_fk => (p_table_name IS NULL),
            p_allow_ddl => FALSE);

        -- v4 : l'enrôlement automatique de la lignée FK est persisté pour le
        -- contrôle autonome (CHECK_COMPATIBILITY(NULL)).
        IF p_table_name IS NULL THEN
            COMMIT;
        END IF;
    END CHECK_COMPATIBILITY;

    PROCEDURE CHECK_COMPATIBILITY (
        p_table_list            IN  t_tab_name_list,
        p_db_link               IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_check_id              OUT NUMBER,
        p_has_blocking_issues   OUT BOOLEAN
    ) IS
        v_names t_str_tab;
    BEGIN
        validate_common_params(C_ERROR_MODE_CONTINUE, p_db_link);
        apply_db_link_override(p_db_link);

        IF p_table_list IS NOT NULL THEN
            FOR i IN 1 .. p_table_list.COUNT LOOP
                v_names(i) := p_table_list(i);
            END LOOP;
        END IF;

        compat_check_core(v_names, p_check_id, p_has_blocking_issues);
    END CHECK_COMPATIBILITY;

    ----------------------------------------------------------------------
    -- is_in_list (helper générique, réutilisé par plusieurs parties du body)
    ----------------------------------------------------------------------
    FUNCTION is_in_list(p_value IN VARCHAR2, p_list IN t_str_tab) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. p_list.COUNT LOOP
            IF p_list(i) = p_value THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END is_in_list;


    --------------------------------------------------------------------------
    -- resolve_effective_mode
    --
    -- Rôle : détermine le mode d'APPLICATION effectif d'une table pour un run.
    --        Règle : si l'override de run p_override est renseigné (différent
    --        de la sentinelle C_SYNC_MODE_KEEP_CURRENT), il s'applique à toutes
    --        les tables (sans persistance) ; sinon c'est le SYNC_MODE configuré
    --        dans SYNC_TABLE_CONFIG qui s'applique.
    --------------------------------------------------------------------------
    FUNCTION resolve_effective_mode(
        p_table_name IN VARCHAR2,
        p_override   IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_mode VARCHAR2(20);
    BEGIN
        IF p_override IS NOT NULL AND p_override != C_SYNC_MODE_KEEP_CURRENT THEN
            RETURN p_override;
        END IF;

        SELECT sync_mode INTO v_mode
        FROM SYNC_TABLE_CONFIG
        WHERE table_name = p_table_name;
        RETURN v_mode;
    END resolve_effective_mode;


    --------------------------------------------------------------------------
    -- build_fk_ancestors_raw
    --
    -- Rôle : reçoit un ensemble de tables et retourne sa FERMETURE TRANSITIVE
    --        COMPLÈTE DES PARENTS FK (ancêtres via les contraintes FK de
    --        SCHEMA_A), SANS AUCUN FILTRE DE CONFIGURATION. C'est la couche
    --        basse (dictionnaire) partagée par expand_fk_ancestors (filtre sur
    --        les tables de SYNC_TABLE_CONFIG actives) et par enroll_fk_lineage
    --        (enrôlement automatique de la lignée, v4).
    --
    -- Implémentation : expansion itérative par fronts (fichiers parents des
    --        tables déjà retenues), jusqu'à point fixe (au plus 50 passes de
    --        garde — un cycle FK est traité par la détection de grappes/cycle
    --        existante, cette fonction ne boucle que sur la découverte).
    --        Ordre de sortie déterministe : tables demandées dans leur ordre,
    --        puis ancêtres dans l'ordre de découverte. Chaque parent n'est
    --        inséré qu'APRÈS tous ses enfants : cet ordre enfants -> parents
    --        est exploité par enroll_fk_lineage pour hériter du sens de
    --        synchronisation de l'enfant.
    --------------------------------------------------------------------------
    FUNCTION build_fk_ancestors_raw(p_tables IN t_str_tab) RETURN t_str_tab IS
        TYPE t_set IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(128);

        v_result    t_str_tab;
        v_present   t_set;
        v_count     PLS_INTEGER := 0;
        v_new       PLS_INTEGER;
    BEGIN
        -- 1) Copie dédupliquée des tables demandées (ordre conservé).
        FOR i IN 1 .. p_tables.COUNT LOOP
            IF NOT v_present.EXISTS(p_tables(i)) THEN
                v_count := v_count + 1;
                v_result(v_count) := p_tables(i);
                v_present(p_tables(i)) := p_tables(i);
            END IF;
        END LOOP;

        -- 2) Fermeture transitive des parents (re-scan complet à chaque passe :
        --    volumétrie faible, clarté garantie).
        FOR pass IN 1 .. 50 LOOP
            v_new := 0;
            FOR f IN 1 .. v_count LOOP
                FOR rec IN (
                    SELECT DISTINCT r.table_name AS parent_table
                    FROM ALL_CONSTRAINTS c
                    JOIN ALL_CONSTRAINTS r
                      ON c.r_constraint_name = r.constraint_name
                     AND c.r_owner = r.owner
                    WHERE c.owner = C_SCHEMA_A
                      AND c.constraint_type = 'R'
                      AND c.status = 'ENABLED'
                      AND r.constraint_type IN ('P', 'U')
                      AND c.table_name = v_result(f)
                )
                LOOP
                    IF NOT v_present.EXISTS(rec.parent_table) THEN
                        v_count := v_count + 1;
                        v_result(v_count) := rec.parent_table;
                        v_present(rec.parent_table) := rec.parent_table;
                        v_new := v_new + 1;
                    END IF;
                END LOOP;
            END LOOP;
            EXIT WHEN v_new = 0;
        END LOOP;

        RETURN v_result;
    END build_fk_ancestors_raw;


    --------------------------------------------------------------------------
    -- expand_fk_ancestors
    --
    -- Rôle : ensemble de run de SYNC_TABLES historique = fermeture transitive
    --        des parents FK restreinte aux tables de SYNC_TABLE_CONFIG ACTIVES
    --        (ENABLED='Y' et SYNC_DIRECTION != 'DISABLED'). Conservée pour
    --        compatibilité ; depuis la v4, SYNC_TABLES utilise la fermeture
    --        COMPLÈTE (build_fk_ancestors_raw) combinée à l'enrôlement
    --        automatique (enroll_fk_lineage), qui rend ce filtre sans objet.
    --------------------------------------------------------------------------
    FUNCTION expand_fk_ancestors(p_tables IN t_str_tab) RETURN t_str_tab IS
        v_raw       t_str_tab;
        v_result    t_str_tab;
        v_idx       PLS_INTEGER := 0;
        v_cfg       NUMBER;
    BEGIN
        v_raw := build_fk_ancestors_raw(p_tables);

        FOR i IN 1 .. v_raw.COUNT LOOP
            SELECT COUNT(*) INTO v_cfg
            FROM SYNC_TABLE_CONFIG
            WHERE table_name = v_raw(i)
              AND enabled = 'Y'
              AND sync_direction != C_DIRECTION_DISABLED;

            IF v_cfg = 1 THEN
                v_idx := v_idx + 1;
                v_result(v_idx) := v_raw(i);
            END IF;
        END LOOP;

        RETURN v_result;
    END expand_fk_ancestors;


    --------------------------------------------------------------------------
    -- enroll_fk_lineage
    --
    -- Rôle (v4) : reçoit la FERMETURE COMPLÈTE de la lignée FK (seeds ∪
    --        ancêtres, ordre enfants -> parents garanti par
    --        build_fk_ancestors_raw) et vérifie que TOUTE cette lignée est
    --        présente dans SYNC_TABLE_CONFIG. Un parent ABSENT y est enrôlé
    --        automatiquement afin de garantir l'ordre d'écriture parent ->
    --        enfant (évite les ORA-02291 sur SCHEMA_B). Un parent PRÉSENT
    --        MAIS DÉSACTIVÉ n'est JAMAIS forcé (respect de l'intention de
    --        l'administrateur) : un WARNING FK_PARENT_DISABLED signale
    --        l'ordre non garanti.
    --
    -- NB : p_ancestors est l'ensemble de validation complet. Les tables de
    --        fermeture DÉJÀ configurées y figurent (seeds actives ou parents
    --        déjà enrôlés par un appel précédent) : seules les ABSENTES de
    --        la configuration déclenchent un enrôlement — d'où l'idempotence.
    --
    -- SYNC_DIRECTION des parents enrôlés : hérité du sens de l'enfant FK
    --        direct actif (unique si possible, ordre enfants -> parents
    --        garanti par build_fk_ancestors_raw) ; en cas de sens multiples,
    --        d'absence d'enfant actif ou de BIDIRECTIONAL, la valeur retenue
    --        est BIDIRECTIONAL (repli le plus permissif, sans sous-propagation).
    --
    -- Les lignes du rapport sont rattachées au p_check_id fourni par
    --        l'appelant (celui du CHECK_COMPATIBILITY en cours).
    --------------------------------------------------------------------------
    PROCEDURE enroll_fk_lineage(
        p_check_id      IN  NUMBER,
        p_ancestors     IN  t_str_tab,
        p_enrolled      OUT NUMBER
    ) IS
        v_enrolled    NUMBER := 0;
        v_cfg_count   NUMBER;
        v_enabled     CHAR(1);
        v_present_dir VARCHAR2(20);
        v_any_child   BOOLEAN;
        v_dir_mixed   BOOLEAN;
        v_dir_first   VARCHAR2(20);
        v_dir         VARCHAR2(20);
        v_children    VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. p_ancestors.COUNT LOOP
            SELECT COUNT(*) INTO v_cfg_count
            FROM SYNC_TABLE_CONFIG
            WHERE table_name = p_ancestors(i);

            IF v_cfg_count = 0 THEN
                --------------------------------------------------------------
                -- Parent ABSENT : enrôlement avec direction héritée de l'enfant.
                --------------------------------------------------------------
                v_any_child := FALSE;
                v_dir_mixed := FALSE;
                v_dir_first := NULL;
                v_children  := NULL;

                FOR child IN (
                    SELECT c.table_name AS child_table
                    FROM ALL_CONSTRAINTS c
                    JOIN ALL_CONSTRAINTS r
                      ON c.r_constraint_name = r.constraint_name
                     AND c.r_owner = r.owner
                    WHERE c.owner = C_SCHEMA_A
                      AND c.constraint_type = 'R'
                      AND c.status = 'ENABLED'
                      AND r.constraint_type IN ('P', 'U')
                      AND r.table_name = p_ancestors(i)
                )
                LOOP
                    -- Enfant restreint à l'ensemble de run courant (les enfants
                    -- arrivent AVANT leur parent dans p_ancestors : un enfant en
                    -- cours d'enrôlement est donc déjà actif en config) et actif.
                    IF is_in_list(child.child_table, p_ancestors) THEN
                        v_present_dir := NULL;
                        BEGIN
                            SELECT sync_direction INTO v_present_dir
                            FROM SYNC_TABLE_CONFIG
                            WHERE table_name = child.child_table
                              AND enabled = 'Y'
                              AND sync_direction != C_DIRECTION_DISABLED;
                        EXCEPTION
                            WHEN NO_DATA_FOUND THEN
                                v_present_dir := NULL;
                        END;

                        IF v_present_dir IS NOT NULL THEN
                            v_any_child := TRUE;
                            v_children := v_children
                                || CASE WHEN v_children IS NOT NULL THEN ',' END
                                || child.child_table;
                            IF v_dir_first IS NULL THEN
                                v_dir_first := v_present_dir;
                            ELSIF v_dir_first != v_present_dir THEN
                                v_dir_mixed := TRUE;
                            END IF;
                        END IF;
                    END IF;
                END LOOP;

                IF NOT v_any_child OR v_dir_mixed
                   OR v_dir_first = C_DIRECTION_BIDIRECTIONAL THEN
                    v_dir := C_DIRECTION_BIDIRECTIONAL;
                ELSE
                    v_dir := v_dir_first;
                END IF;

                INSERT INTO SYNC_TABLE_CONFIG (
                    table_name, enabled, sync_delete, sync_direction,
                    sync_mode, conflict_strategy, priority, updated_by
                ) VALUES (
                    p_ancestors(i), 'Y', 'N', v_dir,
                    C_SYNC_MODE_INSERT_UPDATE, C_CONFLICT_ERROR_ON_CONFLICT,
                    100, 'AUTO_FK_LINEAGE'
                );

                v_enrolled := v_enrolled + 1;

                insert_compat_report(
                    p_check_id    => p_check_id,
                    p_table_name  => p_ancestors(i),
                    p_column_name => NULL,
                    p_issue_type  => C_ISSUE_FK_PARENT_ENROLLED,
                    p_severity    => C_SEVERITY_WARNING,
                    p_detail_a    => 'Parent FK absent de SYNC_TABLE_CONFIG, enrole automatiquement (SYNC_DIRECTION=' ||
                                     v_dir || '). Enfants declencheurs : ' || NVL(v_children, '-'),
                    p_detail_b    => NULL
                );

            ELSIF v_cfg_count > 0 THEN
                --------------------------------------------------------------
                -- Parent PRÉSENT : WARNING si désactivé (jamais de forçage).
                --------------------------------------------------------------
                SELECT enabled, sync_direction INTO v_enabled, v_present_dir
                FROM SYNC_TABLE_CONFIG
                WHERE table_name = p_ancestors(i);

                IF v_enabled = 'N' OR v_present_dir = C_DIRECTION_DISABLED THEN
                    insert_compat_report(
                        p_check_id    => p_check_id,
                        p_table_name  => p_ancestors(i),
                        p_column_name => NULL,
                        p_issue_type  => C_ISSUE_FK_PARENT_DISABLED,
                        p_severity    => C_SEVERITY_WARNING,
                        p_detail_a    => 'Parent FK present mais desactive dans SYNC_TABLE_CONFIG : ordre parent -> enfant NON garanti (ORA-02291 possible sur SCHEMA_B).',
                        p_detail_b    => NULL
                    );
                END IF;
            END IF;
        END LOOP;

        p_enrolled := v_enrolled;
    END enroll_fk_lineage;


    ----------------------------------------------------------------------
    -- build_fk_edges
    --
    -- Découvre les arêtes FK (parent -> child) entre tables actives,
    -- restreintes à p_active_tables. Les FK pointant vers une table hors
    -- périmètre synchronisé sont ignorées (jamais écrite par le package).
    ----------------------------------------------------------------------
    FUNCTION build_fk_edges(p_active_tables IN t_str_tab) RETURN t_fk_edge_tab IS
        v_result    t_fk_edge_tab;
        v_idx       PLS_INTEGER := 0;
    BEGIN
        FOR rec IN (
            SELECT c.table_name AS child_table,
                   r.table_name AS parent_table,
                   c.deferrable AS deferrable_flag
            FROM ALL_CONSTRAINTS c
            JOIN ALL_CONSTRAINTS r
              ON c.r_constraint_name = r.constraint_name
             AND c.r_owner = r.owner
            WHERE c.owner = C_SCHEMA_A
              AND c.constraint_type = 'R'
              AND c.status = 'ENABLED'
              AND r.constraint_type IN ('P', 'U')
        ) LOOP
            IF is_in_list(rec.child_table, p_active_tables) AND is_in_list(rec.parent_table, p_active_tables) THEN
                v_idx := v_idx + 1;
                v_result(v_idx).parent_table    := rec.parent_table;
                v_result(v_idx).child_table     := rec.child_table;
                v_result(v_idx).deferrable_flag := rec.deferrable_flag;
            END IF;
        END LOOP;

        RETURN v_result;
    END build_fk_edges;


    ----------------------------------------------------------------------
    -- compute_run_clusters
    --
    -- Calcule, pour l'ensemble des tables actives (déjà filtrées des
    -- tables en anomalie BLOCKING par l'appelant) :
    --   1. les composantes connexes du graphe FK (non orienté, pour le
    --      regroupement en grappes de commit) ;
    --   2. au sein de chaque grappe, l'ordre topologique (Kahn) pour
    --      l'INSERT (parent avant enfant) ;
    --   3. la détection de cycle : si toutes les arêtes du cycle sont
    --      DEFERRABLE, la grappe est acceptée avec requires_deferred=TRUE
    --      (le corps d'application exécutera SET CONSTRAINTS ALL DEFERRED
    --      avant d'écrire dans cette grappe). Sinon, la grappe ENTIÈRE est
    --      exclue (exclusion automatique, décision validée), journalisée
    --      avec la liste des tables concernées.
    --
    -- Limite assumée : en cas de cycle partiel, toute la composante non
    -- résolue est exclue plutôt que de tenter une exclusion plus fine —
    -- plus simple et plus sûr, au prix d'exclure éventuellement quelques
    -- tables qui auraient pu être traitées indépendamment.
    ----------------------------------------------------------------------
    PROCEDURE compute_run_clusters(
        p_active_tables     IN  t_str_tab,
        p_check_id          IN  NUMBER,          -- CHECK_ID du CHECK_COMPATIBILITY exécuté en tête de SYNC_ALL,
                                                   -- réutilisé pour journaliser les cycles FK (résolution du point
                                                   -- ouvert signalé en fin de Partie 3)
        p_tables            OUT t_cluster_table_tab,
        p_cluster_meta      OUT t_cluster_meta_tab
    ) IS
        TYPE t_num_by_pos IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

        v_edges         t_fk_edge_tab;
        v_cluster_id    t_num_by_pos;   -- cluster_id courant, indexé par POSITION dans p_active_tables
        v_out_idx       PLS_INTEGER := 0;
        v_meta_idx      PLS_INTEGER := 0;

        FUNCTION position_of(p_table IN VARCHAR2) RETURN PLS_INTEGER IS
        BEGIN
            FOR i IN 1 .. p_active_tables.COUNT LOOP
                IF p_active_tables(i) = p_table THEN RETURN i; END IF;
            END LOOP;
            RETURN NULL;
        END position_of;

    BEGIN
        v_edges := build_fk_edges(p_active_tables);

        -- 1) Union-Find simplifié (volumétrie faible : dizaines de tables,
        --    O(n*m) largement suffisant, pas besoin de path compression)
        FOR i IN 1 .. p_active_tables.COUNT LOOP
            v_cluster_id(i) := i;
        END LOOP;

        FOR e IN 1 .. v_edges.COUNT LOOP
            DECLARE
                v_p PLS_INTEGER := position_of(v_edges(e).parent_table);
                v_c PLS_INTEGER := position_of(v_edges(e).child_table);
                v_old NUMBER;
                v_new NUMBER;
            BEGIN
                IF v_p IS NOT NULL AND v_c IS NOT NULL AND v_cluster_id(v_p) != v_cluster_id(v_c) THEN
                    v_old := GREATEST(v_cluster_id(v_p), v_cluster_id(v_c));
                    v_new := LEAST(v_cluster_id(v_p), v_cluster_id(v_c));
                    FOR i IN 1 .. p_active_tables.COUNT LOOP
                        IF v_cluster_id(i) = v_old THEN
                            v_cluster_id(i) := v_new;
                        END IF;
                    END LOOP;
                END IF;
            END;
        END LOOP;

        -- 2) Traitement grappe par grappe : tri topologique + détection de cycle
        DECLARE
            v_distinct_clusters t_num_by_pos;
            v_dc_count          PLS_INTEGER := 0;

            FUNCTION already_seen(p_val NUMBER) RETURN BOOLEAN IS
            BEGIN
                FOR i IN 1 .. v_dc_count LOOP
                    IF v_distinct_clusters(i) = p_val THEN RETURN TRUE; END IF;
                END LOOP;
                RETURN FALSE;
            END already_seen;
        BEGIN
            FOR i IN 1 .. p_active_tables.COUNT LOOP
                IF NOT already_seen(v_cluster_id(i)) THEN
                    v_dc_count := v_dc_count + 1;
                    v_distinct_clusters(v_dc_count) := v_cluster_id(i);
                END IF;
            END LOOP;

            FOR ci IN 1 .. v_dc_count LOOP
                DECLARE
                    v_cid            NUMBER := v_distinct_clusters(ci);
                    v_members        t_str_tab;
                    v_m_count        PLS_INTEGER := 0;
                    v_in_degree      t_num_by_pos;
                    v_resolved       t_str_tab;
                    v_r_count        PLS_INTEGER := 0;
                    v_order          PLS_INTEGER := 0;
                    v_progress       BOOLEAN;
                    v_priority_sum   NUMBER := 0;
                    v_all_deferrable BOOLEAN := TRUE;
                    v_prio           NUMBER;
                    v_cycle_msg      VARCHAR2(4000) := '';
                    v_remaining      t_str_tab;
                    v_rem_count      PLS_INTEGER := 0;
                    v_tmp            VARCHAR2(128);
                    v_disable_mode   BOOLEAN := FALSE;
                BEGIN
                    FOR i IN 1 .. p_active_tables.COUNT LOOP
                        IF v_cluster_id(i) = v_cid THEN
                            v_m_count := v_m_count + 1;
                            v_members(v_m_count) := p_active_tables(i);

                            SELECT priority INTO v_prio FROM SYNC_TABLE_CONFIG WHERE table_name = p_active_tables(i);
                            v_priority_sum := v_priority_sum + v_prio;
                        END IF;
                    END LOOP;

                    FOR i IN 1 .. v_m_count LOOP
                        v_in_degree(i) := 0;
                    END LOOP;
                    FOR e IN 1 .. v_edges.COUNT LOOP
                        IF is_in_list(v_edges(e).child_table, v_members)
                           AND is_in_list(v_edges(e).parent_table, v_members) THEN
                            FOR i IN 1 .. v_m_count LOOP
                                IF v_members(i) = v_edges(e).child_table THEN
                                    v_in_degree(i) := v_in_degree(i) + 1;
                                END IF;
                            END LOOP;
                        END IF;
                    END LOOP;

                    -- Kahn
                    LOOP
                        v_progress := FALSE;
                        FOR i IN 1 .. v_m_count LOOP
                            IF v_in_degree(i) = 0 AND NOT is_in_list(v_members(i), v_resolved) THEN
                                v_order := v_order + 1;
                                v_r_count := v_r_count + 1;
                                v_resolved(v_r_count) := v_members(i);
                                v_progress := TRUE;

                                v_out_idx := v_out_idx + 1;
                                p_tables(v_out_idx).cluster_id := v_cid;
                                p_tables(v_out_idx).table_name := v_members(i);
                                p_tables(v_out_idx).topo_order := v_order;

                                FOR e IN 1 .. v_edges.COUNT LOOP
                                    IF v_edges(e).parent_table = v_members(i)
                                       AND is_in_list(v_edges(e).child_table, v_members) THEN
                                        FOR k IN 1 .. v_m_count LOOP
                                            IF v_members(k) = v_edges(e).child_table THEN
                                                v_in_degree(k) := v_in_degree(k) - 1;
                                            END IF;
                                        END LOOP;
                                    END IF;
                                END LOOP;
                            END IF;
                        END LOOP;
                        EXIT WHEN NOT v_progress OR v_r_count = v_m_count;
                    END LOOP;

                    v_meta_idx := v_meta_idx + 1;
                    p_cluster_meta(v_meta_idx).cluster_id   := v_cid;
                    p_cluster_meta(v_meta_idx).avg_priority := v_priority_sum / v_m_count;

                    IF v_r_count = v_m_count THEN
                        p_cluster_meta(v_meta_idx).requires_deferred := FALSE;
                        p_cluster_meta(v_meta_idx).excluded          := FALSE;
                    ELSE
                        -- Cycle détecté parmi les tables non résolues.
                        FOR e IN 1 .. v_edges.COUNT LOOP
                            IF is_in_list(v_edges(e).child_table, v_members)
                               AND is_in_list(v_edges(e).parent_table, v_members)
                               AND NOT is_in_list(v_edges(e).child_table, v_resolved) THEN
                                IF v_edges(e).deferrable_flag != 'DEFERRABLE' THEN
                                    v_all_deferrable := FALSE;
                                END IF;
                            END IF;
                        END LOOP;

                        -- Construction du message listant les tables non résolues (cycle),
                        -- par simple concaténation - plus robuste qu'un détour SQL pour un
                        -- message texte de log.
                        FOR i IN 1 .. v_m_count LOOP
                            IF NOT is_in_list(v_members(i), v_resolved) THEN
                                v_cycle_msg := v_cycle_msg
                                    || CASE WHEN v_cycle_msg IS NOT NULL THEN ', ' END
                                    || v_members(i);
                            END IF;
                        END LOOP;

                        -- Tri alphabétique des tables restantes du cycle : ordre
                        -- arbitraire mais déterministe, sans importance relative
                        -- (FK différées, ou désactivées par DISABLE_FK).
                        v_rem_count := 0;
                        FOR i IN 1 .. v_m_count LOOP
                            IF NOT is_in_list(v_members(i), v_resolved) THEN
                                v_rem_count := v_rem_count + 1;
                                v_remaining(v_rem_count) := v_members(i);
                            END IF;
                        END LOOP;
                        FOR a IN 1 .. v_rem_count LOOP
                            FOR b IN a+1 .. v_rem_count LOOP
                                IF v_remaining(b) < v_remaining(a) THEN
                                    v_tmp := v_remaining(a);
                                    v_remaining(a) := v_remaining(b);
                                    v_remaining(b) := v_tmp;
                                END IF;
                            END LOOP;
                        END LOOP;

                        -- v5 : un cycle non déferrable peut être TRAITÉ (et non plus
                        -- seulement exclu) si l'option CYCLE_HANDLING='DISABLE_FK' :
                        -- la grappe est conservée, ses FK seront temporairement
                        -- désactivées côté SCHEMA_B en exécution (échec possible
                        -- => repli sur l'exclusion BLOCKING, géré dans execute_clusters).
                        v_disable_mode := (NOT v_all_deferrable)
                            AND NVL(get_run_option(C_OPT_CYCLE_HANDLING), 'BLOCK') = 'DISABLE_FK';

                        IF v_all_deferrable OR v_disable_mode THEN
                            -- Grappe acceptée ; pour v_all_deferrable : FK différées
                            -- (vérifiées au COMMIT). Pour v_disable_mode : FK du cycle
                            -- désactivées temporairement côté B.
                            FOR i IN 1 .. v_rem_count LOOP
                                v_order := v_order + 1;
                                v_out_idx := v_out_idx + 1;
                                p_tables(v_out_idx).cluster_id := v_cid;
                                p_tables(v_out_idx).table_name := v_remaining(i);
                                p_tables(v_out_idx).topo_order := v_order;
                            END LOOP;

                            p_cluster_meta(v_meta_idx).requires_deferred    := v_all_deferrable;
                            p_cluster_meta(v_meta_idx).requires_cycle_disable := v_disable_mode;
                            p_cluster_meta(v_meta_idx).excluded             := FALSE;

                            -- Traçabilité : une ligne PAR TABLE du cycle (même raison
                            -- que le recours à une liste concaténée en TABLE_NAME :
                            -- TABLE_NAME est VARCHAR2(128), réservé à UN nom).
                            FOR i IN 1 .. v_m_count LOOP
                                IF NOT is_in_list(v_members(i), v_resolved) THEN
                                    IF v_disable_mode THEN
                                        insert_compat_report(
                                            p_check_id      => p_check_id,
                                            p_table_name    => v_members(i),
                                            p_column_name   => NULL,
                                            p_issue_type    => C_ISSUE_FK_CYCLE_HANDLED_BY_DISABLE,
                                            p_severity      => C_SEVERITY_WARNING,
                                            p_detail_a      => 'Cycle FK non deferrable traite par desactivation temporaire des FK cote B. Membres du cycle : ' || v_cycle_msg,
                                            p_detail_b      => NULL
                                        );
                                    ELSE
                                        insert_compat_report(
                                            p_check_id      => p_check_id,
                                            p_table_name    => v_members(i),
                                            p_column_name   => NULL,
                                            p_issue_type    => C_ISSUE_FK_CYCLE_DEFERRABLE,
                                            p_severity      => C_SEVERITY_WARNING,
                                            p_detail_a      => 'Cycle deferrable accepte, contraintes differees pour ce run. Membres du cycle : ' || v_cycle_msg,
                                            p_detail_b      => NULL
                                        );
                                    END IF;
                                END IF;
                            END LOOP;
                        ELSE
                            p_cluster_meta(v_meta_idx).requires_deferred := FALSE;
                            p_cluster_meta(v_meta_idx).requires_cycle_disable := FALSE;
                            p_cluster_meta(v_meta_idx).excluded          := TRUE;
                            p_cluster_meta(v_meta_idx).exclusion_reason  :=
                                'Cycle FK non deferrable detecte parmi : ' || v_cycle_msg;

                            -- Persistance de l'exclusion (corrige un oubli précédent : sans
                            -- ceci, seule la structure en mémoire du run courant connaissait
                            -- la raison de l'exclusion, perdue après le run). Une ligne PAR
                            -- TABLE du cycle, même raison que ci-dessus (ORA-12899 évité).
                            FOR i IN 1 .. v_m_count LOOP
                                IF NOT is_in_list(v_members(i), v_resolved) THEN
                                    insert_compat_report(
                                        p_check_id      => p_check_id,
                                        p_table_name    => v_members(i),
                                        p_column_name   => NULL,
                                        p_issue_type    => C_ISSUE_FK_CYCLE_NOT_DEFERRABLE,
                                        p_severity      => C_SEVERITY_BLOCKING,
                                        p_detail_a      => p_cluster_meta(v_meta_idx).exclusion_reason,
                                        p_detail_b      => NULL
                                    );
                                END IF;
                            END LOOP;
                        END IF;
                    END IF;
                END;
            END LOOP;
        END;
    END compute_run_clusters;

    ----------------------------------------------------------------------
    -- build_column_lists
    --
    -- Rôle : construit les fragments SQL réutilisés par les générateurs de
    --        DML : liste de colonnes non-clé (pour SET/UPDATE), liste de
    --        colonnes complètes (pour INSERT), et clause ON/WHERE de
    --        correspondance par clé (tgt.col = src.col AND ...).
    ----------------------------------------------------------------------
    PROCEDURE build_column_lists(
        p_columns       IN  t_column_tab,
        p_key_cols      IN  t_str_tab,
        p_all_cols_csv  OUT VARCHAR2,   -- "col1,col2,col3"
        p_set_clause    OUT VARCHAR2,   -- "tgt.col2 = src.col2, tgt.col3 = src.col3" (colonnes non-clé)
        p_src_cols_csv  OUT VARCHAR2    -- "src.col1,src.col2,src.col3"
    ) IS
        v_is_key BOOLEAN;
    BEGIN
        p_all_cols_csv := NULL;
        p_set_clause   := NULL;
        p_src_cols_csv := NULL;

        FOR i IN 1 .. p_columns.COUNT LOOP
            DECLARE v_col VARCHAR2(128) := sanitize_ident(p_columns(i).column_name);
            BEGIN
                p_all_cols_csv := p_all_cols_csv || CASE WHEN i > 1 THEN ',' END || v_col;
                p_src_cols_csv := p_src_cols_csv || CASE WHEN i > 1 THEN ',' END || 'src.' || v_col;

                v_is_key := FALSE;
                FOR k IN 1 .. p_key_cols.COUNT LOOP
                    IF p_key_cols(k) = p_columns(i).column_name THEN v_is_key := TRUE; END IF;
                END LOOP;

                IF NOT v_is_key THEN
                    p_set_clause := p_set_clause
                        || CASE WHEN p_set_clause IS NOT NULL THEN ', ' END
                        || 'tgt.' || v_col || ' = src.' || v_col;
                END IF;
            END;
        END LOOP;
    END build_column_lists;


    ----------------------------------------------------------------------
    -- build_on_clause
    ----------------------------------------------------------------------
    FUNCTION build_on_clause(p_key_cols IN t_str_tab, p_left_alias IN VARCHAR2, p_right_alias IN VARCHAR2) RETURN VARCHAR2 IS
        v_result VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_result := v_result || CASE WHEN i > 1 THEN ' AND ' END
                || p_left_alias || '.' || sanitize_ident(p_key_cols(i))
                || ' = ' || p_right_alias || '.' || sanitize_ident(p_key_cols(i));
        END LOOP;
        RETURN v_result;
    END build_on_clause;

    ----------------------------------------------------------------------
    -- build_key_expr
    --
    -- Rôle : construit l'expression SQL de concaténation déterministe des
    --        colonnes de clé (séparateur '~~'), utilisée pour générer
    --        PK_HASH_KEY de façon reproductible entre A et B.
    -- Variante non aliasée (table nue) ; build_key_expr_aliased, définie
    -- ci-après, correspond à l'appel build_key_expr(cols) avec p_alias NULL.
    ----------------------------------------------------------------------
    FUNCTION build_key_expr(p_key_cols IN t_str_tab, p_types IN t_coltype_tab) RETURN VARCHAR2 IS
    BEGIN
        RETURN build_key_hash_expr(p_key_cols, p_types, NULL);
    END build_key_expr;

    ----------------------------------------------------------------------
    -- build_row_hash_expr
    --
    -- Rôle : construit l'expression SQL SHA-256 servant de comparaison de
    --        ligne entre A et B (cas identiques = hash égal). S'applique à
    --        TOUTES les colonnes synchronisées y compris les LOB : en v1 les
    --        LOB étaient exclus et un UPDATE ne touchant QUE des colonnes LOB
    --        n'était jamais détecté (correctif v2).
    -- Double chemin (décision v2) :
    --          - concaténation courte (VARCHAR2, < 4000) : chemin rapide
    --            RAWTOHEX(STANDARD_HASH(...,'SHA256')) — STANDARD_HASH refuse
    --            les LOB (vérifié Oracle 23), d'où une borne de bascule ;
    --          - sinon : concaténation CLOB (TO_CLOB par morceau) +
    --            RAWTOHEX(DBMS_CRYPTO.HASH(...,4)), sans plafond de taille.
    --        Les BLOB, impossibles à concaténer en CLOB, sont hashés
    --        isolément en hex puis injectés en texte (lob_hash_expr).
    -- Si aucune colonne (table vide de colonnes synchronisées), retourne une
    --        constante déterministe : il n'y a rien à comparer.
    ----------------------------------------------------------------------
    FUNCTION build_row_hash_expr(p_columns IN t_column_tab) RETURN VARCHAR2 IS
        v_expr   VARCHAR2(32000);
        v_piece  VARCHAR2(32000);
        v_est    NUMBER := 0;
        v_fast   BOOLEAN;
    BEGIN
        IF p_columns.COUNT = 0 THEN
            RETURN sql_literal('NO_HASHABLE_COLUMN');
        END IF;

        FOR i IN 1 .. p_columns.COUNT LOOP
            v_est := v_est + approx_text_len(p_columns(i)) + 4;  -- + 4 = '~~'
        END LOOP;
        v_fast := (v_est < 4000);

        FOR i IN 1 .. p_columns.COUNT LOOP
            IF p_columns(i).is_lob THEN
                v_piece := lob_hash_expr(p_columns(i), NULL);
            ELSIF v_fast THEN
                v_piece := canonical_scalar_expr(p_columns(i), NULL);
            ELSE
                v_piece := 'TO_CLOB(' || canonical_scalar_expr(p_columns(i), NULL) || ')';
            END IF;

            v_expr := v_expr
                || CASE WHEN i > 1 THEN ' ||' || sql_literal('~~') || ' || ' END
                || v_piece;
        END LOOP;

        IF v_fast THEN
            RETURN 'RAWTOHEX(STANDARD_HASH(' || v_expr || ',' || sql_literal('SHA256') || '))';
        END IF;

        RETURN 'RAWTOHEX(DBMS_CRYPTO.HASH(' || v_expr || ',4))';
    END build_row_hash_expr;

    ----------------------------------------------------------------------
    -- build_key_expr_aliased
    --
    -- Variante de build_key_expr acceptant un préfixe d'alias de table
    -- optionnel, nécessaire ici car les colonnes de clé sont évaluées dans le
    -- contexte d'une sous-requête (pas de la table nue). Délègue le hachage
    -- canonique (NLS-safe, seuil 4000, CLOB de secours) à build_key_hash_expr.
    ----------------------------------------------------------------------
    FUNCTION build_key_expr_aliased(
        p_key_cols IN t_str_tab,
        p_alias    IN VARCHAR2,
        p_types    IN t_coltype_tab
    ) RETURN VARCHAR2 IS
    BEGIN
        RETURN build_key_hash_expr(p_key_cols, p_types, p_alias);
    END build_key_expr_aliased;


    ----------------------------------------------------------------------
    -- apply_to_local_target
    --
    -- Rôle : applique les lignes classées direction=B_TO_A (INSERT_TO_A et
    --        UPDATE_TO_A confondus) via un unique MERGE INTO {SCHEMA_A}.
    --        {table}, source = sous-requête distante via SYNC_LINK_B
    --        restreinte aux clés présentes dans SYNC_WORK_DIFF pour cette
    --        direction. MATCHED/NOT MATCHED est évalué par Oracle contre
    --        l'état réel de la cible, ce qui correspond exactement à la
    --        classification déjà faite (une ligne classée UPDATE_TO_A est,
    --        par construction du diagnostic, présente dans la cible A ->
    --        MATCHED ; une ligne INSERT_TO_A ne l'est pas -> NOT MATCHED).
    -- Comptage : les volumes INSERT/UPDATE sont lus depuis SYNC_WORK_DIFF
    --        AVANT exécution (et non via SQL%ROWCOUNT après coup) : un
    --        MERGE est atomique — soit il s'applique intégralement, soit il
    --        lève une exception sans rien appliquer — donc les comptes
    --        prévisionnels sont fiables s'il n'y a pas d'exception.
    ----------------------------------------------------------------------
    PROCEDURE apply_to_local_target(
        p_run_id            IN  NUMBER,
        p_table_name        IN  VARCHAR2,
        p_key_cols          IN  t_str_tab,
        p_columns           IN  t_column_tab,
        p_dry_run           IN  BOOLEAN,
        p_sync_mode         IN  VARCHAR2,
        p_rows_inserted     OUT NUMBER,
        p_rows_updated      OUT NUMBER
    ) IS
        v_all_cols  VARCHAR2(32767);
        v_set       VARCHAR2(32767);
        v_src_cols  VARCHAR2(32767);
        v_table     VARCHAR2(128) := sanitize_ident(p_table_name);
        v_types     t_coltype_tab := type_map_from_columns(p_columns);
        v_sql       VARCHAR2(32767);
        v_ins       NUMBER;
        v_upd       NUMBER;
        v_diff_list VARCHAR2(120);
    BEGIN
        SELECT COUNT(*) INTO v_ins FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_A';
        SELECT COUNT(*) INTO v_upd FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'UPDATE_TO_A';

        -- Filtrage par mode : les opérations hors mode sont comptées 0 et ne
        -- sont pas appliquées (v_diff_list ci-dessous restreint la source).
        p_rows_inserted := v_ins;
        p_rows_updated  := v_upd;
        IF p_sync_mode = C_SYNC_MODE_UPDATE THEN
            p_rows_inserted := 0;
        ELSIF p_sync_mode = C_SYNC_MODE_INSERT THEN
            p_rows_updated := 0;
        END IF;

        IF p_dry_run OR (p_rows_inserted = 0 AND p_rows_updated = 0) THEN
            RETURN; -- rien à appliquer réellement, ou simulation : comptes déjà connus
        END IF;

        -- Restrictions source par mode. Un MERGE classe MATCHED/NOT MATCHED par
        -- l'état réel de la cible : restreindre la source aux seules clés autorisées
        -- (INSERT_TO_A ≡ non présente en A -> NOT MATCHED ; UPDATE_TO_A ≡ présente
        -- -> MATCHED) rend l'autre branche inerte sans changer sa syntaxe.
        IF p_sync_mode = C_SYNC_MODE_INSERT THEN
            v_diff_list := '(''INSERT_TO_A'')';
        ELSIF p_sync_mode = C_SYNC_MODE_UPDATE THEN
            v_diff_list := '(''UPDATE_TO_A'')';
        ELSE
            v_diff_list := '(''INSERT_TO_A'',''UPDATE_TO_A'')';
        END IF;

        build_column_lists(p_columns, p_key_cols, v_all_cols, v_set, v_src_cols);

        v_sql :=
            'MERGE INTO ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table || ' tgt ' ||
            'USING (SELECT ' || v_all_cols || ' FROM ' || b_table_ref(p_table_name) ||
            ' WHERE ' || build_key_expr_aliased(p_key_cols, NULL, v_types) ||
            ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :tn ' ||
            '     AND direction = :dir AND diff_type IN ' || v_diff_list || ')) src ' ||
            'ON (' || build_on_clause(p_key_cols, 'tgt', 'src') || ') ' ||
            'WHEN MATCHED THEN UPDATE SET ' || v_set || ' ' ||
            'WHEN NOT MATCHED THEN INSERT (' || v_all_cols || ') VALUES (' || v_src_cols || ')';

        EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name, C_DIRECTION_B_TO_A;
    END apply_to_local_target;


    ----------------------------------------------------------------------
    -- apply_to_remote_target
    --
    -- Rôle : applique les lignes classées direction=A_TO_B, en DEUX étapes
    --        distinctes (cf. justification en tête de partie) :
    --          1. INSERT INTO {SCHEMA_B}.{table}@SYNC_LINK_B (...) SELECT
    --             ... FROM {SCHEMA_A}.{table} WHERE clé IN (INSERT_TO_B)
    --          2. UPDATE {SCHEMA_B}.{table}@SYNC_LINK_B tgt
    --             SET (col2,...) = (SELECT col2,... FROM {SCHEMA_A}.{table} src
    --                                WHERE clé(src) = clé(tgt))
    --             WHERE clé(tgt) IN (UPDATE_TO_B)
    --
    -- Risque de performance signalé : la clause UPDATE ... SET (...) =
    --        (sous-requête corrélée) à travers un DB LINK peut, selon le
    --        plan choisi par l'optimiseur distribué, être exécutée ligne
    --        par ligne plutôt que réécrite en jointure distribuée
    --        ensembliste. A VALIDER EN TEST DE CHARGE réel sur le volume de
    --        lignes UPDATE_TO_B typique de la production cible ; si les
    --        volumes de conflits/updates concurrents sont significatifs
    --        (plusieurs milliers de lignes par run), envisager un
    --        rapatriement intermédiaire en GTT côté B via un mécanisme
    --        équivalent (nécessiterait un point d'exécution PL/SQL côté
    --        B, hors périmètre actuel où seul un DB LINK simple est
    --        disponible) — signalé comme limite connue de l'architecture
    --        DB LINK simple retenue.
    ----------------------------------------------------------------------
    PROCEDURE apply_to_remote_target(
        p_run_id            IN  NUMBER,
        p_table_name        IN  VARCHAR2,
        p_key_cols          IN  t_str_tab,
        p_columns           IN  t_column_tab,
        p_dry_run           IN  BOOLEAN,
        p_sync_mode         IN  VARCHAR2,
        p_rows_inserted     OUT NUMBER,
        p_rows_updated      OUT NUMBER
    ) IS
        v_all_cols  VARCHAR2(32767);
        v_set       VARCHAR2(32767);
        v_src_cols  VARCHAR2(32767);
        v_table     VARCHAR2(128) := sanitize_ident(p_table_name);
        v_types     t_coltype_tab := type_map_from_columns(p_columns);
        v_sql       VARCHAR2(32767);
        v_non_key_cols VARCHAR2(32767);
        v_select_non_key VARCHAR2(32767);
        v_is_key BOOLEAN;
        v_ins       NUMBER;
        v_upd       NUMBER;
        v_apply_ins BOOLEAN;
        v_apply_upd BOOLEAN;
    BEGIN
        SELECT COUNT(*) INTO v_ins FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_B';
        SELECT COUNT(*) INTO v_upd FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'UPDATE_TO_B';

        -- Filtrage par mode : l'opération hors mode est comptée 0 et non exécutée.
        v_apply_ins := p_sync_mode IN (C_SYNC_MODE_INSERT, C_SYNC_MODE_INSERT_UPDATE);
        v_apply_upd := p_sync_mode IN (C_SYNC_MODE_UPDATE, C_SYNC_MODE_INSERT_UPDATE);
        p_rows_inserted := CASE WHEN v_apply_ins THEN v_ins ELSE 0 END;
        p_rows_updated  := CASE WHEN v_apply_upd THEN v_upd ELSE 0 END;

        IF p_dry_run OR (p_rows_inserted = 0 AND p_rows_updated = 0) THEN
            RETURN;
        END IF;

        build_column_lists(p_columns, p_key_cols, v_all_cols, v_set, v_src_cols);

        ------------------------------------------------------------------
        -- 1) INSERT distribué (uniquement si le mode l'autorise)
        ------------------------------------------------------------------
        IF v_apply_ins AND p_rows_inserted > 0 THEN
            v_sql :=
                'INSERT INTO ' || b_table_ref(p_table_name) ||
                ' (' || v_all_cols || ') ' ||
                'SELECT ' || v_all_cols || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table ||
                ' WHERE ' || build_key_expr_aliased(p_key_cols, NULL, v_types) ||
                ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :tn ' ||
                '     AND diff_type = ''INSERT_TO_B'')';

            EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;
        END IF;

        ------------------------------------------------------------------
        -- 2) UPDATE distribué (colonnes non-clé uniquement, mode autorisé)
        ------------------------------------------------------------------
        IF v_apply_upd AND p_rows_updated > 0 THEN
            v_non_key_cols := NULL;
            v_select_non_key := NULL;
            FOR i IN 1 .. p_columns.COUNT LOOP
                v_is_key := FALSE;
                FOR k IN 1 .. p_key_cols.COUNT LOOP
                    IF p_key_cols(k) = p_columns(i).column_name THEN v_is_key := TRUE; END IF;
                END LOOP;
                IF NOT v_is_key THEN
                    DECLARE v_col VARCHAR2(128) := sanitize_ident(p_columns(i).column_name);
                    BEGIN
                        v_non_key_cols := v_non_key_cols || CASE WHEN v_non_key_cols IS NOT NULL THEN ',' END || v_col;
                        v_select_non_key := v_select_non_key || CASE WHEN v_select_non_key IS NOT NULL THEN ',' END
                            || 'src.' || v_col;
                    END;
                END IF;
            END LOOP;

            v_sql :=
                'UPDATE ' || b_table_ref(p_table_name) || ' tgt ' ||
                'SET (' || v_non_key_cols || ') = ( ' ||
                '  SELECT ' || v_select_non_key || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table || ' src ' ||
                '  WHERE ' || build_on_clause(p_key_cols, 'src', 'tgt') ||
                ') ' ||
                'WHERE ' || build_key_expr_aliased(p_key_cols, 'tgt', v_types) ||
                ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :tn ' ||
                '     AND diff_type = ''UPDATE_TO_B'')';

            EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;
        END IF;
    END apply_to_remote_target;


    ----------------------------------------------------------------------
    -- apply_table_diffs
    --
    -- Rôle : point d'entrée unique appelé par l'orchestrateur (Partie 7)
    --        pour appliquer, dans les deux sens si nécessaire (table
    --        BIDIRECTIONAL), l'ensemble des écritures classées pour une
    --        table donnée. Agrège les compteurs pour SYNC_LOG.
    ----------------------------------------------------------------------
    PROCEDURE apply_table_diffs(
        p_run_id                IN  NUMBER,
        p_table_name            IN  VARCHAR2,
        p_key_cols              IN  t_str_tab,
        p_columns                IN  t_column_tab,
        p_dry_run                IN  BOOLEAN,
        p_sync_mode              IN  VARCHAR2,
        p_rows_inserted_a_to_b   OUT NUMBER,
        p_rows_inserted_b_to_a   OUT NUMBER,
        p_rows_updated_a_to_b    OUT NUMBER,
        p_rows_updated_b_to_a    OUT NUMBER
    ) IS
    BEGIN
        apply_to_remote_target(p_run_id, p_table_name, p_key_cols, p_columns, p_dry_run, p_sync_mode,
            p_rows_inserted_a_to_b, p_rows_updated_a_to_b);

        apply_to_local_target(p_run_id, p_table_name, p_key_cols, p_columns, p_dry_run, p_sync_mode,
            p_rows_inserted_b_to_a, p_rows_updated_b_to_a);
    END apply_table_diffs;


    --------------------------------------------------------------------------
    -- fk_parent_refs (privée, v5)
    --
    -- Rôle : renvoyer les arêtes FK EFFECTIVES portées par une table de
    --        SCHEMA_A (ALL_CONSTRAINTS référence visibles), avec leurs
    --        colonnes (enfant/parent) et la nullabilité de la colonne enfant.
    --        Sert au backfill des parents manquants et à la réparation des
    --        cycles (liste des contraintes à désactiver/re-activer côté B).
    -- NB : la nullabilité enfant sert à décider si une référence manquante
    --      peut être neutralisée (colonnes NULL) plutôt que de déclencher un
    --      backfill ; le champ deferrable dit si la contrainte peut être
    --      contournée par SET CONSTRAINTS ALL DEFERRED dans un run.
    -- NB (correctif de compilation) : la jointure porte sur ALL_TAB_COLUMNS,
    --      qui ne expose QUE les colonnes visibles (les colonnes masquées ne
    --      sont listées que par ALL_TAB_COLS, seule vue à porter une colonne
    --      HIDDEN). Le predicat "cols.hidden = 'NO'" référençait donc une
    --      colonne inexistante ici (ORA-00904 / PLS-00302) : il est retiré,
    --      la sémantique "colonnes visibles" étant déjà celle de la vue.
    -- NB (correctif de compilation, idem) : ALL_CONSTRAINTS ne porte pas de
    --      colonne DELETED non plus (ORA-00904) — le predicat "c.deleted =
    --      'NO'" est retiré ; "c.status = 'ENABLED'" filtre déjà les
    --      contraintes actives.
    --------------------------------------------------------------------------
    FUNCTION fk_parent_refs(p_child_table IN VARCHAR2) RETURN t_fk_ref_tab IS
        v_result t_fk_ref_tab;
        v_idx    PLS_INTEGER := 0;
    BEGIN
        FOR r IN (
            SELECT c.constraint_name, c.deferrable,
                   pc.table_name AS parent_table,
                   chi.column_name AS child_column,
                   par.column_name AS parent_column,
                   cols.nullable AS child_nullable
            FROM ALL_CONSTRAINTS c
            JOIN ALL_CONS_COLUMNS chi
              ON chi.owner = c.owner AND chi.constraint_name = c.constraint_name
             AND chi.table_name = c.table_name
            JOIN ALL_CONSTRAINTS pc
              ON pc.owner = c.r_owner AND pc.constraint_name = c.r_constraint_name
            JOIN ALL_CONS_COLUMNS par
              ON par.owner = pc.owner AND par.constraint_name = pc.constraint_name
             AND par.table_name = pc.table_name AND par.position = chi.position
            JOIN ALL_TAB_COLUMNS cols
              ON cols.owner = c.owner AND cols.table_name = c.table_name
             AND cols.column_name = chi.column_name
            WHERE c.owner = C_SCHEMA_A
              AND c.constraint_type = 'R'
              AND c.table_name = p_child_table
              AND c.status = 'ENABLED'
              AND pc.owner = C_SCHEMA_A
            ORDER BY c.constraint_name, chi.position
        ) LOOP
            IF v_result.COUNT = 0 OR v_result(v_result.COUNT).constraint_name != r.constraint_name THEN
                v_idx := v_result.COUNT + 1;
                v_result(v_idx).constraint_name := r.constraint_name;
                v_result(v_idx).parent_table    := r.parent_table;
                v_result(v_idx).deferrable      := r.deferrable;
                v_result(v_idx).child_nullable  := TRUE;
            END IF;
            v_result(v_idx).cols(v_result(v_idx).cols.COUNT + 1).child_column  := r.child_column;
            v_result(v_idx).cols(v_result(v_idx).cols.COUNT).parent_column := r.parent_column;
            IF r.child_nullable != 'Y' THEN
                v_result(v_idx).child_nullable := FALSE;
            END IF;
        END LOOP;

        RETURN v_result;
    END fk_parent_refs;

    --------------------------------------------------------------------------
    -- insert_missing_parent_rows (privée, v5)
    --
    -- Rôle : re-insérer dans SCHEMA_B les lignes PARENTE manquantes référencées
    --        par les lignes de p_child_table classées INSERT_TO_B pour le run,
    --        en copiant depuis SCHEMA_A la ligne parente complète (colonnes
    --        synchronisées). Ne copie QUE les parents effectivement absents de
    --        B (NOT EXISTS sur la clé parente) : opération idempotente et
    --        sûre en cas de ré-exécution.
    -- Retour : nombre de lignes parente insérées. Une exception est absorbée
    --          et tracée (PARENT_BACKFILL_FAILED, BLOCKING) — l'échec du
    --          backfill ne remonte PAS ici : il accule l'enfant, qui sera
    --          journalisé en FAILED par le mécanisme normal si la retentative
    --          échoue à son tour.
    --------------------------------------------------------------------------
    FUNCTION insert_missing_parent_rows(
        p_child_table   IN VARCHAR2,
        p_run_id        IN NUMBER,
        p_ref           IN t_fk_ref_rec,
        p_check_id      IN NUMBER
    ) RETURN NUMBER IS
        v_parent       VARCHAR2(128) := p_ref.parent_table;
        v_parent_key   t_str_tab;
        v_pcols        t_column_tab;
        v_child_key    t_str_tab;
        v_child_types  t_coltype_tab;
        v_parent_types t_coltype_tab;
        v_all_cols     VARCHAR2(32767);
        v_pair         VARCHAR2(32767) := '';
        v_stmt         VARCHAR2(32767);
        v_rows         NUMBER := 0;
    BEGIN
        v_parent_key  := get_effective_key(v_parent);
        v_child_key   := get_effective_key(p_child_table);
        v_pcols       := get_sync_columns(v_parent, v_parent_key);
        v_child_types := get_col_type_map(p_child_table);
        v_parent_types := get_col_type_map(v_parent);

        IF v_parent_key.COUNT = 0 OR v_child_key.COUNT = 0 OR v_pcols.COUNT = 0 THEN
            insert_compat_report(p_check_id, v_parent,
                NULL, C_ISSUE_PARENT_BACKFILL_FAILED, C_SEVERITY_BLOCKING,
                'Backfill inapplicable : cle ou colonnes synchronisees indisponibles pour ' || v_parent, NULL);
            RETURN 0;
        END IF;

        FOR i IN 1 .. v_pcols.COUNT LOOP
            v_all_cols := v_all_cols
                || CASE WHEN v_all_cols IS NOT NULL THEN ',' END
                || sanitize_ident(v_pcols(i).column_name);
        END LOOP;
        IF v_all_cols IS NULL THEN
            RETURN 0;
        END IF;

        -- Correspondance colonnes-à-colonnes local -> distant (identifiant
        -- la ligne parente référencée par l'enfant), sur les colonnes de la FK.
        FOR c IN 1 .. p_ref.cols.COUNT LOOP
            v_pair := v_pair
                || CASE WHEN v_pair IS NOT NULL THEN ' AND ' END
                || 'ch.' || sanitize_ident(p_ref.cols(c).child_column)
                || ' = p.' || sanitize_ident(p_ref.cols(c).parent_column);
        END LOOP;

        v_stmt :=
            'INSERT INTO ' || b_table_ref(v_parent) || ' (' || v_all_cols || ') ' ||
            'SELECT ' || v_all_cols || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || sanitize_ident(v_parent) || ' p ' ||
            'WHERE EXISTS (SELECT 1 FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || sanitize_ident(p_child_table) || ' ch ' ||
            '   WHERE ' || v_pair ||
            '     AND ' || build_key_expr_aliased(v_child_key, 'ch', v_child_types) ||
            ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :ct ' ||
            '     AND diff_type = ''INSERT_TO_B'')) ' ||
            ' AND NOT EXISTS (SELECT 1 FROM ' || b_table_ref(v_parent) || ' bp WHERE ' ||
            build_on_clause(v_parent_key, 'bp', 'p') || ')';

        EXECUTE IMMEDIATE v_stmt USING p_run_id, p_child_table;
        v_rows := SQL%ROWCOUNT;

        IF v_rows > 0 THEN
            insert_compat_report(p_check_id, v_parent, NULL,
                C_ISSUE_PARENT_BACKFILLED, C_SEVERITY_WARNING,
                'Parent reinsere dans SCHEMA_B depuis SCHEMA_A (backfill) : ' || v_rows || ' ligne(s)', NULL);
        END IF;

        RETURN v_rows;
    EXCEPTION
        WHEN OTHERS THEN
            insert_compat_report(p_check_id, v_parent,
                NULL, C_ISSUE_PARENT_BACKFILL_FAILED, C_SEVERITY_BLOCKING,
                'Backfill impossible pour ' || v_parent || ' : ' || SQLERRM, NULL);
            RETURN 0;
    END insert_missing_parent_rows;


    --------------------------------------------------------------------------
    -- backfill_missing_parents (privée, v5)
    --
    -- Rôle : point d'entrée du backfill pour une table : repère les arêtes FK
    --        portées par la table, et re-insère chacun des parents manquants.
    --        Les chaînes multi-niveaux sont résolues naturellement au fil du
    --        run (chaque ancêtre est lui-même un table du run — enrôlée en v4 —
    --        et son propre INSERT_TO_B déclenchera son propre backfill, dans
    --        l'ordre topologique parent-d'abord de la grappe).
    -- Retour : nombre TOTAL de lignes parente insérées (tous parents).
    --------------------------------------------------------------------------
    FUNCTION backfill_missing_parents(
        p_child_table   IN VARCHAR2,
        p_run_id        IN NUMBER,
        p_check_id      IN NUMBER
    ) RETURN NUMBER IS
        v_refs   t_fk_ref_tab := fk_parent_refs(p_child_table);
        v_total  NUMBER := 0;
        v_inserted NUMBER;
    BEGIN
        FOR i IN 1 .. v_refs.COUNT LOOP
            v_inserted := insert_missing_parent_rows(p_child_table, p_run_id, v_refs(i), p_check_id);
            v_total := v_total + v_inserted;
        END LOOP;
        RETURN v_total;
    END backfill_missing_parents;

    ----------------------------------------------------------------------
    -- Décision de conception (granularité de reprise) : SAVEPOINT PAR TABLE
    -- à l'intérieur de la transaction de grappe. La grappe reste commitée en un
    -- seul bloc (décision validée "commit par grappe"), mais si une table
    -- échoue, seul SON travail est annulé (ROLLBACK TO SAVEPOINT) ; les tables
    -- de la même grappe déjà traitées avec succès restent dans la transaction
    -- et sont commitées normalement à la fin de la grappe. Ce choix permet à
    -- CONTINUE_ON_ERROR de fonctionner correctement même DANS une grappe
    -- multi-tables (§13 du cahier des charges : "continuer avec les autres
    -- tables si le mode choisi l'autorise").
    --
    -- Point d'attention traité explicitement : un ROLLBACK TO SAVEPOINT annule
    -- TOUT le travail effectué depuis le SAVEPOINT, y compris la ligne SYNC_LOG
    -- créée en IN_PROGRESS par process_one_table pour cette table. La ligne
    -- SYNC_LOG définitive (status=FAILED) est donc RE-INSÉRÉE par l'appelant
    -- APRES le ROLLBACK, jamais mise à jour par process_one_table lui-même en
    -- cas d'erreur (qui se contente de laisser l'exception se propager).
    ----------------------------------------------------------------------
    -- populate_work_hash
    --
    -- Rôle : calcule et alimante les GTT de travail SYNC_WORK_HASH_A/B avec
    --        les paires (PK_HASH_KEY, ROW_HASH) pour la table donnée.
    --        Côté A : lecture locale. Côté B : lecture distante via SYNC_LINK_B.
    --        PK_HASH_KEY et ROW_HASH sont générés selon des règles identiques
    --        des deux côtés (build_key_expr / build_row_hash_expr) pour que la
    --        comparaison A/B soit reproductible.
    --
    -- Double voie (correctif v2) :
    --   - SANS colonne LOB : tout est calculé en ENSEMBLE dans une unique
    --     instruction SQL (chemin rapide STANDARD_HASH, ou chemin DBMS_CRYPTO
    --     sur CLOB construit en SQL — un CLOB construit en SQL est hashable,
    --     seul le locator LOB d'une colonne de table ne l'est pas) ;
    --   - AVEC colonne LOB : passage par ligne en PL/SQL
    --     (populate_work_hash_lob), seul endroit où le locator LOB est
    --     exploitable pour un hash complet (limite Oracle 23 vérifiée
    --     empiriquement : ORA-00932/ORA-00902 dès que DBMS_CRYPTO ou
    --     STANDARD_HASH rencontre une colonne LOB en SQL).
    ----------------------------------------------------------------------
    PROCEDURE populate_work_hash_lob(
        p_run_id        IN NUMBER,
        p_table_name    IN VARCHAR2,
        p_key_cols      IN t_str_tab,
        p_columns       IN t_column_tab,
        p_side          IN VARCHAR2    -- 'A' : source = SCHEMA_A, GTT = SYNC_WORK_HASH_A
    ) IS
        v_types     t_coltype_tab := type_map_from_columns(p_columns);
        v_pk_expr   VARCHAR2(32000) := build_key_hash_expr(p_key_cols, v_types, NULL);
        v_src       VARCHAR2(300);
        v_gtt       VARCHAR2(30);
        v_sql       VARCHAR2(32000);
        v_piece     VARCHAR2(32000);
        v_cur       INTEGER;
        v_ncols     NUMBER;
        v_pk        VARCHAR2(64);
        v_scalar    VARCHAR2(4000);
        v_clob      CLOB;
        v_blob      BLOB;
        v_final     CLOB := NULL;
        v_sep       VARCHAR2(4) := '~~';
        v_rowhash   VARCHAR2(64);
        v_fetched   INTEGER;
        v_idx       NUMBER;
    BEGIN
        IF p_side = 'A' THEN
            v_src := sanitize_ident(C_SCHEMA_A) || '.' || sanitize_ident(p_table_name);
            v_gtt := 'SYNC_WORK_HASH_A';
        ELSE
            v_src := b_table_ref(p_table_name);
            v_gtt := 'SYNC_WORK_HASH_B';
        END IF;

        -- SELECT : clé hashée + une expression par colonne synchronisée.
        v_sql := 'SELECT ' || v_pk_expr;
        FOR i IN 1 .. p_columns.COUNT LOOP
            IF p_columns(i).is_lob AND p_columns(i).data_type = 'BLOB' THEN
                v_piece := sanitize_ident(p_columns(i).column_name);
            ELSIF p_columns(i).is_lob THEN
                -- CLOB/NCLOB : rapatrié en CLOB (TO_CLOB normalise le NCLOB)
                v_piece := 'TO_CLOB(' || sanitize_ident(p_columns(i).column_name) || ')';
            ELSE
                v_piece := canonical_scalar_expr(p_columns(i), NULL);
            END IF;
            v_sql := v_sql || ', ' || v_piece;
        END LOOP;
        v_sql := v_sql || ' FROM ' || v_src;

        v_cur := DBMS_SQL.OPEN_CURSOR;
        DBMS_SQL.PARSE(v_cur, v_sql, DBMS_SQL.NATIVE);
        DBMS_SQL.DEFINE_COLUMN(v_cur, 1, v_pk, 64);
        v_idx := 2;
        FOR i IN 1 .. p_columns.COUNT LOOP
            IF p_columns(i).is_lob AND p_columns(i).data_type = 'BLOB' THEN
                DBMS_SQL.DEFINE_COLUMN(v_cur, v_idx, v_blob);
            ELSIF p_columns(i).is_lob THEN
                DBMS_SQL.DEFINE_COLUMN(v_cur, v_idx, v_clob);
            ELSE
                DBMS_SQL.DEFINE_COLUMN(v_cur, v_idx, v_scalar, 4000);
            END IF;
            v_idx := v_idx + 1;
        END LOOP;

        v_ncols := DBMS_SQL.EXECUTE(v_cur);

        LOOP
            v_fetched := DBMS_SQL.FETCH_ROWS(v_cur);
            EXIT WHEN v_fetched = 0;

            DBMS_SQL.COLUMN_VALUE(v_cur, 1, v_pk);

            v_final := NULL;
            v_idx := 2;
            FOR i IN 1 .. p_columns.COUNT LOOP
                IF p_columns(i).is_lob AND p_columns(i).data_type = 'BLOB' THEN
                    DBMS_SQL.COLUMN_VALUE(v_cur, v_idx, v_blob);
                    IF v_blob IS NULL THEN
                        v_final := v_final || v_sep || '<NULL>';
                    ELSE
                        v_final := v_final || v_sep || RAWTOHEX(DBMS_CRYPTO.HASH(v_blob, 4));
                    END IF;
                ELSIF p_columns(i).is_lob THEN
                    DBMS_SQL.COLUMN_VALUE(v_cur, v_idx, v_clob);
                    IF v_clob IS NULL THEN
                        v_final := v_final || v_sep || '<NULL>';
                    ELSE
                        v_final := v_final || v_sep || v_clob;
                    END IF;
                ELSE
                    DBMS_SQL.COLUMN_VALUE(v_cur, v_idx, v_scalar);
                    v_final := v_final || v_sep || NVL(v_scalar, '<NULL>');
                END IF;
                v_idx := v_idx + 1;
            END LOOP;

            v_rowhash := RAWTOHEX(DBMS_CRYPTO.HASH(v_final, 4));

            EXECUTE IMMEDIATE
                'INSERT INTO ' || v_gtt || ' (run_id, table_name, pk_hash_key, row_hash) ' ||
                'VALUES (:1, :2, :3, :4)'
                USING p_run_id, p_table_name, v_pk, v_rowhash;
        END LOOP;

        DBMS_SQL.CLOSE_CURSOR(v_cur);
    END populate_work_hash_lob;


    PROCEDURE populate_work_hash(
        p_run_id        IN NUMBER,
        p_table_name    IN VARCHAR2,
        p_key_cols      IN t_str_tab,
        p_columns       IN t_column_tab
    ) IS
        v_key_expr  VARCHAR2(32000) := build_key_expr(p_key_cols, type_map_from_columns(p_columns));
        v_hash_expr VARCHAR2(32000) := build_row_hash_expr(p_columns);
        v_table     VARCHAR2(128)   := sanitize_ident(p_table_name);
        v_sql       VARCHAR2(32000);
        v_has_lob   BOOLEAN := FALSE;
    BEGIN
        FOR i IN 1 .. p_columns.COUNT LOOP
            IF p_columns(i).is_lob THEN
                v_has_lob := TRUE;
                EXIT;
            END IF;
        END LOOP;

        IF v_has_lob THEN
            populate_work_hash_lob(p_run_id, p_table_name, p_key_cols, p_columns, 'A');
            populate_work_hash_lob(p_run_id, p_table_name, p_key_cols, p_columns, 'B');
            RETURN;
        END IF;

        -- Côté A (local)
        v_sql := 'INSERT INTO SYNC_WORK_HASH_A (run_id, table_name, pk_hash_key, row_hash) ' ||
                 'SELECT :rid, :tn, ' || v_key_expr || ', ' || v_hash_expr ||
                 ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table;
        EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;

        -- Côté B (distant via DB LINK, ou local direct si C_DB_LINK_B est NULL)
        v_sql := 'INSERT INTO SYNC_WORK_HASH_B (run_id, table_name, pk_hash_key, row_hash) ' ||
                 'SELECT :rid, :tn, ' || v_key_expr || ', ' || v_hash_expr ||
                 ' FROM ' || b_table_ref(p_table_name);
        EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;
    END populate_work_hash;

    ----------------------------------------------------------------------
    -- run_diagnostic
    --
    -- Rôle : compare les hash A/B pour la table (GTT), et classe chaque clé
    --        en INSERT_TO_A / INSERT_TO_B / CONFLICT_CANDIDATE dans
    --        SYNC_WORK_DIFF. Les clés identiques ne sont pas traitées.
    ----------------------------------------------------------------------
    PROCEDURE run_diagnostic(p_run_id IN NUMBER, p_table_name IN VARCHAR2) IS
    BEGIN
        INSERT INTO SYNC_WORK_DIFF (run_id, table_name, pk_hash_key, diff_type, direction)
        SELECT p_run_id, p_table_name, pk, diff_type, NULL
        FROM (
            SELECT
                NVL(a.pk_hash_key, b.pk_hash_key) AS pk,
                CASE
                    WHEN b.pk_hash_key IS NULL THEN 'INSERT_TO_B'
                    WHEN a.pk_hash_key IS NULL THEN 'INSERT_TO_A'
                    WHEN a.row_hash != b.row_hash THEN 'CONFLICT_CANDIDATE'
                    ELSE NULL  -- identique : aucune action, filtré ci-dessous
                END AS diff_type
            FROM (SELECT pk_hash_key, row_hash FROM SYNC_WORK_HASH_A
                  WHERE run_id = p_run_id AND table_name = p_table_name) a
            FULL OUTER JOIN
                 (SELECT pk_hash_key, row_hash FROM SYNC_WORK_HASH_B
                  WHERE run_id = p_run_id AND table_name = p_table_name) b
            ON a.pk_hash_key = b.pk_hash_key
        )
        WHERE diff_type IS NOT NULL;
    END run_diagnostic;

    ----------------------------------------------------------------------
    -- log_conflicts_for_table
    --
    -- Rôle : journalise en ENSEMBLE (un unique INSERT...SELECT, plus aucune
    --        itération ligne à ligne) toutes les lignes conflictuelles de la
    --        table dans SYNC_CONFLICT. C'est le remplacement v2 de log_conflict
    --        (N+1 : 3 requêtes dynamiques + 1 insert par conflit) qui corrige
    --        le point de performance identifié sur les volumes de conflits.
    -- VALUE_A/VALUE_B portent la sérialisation JSON des lignes concernées
    --        (colonnes non-LOB) à l'instant du diagnostic ; les deux côtés
    --        sont joignables au hash de clé déjà stocké dans SYNC_WORK_DIFF
    --        (clé unique par construction -> correspondance déterministe).
    ----------------------------------------------------------------------
    PROCEDURE log_conflicts_for_table(
        p_run_id              IN  NUMBER,
        p_table_name          IN  VARCHAR2,
        p_key_cols            IN  t_str_tab,
        p_resolution_strategy IN  VARCHAR2,
        p_resolved_side       IN  VARCHAR2
    ) IS
        v_columns   t_column_tab;
        v_types     t_coltype_tab;
        v_table     VARCHAR2(128)  := sanitize_ident(p_table_name);
        v_jo_cols   VARCHAR2(32000);
        v_sel_disp  VARCHAR2(32000);
        v_json_expr VARCHAR2(32000) := 'NULL';
        v_hkey      VARCHAR2(32000);
        v_sql       VARCHAR2(32000);
        v_b_ref     VARCHAR2(300);
    BEGIN
        v_columns := get_sync_columns(p_table_name, p_key_cols);
        v_types   := get_col_type_map(p_table_name);
        v_hkey    := build_key_hash_expr(p_key_cols, v_types, NULL);

        -- Liste des colonnes sérialisées en JSON (LOBs exclus : coûteux et
        -- non fiables en sérialisation, cf. build_row_hash_expr).
        FOR i IN 1 .. v_columns.COUNT LOOP
            IF NOT v_columns(i).is_lob THEN
                v_jo_cols := v_jo_cols
                    || CASE WHEN v_jo_cols IS NOT NULL THEN ', ' END
                    || 'KEY ' || sql_literal(v_columns(i).column_name) || ' VALUE '
                    || sanitize_ident(v_columns(i).column_name);
            END IF;
        END LOOP;
        IF v_jo_cols IS NOT NULL THEN
            v_json_expr := 'JSON_OBJECT(' || v_jo_cols || ')';
        END IF;

        -- Représentation lisible "CLIENT_ID=10, ..." (fallback : hash brut si
        -- ligne absente côté A — ne devrait pas arriver pour un conflit, dont
        -- la clé existe des deux côtés par construction).
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_sel_disp := v_sel_disp
                || CASE WHEN i > 1 THEN ' || '', '' || ' END
                || sql_literal(p_key_cols(i) || '=') || ' || TO_CHAR(' || sanitize_ident(p_key_cols(i)) || ')';
        END LOOP;

        v_b_ref := b_table_ref(p_table_name);

        v_sql :=
            'INSERT INTO SYNC_CONFLICT (conflict_id, run_id, table_name, pk_hash_key, pk_display, ' ||
            '                            value_a, value_b, resolution_strategy, resolved_side) ' ||
            'SELECT SYNC_CONFLICT_ID_SEQ.NEXTVAL, :rid, :tn, w.pk_hash_key, ' ||
            '       NVL(sa.disp, w.pk_hash_key), sa.json_v, sb.json_v, :strat, :side ' ||
            'FROM SYNC_WORK_DIFF w ' ||
            'LEFT JOIN (SELECT ' || v_hkey || ' AS pk_h, ' || v_sel_disp || ' AS disp, ' ||
            v_json_expr || ' AS json_v ' ||
            '            FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table || ') sa ' ||
            '       ON sa.pk_h = w.pk_hash_key ' ||
            'LEFT JOIN (SELECT ' || v_hkey || ' AS pk_h, ' || v_json_expr || ' AS json_v ' ||
            '            FROM ' || v_b_ref || ') sb ' ||
            '       ON sb.pk_h = w.pk_hash_key ' ||
            'WHERE w.run_id = ' || p_run_id ||
            '  AND w.table_name = ' || sql_literal(p_table_name) ||
            '  AND w.diff_type = ''CONFLICT_CANDIDATE''';

        EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name, p_resolution_strategy, p_resolved_side;
    END log_conflicts_for_table;

    ----------------------------------------------------------------------
    -- resolve_table_diffs
    --
    -- Rôle : résout la classification de SYNC_WORK_DIFF issue de
    --        run_diagnostic en fonction de la configuration de la table :
    --          - inserts orphelins supprimés si direction unique, conservés
    --            avec leur sens si BIDIRECTIONAL ;
    --          - CONFLICT_CANDIDATE résolus ligne à ligne (SOURCE_A_WINS /
    --            SOURCE_B_WINS / direction forcée / ERROR_ON_CONFLICT),
    --            avec journalisation SYNC_CONFLICT systématique.
    ----------------------------------------------------------------------
    PROCEDURE resolve_table_diffs(
        p_run_id        IN NUMBER,
        p_table_name    IN VARCHAR2,
        p_key_cols      IN t_str_tab
    ) IS
        v_direction             VARCHAR2(20);
        v_conflict_strategy     VARCHAR2(20);
        v_final_diff_type       VARCHAR2(20);
        v_final_direction       VARCHAR2(10);
        v_resolution_strategy   VARCHAR2(30);
        v_resolved_side         VARCHAR2(1);
    BEGIN
        SELECT sync_direction, conflict_strategy
        INTO v_direction, v_conflict_strategy
        FROM SYNC_TABLE_CONFIG
        WHERE table_name = p_table_name;

        ------------------------------------------------------------------
        -- 1) Inserts simples : orphelins supprimés si direction unique,
        --    conservés tels quels si BIDIRECTIONAL.
        ------------------------------------------------------------------
        IF v_direction = C_DIRECTION_A_TO_B THEN
            DELETE FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_A';

            UPDATE SYNC_WORK_DIFF SET direction = C_DIRECTION_A_TO_B
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_B';

        ELSIF v_direction = C_DIRECTION_B_TO_A THEN
            DELETE FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_B';

            UPDATE SYNC_WORK_DIFF SET direction = C_DIRECTION_B_TO_A
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_A';

        ELSE -- BIDIRECTIONAL
            UPDATE SYNC_WORK_DIFF SET direction = C_DIRECTION_A_TO_B
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_B';

            UPDATE SYNC_WORK_DIFF SET direction = C_DIRECTION_B_TO_A
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_A';
        END IF;

        ------------------------------------------------------------------
        -- 2) Conflits candidats : JOURNALISATION SYNC_CONFLICT puis
        --    résolution ENSEMBLISTE. La règle est constante par table
        --    (direction ou stratégie de conflit) : une seule décision
        --    s'applique à toutes les lignes CONFLICT_CANDIDATE, plus
        --    aucune itération ligne à ligne.
        --    Ordre impératif (fix v5.2) : log_conflicts_for_table doit
        --    être appelé AVANT la conversion ci-dessous, car il filtre
        --    les lignes encore en 'CONFLICT_CANDIDATE' (snapshot des deux
        --    côtés au diagnostic) ; après la conversion, plus aucune ligne
        --    ne matcherait et SYNC_CONFLICT resterait vide (conflict_count
        --    systématiquement nul, dry runs masquant les vrais conflits).
        ------------------------------------------------------------------
        IF v_direction = C_DIRECTION_A_TO_B THEN
                v_final_diff_type := 'UPDATE_TO_B';
                v_final_direction := C_DIRECTION_A_TO_B;
                v_resolution_strategy := 'DIRECTION_FORCED';
                v_resolved_side := 'A';

            ELSIF v_direction = C_DIRECTION_B_TO_A THEN
                v_final_diff_type := 'UPDATE_TO_A';
                v_final_direction := C_DIRECTION_B_TO_A;
                v_resolution_strategy := 'DIRECTION_FORCED';
                v_resolved_side := 'B';

            ELSIF v_conflict_strategy = C_CONFLICT_SOURCE_A_WINS THEN
                v_final_diff_type := 'UPDATE_TO_B';
                v_final_direction := C_DIRECTION_A_TO_B;
                v_resolution_strategy := C_CONFLICT_SOURCE_A_WINS;
                v_resolved_side := 'A';

            ELSIF v_conflict_strategy = C_CONFLICT_SOURCE_B_WINS THEN
                v_final_diff_type := 'UPDATE_TO_A';
                v_final_direction := C_DIRECTION_B_TO_A;
                v_resolution_strategy := C_CONFLICT_SOURCE_B_WINS;
                v_resolved_side := 'B';

            ELSE -- ERROR_ON_CONFLICT : non résolu, non appliqué
                v_final_diff_type := 'CONFLICT';
                v_final_direction := NULL;
                v_resolution_strategy := C_CONFLICT_ERROR_ON_CONFLICT;
                v_resolved_side := NULL;
            END IF;

            -- Journalisation de TOUS les candidats (résolus ou non) avec la
            -- stratégie et le côté retenus : traçabilité systématique, y
            -- compris les écarts forcés d'une direction unique (DIRECTION_FORCED
            -- ne pèse pas dans conflict_count, cf. process_one_table).
            log_conflicts_for_table(p_run_id, p_table_name, p_key_cols,
                                    v_resolution_strategy, v_resolved_side);

            -- Décision unique pour TOUTES les lignes de la table (la règle de
            -- résolution est constante par table) : application ensembliste.
            UPDATE SYNC_WORK_DIFF
            SET diff_type = v_final_diff_type, direction = v_final_direction
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'CONFLICT_CANDIDATE';
    END resolve_table_diffs;

    ----------------------------------------------------------------------
    -- purge_work_tables
    --
    -- Rôle : purge les lignes de la table traitée dans les GTT de travail,
    --        une fois la table terminée (cf. choix ON COMMIT PRESERVE ROWS :
    --        la purge explicite évite toute accumulation entre runs).
    ----------------------------------------------------------------------
    PROCEDURE purge_work_tables(p_run_id IN NUMBER, p_table_name IN VARCHAR2) IS
    BEGIN
        DELETE FROM SYNC_WORK_HASH_A WHERE run_id = p_run_id AND table_name = p_table_name;
        DELETE FROM SYNC_WORK_HASH_B WHERE run_id = p_run_id AND table_name = p_table_name;
        DELETE FROM SYNC_WORK_DIFF   WHERE run_id = p_run_id AND table_name = p_table_name;
    END purge_work_tables;

    ----------------------------------------------------------------------
    -- process_one_table
    --
    -- Rôle : traite une table de bout en bout (découverte clé/colonnes,
    --        hash, diagnostic, résolution, application). Écrit sa ligne
    --        SYNC_LOG en IN_PROGRESS au début, la met à jour en cas de
    --        SUCCÈS uniquement. En cas d'erreur, NE TENTE PAS de mettre à
    --        jour SYNC_LOG elle-même (cf. justification en tête de partie)
    --        : elle laisse l'exception se propager telle quelle vers
    --        l'appelant, qui gère le SAVEPOINT et la journalisation finale
    --        de l'échec.
    ----------------------------------------------------------------------
    PROCEDURE process_one_table(
        p_run_id        IN  NUMBER,
        p_table_name    IN  VARCHAR2,
        p_cluster_id    IN  NUMBER,
        p_topo_order    IN  NUMBER,
        p_sync_mode     IN  VARCHAR2,      -- override de run (sentinelle = suivre la config)
        p_dry_run       IN  BOOLEAN,
        p_check_id      IN  NUMBER,        -- v5 : traçabilité backfill/réparation FK
        p_status        OUT VARCHAR2
    ) IS
        v_log_id            NUMBER := SYNC_LOG_ID_SEQ.NEXTVAL;
        v_key               t_str_tab;
        v_columns           t_column_tab;
        v_ins_atb           NUMBER := 0;
        v_ins_bta           NUMBER := 0;
        v_upd_atb           NUMBER := 0;
        v_upd_bta           NUMBER := 0;
        v_conflict_count    NUMBER := 0;
        v_eff_mode          VARCHAR2(20);
        v_auto_bf           BOOLEAN;
        v_max_tries         PLS_INTEGER := 1;
        v_tries             PLS_INTEGER := 0;
        v_bf_total          PLS_INTEGER := 0;
    BEGIN
        -- Mode d'application effectif : override de run, sinon SYNC_MODE configuré.
        v_eff_mode := resolve_effective_mode(p_table_name, p_sync_mode);

        -- v5 : options d'auto-réparation FK (backfill des parents manquants).
        v_auto_bf := NVL(get_run_option(C_OPT_AUTO_BACKFILL_PARENTS), 'Y') = 'Y';
        IF v_auto_bf THEN
            BEGIN
                v_max_tries := TO_NUMBER(NVL(get_run_option(C_OPT_MAX_FK_RETRY), '3'));
                IF v_max_tries < 1 THEN
                    v_max_tries := 1;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    v_max_tries := 1;
            END;
        END IF;

        INSERT INTO SYNC_LOG (log_id, run_id, table_name, status, cluster_id, cluster_order, sync_mode)
        VALUES (v_log_id, p_run_id, p_table_name, C_STATUS_IN_PROGRESS, p_cluster_id, p_topo_order, v_eff_mode);

        v_key     := get_effective_key(p_table_name);
        v_columns := get_sync_columns(p_table_name, v_key);

        populate_work_hash(p_run_id, p_table_name, v_key, v_columns);
        run_diagnostic(p_run_id, p_table_name);
        resolve_table_diffs(p_run_id, p_table_name, v_key);

        -- Application direction A->B avec AUTO-RÉPARATION FK (v5) : si un
        -- INSERT enfant échoue sur ORA-02291 (parent absent de SCHEMA_B),
        -- l'énoncé est annulé automatiquement (atomicité d'énoncé), les
        -- parents manquants sont re-insérés depuis SCHEMA_A (backfill), puis
        -- le run réessaie jusqu'à MAX_FK_RETRY tentatives. Ce mécanisme
        -- complète l'auto-ENRÔLEMENT de la lignée (v4) : les ancêtres font
        -- partie du run et leurs OWN inserts sont réparés de la même façon,
        -- de sorte que les chaînes multi-niveaux se résolvent naturellement,
        -- grappe (ordre topologique parent d'abord) après grappe.
        -- NB : les lignes diff restent valides pour la retentative (le backfill
        --      ne les modifie pas) ; le cas où le backfill échoue OU sature
        --      les tentatives remonte en ORA-02291 -> table en FAILED (BLOCKING
        --      PARENT_BACKFILL_FAILED journalisé), comportement historique
        --      préservé par défaut via AUTO_BACKFILL_PARENTS='N'.
        LOOP
            v_tries := v_tries + 1;
            BEGIN
                apply_to_remote_target(p_run_id, p_table_name, v_key, v_columns, p_dry_run, v_eff_mode,
                    v_ins_atb, v_upd_atb);
                EXIT;
            EXCEPTION
                WHEN OTHERS THEN
                    IF SQLCODE = -2291 AND v_auto_bf AND v_tries < v_max_tries THEN
                        v_bf_total := v_bf_total
                            + backfill_missing_parents(p_table_name, p_run_id, p_check_id);
                        IF v_bf_total > 0 THEN
                            insert_compat_report(p_check_id, p_table_name, NULL,
                                C_ISSUE_FK_CHILD_RETRIED, C_SEVERITY_WARNING,
                                'Table retentee apres backfill de ' || v_bf_total || ' parent(s) (MAX_FK_RETRY=' || v_max_tries || ')',
                                NULL);
                        END IF;
                    ELSE
                        RAISE;
                    END IF;
            END;
        END LOOP;

        -- Application direction B->A (table BIDIRECTIONAL) : aucun backfill
        -- n'est tenté sur cette direction (l'asymétrie "parents en A" ne
        -- s'applique pas à l'insertion cible SCHEMA_A).
        apply_to_local_target(p_run_id, p_table_name, v_key, v_columns, p_dry_run, v_eff_mode,
            v_ins_bta, v_upd_bta);

        -- Nombre de conflits RÉELS journalisés pour cette table : les écarts
        -- forcés par une direction unique (DIRECTION_FORCED) ne sont pas des
        -- conflits bidirectionnels, ils ne pèsent pas dans ce compteur.
        SELECT COUNT(*) INTO v_conflict_count FROM SYNC_CONFLICT
            WHERE run_id = p_run_id AND table_name = p_table_name
              AND resolution_strategy != 'DIRECTION_FORCED';

        p_status := CASE WHEN v_conflict_count > 0 THEN C_STATUS_SUCCESS_CONFLICTS ELSE C_STATUS_SUCCESS END;

        UPDATE SYNC_LOG SET
            end_date = SYSTIMESTAMP,
            status = p_status,
            rows_inserted_a_to_b = v_ins_atb,
            rows_inserted_b_to_a = v_ins_bta,
            rows_updated_a_to_b  = v_upd_atb,
            rows_updated_b_to_a  = v_upd_bta,
            conflict_count = v_conflict_count
        WHERE log_id = v_log_id;

        purge_work_tables(p_run_id, p_table_name);
        -- Pas de EXCEPTION WHEN OTHERS ici : cf. justification en tête de partie.
        -- Toute erreur remonte telle quelle vers l'appelant.
    END process_one_table;


    ----------------------------------------------------------------------
    -- order_clusters_by_priority
    --
    -- Rôle : retourne les INDICES (dans p_cluster_meta) des grappes NON
    --        exclues, triés par avg_priority croissante (décision
    --        validée). Tri par sélection simple, volumétrie négligeable.
    ----------------------------------------------------------------------
    FUNCTION order_clusters_by_priority(p_cluster_meta IN t_cluster_meta_tab) RETURN t_num_tab IS
        v_result    t_num_tab;
        v_count     PLS_INTEGER := 0;
    BEGIN
        FOR i IN 1 .. p_cluster_meta.COUNT LOOP
            IF NOT p_cluster_meta(i).excluded THEN
                v_count := v_count + 1;
                v_result(v_count) := i;
            END IF;
        END LOOP;

        FOR a IN 1 .. v_count LOOP
            FOR b IN a + 1 .. v_count LOOP
                IF p_cluster_meta(v_result(b)).avg_priority < p_cluster_meta(v_result(a)).avg_priority THEN
                    DECLARE v_tmp NUMBER := v_result(a);
                    BEGIN
                        v_result(a) := v_result(b);
                        v_result(b) := v_tmp;
                    END;
                END IF;
            END LOOP;
        END LOOP;

        RETURN v_result;
    END order_clusters_by_priority;


    ----------------------------------------------------------------------
    -- process_cluster
    --
    -- Rôle : traite toutes les tables d'UNE grappe, dans leur ordre
    --        topologique (déjà garanti par la construction séquentielle de
    --        v_cluster_tables dans compute_run_clusters : les tables d'une
    --        même grappe apparaissent consécutivement et dans l'ordre
    --        topo_order croissant — pas de tri supplémentaire nécessaire
    --        ici). Gère le SAVEPOINT par table et l'arrêt anticipé si
    --        p_error_mode = STOP.
    ----------------------------------------------------------------------
    PROCEDURE process_cluster(
        p_run_id            IN  NUMBER,
        p_cluster_id        IN  NUMBER,
        p_cluster_tables    IN  t_cluster_table_tab,
        p_dry_run           IN  BOOLEAN,
        p_error_mode        IN  VARCHAR2,
        p_sync_mode         IN  VARCHAR2,
        p_check_id          IN  NUMBER,
        p_success_count     IN OUT NUMBER,
        p_conflict_count    IN OUT NUMBER,
        p_failed_count      IN OUT NUMBER,
        p_stopped_early     IN OUT BOOLEAN
    ) IS
        v_status    VARCHAR2(30);
        v_err_msg   VARCHAR2(4000);
        v_err_bt    CLOB;
    BEGIN
        FOR i IN 1 .. p_cluster_tables.COUNT LOOP
            IF p_cluster_tables(i).cluster_id = p_cluster_id THEN

                SAVEPOINT sp_table;
                BEGIN
                    process_one_table(p_run_id, p_cluster_tables(i).table_name, p_cluster_id,
                        p_cluster_tables(i).topo_order, p_sync_mode, p_dry_run, p_check_id, v_status);

                    IF v_status = C_STATUS_SUCCESS THEN
                        p_success_count := p_success_count + 1;
                    ELSE
                        p_conflict_count := p_conflict_count + 1;
                    END IF;

                EXCEPTION
                    WHEN OTHERS THEN
                        v_err_msg := SUBSTR(SQLERRM, 1, 4000);
                        v_err_bt  := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;

                        ROLLBACK TO SAVEPOINT sp_table;

                        p_failed_count := p_failed_count + 1;

                        INSERT INTO SYNC_LOG (
                            log_id, run_id, table_name, status, cluster_id, cluster_order,
                            end_date, error_count, error_message, error_backtrace
                        ) VALUES (
                            SYNC_LOG_ID_SEQ.NEXTVAL, p_run_id, p_cluster_tables(i).table_name, C_STATUS_FAILED,
                            p_cluster_id, p_cluster_tables(i).topo_order,
                            SYSTIMESTAMP, 1, v_err_msg, v_err_bt
                        );

                        IF p_error_mode = C_ERROR_MODE_STOP THEN
                            p_stopped_early := TRUE;
                        END IF;
                END;

                EXIT WHEN p_stopped_early;
            END IF;
        END LOOP;
    END process_cluster;


    ----------------------------------------------------------------------
    -- compute_final_status
    --
    -- Rôle : agrège le statut global du run à partir des compteurs
    --        accumulés. Règle retenue (décision déléguée, tranchée ici) :
    --          - TABLES_FAILED = TOTAL_TABLES traité (aucune réussite)
    --                                          -> FAILED
    --          - TABLES_FAILED > 0 (partiel, que ce soit parce que STOP a
    --            interrompu le run ou parce que CONTINUE a laissé certaines
    --            tables échouer tout en terminant les autres grappes)
    --                                          -> PARTIAL
    --          - TABLES_FAILED = 0 ET au moins un conflit journalisé
    --                                          -> SUCCESS_WITH_CONFLICTS
    --          - sinon                        -> SUCCESS
    --        Justification : un run avec des tables en échec n'est jamais
    --        un franc SUCCESS même s'il a été jusqu'au bout (CONTINUE) :
    --        PARTIAL reflète mieux la réalité ("synchronisation
    --        partiellement aboutie") qu'un SUCCESS trompeur ou qu'un FAILED
    --        excessif qui masquerait les tables réellement synchronisées.
    ----------------------------------------------------------------------
    FUNCTION compute_final_status(
        p_total NUMBER, p_success NUMBER, p_conflict NUMBER, p_failed NUMBER, p_excluded NUMBER
    ) RETURN VARCHAR2 IS
        v_processed NUMBER := p_total - p_excluded;
    BEGIN
        IF v_processed > 0 AND p_failed = v_processed THEN
            RETURN C_STATUS_FAILED;
        ELSIF p_failed > 0 THEN
            RETURN C_STATUS_PARTIAL;
        ELSIF p_conflict > 0 THEN
            RETURN C_STATUS_SUCCESS_CONFLICTS;
        ELSE
            RETURN C_STATUS_SUCCESS;
        END IF;
    END compute_final_status;


    ----------------------------------------------------------------------
    -- discover_and_register_tables
    --
    -- Rôle : appelée par SYNC_ALL UNIQUEMENT lorsque SYNC_TABLE_CONFIG est
    --        totalement vide (aucune ligne, quelle que soit sa valeur
    --        ENABLED). Découvre les tables présentes À L'IDENTIQUE (même
    --        nom) dans SCHEMA_A et SCHEMA_B, et les enregistre dans
    --        SYNC_TABLE_CONFIG avec des valeurs par défaut prudentes, afin
    --        de permettre un premier run sans configuration manuelle
    --        préalable.
    --
    -- Valeurs par défaut appliquées (décision de conception, à ajuster
    -- ensuite table par table si besoin) :
    --   ENABLED           = 'Y'
    --   SYNC_DIRECTION    = 'BIDIRECTIONAL'
    --   CONFLICT_STRATEGY = 'ERROR_ON_CONFLICT'  (jamais d'écrasement
    --                       silencieux sur une table qu'aucun opérateur n'a
    --                       explicitement configurée)
    --   PRIORITY          = 100 (neutre ; l'ordre FK intra-grappe reste
    --                       gouverné par le tri topologique, inchangé)
    --   UPDATED_BY        = 'AUTO_DISCOVERY' (au lieu de l'utilisateur
    --                       courant, pour distinguer visiblement dans
    --                       SYNC_TABLE_CONFIG les lignes auto-générées des
    --                       lignes saisies manuellement)
    --
    -- Filtrage technique : exclut les tables temporaires (GTT), les
    -- segments de débordement IOT, et les tables secondaires d'index de
    -- domaine — seules les tables métier "normales" sont éligibles.
    --
    -- Note : les tables sans clé exploitable ne sont PAS filtrées ici ;
    -- elles sont enregistrées comme les autres puis naturellement exclues
    -- en BLOCKING (PK_MISSING) par CHECK_COMPATIBILITY, qui s'exécute juste
    -- après dans SYNC_ALL — pas de duplication de la logique de détection
    -- de clé à cet endroit.
    ----------------------------------------------------------------------
    FUNCTION discover_and_register_tables RETURN NUMBER IS
        v_sql       VARCHAR2(4000);
        v_tables    t_str_tab;
        v_count     NUMBER := 0;
    BEGIN
        v_sql :=
            'SELECT table_name FROM ALL_TABLES ' ||
            ' WHERE owner = :o1' ||
            '   AND NVL(temporary,''N'') = ''N''' ||
            '   AND NVL(nested,''NO'') = ''NO''' ||
            '   AND NVL(secondary,''N'') = ''N''' ||
            '   AND (iot_type IS NULL OR iot_type = ''IOT'')' ||
            ' INTERSECT ' ||
            'SELECT table_name FROM ALL_TABLES' || b_link_suffix ||
            ' WHERE owner = :o2' ||
            '   AND NVL(temporary,''N'') = ''N''' ||
            '   AND NVL(nested,''NO'') = ''NO''' ||
            '   AND NVL(secondary,''N'') = ''N''' ||
            '   AND (iot_type IS NULL OR iot_type = ''IOT'')';

        EXECUTE IMMEDIATE v_sql BULK COLLECT INTO v_tables USING C_SCHEMA_A, C_SCHEMA_B;

        FOR i IN 1 .. v_tables.COUNT LOOP
            INSERT INTO SYNC_TABLE_CONFIG (
                table_name, enabled, sync_delete, sync_direction,
                conflict_strategy, priority, updated_by
            ) VALUES (
                v_tables(i), 'Y', 'N', C_DIRECTION_BIDIRECTIONAL,
                C_CONFLICT_ERROR_ON_CONFLICT, 100, 'AUTO_DISCOVERY'
            );
            v_count := v_count + 1;
        END LOOP;

        RETURN v_count;
    END discover_and_register_tables;


    ----------------------------------------------------------------------
    -- b_ddl_table_ref (privée, v5)
    --
    -- Rôle : référence de table adaptée à un DDL côté SCHEMA_B. Contrairement
    --        à b_table_ref (DML, suffixe @link), un DDL ne supporte pas le
    --        pont DB LINK. Le DDL est TOUJOURS qualifié par C_SCHEMA_B : la
    --        session du lien (ORASYNC_LINK_USER=SYNC_ADMIN) ne doit PAS être
    --        confondue avec le propriétaire réel des tables (SCHEMA_B) — seul
    --        un compte disposant des privilèges système requis (CREATE ANY
    --        TABLE, ALTER ANY TABLE) peut l'exécuter au travers du lien.
    ----------------------------------------------------------------------
    FUNCTION b_ddl_table_ref(p_table_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN C_SCHEMA_B || '.' || sanitize_ident(p_table_name);
    END b_ddl_table_ref;


    --------------------------------------------------------------------------
    -- fk_exists_at_b (privée, v5.3)
    --
    -- Rôle : indiquer si une contrainte FK donnée existe EFFECTIVEMENT côté
    --        SCHEMA_B (même table, même nom, type 'R'). Sert au disable des
    --        cycles FK : quand le graphe de contraintes diverge entre A et B
    --        (FK présente côté A, absente côté B — scénario réel observé sur
    --        deux bases jumelles dont l'une a évolué), tenter le
    --        ALTER ... DISABLE CONSTRAINT lèverait ORA-02431 ("no such
    --        constraint") et, par le repli all-or-nothing des grappes
    --        cycliques, ferait exclure TOUTE la grappe de 30+ tables pour
    --        une contrainte qui n'existe pas côté B.
    -- Sécurité : une FK absente de B ne peut PAS violer d'INSERT côté B
    --        (aucune contrainte à vérifier) : ignorer sa désactivation est
    --        donc sans risque pour l'intégrité de B.
    -- Limite : comme exec_ddl_at_b, n'est utilisable qu'en mode "même
    --        instance" (g_db_link_b IS NULL) ; sinon on renvoie TRUE pour
    --        préserver le comportement historique (lèvement de
    --        E_REMOTE_DDL_UNSUPPORTED au premier DDL plutôt qu'un skip
    --        silencieux).
    --------------------------------------------------------------------------
    FUNCTION fk_exists_at_b(
        p_table_name      IN VARCHAR2,
        p_constraint_name IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_count PLS_INTEGER;
    BEGIN
        IF g_db_link_b IS NOT NULL THEN
            RETURN TRUE;
        END IF;
        SELECT COUNT(*) INTO v_count
        FROM ALL_CONSTRAINTS
        WHERE owner          = C_SCHEMA_B
          AND table_name     = p_table_name
          AND constraint_name = p_constraint_name
          AND constraint_type = 'R';
        RETURN v_count > 0;
    END fk_exists_at_b;


    --------------------------------------------------------------------------
    -- disable_cluster_fks / enable_cluster_fks (privées, v5)
    --
    -- Rôle : désactiver (respectivement réactiver), côté SCHEMA_B, les
    --        contraintes FK NON DÉFERRABLES dont les deux extrémités
    --        appartiennent à la même grappe cyclique (option
    --        CYCLE_HANDLING='DISABLE_FK'). Les FKs déferrables restent
    --        confiées au SET CONSTRAINTS ALL DEFERRED ; les autres FKs (vers
    --        des tables hors grappe) sont hors de propos (données parentes
    --        déjà présentes en B) et ne sont pas touchées.
    -- Sécurité : si la désactivation échoue en cours de route (ex. contrainte
    --        absente de B sous un autre nom), les contraintes DÉJÀ désactivées
    --        sont immédiatement réactivées puis l'erreur est propagée vers
    --        execute_clusters, qui replie la grappe sur l'exclusion BLOCKING.
    --        La réactivation est systématique en fin de grappe, y compris sur
    --        échec de table (process_cluster encaisse) — un run ne doit JAMAIS
    --        laisser une FK désactivée derrière lui.
    --------------------------------------------------------------------------
    FUNCTION disable_cluster_fks(
        p_cluster_id      IN  NUMBER,
        p_cluster_tables  IN  t_cluster_table_tab
    ) RETURN t_str_tab IS
        v_done      t_str_tab;   -- 'child_table|constraint_name' désactivées
        v_refs      t_fk_ref_tab;
        v_member    BOOLEAN;
        v_token     VARCHAR2(257);
    BEGIN
        FOR i IN 1 .. p_cluster_tables.COUNT LOOP
            IF p_cluster_tables(i).cluster_id = p_cluster_id THEN
                v_refs := fk_parent_refs(p_cluster_tables(i).table_name);
                FOR r IN 1 .. v_refs.COUNT LOOP
                    IF v_refs(r).deferrable = 'DEFERRABLE' THEN
                        CONTINUE;
                    END IF;
                    v_member := FALSE;
                    FOR j IN 1 .. p_cluster_tables.COUNT LOOP
                        IF p_cluster_tables(j).cluster_id = p_cluster_id
                           AND p_cluster_tables(j).table_name = v_refs(r).parent_table THEN
                            v_member := TRUE;
                            EXIT;
                        END IF;
                    END LOOP;
                    IF NOT v_member THEN
                        CONTINUE;
                    END IF;

                    v_token := p_cluster_tables(i).table_name || '|' || v_refs(r).constraint_name;
                    IF is_in_list(v_token, v_done) THEN
                        CONTINUE;
                    END IF;

                    -- v5.3 : FK présente en A mais absente de B (graphe FK
                    -- divergent entre les deux bases) : rien à désactiver
                    -- côté B. Sauter est sans risque — aucun INSERT ne peut
                    -- violer une contrainte inexistante — et évite un
                    -- ORA-02431 qui, par le repli all-or-nothing des grappes
                    -- cycliques, ferait exclure TOUTE la grappe en BLOCKING.
                    IF NOT fk_exists_at_b(p_cluster_tables(i).table_name, v_refs(r).constraint_name) THEN
                        DBMS_OUTPUT.PUT_LINE('disable_cluster_fks : FK ' || v_refs(r).constraint_name
                            || ' absente de ' || C_SCHEMA_B || ' (graphe FK divergent), ignoree');
                        CONTINUE;
                    END IF;

                    BEGIN
                        exec_ddl_at_b('ALTER TABLE ' || b_ddl_table_ref(p_cluster_tables(i).table_name)
                            || ' DISABLE CONSTRAINT ' || sanitize_ident(v_refs(r).constraint_name));
                        v_done(v_done.COUNT + 1) := v_token;
                        DBMS_OUTPUT.PUT_LINE('disable_cluster_fks : FK ' || v_refs(r).constraint_name
                            || ' desactivee sur ' || p_cluster_tables(i).table_name);
                    EXCEPTION
                        WHEN OTHERS THEN
                            -- Réactivation immédiate du travail déjà fait, puis
                            -- propagation (execute_clusters replie en BLOCKING).
                            FOR k IN 1 .. v_done.COUNT LOOP
                                DECLARE
                                    v_t  VARCHAR2(128) := SUBSTR(v_done(k), 1, INSTR(v_done(k), '|') - 1);
                                    v_c  VARCHAR2(128) := SUBSTR(v_done(k), INSTR(v_done(k), '|') + 1);
                                BEGIN
                                    exec_ddl_at_b('ALTER TABLE ' || b_ddl_table_ref(v_t)
                                        || ' ENABLE CONSTRAINT ' || sanitize_ident(v_c));
                                EXCEPTION
                                    WHEN OTHERS THEN
                                        NULL; -- propagée plus bas ; on re-tente les suivantes
                                END;
                            END LOOP;
                            RAISE;
                    END;
                END LOOP;
            END IF;
        END LOOP;

        RETURN v_done;
    END disable_cluster_fks;


    PROCEDURE enable_cluster_fks(
        p_disabled        IN  t_str_tab,
        p_cluster_id      IN  NUMBER,
        p_cluster_tables  IN  t_cluster_table_tab
    ) IS
        v_refs    t_fk_ref_tab;
        v_found   BOOLEAN;
    BEGIN
        FOR i IN 1 .. p_cluster_tables.COUNT LOOP
            IF p_cluster_tables(i).cluster_id = p_cluster_id THEN
                v_refs := fk_parent_refs(p_cluster_tables(i).table_name);
                FOR r IN 1 .. v_refs.COUNT LOOP
                    v_found := FALSE;
                    FOR k IN 1 .. p_disabled.COUNT LOOP
                        IF p_disabled(k) = p_cluster_tables(i).table_name || '|' || v_refs(r).constraint_name THEN
                            v_found := TRUE;
                            EXIT;
                        END IF;
                    END LOOP;
                    IF v_found THEN
                        exec_ddl_at_b('ALTER TABLE ' || b_ddl_table_ref(p_cluster_tables(i).table_name)
                            || ' ENABLE CONSTRAINT ' || sanitize_ident(v_refs(r).constraint_name));
                        DBMS_OUTPUT.PUT_LINE('enable_cluster_fks : FK ' || v_refs(r).constraint_name
                            || ' reactivee sur ' || p_cluster_tables(i).table_name);
                    END IF;
                END LOOP;
            END IF;
        END LOOP;
    END enable_cluster_fks;


    ----------------------------------------------------------------------
    -- execute_clusters (privée)
    --
    -- Rôle : point commun d'exécution de la phase "grappes" d'un run, partagé
    --        par SYNC_ALL et SYNC_TABLES (factorisation du corps historique de
    --        SYNC_ALL) :
    --          - calcul des grappes FK / tri topologique / exclusions de cycle ;
    --          - mise à jour des compteurs de l'en-tête (TOTAL_TABLES /
    --            TABLES_EXCLUDED) ;
    --          - traitement des grappes par priorité moyenne croissante, avec
    --            SET CONSTRAINTS ALL DEFERRED avant chaque grappe requérant un
    --            cycle déferrable, COMMIT par grappe, SAVEPOINT par table ;
    --          - statut final agrégé et clôture de l'en-tête.
    --
    -- p_active_tables  : tables DÉJÀ filtrées des blocages BLOCKING (par
    --                    l'appelant, via SYNC_COMPATIBILITY_REPORT du CHECK_ID) ;
    -- p_total_tables   : ensemble de référence (avant filtrage des blocages) ;
    -- p_excluded_base  : nombre de tables déjà exclues AVANT les grappes
    --                    (= p_total_tables - p_active_tables.COUNT).
    --
    -- Gère sa propre journalisation d'échec structurel (ROLLBACK + run FAILED
    -- + RAISE) : un échec interne laisse l'exception se propager telle quelle.
    ----------------------------------------------------------------------
    PROCEDURE execute_clusters(
        p_run_id            IN  NUMBER,
        p_dry_run           IN  BOOLEAN,
        p_error_mode        IN  VARCHAR2,
        p_sync_mode         IN  VARCHAR2,
        p_active_tables     IN  t_str_tab,
        p_check_id          IN  NUMBER,
        p_total_tables      IN  NUMBER,
        p_excluded_base     IN  NUMBER
    ) IS
        v_cluster_tables    t_cluster_table_tab;
        v_cluster_meta      t_cluster_meta_tab;
        v_ordered_idx       t_num_tab;
        v_excluded_count    NUMBER := p_excluded_base;
        v_success_count     NUMBER := 0;
        v_conflict_count    NUMBER := 0;
        v_failed_count      NUMBER := 0;
        v_stopped_early     BOOLEAN := FALSE;
        v_final_status      VARCHAR2(30);
    BEGIN
        compute_run_clusters(p_active_tables, p_check_id, v_cluster_tables, v_cluster_meta);

        FOR i IN 1 .. v_cluster_meta.COUNT LOOP
            IF v_cluster_meta(i).excluded THEN
                FOR j IN 1 .. v_cluster_tables.COUNT LOOP
                    IF v_cluster_tables(j).cluster_id = v_cluster_meta(i).cluster_id THEN
                        v_excluded_count := v_excluded_count + 1;
                    END IF;
                END LOOP;
            END IF;
        END LOOP;

        UPDATE SYNC_RUN_HEADER
        SET total_tables = p_total_tables, tables_excluded = v_excluded_count
        WHERE run_id = p_run_id;
        COMMIT;

        v_ordered_idx := order_clusters_by_priority(v_cluster_meta);

        FOR oi IN 1 .. v_ordered_idx.COUNT LOOP
            EXIT WHEN v_stopped_early;

            DECLARE
                v_meta_idx     PLS_INTEGER := v_ordered_idx(oi);
                v_cid          NUMBER := v_cluster_meta(v_meta_idx).cluster_id;
                v_disabled     t_str_tab;
                v_need_reenable BOOLEAN := FALSE;
                v_skip_cluster BOOLEAN := FALSE;
            BEGIN
                IF v_cluster_meta(v_meta_idx).requires_deferred THEN
                    EXECUTE IMMEDIATE 'SET CONSTRAINTS ALL DEFERRED';
                    -- Limite connue (signalée) : portée locale au schéma A
                    -- uniquement, cf. commentaire détaillé en Partie 3.
                END IF;

                -- v5 : cycle FK non déferrable -> désactivation temporaire des
                -- FKs du cycle côté SCHEMA_B (option CYCLE_HANDLING=DISABLE_FK).
                -- En cas d'échec de désactivation, la grappe est repliée sur
                -- l'exclusion BLOCKING (comportement historique) : les FKs
                -- éventuellement déjà désactivées ont été réactivées en interne.
                IF v_cluster_meta(v_meta_idx).requires_cycle_disable THEN
                    BEGIN
                        v_disabled := disable_cluster_fks(v_cid, v_cluster_tables);
                        v_need_reenable := TRUE;
                        v_skip_cluster := FALSE;
                    EXCEPTION
                        WHEN OTHERS THEN
                            FOR j IN 1 .. v_cluster_tables.COUNT LOOP
                                IF v_cluster_tables(j).cluster_id = v_cid THEN
                                    v_excluded_count := v_excluded_count + 1;
                                    insert_compat_report(
                                        p_check_id      => p_check_id,
                                        p_table_name    => v_cluster_tables(j).table_name,
                                        p_column_name   => NULL,
                                        p_issue_type    => C_ISSUE_FK_CYCLE_NOT_DEFERRABLE,
                                        p_severity      => C_SEVERITY_BLOCKING,
                                        p_detail_a      => 'Desactivation FK impossible cote B (repli BLOCK) : ' || SUBSTR(SQLERRM, 1, 4000),
                                        p_detail_b      => NULL
                                    );
                                END IF;
                            END LOOP;
                            v_skip_cluster := TRUE;
                            v_need_reenable := FALSE;
                    END;
                END IF;

                IF NOT v_skip_cluster THEN
                    process_cluster(p_run_id, v_cid, v_cluster_tables, p_dry_run, p_error_mode, p_sync_mode,
                        p_check_id, v_success_count, v_conflict_count, v_failed_count, v_stopped_early);
                END IF;

                -- Réactivation systématique des FKs désactivées pour cette
                -- grappe (on ne laisse JAMAIS une FK désactivée derrière soi ;
                -- un échec ici est structurel : run FAILED + RAISE).
                IF v_need_reenable THEN
                    BEGIN
                        enable_cluster_fks(v_disabled, v_cid, v_cluster_tables);
                    EXCEPTION
                        WHEN OTHERS THEN
                            ROLLBACK;
                            UPDATE SYNC_RUN_HEADER SET
                                end_date = SYSTIMESTAMP, status = C_STATUS_FAILED
                            WHERE run_id = p_run_id;
                            COMMIT;
                            RAISE E_FK_CYCLE_DETECTED;
                    END;
                END IF;

                COMMIT; -- commit de la grappe entière (décision validée), qu'elle
                        -- contienne ou non des tables en échec (celles-ci ont déjà
                        -- été annulées individuellement par ROLLBACK TO SAVEPOINT
                        -- dans process_cluster ; ce COMMIT ne valide donc que le
                        -- travail des tables réussies de la grappe)
            END;
        END LOOP;

        v_final_status := compute_final_status(
            p_total_tables, v_success_count, v_conflict_count, v_failed_count, v_excluded_count
        );
        IF v_stopped_early AND v_final_status = C_STATUS_SUCCESS THEN
            -- Cas limite : arrêt anticipé mais aucune table en échec comptée
            -- (ne devrait pas arriver en pratique, v_stopped_early n'est mis à
            -- TRUE que suite à un échec, mais gardé par prudence défensive).
            v_final_status := C_STATUS_PARTIAL;
        END IF;

        UPDATE SYNC_RUN_HEADER SET
            end_date = SYSTIMESTAMP,
            status = v_final_status,
            tables_success = v_success_count,
            tables_conflict = v_conflict_count,
            tables_failed = v_failed_count,
            tables_excluded = v_excluded_count
        WHERE run_id = p_run_id;
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            -- Erreur structurelle survenue dans la phase grappes : le run est
            -- marqué FAILED et l'exception est propagée à l'appelant, jamais
            -- masquée (décision validée). ROLLBACK préalable (correctif v2) :
            -- on ne doit pas valider par le COMMIT de l'en-tête un éventuel
            -- travail de grappe déjà fait mais non commité.
            ROLLBACK;
            UPDATE SYNC_RUN_HEADER SET
                end_date = SYSTIMESTAMP, status = C_STATUS_FAILED
            WHERE run_id = p_run_id;
            COMMIT;
            RAISE;
    END execute_clusters;


    ----------------------------------------------------------------------
    -- SYNC_ALL  (procédure publique)
    ----------------------------------------------------------------------
    PROCEDURE SYNC_ALL (
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_run_id        OUT NUMBER,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT
    ) IS
        v_run_id            NUMBER := SYNC_RUN_ID_SEQ.NEXTVAL;
        v_check_id          NUMBER;
        v_blocking          BOOLEAN;
        v_active_tables     t_str_tab;
        v_total_tables      NUMBER := 0;
        v_config_count      NUMBER;
        v_discovered_count  NUMBER;
        v_names             t_str_tab;
        -- Oracle SQL n'a pas de type BOOLEAN (contrairement à PL/SQL) : un
        -- paramètre IN BOOLEAN ne peut jamais être référencé, même via
        -- CASE WHEN, à l'intérieur d'une instruction SQL statique (INSERT/
        -- UPDATE/SELECT) — d'où ORA-00920 si on l'y tente directement. On
        -- convertit donc TOUJOURS le BOOLEAN en VARCHAR2 'Y'/'N' par une
        -- affectation PL/SQL pure (ligne ci-dessous, hors de tout contexte
        -- SQL), puis on n'utilise plus que cette variable dans le INSERT.
        v_dry_run_flag      VARCHAR2(1) := CASE WHEN p_dry_run THEN 'Y' ELSE 'N' END;
    BEGIN
        -- Correctif v2 : valider AVANT d'appliquer l'override. Sinon un
        -- p_db_link invalide était écrit dans g_db_link_b par
        -- apply_db_link_override AVANT que validate_common_params ne lève
        -- l'erreur, corrompant l'état de session pour tous les appels suivants.
        validate_common_params(p_error_mode, p_db_link);
        validate_sync_mode(p_sync_mode);
        apply_db_link_override(p_db_link);

        INSERT INTO SYNC_RUN_HEADER (run_id, run_type, dry_run, error_mode)
        VALUES (v_run_id, 'SYNC_ALL', v_dry_run_flag, p_error_mode);
        COMMIT; -- l'en-tête doit rester traçable même si tout échoue ensuite

        p_run_id := v_run_id;

        ------------------------------------------------------------------
        -- 0) Découverte automatique si SYNC_TABLE_CONFIG est totalement vide
        ------------------------------------------------------------------
        SELECT COUNT(*) INTO v_config_count FROM SYNC_TABLE_CONFIG;

        IF v_config_count = 0 THEN
            v_discovered_count := discover_and_register_tables;
            COMMIT;
        END IF;

        ------------------------------------------------------------------
        -- 1) Compatibilité (systématique en tête de run, décision validée)
        -- Invoqué en interne (compat_check_core, NON via l'overload public) :
        -- p_enroll_fk=TRUE pour l'auto-enrôlement v4 des parents FK, et
        -- p_allow_ddl=NOT p_dry_run pour laisser l'auto-création v5 créer en B
        -- les tables actives absentes (option AUTO_CREATE_MISSING_TABLE) sur un
        -- vrai run — jamais sur un dry-run ni sur un contrôle autonome.
        ------------------------------------------------------------------
        SELECT table_name BULK COLLECT INTO v_names
        FROM SYNC_TABLE_CONFIG
        WHERE enabled = 'Y';

        -- v4 : fermeture COMPLÈTE de la lignée FK côté SCHEMA_A (seeds ∪ ancêtres).
        IF v_names.COUNT > 0 THEN
            v_names := build_fk_ancestors_raw(v_names);
        END IF;

        compat_check_core(v_names, v_check_id, v_blocking,
            p_enroll_fk => TRUE, p_allow_ddl => NOT p_dry_run);

        -- v4 : persistance de l'enrôlement automatique de la lignée FK.
        COMMIT;

        -- TOTAL_TABLES = ensemble de référence : nombre de tables ACTIVES
        -- avant filtrage des blocages (corrige le bug v1 où total valait le
        -- sous-ensemble déjà filtré, puis se faisait re-soustraire les mêmes
        -- tables bloquantes dans compute_final_status -> processed faussé).
        SELECT COUNT(*) INTO v_total_tables
        FROM SYNC_TABLE_CONFIG
        WHERE enabled = 'Y' AND sync_direction != C_DIRECTION_DISABLED;

        -- Tables actives non bloquantes = ensemble réellement traité. Le reste
        -- est porté dans p_excluded_base de execute_clusters (comptabilisé en
        -- TABLES_EXCLUDED, ainsi que les membres de grappes FK en cycle).
        SELECT table_name BULK COLLECT INTO v_active_tables
        FROM SYNC_TABLE_CONFIG stc
        WHERE enabled = 'Y' AND sync_direction != C_DIRECTION_DISABLED
          AND NOT EXISTS (
              SELECT 1 FROM SYNC_COMPATIBILITY_REPORT r
              WHERE r.check_id = v_check_id AND r.table_name = stc.table_name AND r.severity = C_SEVERITY_BLOCKING
          );

        ------------------------------------------------------------------
        -- 2) Exécution des grappes (factorisée avec SYNC_TABLES)
        ------------------------------------------------------------------
        execute_clusters(v_run_id, p_dry_run, p_error_mode, p_sync_mode, v_active_tables, v_check_id,
            v_total_tables, v_total_tables - v_active_tables.COUNT);

    EXCEPTION
        WHEN OTHERS THEN
            -- Erreur structurelle survenue AVANT ou EN DEHORS de la phase
            -- grappes (ex. schéma/DB LINK inaccessible dès
            -- CHECK_COMPATIBILITY). Le run est marqué FAILED et l'exception
            -- est propagée à l'appelant, jamais masquée (décision validée).
            -- ROLLBACK préalable (correctif v2) : on ne doit PAS valider par
            -- le COMMIT de l'en-tête un éventuel travail de grappe déjà fait
            -- mais non commité.
            ROLLBACK;
            UPDATE SYNC_RUN_HEADER SET
                end_date = SYSTIMESTAMP, status = C_STATUS_FAILED
            WHERE run_id = v_run_id;
            COMMIT;
            RAISE;
    END SYNC_ALL;


    ----------------------------------------------------------------------
    -- SYNC_TABLE  (procédure publique)
    --
    -- Rappel (cf. spécification, Script 3) : ne traite QUE la table
    -- demandée, jamais le reste de sa grappe FK — traitée comme une grappe
    -- singleton, sans calcul de dépendances avec d'autres tables. Un seul
    -- SAVEPOINT/COMMIT, pas de notion de PRIORITY inter-grappes (une seule
    -- table = un seul "cluster" implicite).
    ----------------------------------------------------------------------
    PROCEDURE SYNC_TABLE (
        p_table_name    IN  VARCHAR2,
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_run_id        OUT NUMBER,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT
    ) IS
        v_run_id        NUMBER := SYNC_RUN_ID_SEQ.NEXTVAL;
        v_check_id      NUMBER;
        v_blocking      BOOLEAN;
        v_status        VARCHAR2(30);
        v_exists        NUMBER;
        v_final_status  VARCHAR2(30);
        -- Cf. commentaire équivalent dans SYNC_ALL : un BOOLEAN PL/SQL ne
        -- peut jamais être référencé, même via CASE WHEN, à l'intérieur
        -- d'une instruction SQL statique (ORA-00920 sinon).
        v_dry_run_flag  VARCHAR2(1) := CASE WHEN p_dry_run THEN 'Y' ELSE 'N' END;
    BEGIN
        -- Correctif v2 : valider AVANT d'appliquer l'override (cf. même
        -- correctif dans SYNC_ALL : évite de corrompre g_db_link_b sur un
        -- p_db_link invalide).
        validate_common_params(C_ERROR_MODE_STOP, p_db_link);
        validate_sync_mode(p_sync_mode);
        apply_db_link_override(p_db_link);

        SELECT COUNT(*) INTO v_exists FROM SYNC_TABLE_CONFIG
        WHERE table_name = p_table_name AND enabled = 'Y' AND sync_direction != C_DIRECTION_DISABLED;

        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Table non configuree ou desactivee pour la synchronisation : ' || p_table_name);
        END IF;

        INSERT INTO SYNC_RUN_HEADER (run_id, run_type, dry_run, error_mode)
        VALUES (v_run_id, 'SYNC_TABLE', v_dry_run_flag, C_ERROR_MODE_STOP);
        COMMIT;

        p_run_id := v_run_id;

        DECLARE
            v_single t_str_tab;
        BEGIN
            v_single(1) := p_table_name;
            -- v5 : p_allow_ddl=NOT p_dry_run autorise l'auto-création en B de la
            -- table si l'option AUTO_CREATE_MISSING_TABLE='Y' (run réel uniquement).
            compat_check_core(v_single, v_check_id, v_blocking,
                p_enroll_fk => FALSE, p_allow_ddl => NOT p_dry_run);
        END;

        IF v_blocking THEN
            UPDATE SYNC_RUN_HEADER SET
                end_date = SYSTIMESTAMP, status = C_STATUS_FAILED, total_tables = 1, tables_excluded = 1
            WHERE run_id = v_run_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20003,
                'Table incompatible entre SCHEMA_A et SCHEMA_B (voir SYNC_COMPATIBILITY_REPORT, CHECK_ID=' ||
                v_check_id || ') : ' || p_table_name);
        END IF;

        UPDATE SYNC_RUN_HEADER SET total_tables = 1 WHERE run_id = v_run_id;
        COMMIT;

        SAVEPOINT sp_table;
        BEGIN
            process_one_table(v_run_id, p_table_name, NULL, 1, p_sync_mode, p_dry_run, v_check_id, v_status);
            v_final_status := v_status;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN
                DECLARE
                    v_err_msg VARCHAR2(4000) := SUBSTR(SQLERRM, 1, 4000);
                    v_err_bt  CLOB := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
                BEGIN
                    ROLLBACK TO SAVEPOINT sp_table;
                    INSERT INTO SYNC_LOG (
                        log_id, run_id, table_name, status, cluster_order,
                        end_date, error_count, error_message, error_backtrace
                    ) VALUES (
                        SYNC_LOG_ID_SEQ.NEXTVAL, v_run_id, p_table_name, C_STATUS_FAILED, 1,
                        SYSTIMESTAMP, 1, v_err_msg, v_err_bt
                    );
                    v_final_status := C_STATUS_FAILED;
                    COMMIT;
                END;
        END;

        UPDATE SYNC_RUN_HEADER SET
            end_date = SYSTIMESTAMP,
            status = v_final_status,
            tables_success = CASE WHEN v_final_status IN (C_STATUS_SUCCESS, C_STATUS_SUCCESS_CONFLICTS) THEN 1 ELSE 0 END,
            tables_conflict = CASE WHEN v_final_status = C_STATUS_SUCCESS_CONFLICTS THEN 1 ELSE 0 END,
            tables_failed = CASE WHEN v_final_status = C_STATUS_FAILED THEN 1 ELSE 0 END
        WHERE run_id = v_run_id;
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            UPDATE SYNC_RUN_HEADER SET end_date = SYSTIMESTAMP, status = C_STATUS_FAILED WHERE run_id = v_run_id;
            COMMIT;
            RAISE;
    END SYNC_TABLE;


    ----------------------------------------------------------------------
    -- SYNC_TABLES  (procédure publique)
    --
    -- Rôle : synchronise une LISTE de tables (type public t_tab_name_list)
    --        avec RÉSOLUTION IMPLICITE DES DÉPENDANCES FK (parents). Cf.
    --        spécification (Script 3) pour la doc fonctionnelle complète.
    --
    -- Séquence :
    --   1. validation des paramètres (liste non vide, p_error_mode, p_db_link,
    --      p_sync_mode), puis validation de chaque table demandée (existante et
    --      ACTIVE : ENABLED='Y' et SYNC_DIRECTION != 'DISABLED'), sinon
    --      E_TABLE_NOT_CONFIGURED ;
    --   2. fermeture transitive COMPLÈTE des ANCÊTRES FK côté SCHEMA_A
    --      (build_fk_ancestors_raw : demandées ∪ parents, sans filtrage
    --      config — v4, l'ancien filtre expirait par expand_fk_ancestors) ;
    --   3. en-tête (RUN_TYPE='SYNC_TABLES'), CHECK_COMPATIBILITY sur le
    --      sous-ensemble (un seul CHECK_ID, + enrôlement automatique v4 des
    --      parents FK absents), filtration des tables BLOCKING ;
    --   4. exécution par grappes (execute_clusters, identique à SYNC_ALL).
    ----------------------------------------------------------------------
    PROCEDURE SYNC_TABLES (
        p_table_list    IN  t_tab_name_list,
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_db_link       IN  VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
        p_sync_mode     IN  VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT,
        p_run_id        OUT NUMBER
    ) IS
        v_run_id        NUMBER := SYNC_RUN_ID_SEQ.NEXTVAL;
        v_check_id      NUMBER;
        v_blocking      BOOLEAN;
        v_requested     t_str_tab;
        v_run_set       t_str_tab;
        v_active        t_str_tab;
        v_exists        NUMBER;
        v_block         NUMBER;
        v_total         NUMBER;
        -- Cf. commentaire équivalent dans SYNC_ALL : un BOOLEAN PL/SQL ne peut
        -- pas être référencé dans une instruction SQL statique.
        v_dry_run_flag  VARCHAR2(1) := CASE WHEN p_dry_run THEN 'Y' ELSE 'N' END;
    BEGIN
        IF p_table_list IS NULL OR p_table_list.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'Parametre p_table_list vide : au moins une table logique attendue.');
        END IF;

        validate_common_params(p_error_mode, p_db_link);
        validate_sync_mode(p_sync_mode);
        apply_db_link_override(p_db_link);

        -- 1) Validation : chaque table de la liste doit être active en config.
        FOR i IN 1 .. p_table_list.COUNT LOOP
            v_requested(i) := UPPER(TRIM(p_table_list(i)));

            SELECT COUNT(*) INTO v_exists FROM SYNC_TABLE_CONFIG
            WHERE table_name = v_requested(i)
              AND enabled = 'Y'
              AND sync_direction != C_DIRECTION_DISABLED;

            IF v_exists = 0 THEN
                RAISE_APPLICATION_ERROR(-20002,
                    'Table non configuree ou desactivee pour la synchronisation : ' || v_requested(i));
            END IF;
        END LOOP;

        -- 2) Résolution implicite des parents FK (fermeture brute COMPLÈTE).
        v_run_set := build_fk_ancestors_raw(v_requested);

        INSERT INTO SYNC_RUN_HEADER (run_id, run_type, dry_run, error_mode)
        VALUES (v_run_id, 'SYNC_TABLES', v_dry_run_flag, p_error_mode);
        COMMIT; -- l'en-tête doit rester traçable même si tout échoue ensuite

        p_run_id := v_run_id;

        -- 3) Compatibilité sur le sous-ensemble (un seul CHECK_ID), avec
        --    enrôlement automatique v4 (parents FK absents ajoutés à
        --    SYNC_TABLE_CONFIG), puis filtration des tables BLOCKING.
        --    TOTAL_TABLES = ensemble de run (demandées + ancêtres), cohérent
        --    avec ce qui est réellement exécuté.
        v_total := v_run_set.COUNT;

        compat_check_core(v_run_set, v_check_id, v_blocking,
            p_enroll_fk => TRUE, p_allow_ddl => NOT p_dry_run);

        -- v4 : l'enrôlement automatique de la lignée FK est persisté.
        COMMIT;

        -- Tables réellement exécutées = ensemble de run, MOINS les tables
        -- BLOCKING, MOINS les tables PRÉSENTES MAIS DÉSACTIVÉES en config
        -- (parents FK désactivés : signalés FK_PARENT_DISABLED, jamais
        -- forcés — le run respecte l'intention de l'administrateur et ne les
        -- synchronise pas).
        FOR i IN 1 .. v_run_set.COUNT LOOP
            SELECT COUNT(*) INTO v_exists FROM SYNC_TABLE_CONFIG
            WHERE table_name = v_run_set(i)
              AND enabled = 'Y'
              AND sync_direction != C_DIRECTION_DISABLED;

            IF v_exists = 1 THEN
                SELECT COUNT(*) INTO v_block
                FROM SYNC_COMPATIBILITY_REPORT
                WHERE check_id = v_check_id AND table_name = v_run_set(i) AND severity = C_SEVERITY_BLOCKING;

                IF v_block = 0 THEN
                    v_active(v_active.COUNT + 1) := v_run_set(i);
                END IF;
            END IF;
        END LOOP;

        -- 4) Exécution des grappes (factorisée avec SYNC_ALL).
        execute_clusters(v_run_id, p_dry_run, p_error_mode, p_sync_mode, v_active, v_check_id,
            v_total, v_total - v_active.COUNT);

    EXCEPTION
        WHEN OTHERS THEN
            -- Erreur structurelle survenue AVANT ou EN DEHORS de la phase
            -- grappes : run marqué FAILED, exception propagée (jamais masquée).
            ROLLBACK;
            UPDATE SYNC_RUN_HEADER SET
                end_date = SYSTIMESTAMP, status = C_STATUS_FAILED
            WHERE run_id = v_run_id;
            COMMIT;
            RAISE;
    END SYNC_TABLES;


    ----------------------------------------------------------------------
    -- PURGE_HISTORY  (procédure publique) — cf. spécification (Script 3).
    --
    -- Rôle : purge de maintenance des tables d'historique. Tout enregistrement
    --        strictement antérieur à (SYSTIMESTAMP - p_keep_days) est supprimé.
    --        Les en-têtes de run ne sont purgés que si aucune ligne SYNC_LOG
    --        ne dépend encore d'eux (le run en cours d'un autre run résiduel
    --        n'est jamais cassé). Correctif v2 : automatisé, alors que le
    --        Script 2 signalait simplement cette purge comme "à prévoir".
    ----------------------------------------------------------------------
    PROCEDURE PURGE_HISTORY (
        p_keep_days IN NUMBER
    ) IS
        v_cutoff    TIMESTAMP;
        v_conflict  NUMBER := 0;
        v_compat    NUMBER := 0;
        v_log       NUMBER := 0;
        v_header    NUMBER := 0;
    BEGIN
        IF p_keep_days IS NULL OR p_keep_days <= 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'Parametre p_keep_days strictement positif attendu, recu : [' ||
                TO_CHAR(p_keep_days) || ']');
        END IF;

        v_cutoff := SYSTIMESTAMP - p_keep_days;

        DELETE FROM SYNC_CONFLICT WHERE resolved_date < v_cutoff;
        v_conflict := SQL%ROWCOUNT;

        DELETE FROM SYNC_COMPATIBILITY_REPORT WHERE check_date < v_cutoff;
        v_compat := SQL%ROWCOUNT;

        DELETE FROM SYNC_LOG WHERE start_date < v_cutoff;
        v_log := SQL%ROWCOUNT;

        DELETE FROM SYNC_RUN_HEADER h
        WHERE h.start_date < v_cutoff
          AND NOT EXISTS (SELECT 1 FROM SYNC_LOG l WHERE l.run_id = h.run_id);
        v_header := SQL%ROWCOUNT;

        DBMS_OUTPUT.PUT_LINE('PURGE_HISTORY(' || p_keep_days || ') - enregistrements supprimes : conflicts=' 
            || v_conflict || ', compatibility=' || v_compat || ', logs=' || v_log || ', headers=' || v_header);
    END PURGE_HISTORY;


    ----------------------------------------------------------------------
    -- GET_RUN_STATUS  (procédure publique)
    ----------------------------------------------------------------------
    PROCEDURE GET_RUN_STATUS (
        p_run_id            IN  NUMBER,
        p_header_cursor      OUT SYS_REFCURSOR,
        p_detail_cursor      OUT SYS_REFCURSOR
    ) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM SYNC_RUN_HEADER WHERE run_id = p_run_id;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20006, 'RUN_ID inconnu : ' || p_run_id);
        END IF;

        OPEN p_header_cursor FOR
            SELECT * FROM SYNC_RUN_HEADER WHERE run_id = p_run_id;

        OPEN p_detail_cursor FOR
            SELECT * FROM SYNC_LOG WHERE run_id = p_run_id ORDER BY cluster_id NULLS FIRST, cluster_order;
    END GET_RUN_STATUS;


    ----------------------------------------------------------------------
    -- SET_RUN_OPTION  (procédure publique, v5)
    ----------------------------------------------------------------------
    PROCEDURE SET_RUN_OPTION (p_option_name IN VARCHAR2, p_option_value IN VARCHAR2) IS
        v_name  VARCHAR2(64)  := UPPER(TRIM(p_option_name));
        v_value VARCHAR2(256) := TRIM(p_option_value);
    BEGIN
        IF v_name NOT IN (C_OPT_AUTO_BACKFILL_PARENTS, C_OPT_MAX_FK_RETRY,
                          C_OPT_CYCLE_HANDLING, C_OPT_AUTO_CREATE_MISSING_TABLE) THEN
            RAISE E_INVALID_PARAMETER;
        END IF;

        -- Correctif v5.1 : validation des VALEURS en dur (la contrainte
        -- CK_SRO_VALUE applique la même règle en base pour toute écriture qui
        -- contournerait l'API — "défense en profondeur"). Sans cela, une valeur
        -- quelconque (ex. 'BIDON') était persistée silencieusement et neutralisait
        -- l'option à l'exécution sans alerter l'opérateur.
        IF v_name IN (C_OPT_AUTO_BACKFILL_PARENTS, C_OPT_AUTO_CREATE_MISSING_TABLE) THEN
            IF v_value NOT IN ('Y', 'N') THEN
                RAISE_APPLICATION_ERROR(-20011,
                    'Valeur interdite pour l''option ' || v_name || ' : [' || v_value
                    || '] (attendu : Y ou N)');
            END IF;
        ELSIF v_name = C_OPT_CYCLE_HANDLING THEN
            IF v_value NOT IN ('DISABLE_FK', 'BLOCK') THEN
                RAISE_APPLICATION_ERROR(-20011,
                    'Valeur interdite pour l''option ' || v_name || ' : [' || v_value
                    || '] (attendu : DISABLE_FK ou BLOCK)');
            END IF;
        ELSE  -- C_OPT_MAX_FK_RETRY
            IF NOT REGEXP_LIKE(v_value, '^[1-9][0-9]{0,9}$') THEN
                RAISE_APPLICATION_ERROR(-20011,
                    'Valeur interdite pour l''option ' || v_name || ' : [' || v_value
                    || '] (attendu : entier positif)');
            END IF;
        END IF;

        MERGE INTO SYNC_RUN_OPTION t
        USING (SELECT v_name AS option_name, v_value AS option_value FROM DUAL) s
        ON (t.option_name = s.option_name)
        WHEN MATCHED THEN UPDATE SET option_value = s.option_value,
                                     updated_date = SYSTIMESTAMP, updated_by = USER
        WHEN NOT MATCHED THEN INSERT (option_name, option_value, updated_by)
            VALUES (s.option_name, s.option_value, USER);

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('SET_RUN_OPTION : ' || v_name || ' = ' || v_value);
    END SET_RUN_OPTION;


    ----------------------------------------------------------------------
    -- GET_RUN_OPTION  (fonction publique, v5)
    ----------------------------------------------------------------------
    FUNCTION GET_RUN_OPTION (p_option_name IN VARCHAR2) RETURN VARCHAR2 IS
        v_value VARCHAR2(256);
    BEGIN
        BEGIN
            SELECT option_value INTO v_value
            FROM SYNC_RUN_OPTION
            WHERE option_name = p_option_name;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_value := NULL;
        END;
        RETURN v_value;
    END GET_RUN_OPTION;

END PKG_SCHEMA_SYNC;
/

SHOW ERRORS PACKAGE BODY PKG_SCHEMA_SYNC;

--------------------------------------------------------------------------------
-- FIN DU CORPS DU PACKAGE (fichier fusionné, prêt à compiler)
--------------------------------------------------------------------------------