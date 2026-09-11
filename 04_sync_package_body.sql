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
    FUNCTION get_primary_or_unique_key(p_table_name IN VARCHAR2) RETURN t_str_tab IS
        v_result        t_str_tab;
        v_constraint    VARCHAR2(128);
    BEGIN
        -- Recherche PRIMARY KEY
        BEGIN
            SELECT constraint_name INTO v_constraint
            FROM ALL_CONSTRAINTS
            WHERE owner = C_SCHEMA_A
              AND table_name = p_table_name
              AND constraint_type = 'P'
              AND status = 'ENABLED';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_constraint := NULL;
            WHEN TOO_MANY_ROWS THEN v_constraint := NULL; -- ne devrait jamais arriver (une seule PK possible)
        END;

        -- A défaut, première contrainte UNIQUE active, ordre déterministe
        IF v_constraint IS NULL THEN
            BEGIN
                SELECT constraint_name INTO v_constraint
                FROM (
                    SELECT constraint_name
                    FROM ALL_CONSTRAINTS
                    WHERE owner = C_SCHEMA_A
                      AND table_name = p_table_name
                      AND constraint_type = 'U'
                      AND status = 'ENABLED'
                    ORDER BY constraint_name
                )
                WHERE ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN v_constraint := NULL;
            END;
        END IF;

        IF v_constraint IS NOT NULL THEN
            SELECT column_name
            BULK COLLECT INTO v_result
            FROM ALL_CONS_COLUMNS
            WHERE owner = C_SCHEMA_A
              AND table_name = p_table_name
              AND constraint_name = v_constraint
            ORDER BY position;
        END IF;

        RETURN v_result;  -- collection vide (non NULL, .COUNT=0) si rien trouvé
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
    -- Méthode : COUNT(*) vs COUNT(DISTINCT clé concaténée) côté A ET côté B
    --           (les deux doivent être vérifiés indépendamment : la clé peut
    --           être unique côté A mais pas côté B, notamment si B contient
    --           des données historiques divergentes).
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
        v_key_expr      VARCHAR2(4000) := '';
        v_sql           VARCHAR2(4000);
        v_total         NUMBER;
        v_distinct      NUMBER;
        v_table_ref     VARCHAR2(300);
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_key_expr := v_key_expr
                || CASE WHEN i > 1 THEN '||''~~''||' END
                || 'TO_CHAR(' || sanitize_ident(p_key_cols(i)) || ')';
        END LOOP;

        v_table_ref := sanitize_ident(p_owner) || '.' || sanitize_ident(p_table_name)
            || CASE WHEN p_db_link IS NOT NULL THEN '@' || sanitize_ident(p_db_link) END;

        v_sql := 'SELECT COUNT(*), COUNT(DISTINCT ' || v_key_expr || ') FROM ' || v_table_ref;

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
            IF NOT validate_key_uniqueness(p_table_name, v_key, C_SCHEMA_B, C_DB_LINK_B) THEN
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
            'FROM (SELECT * FROM ALL_TAB_COLUMNS WHERE owner = :owner_a AND table_name = :tbl) a ' ||
            'FULL OUTER JOIN ' ||
            '     (SELECT * FROM ALL_TAB_COLUMNS@' || sanitize_ident(C_DB_LINK_B) ||
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
    -- CHECK_COMPATIBILITY (procédure publique) — cf. Script 3 pour la doc
    -- fonctionnelle complète. Règles de sévérité résumées dans les
    -- commentaires du corps ci-dessous.
    --------------------------------------------------------------------------
    PROCEDURE CHECK_COMPATIBILITY (
        p_table_name            IN  VARCHAR2 DEFAULT NULL,
        p_check_id              OUT NUMBER,
        p_has_blocking_issues   OUT BOOLEAN
    ) IS
        v_check_id      NUMBER := SYNC_COMPAT_CHECK_ID_SEQ.NEXTVAL;
        v_blocking      BOOLEAN := FALSE;
        v_key           t_str_tab;
        v_compare       t_col_compare_tab;
        v_is_key        BOOLEAN;

        CURSOR c_tables IS
            SELECT table_name FROM SYNC_TABLE_CONFIG
            WHERE (p_table_name IS NULL OR table_name = p_table_name)
              AND enabled = 'Y';
    BEGIN
        FOR t IN c_tables LOOP

            IF NOT table_exists(C_SCHEMA_A, t.table_name, NULL) THEN
                insert_compat_report(v_check_id, t.table_name, NULL, 'MISSING_IN_A', C_SEVERITY_BLOCKING,
                    'Table absente', 'Table presente');
                v_blocking := TRUE;
                CONTINUE;
            END IF;

            IF NOT table_exists(C_SCHEMA_B, t.table_name, C_DB_LINK_B) THEN
                insert_compat_report(v_check_id, t.table_name, NULL, 'MISSING_IN_B', C_SEVERITY_BLOCKING,
                    'Table presente', 'Table absente');
                v_blocking := TRUE;
                CONTINUE;
            END IF;

            BEGIN
                v_key := get_effective_key(t.table_name);
            EXCEPTION
                WHEN OTHERS THEN
                    insert_compat_report(v_check_id, t.table_name, NULL, 'PK_MISSING', C_SEVERITY_BLOCKING,
                        SQLERRM, NULL);
                    v_blocking := TRUE;
                    CONTINUE;
            END;

            v_compare := get_column_comparison(t.table_name);

            FOR i IN 1 .. v_compare.COUNT LOOP

                v_is_key := FALSE;
                FOR k IN 1 .. v_key.COUNT LOOP
                    IF v_key(k) = v_compare(i).column_name THEN
                        v_is_key := TRUE;
                    END IF;
                END LOOP;

                IF v_compare(i).a_data_type IS NULL THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'MISSING_IN_A', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        NULL, v_compare(i).b_data_type);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF v_compare(i).b_data_type IS NULL THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'MISSING_IN_B', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        v_compare(i).a_data_type, NULL);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF NOT is_type_supported(v_compare(i).a_data_type, v_compare(i).a_type_owner)
                   OR NOT is_type_supported(v_compare(i).b_data_type, v_compare(i).b_type_owner) THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'UNSUPPORTED_TYPE', CASE WHEN v_is_key THEN C_SEVERITY_BLOCKING ELSE C_SEVERITY_WARNING END,
                        v_compare(i).a_data_type, v_compare(i).b_data_type);
                    IF v_is_key THEN v_blocking := TRUE; END IF;
                    CONTINUE;
                END IF;

                IF v_compare(i).a_data_type != v_compare(i).b_data_type THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'TYPE_MISMATCH', C_SEVERITY_BLOCKING,
                        v_compare(i).a_data_type, v_compare(i).b_data_type);
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;

                IF NVL(v_compare(i).a_data_length, -1)     != NVL(v_compare(i).b_data_length, -1)
                   OR NVL(v_compare(i).a_data_precision, -1) != NVL(v_compare(i).b_data_precision, -1)
                   OR NVL(v_compare(i).a_data_scale, -1)     != NVL(v_compare(i).b_data_scale, -1) THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'LENGTH_MISMATCH', C_SEVERITY_BLOCKING,
                        v_compare(i).a_data_type || '(' || v_compare(i).a_data_length || ')',
                        v_compare(i).b_data_type || '(' || v_compare(i).b_data_length || ')');
                    v_blocking := TRUE;
                    CONTINUE;
                END IF;

                IF NVL(v_compare(i).a_nullable, 'Y') != NVL(v_compare(i).b_nullable, 'Y') THEN
                    insert_compat_report(v_check_id, t.table_name, v_compare(i).column_name,
                        'NULLABLE_MISMATCH', C_SEVERITY_WARNING,
                        v_compare(i).a_nullable, v_compare(i).b_nullable);
                END IF;

            END LOOP;

        END LOOP;

        p_check_id := v_check_id;
        p_has_blocking_issues := v_blocking;
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

                        IF v_all_deferrable THEN
                            -- Grappe acceptée avec contraintes différées ; ordre arbitraire
                            -- déterministe (alphabétique) pour les tables restantes, car leur
                            -- ordre relatif est sans importance tant que les FK ne sont
                            -- vérifiées qu'au COMMIT (SET CONSTRAINTS ALL DEFERRED).
                            DECLARE
                                v_remaining t_str_tab;
                                v_rem_count PLS_INTEGER := 0;
                                v_tmp       VARCHAR2(128);
                            BEGIN
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
                                FOR i IN 1 .. v_rem_count LOOP
                                    v_order := v_order + 1;
                                    v_out_idx := v_out_idx + 1;
                                    p_tables(v_out_idx).cluster_id := v_cid;
                                    p_tables(v_out_idx).table_name := v_remaining(i);
                                    p_tables(v_out_idx).topo_order := v_order;
                                END LOOP;
                            END;

                            p_cluster_meta(v_meta_idx).requires_deferred := TRUE;
                            p_cluster_meta(v_meta_idx).excluded          := FALSE;

                            -- Traçabilité même en cas d'acceptation : un cycle, même
                            -- déferrable, reste une situation à surveiller. Une ligne
                            -- PAR TABLE du cycle (et non une ligne unique avec la liste
                            -- concaténée en TABLE_NAME, qui risquerait ORA-12899 dès que
                            -- le cycle comporte plusieurs tables aux noms un peu longs :
                            -- TABLE_NAME est VARCHAR2(128) et n'est prévue que pour UN nom).
                            FOR i IN 1 .. v_m_count LOOP
                                IF NOT is_in_list(v_members(i), v_resolved) THEN
                                    insert_compat_report(
                                        p_check_id      => p_check_id,
                                        p_table_name    => v_members(i),
                                        p_column_name   => NULL,
                                        p_issue_type    => 'FK_CYCLE_NOT_DEFERRABLE',
                                        p_severity      => C_SEVERITY_WARNING,
                                        p_detail_a      => 'Cycle deferrable accepte, contraintes differees pour ce run. Membres du cycle : ' || v_cycle_msg,
                                        p_detail_b      => NULL
                                    );
                                END IF;
                            END LOOP;
                        ELSE
                            p_cluster_meta(v_meta_idx).requires_deferred := FALSE;
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
                                        p_issue_type    => 'FK_CYCLE_NOT_DEFERRABLE',
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
    FUNCTION build_key_expr(p_key_cols IN t_str_tab) RETURN VARCHAR2 IS
        v_expr VARCHAR2(4000) := '';
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_expr := v_expr
                || CASE WHEN i > 1 THEN '||''~~''||' END
                || 'TO_CHAR(' || sanitize_ident(p_key_cols(i)) || ')';
        END LOOP;
        RETURN v_expr;
    END build_key_expr;

    ----------------------------------------------------------------------
    -- build_row_hash_expr
    --
    -- Rôle : construit l'expression SQL STANDARD_HASH(...,'SHA256') servant de
    --        comparaison de ligne entre A et B (cas identiques = hash égal).
    --        Les colonnes LOB (CLOB/BLOB/NCLOB) sont EXCLUES du hash :
    --        la concaténation puis le hash de gros LOB sont non fiables/coûteux
    --        (limite documentée : un UPDATE ne touchant QUE des colonnes LOB
    --        n'est pas détecté par le diagnostic en v1 — jamais écrit).
    --        Si aucune colonne hachable (table clé uniquement ou tout LOB),
    --        retourne une constante : il n'y a alors rien à comparer, seul
    --        l'INSERT initial a un sens.
    -- Limite : la concaténation intermédiaire est bornée à VARCHAR2 ;
    --        au-delà de ~4000 caractères le résultat peut être tronqué
    --        (hypothèse volumétrique documentée, cf. SYNC_CONFLICT pour un
    --        cas similaire).
    ----------------------------------------------------------------------
    FUNCTION build_row_hash_expr(p_columns IN t_column_tab) RETURN VARCHAR2 IS
        v_expr   VARCHAR2(4000);
        v_hashed BOOLEAN := FALSE;
    BEGIN
        FOR i IN 1 .. p_columns.COUNT LOOP
            IF NOT p_columns(i).is_lob THEN
                v_expr := v_expr
                    || CASE WHEN v_expr IS NOT NULL THEN ' || ''~~'' || ' END
                    || 'TO_CHAR(' || sanitize_ident(p_columns(i).column_name) || ')';
                v_hashed := TRUE;
            END IF;
        END LOOP;

        IF NOT v_hashed THEN
            RETURN 'STANDARD_HASH(''NO_HASHABLE_COLUMN'',''SHA256'')';
        END IF;

        RETURN 'STANDARD_HASH(' || v_expr || ',''SHA256'')';
    END build_row_hash_expr;

    ----------------------------------------------------------------------
    -- build_key_expr_aliased
    --
    -- Variante de build_key_expr (Partie 4) acceptant un préfixe d'alias de
    -- table optionnel, nécessaire ici car les colonnes de clé sont évaluées
    -- dans le contexte d'une sous-requête (pas de la table nue).
    ----------------------------------------------------------------------
    FUNCTION build_key_expr_aliased(p_key_cols IN t_str_tab, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
        v_expr  VARCHAR2(4000) := '';
        v_pfx   VARCHAR2(130)  := CASE WHEN p_alias IS NOT NULL THEN p_alias || '.' END;
    BEGIN
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_expr := v_expr
                || CASE WHEN i > 1 THEN '||''~~''||' END
                || 'TO_CHAR(' || v_pfx || sanitize_ident(p_key_cols(i)) || ')';
        END LOOP;
        RETURN v_expr;
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
        p_rows_inserted     OUT NUMBER,
        p_rows_updated      OUT NUMBER
    ) IS
        v_all_cols  VARCHAR2(4000);
        v_set       VARCHAR2(4000);
        v_src_cols  VARCHAR2(4000);
        v_table     VARCHAR2(128) := sanitize_ident(p_table_name);
        v_sql       VARCHAR2(4000);
    BEGIN
        SELECT COUNT(*) INTO p_rows_inserted FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_A';
        SELECT COUNT(*) INTO p_rows_updated FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'UPDATE_TO_A';

        IF p_dry_run OR (p_rows_inserted = 0 AND p_rows_updated = 0) THEN
            RETURN; -- rien à appliquer réellement, ou simulation : comptes déjà connus
        END IF;

        build_column_lists(p_columns, p_key_cols, v_all_cols, v_set, v_src_cols);

        v_sql :=
            'MERGE INTO ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table || ' tgt ' ||
            'USING (SELECT ' || v_all_cols || ' FROM ' || sanitize_ident(C_SCHEMA_B) || '.' || v_table ||
            '@' || sanitize_ident(C_DB_LINK_B) || ' WHERE ' || build_key_expr_aliased(p_key_cols, NULL) ||
            ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :tn ' ||
            '     AND direction = :dir)) src ' ||
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
        p_rows_inserted     OUT NUMBER,
        p_rows_updated      OUT NUMBER
    ) IS
        v_all_cols  VARCHAR2(4000);
        v_set       VARCHAR2(4000);
        v_src_cols  VARCHAR2(4000);
        v_table     VARCHAR2(128) := sanitize_ident(p_table_name);
        v_sql       VARCHAR2(4000);
        v_non_key_cols VARCHAR2(4000);
        v_select_non_key VARCHAR2(4000);
        v_is_key BOOLEAN;
    BEGIN
        SELECT COUNT(*) INTO p_rows_inserted FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'INSERT_TO_B';
        SELECT COUNT(*) INTO p_rows_updated FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'UPDATE_TO_B';

        IF p_dry_run OR (p_rows_inserted = 0 AND p_rows_updated = 0) THEN
            RETURN;
        END IF;

        build_column_lists(p_columns, p_key_cols, v_all_cols, v_set, v_src_cols);

        ------------------------------------------------------------------
        -- 1) INSERT distribué
        ------------------------------------------------------------------
        IF p_rows_inserted > 0 THEN
            v_sql :=
                'INSERT INTO ' || sanitize_ident(C_SCHEMA_B) || '.' || v_table || '@' || sanitize_ident(C_DB_LINK_B) ||
                ' (' || v_all_cols || ') ' ||
                'SELECT ' || v_all_cols || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table ||
                ' WHERE ' || build_key_expr_aliased(p_key_cols, NULL) ||
                ' IN (SELECT pk_hash_key FROM SYNC_WORK_DIFF WHERE run_id = :rid AND table_name = :tn ' ||
                '     AND diff_type = ''INSERT_TO_B'')';

            EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;
        END IF;

        ------------------------------------------------------------------
        -- 2) UPDATE distribué (colonnes non-clé uniquement)
        ------------------------------------------------------------------
        IF p_rows_updated > 0 THEN
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
                'UPDATE ' || sanitize_ident(C_SCHEMA_B) || '.' || v_table || '@' || sanitize_ident(C_DB_LINK_B) || ' tgt ' ||
                'SET (' || v_non_key_cols || ') = ( ' ||
                '  SELECT ' || v_select_non_key || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table || ' src ' ||
                '  WHERE ' || build_on_clause(p_key_cols, 'src', 'tgt') ||
                ') ' ||
                'WHERE ' || build_key_expr_aliased(p_key_cols, 'tgt') ||
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
        p_rows_inserted_a_to_b   OUT NUMBER,
        p_rows_inserted_b_to_a   OUT NUMBER,
        p_rows_updated_a_to_b    OUT NUMBER,
        p_rows_updated_b_to_a    OUT NUMBER
    ) IS
    BEGIN
        apply_to_remote_target(p_run_id, p_table_name, p_key_cols, p_columns, p_dry_run,
            p_rows_inserted_a_to_b, p_rows_updated_a_to_b);

        apply_to_local_target(p_run_id, p_table_name, p_key_cols, p_columns, p_dry_run,
            p_rows_inserted_b_to_a, p_rows_updated_b_to_a);
    END apply_table_diffs;

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
    --        PK_HASH_KEY et ROW_HASH sont générés à l'aide de expressions SQL
    --        identiques des deux côtés (build_key_expr / build_row_hash_expr)
    --        pour que la comparaison A/B soit reproductible.
    ----------------------------------------------------------------------
    PROCEDURE populate_work_hash(
        p_run_id        IN NUMBER,
        p_table_name    IN VARCHAR2,
        p_key_cols      IN t_str_tab,
        p_columns       IN t_column_tab
    ) IS
        v_key_expr  VARCHAR2(4000) := build_key_expr(p_key_cols);
        v_hash_expr VARCHAR2(4000) := build_row_hash_expr(p_columns);
        v_table     VARCHAR2(128)  := sanitize_ident(p_table_name);
        v_sql       VARCHAR2(4000);
    BEGIN
        -- Côté A (local)
        v_sql := 'INSERT INTO SYNC_WORK_HASH_A (run_id, table_name, pk_hash_key, row_hash) ' ||
                 'SELECT :rid, :tn, ' || v_key_expr || ', ' || v_hash_expr ||
                 ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table;
        EXECUTE IMMEDIATE v_sql USING p_run_id, p_table_name;

        -- Côté B (distant, via DB LINK)
        v_sql := 'INSERT INTO SYNC_WORK_HASH_B (run_id, table_name, pk_hash_key, row_hash) ' ||
                 'SELECT :rid, :tn, ' || v_key_expr || ', ' || v_hash_expr ||
                 ' FROM ' || sanitize_ident(C_SCHEMA_B) || '.' || v_table || '@' || sanitize_ident(C_DB_LINK_B);
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
    -- log_conflict
    --
    -- Rôle : journalise une ligne dans SYNC_CONFLICT (conflit réel résolu,
    --        écart forcé par direction unique, ou conflit non résolu en
    --        ERROR_ON_CONFLICT). VALUE_A/VALUE_B portent la sérialisation
    --        JSON des lignes concernées (colonnes synchronisées non-LOB) à
    --        l'instant du diagnostic ; la référence de ligne est reconstruite
    --        en re-calculant le hash de clé des deux côtés (la clé effective
    --        étant unique par construction, le résultat est déterministe).
    ----------------------------------------------------------------------
    PROCEDURE log_conflict(
        p_run_id             IN  NUMBER,
        p_table_name         IN  VARCHAR2,
        p_pk_hash_key        IN  VARCHAR2,
        p_key_cols           IN  t_str_tab,
        p_resolution_strategy IN VARCHAR2,
        p_resolved_side      IN  VARCHAR2
    ) IS
        v_columns  t_column_tab;
        v_table    VARCHAR2(128) := sanitize_ident(p_table_name);
        v_jo_cols  VARCHAR2(4000);
        v_sel_disp VARCHAR2(4000);
        v_hdest    VARCHAR2(4000);
        v_display  VARCHAR2(4000);
        v_value_a  CLOB;
        v_value_b  CLOB;
        v_sql      VARCHAR2(4000);
    BEGIN
        v_columns := get_sync_columns(p_table_name, p_key_cols);
        v_hdest   := build_key_expr(p_key_cols);

        -- Liste des colonnes sérialisées en JSON (LOBs exclus : non fiables/
        -- coûteux, cf. build_row_hash_expr).
        FOR i IN 1 .. v_columns.COUNT LOOP
            IF NOT v_columns(i).is_lob THEN
                v_jo_cols := v_jo_cols
                    || CASE WHEN v_jo_cols IS NOT NULL THEN ', ' END
                    || 'KEY ''' || v_columns(i).column_name || ''' VALUE '
                    || sanitize_ident(v_columns(i).column_name);
            END IF;
        END LOOP;

        -- Représentation lisible "CLIENT_ID=10, ..." depuis le côté A
        -- (fallback : hash brut si ligne absente).
        FOR i IN 1 .. p_key_cols.COUNT LOOP
            v_sel_disp := v_sel_disp
                || CASE WHEN i > 1 THEN ' || '', '' || ' END
                || '''' || p_key_cols(i) || '='' || TO_CHAR(' || sanitize_ident(p_key_cols(i)) || ')';
        END LOOP;
        v_sql := 'SELECT ' || v_sel_disp
                 || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table
                 || ' WHERE ' || v_hdest || ' = :h';
        BEGIN
            EXECUTE IMMEDIATE v_sql INTO v_display USING p_pk_hash_key;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_display := p_pk_hash_key;
        END;

        IF v_jo_cols IS NOT NULL THEN
            v_sql := 'SELECT JSON_OBJECT(' || v_jo_cols || ')'
                     || ' FROM ' || sanitize_ident(C_SCHEMA_A) || '.' || v_table
                     || ' WHERE ' || v_hdest || ' = :h';
            BEGIN
                EXECUTE IMMEDIATE v_sql INTO v_value_a USING p_pk_hash_key;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN v_value_a := NULL;
            END;

            v_sql := 'SELECT JSON_OBJECT(' || v_jo_cols || ')'
                     || ' FROM ' || sanitize_ident(C_SCHEMA_B) || '.' || v_table
                     || '@' || sanitize_ident(C_DB_LINK_B)
                     || ' WHERE ' || v_hdest || ' = :h';
            BEGIN
                EXECUTE IMMEDIATE v_sql INTO v_value_b USING p_pk_hash_key;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN v_value_b := NULL;
            END;
        END IF;

        INSERT INTO SYNC_CONFLICT (
            conflict_id, run_id, table_name, pk_hash_key, pk_display,
            value_a, value_b, resolution_strategy, resolved_side
        ) VALUES (
            SYNC_CONFLICT_ID_SEQ.NEXTVAL, p_run_id, p_table_name, p_pk_hash_key, v_display,
            v_value_a, v_value_b, p_resolution_strategy, p_resolved_side
        );
    END log_conflict;

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
        -- 2) Conflits candidats : résolution ligne par ligne
        ------------------------------------------------------------------
        FOR rec IN (
            SELECT pk_hash_key FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'CONFLICT_CANDIDATE'
        ) LOOP

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

            UPDATE SYNC_WORK_DIFF
            SET diff_type = v_final_diff_type, direction = v_final_direction
            WHERE run_id = p_run_id AND table_name = p_table_name AND pk_hash_key = rec.pk_hash_key;

            log_conflict(p_run_id, p_table_name, rec.pk_hash_key, p_key_cols,
                         v_resolution_strategy, v_resolved_side);

        END LOOP;
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
        p_dry_run       IN  BOOLEAN,
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
    BEGIN
        INSERT INTO SYNC_LOG (log_id, run_id, table_name, status, cluster_id, cluster_order)
        VALUES (v_log_id, p_run_id, p_table_name, C_STATUS_IN_PROGRESS, p_cluster_id, p_topo_order);

        v_key     := get_effective_key(p_table_name);
        v_columns := get_sync_columns(p_table_name, v_key);

        populate_work_hash(p_run_id, p_table_name, v_key, v_columns);
        run_diagnostic(p_run_id, p_table_name);
        resolve_table_diffs(p_run_id, p_table_name, v_key);

        apply_table_diffs(p_run_id, p_table_name, v_key, v_columns, p_dry_run,
            v_ins_atb, v_ins_bta, v_upd_atb, v_upd_bta);

        SELECT COUNT(*) INTO v_conflict_count FROM SYNC_WORK_DIFF
            WHERE run_id = p_run_id AND table_name = p_table_name AND diff_type = 'CONFLICT';

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
                        p_cluster_tables(i).topo_order, p_dry_run, v_status);

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
    -- SYNC_ALL  (procédure publique)
    ----------------------------------------------------------------------
    PROCEDURE SYNC_ALL (
        p_dry_run       IN  BOOLEAN  DEFAULT FALSE,
        p_error_mode    IN  VARCHAR2 DEFAULT C_ERROR_MODE_CONTINUE,
        p_run_id        OUT NUMBER
    ) IS
        v_run_id            NUMBER := SYNC_RUN_ID_SEQ.NEXTVAL;
        v_check_id          NUMBER;
        v_blocking          BOOLEAN;
        v_active_tables     t_str_tab;
        v_cluster_tables    t_cluster_table_tab;
        v_cluster_meta      t_cluster_meta_tab;
        v_ordered_idx       t_num_tab;
        v_total_tables      NUMBER := 0;
        v_excluded_count    NUMBER := 0;
        v_success_count     NUMBER := 0;
        v_conflict_count    NUMBER := 0;
        v_failed_count      NUMBER := 0;
        v_stopped_early     BOOLEAN := FALSE;
        v_final_status      VARCHAR2(30);
    BEGIN
        INSERT INTO SYNC_RUN_HEADER (run_id, run_type, dry_run, error_mode)
        VALUES (v_run_id, 'SYNC_ALL', CASE WHEN p_dry_run THEN 'Y' ELSE 'N' END, p_error_mode);
        COMMIT; -- l'en-tête doit rester traçable même si tout échoue ensuite

        p_run_id := v_run_id;

        ------------------------------------------------------------------
        -- 1) Compatibilité (systématique en tête de run, décision validée)
        ------------------------------------------------------------------
        CHECK_COMPATIBILITY(NULL, v_check_id, v_blocking);

        SELECT table_name BULK COLLECT INTO v_active_tables
        FROM SYNC_TABLE_CONFIG stc
        WHERE enabled = 'Y' AND sync_direction != C_DIRECTION_DISABLED
          AND NOT EXISTS (
              SELECT 1 FROM SYNC_COMPATIBILITY_REPORT r
              WHERE r.check_id = v_check_id AND r.table_name = stc.table_name AND r.severity = C_SEVERITY_BLOCKING
          );

        SELECT COUNT(DISTINCT table_name) INTO v_excluded_count
        FROM SYNC_COMPATIBILITY_REPORT
        WHERE check_id = v_check_id AND severity = C_SEVERITY_BLOCKING;

        v_total_tables := v_active_tables.COUNT;

        ------------------------------------------------------------------
        -- 2) Grappes FK (référence CHECK_ID pour la journalisation des cycles)
        ------------------------------------------------------------------
        compute_run_clusters(v_active_tables, v_check_id, v_cluster_tables, v_cluster_meta);

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
        SET total_tables = v_total_tables, tables_excluded = v_excluded_count
        WHERE run_id = v_run_id;
        COMMIT;

        ------------------------------------------------------------------
        -- 3) Traitement des grappes, par ordre de PRIORITY moyenne croissante
        ------------------------------------------------------------------
        v_ordered_idx := order_clusters_by_priority(v_cluster_meta);

        FOR oi IN 1 .. v_ordered_idx.COUNT LOOP
            EXIT WHEN v_stopped_early;

            DECLARE
                v_meta_idx  PLS_INTEGER := v_ordered_idx(oi);
                v_cid       NUMBER := v_cluster_meta(v_meta_idx).cluster_id;
            BEGIN
                IF v_cluster_meta(v_meta_idx).requires_deferred THEN
                    EXECUTE IMMEDIATE 'SET CONSTRAINTS ALL DEFERRED';
                    -- Limite connue (signalée) : portée locale au schéma A
                    -- uniquement, cf. commentaire détaillé en Partie 3.
                END IF;

                process_cluster(v_run_id, v_cid, v_cluster_tables, p_dry_run, p_error_mode,
                    v_success_count, v_conflict_count, v_failed_count, v_stopped_early);

                COMMIT; -- commit de la grappe entière (décision validée), qu'elle
                        -- contienne ou non des tables en échec (celles-ci ont déjà
                        -- été annulées individuellement par ROLLBACK TO SAVEPOINT
                        -- dans process_cluster ; ce COMMIT ne valide donc que le
                        -- travail des tables réussies de la grappe)
            END;
        END LOOP;

        ------------------------------------------------------------------
        -- 4) Statut final
        ------------------------------------------------------------------
        v_final_status := compute_final_status(
            v_active_tables.COUNT, v_success_count, v_conflict_count, v_failed_count, v_excluded_count
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
            tables_failed = v_failed_count
        WHERE run_id = v_run_id;
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            -- Erreur structurelle survenue AVANT ou EN DEHORS de la boucle de
            -- traitement des grappes (ex. schéma/DB LINK inaccessible dès
            -- CHECK_COMPATIBILITY). Le run est marqué FAILED et l'exception
            -- est propagée à l'appelant, jamais masquée (décision validée).
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
        p_run_id        OUT NUMBER
    ) IS
        v_run_id        NUMBER := SYNC_RUN_ID_SEQ.NEXTVAL;
        v_check_id      NUMBER;
        v_blocking      BOOLEAN;
        v_status        VARCHAR2(30);
        v_exists        NUMBER;
        v_final_status  VARCHAR2(30);
    BEGIN
        SELECT COUNT(*) INTO v_exists FROM SYNC_TABLE_CONFIG
        WHERE table_name = p_table_name AND enabled = 'Y' AND sync_direction != C_DIRECTION_DISABLED;

        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Table non configuree ou desactivee pour la synchronisation : ' || p_table_name);
        END IF;

        INSERT INTO SYNC_RUN_HEADER (run_id, run_type, dry_run, error_mode)
        VALUES (v_run_id, 'SYNC_TABLE', CASE WHEN p_dry_run THEN 'Y' ELSE 'N' END, C_ERROR_MODE_STOP);
        COMMIT;

        p_run_id := v_run_id;

        CHECK_COMPATIBILITY(p_table_name, v_check_id, v_blocking);

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
            process_one_table(v_run_id, p_table_name, NULL, 1, p_dry_run, v_status);
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

END PKG_SCHEMA_SYNC;
/

SHOW ERRORS PACKAGE BODY PKG_SCHEMA_SYNC;

--------------------------------------------------------------------------------
-- FIN DU CORPS DU PACKAGE (fichier fusionné, prêt à compiler)
--------------------------------------------------------------------------------