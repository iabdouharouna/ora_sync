-- \===========================================================================
-- SCRIPT 12 — SYNCHRONISATION D'UNE LISTE DE TABLES (FICHIER UNIQUE PARAMÉTRABLE)
-- \===========================================================================
-- Objet   : configurer + (dry run puis éventuellement run réel) + vérifier
--           la synchronisation d'une LISTE de tables, avec UN SEUL script.
--
-- Lancement :
--     python setup_project.py sql 12_SYNC_UNE_LISTE.sql
--     (ou SQL*Plus :  SET SERVEROUTPUT ON ;  @12_SYNC_UNE_LISTE.sql)
--
-- À ÉDITER : la section « PARAMÈTRES (À ÉDITER) » au début du bloc PL/SQL
--            ci-dessous (liste des tables, schémas A/B, direction, dry/reel...).
--
-- Sécurités :
--   * DRY RUN PAR DÉFAUT (param c_dry_seul = 'Y') : rien n'est écrit sur les
--     tables métier. Le run réel n'a lieu que si c_dry_seul = 'N'.
--   * Idempotent : la configuration déjà posée n'est JAMAIS écrasée (INSERT
--     conditionnels NOT EXISTS) ; le script peut être relancé sans risque.
--   * Aucune suppression n'est jamais propagée (SYNC_DELETE='N' verrouillé).
--   * Vérifie au démarrage que les constantes compilées du package
--     (C_SCHEMA_A / C_SCHEMA_B) correspondent à c_schema_a / c_schema_b ;
--     sinon ARRÊT avec message (voir Annexe C de 11_PROCEDURE_SYNCHRONISATION.md
--     pour le patch temporaire des constantes).
--
-- Prérequis : package PKG_SCHEMA_SYNC v5.3 compilé et VALID dans SYNC_ADMIN.
-- ===========================================================================
SET SERVEROUTPUT ON

DECLARE
    -- ========================================================================
    -- ============ PARAMÈTRES (À ÉDITER) =====================================
    -- ========================================================================
    -- Liste des tables à synchroniser, SÉPARÉES PAR DES VIRGULES.
    c_liste      CONSTANT VARCHAR2(4000) :=
        'BANK,BANK_ADDENDUM,BANK_NETWORK,RESOURCES,CONTROL_VERIFICATION_FLAGS,'
      || 'CARD_RANGE,MER_ACCEPTOR_POINT,STOP_LIST_VERSIONS,ACQ_ONUS_RANGE,'
      || 'CONVERSION_RATE,CARD_PRODUCT,REPLACEMENT_REASON_CODE,ISS_POSTING_RULES,'
      || 'EMV_KEYS_ASSIGNMENT,POS_PROFILE,POS_ISO_PREFIXES_DT,POS_ISO_PREFIXES,'
      || 'POS_ISO_LOCAL_BINS,HSM_KEY_MEMBER,P7_ROUTING_CRITERIA';

    -- Schémas jumeaux (doivent correspondre aux constantes compilées du package).
    c_schema_a   CONSTANT VARCHAR2(128) := 'PCARDIMPBO';
    c_schema_b   CONSTANT VARCHAR2(128) := 'PCARDIMPFE';

    -- Profil de synchronisation appliqué aux tables de la liste :
    c_direction  CONSTANT VARCHAR2(20)  := 'A_TO_B';        -- A_TO_B / B_TO_A / BIDIRECTIONAL
    c_mode       CONSTANT VARCHAR2(20)  := 'INSERT_UPDATE'; -- INSERT / UPDATE / INSERT_UPDATE
    c_conflits   CONSTANT VARCHAR2(20)  := 'ERROR_ON_CONFLICT'; -- SOURCE_A_WINS / SOURCE_B_WINS / ERROR_ON_CONFLICT
    c_priorite   CONSTANT NUMBER        := 100;

    -- 'Y' = DRY RUN SEUL (rien sur les tables métier) ;
    -- 'N' = dry run PUIS run réel (à passer après avoir validé le dry).
    c_dry_seul   CONSTANT CHAR(1)       := 'Y';

    -- Colonnes à EXCLURE de la synchro (audit ré-estampé par triggers, etc.).
    -- SÉPARÉES PAR DES VIRGULES. (Opt-out : une colonne non listée = synchronisée.)
    c_exclusions CONSTANT VARCHAR2(4000) := 'DATE_CREATE,DATE_MODIF,USER_MODIF,DATE_CREATION,CREATED_DATE,UPDATED_DATE';
    -- ========================================================================

    -- Types et variables internes (ne pas modifier) ---------------------------
    v_list       PKG_SCHEMA_SYNC.t_tab_name_list := PKG_SCHEMA_SYNC.t_tab_name_list();
    v_excl       PKG_SCHEMA_SYNC.t_tab_name_list := PKG_SCHEMA_SYNC.t_tab_name_list();
    v_dry_id     NUMBER;
    v_reel_id    NUMBER;

    v_comp_a     VARCHAR2(4000);
    v_comp_b     VARCHAR2(4000);
    v_spec_st    VARCHAR2(30);
    v_body_st    VARCHAR2(30);

    v_in_a       NUMBER;
    v_in_b       NUMBER;
    v_pk         VARCHAR2(4000);
    v_n_bo       NUMBER;
    v_n_fe       NUMBER;
    v_col_aud    NUMBER;
    v_check_id   NUMBER;
    v_a_b        BOOLEAN;
    v_txt        VARCHAR2(4000);
    v_i          BINARY_INTEGER;
    v_j          BINARY_INTEGER;
    v_ligne      VARCHAR2(4000);
    v_code       NUMBER;
    v_msg        VARCHAR2(4000);

    -- ========================================================================
    -- Petits outils (ne pas modifier)
    -- ========================================================================
    PROCEDURE ligne(p VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p);
    END ligne;

    PROCEDURE titre(p VARCHAR2) IS
    BEGIN
        ligne(RPAD('=', 110, '=') || chr(10) || p || chr(10) || RPAD('=', 110, '='));
    END titre;

    -- Découpe une liste 'A,B,C' en collection (toujours en MAJUSCULES).
    PROCEDURE parse_liste(p_txt VARCHAR2, p_out IN OUT NOCOPY PKG_SCHEMA_SYNC.t_tab_name_list) IS
        v_pos BINARY_INTEGER := 1;
        v_fin BINARY_INTEGER;
        v_tok VARCHAR2(4000);
    BEGIN
        p_out := PKG_SCHEMA_SYNC.t_tab_name_list();
        WHILE v_pos <= LENGTH(p_txt) LOOP
            v_fin := INSTR(p_txt, ',', v_pos);
            IF v_fin = 0 THEN v_fin := LENGTH(p_txt) + 1; END IF;
            v_tok := TRIM(SUBSTR(p_txt, v_pos, v_fin - v_pos));
            IF v_tok IS NOT NULL THEN
                p_out.EXTEND;
                p_out(p_out.COUNT) := UPPER(v_tok);
            END IF;
            v_pos := v_fin + 1;
        END LOOP;
    END parse_liste;

BEGIN
    -- ========================================================================
    -- ÉTAPE 1 — VÉRIFICATION DE L'ENVIRONNEMENT
    -- ========================================================================
    titre('ÉTAPE 1 — Vérification de l''environnement');

    IF c_direction NOT IN ('A_TO_B','B_TO_A','BIDIRECTIONAL') OR
       c_mode      NOT IN ('INSERT','UPDATE','INSERT_UPDATE') OR
       c_conflits  NOT IN ('SOURCE_A_WINS','SOURCE_B_WINS','ERROR_ON_CONFLICT') THEN
        RAISE_APPLICATION_ERROR(-20001, 'Paramètres c_direction/c_mode/c_conflits invalides.');
    END IF;

    SELECT status INTO v_spec_st FROM user_objects
     WHERE object_name = 'PKG_SCHEMA_SYNC' AND object_type = 'PACKAGE';
    SELECT status INTO v_body_st FROM user_objects
     WHERE object_name = 'PKG_SCHEMA_SYNC' AND object_type = 'PACKAGE BODY';
    ligne('Package     : spec ' || v_spec_st || ' / corps ' || v_body_st ||
          '  (attendu : VALID / VALID)');
    IF v_spec_st <> 'VALID' OR v_body_st <> 'VALID' THEN
        RAISE_APPLICATION_ERROR(-20002, 'Package non compilé : relancer install+migrate.');
    END IF;

    -- Constantes compilées du package (accessibles à l'exécution) vs paramètres.
    EXECUTE IMMEDIATE 'BEGIN :v := PKG_SCHEMA_SYNC.C_SCHEMA_A; END;' USING OUT v_comp_a;
    EXECUTE IMMEDIATE 'BEGIN :v := PKG_SCHEMA_SYNC.C_SCHEMA_B; END;' USING OUT v_comp_b;
    ligne('Constantes  : C_SCHEMA_A=' || v_comp_a || ' (param=' || c_schema_a || ')');
    ligne('              C_SCHEMA_B=' || v_comp_b || ' (param=' || c_schema_b || ')');
    IF v_comp_a <> c_schema_a OR v_comp_b <> c_schema_b THEN
        RAISE_APPLICATION_ERROR(-20003,
            'Constantes compilées du package <> paramètres c_schema_a/c_schema_b. '
         || 'Appliquer le patch temporaire (Annexe C de 11_PROCEDURE_SYNCHRONISATION.md) '
         || 'ou corriger les paramètres. Le run est annulé.');
    END IF;

    parse_liste(c_liste, v_list);
    parse_liste(c_exclusions, v_excl);
    IF v_list.COUNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20004, 'c_liste est vide : renseigner au moins une table.');
    END IF;
    ligne('Liste       : ' || v_list.COUNT || ' table(s) configurées.');
    ligne('Profil      : direction=' || c_direction || ' mode=' || c_mode ||
          ' conflits=' || c_conflits || ' priorité=' || c_priorite ||
          ' dry_seul=' || c_dry_seul);
    ligne('Exclusions  : ' || c_exclusions);

    -- ========================================================================
    -- ÉTAPE 2 — DÉCOUVERTE (existence A/B, clé, volumes, colonnes audit)
    -- ========================================================================
    titre('ÉTAPE 2 — Découverte des tables cibles');
    ligne(RPAD('TABLE', 32) || RPAD('ÉTAT', 14) ||
          RPAD('VOL BO', 9) || RPAD('VOL FE', 9) || 'CLÉ (A)');
    FOR k IN 1 .. v_list.COUNT LOOP
        v_txt := v_list(k);

        SELECT COUNT(*) INTO v_in_a FROM all_tables WHERE owner = c_schema_a AND table_name = v_txt;
        SELECT COUNT(*) INTO v_in_b FROM all_tables WHERE owner = c_schema_b AND table_name = v_txt;

        IF v_in_a = 1 THEN
            BEGIN
                SELECT LISTAGG(cc.column_name, ',') WITHIN GROUP (ORDER BY cc.position)
                  INTO v_pk
                  FROM all_constraints c
                  JOIN all_cons_columns cc
                    ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
                 WHERE c.owner = c_schema_a AND c.table_name = v_txt
                   AND c.constraint_type IN ('P','U');
            EXCEPTION WHEN NO_DATA_FOUND THEN v_pk := 'AUCUNE -> SYNC_KEY_CONFIG';
            END;
        ELSE
            v_pk := '-';
        END IF;

        v_n_bo := 0; v_n_fe := 0;
        IF v_in_a = 1 THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || c_schema_a || '"."' || v_txt || '"' INTO v_n_bo;
        END IF;
        IF v_in_b = 1 THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || c_schema_b || '"."' || v_txt || '"' INTO v_n_fe;
        END IF;

        IF v_in_a = 1 AND v_in_b = 1 THEN
            v_ligne := 'SYNCABLE';
        ELSIF v_in_a = 1 THEN
            v_ligne := 'ABSENTE DE B';
        ELSIF v_in_b = 1 THEN
            v_ligne := 'ABSENTE DE A';
        ELSE
            v_ligne := 'ABSENTE DES 2';
        END IF;

        ligne(RPAD(v_txt, 32) || RPAD(v_ligne, 14) ||
              RPAD(TO_CHAR(v_n_bo), 9) || RPAD(TO_CHAR(v_n_fe), 9) || v_pk);
    END LOOP;

    -- ========================================================================
    -- ÉTAPE 3 — CONFIGURATION (idempotente) + exclusions de colonnes
    -- ========================================================================
    titre('ÉTAPE 3 — Configuration (SYNC_TABLE_CONFIG / SYNC_COLUMN_CONFIG)');
    FOR k IN 1 .. v_list.COUNT LOOP
        v_txt := v_list(k);
        SELECT COUNT(*) INTO v_in_a FROM all_tables WHERE owner = c_schema_a AND table_name = v_txt;
        SELECT COUNT(*) INTO v_in_b FROM all_tables WHERE owner = c_schema_b AND table_name = v_txt;

        IF v_in_a = 0 OR v_in_b = 0 THEN
            IF v_in_a = 1 AND v_in_b = 0 THEN
                -- ABSENTE DE B : non configurée, exclue du run (MISSING_IN_B).
                ligne('SKIP   ' || RPAD(v_txt, 32) || 'absente de B : non configurée (exclue du run)');
            ELSIF v_in_b = 1 THEN
                -- ABSENTE DE A : hors périmètre A_TO_B.
                ligne('SKIP   ' || RPAD(v_txt, 32) || 'absente de A : hors périmètre');
            ELSE
                ligne('SKIP   ' || RPAD(v_txt, 32) || 'absente des deux schémas');
            END IF;
        ELSE
            -- Ligne de config (INSERT conditionnel : l'existant n'est jamais écrasé).
            INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, SYNC_MODE,
                                           CONFLICT_STRATEGY, PRIORITY)
            SELECT v_txt, 'Y', c_direction, c_mode, c_conflits, c_priorite FROM DUAL
             WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = v_txt);

            -- Exclusions de colonnes (audit) présentes dans la table A.
            FOR j IN 1 .. v_excl.COUNT LOOP
                SELECT COUNT(*) INTO v_col_aud
                  FROM all_tab_columns
                 WHERE owner = c_schema_a AND table_name = v_txt AND column_name = v_excl(j);
                IF v_col_aud = 1 THEN
                    INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
                    SELECT v_txt, v_excl(j), 'N' FROM DUAL
                     WHERE NOT EXISTS (SELECT 1 FROM SYNC_COLUMN_CONFIG
                                        WHERE TABLE_NAME = v_txt AND COLUMN_NAME = v_excl(j));
                END IF;
            END LOOP;

            -- Clé effective de la table (recalcul local : v_pk de l'ÉTAPE 2
            -- porte la dernière table parcourue).
            BEGIN
                SELECT LISTAGG(cc.column_name, ',') WITHIN GROUP (ORDER BY cc.position)
                  INTO v_pk
                  FROM all_constraints c
                  JOIN all_cons_columns cc
                    ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
                 WHERE c.owner = c_schema_a AND c.table_name = v_txt
                   AND c.constraint_type IN ('P','U');
            EXCEPTION WHEN NO_DATA_FOUND THEN v_pk := 'AUCUNE -> SYNC_KEY_CONFIG';
            END;
            IF v_pk LIKE 'AUCUNE%' THEN
                ligne('INFO   ' || RPAD(v_txt, 32) || 'sans PK/UNIQUE : '
                   || 'déclarer la clé logique dans SYNC_KEY_CONFIG (sinon la table sera exclue, PK_MISSING)');
            END IF;
            ligne('CONFIG ' || RPAD(v_txt, 32) || 'OK (' || c_direction || ' / ' || c_mode || ')');
        END IF;
    END LOOP;
    COMMIT;

    -- ========================================================================
    -- ÉTAPE 4 — CONTRÔLE DE COMPATIBILITÉ (go / no-go avant le run)
    -- ========================================================================
    titre('ÉTAPE 4 — Contrôle de compatibilité (CHECK_COMPATIBILITY)');
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(
        p_table_list => v_list,
        p_check_id   => v_check_id,
        p_has_blocking_issues => v_a_b
    );
    ligne('CHECK_ID : ' || v_check_id || '  (issues bloquantes : ' ||
          CASE WHEN v_a_b THEN 'OUI' ELSE 'NON' END || ')');

    FOR r IN (SELECT table_name, issue_type, COUNT(*) AS nb
                FROM sync_compatibility_report
               WHERE check_id = v_check_id AND severity = 'BLOCKING'
               GROUP BY table_name, issue_type ORDER BY table_name, issue_type) LOOP
        ligne('BLOCKING ' || RPAD(r.table_name, 30) || RPAD(r.issue_type, 28) || 'x' || r.nb);
    END LOOP;

    -- ========================================================================
    -- ÉTAPE 5 — DRY RUN (aucune écriture sur les tables métier)
    -- ========================================================================
    titre('ÉTAPE 5 — Dry run (p_dry_run => TRUE)');
    PKG_SCHEMA_SYNC.SYNC_TABLES(
        p_table_list => v_list,
        p_dry_run    => TRUE,
        p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE,
        p_run_id     => v_dry_id
    );
    ligne('DRY RUN_ID : ' || v_dry_id);
    SELECT status, total_tables, tables_success, tables_conflict, tables_failed, tables_excluded
      INTO v_txt, v_n_bo, v_n_fe, v_i, v_j, v_code
      FROM sync_run_header WHERE run_id = v_dry_id;
    ligne('Statut dry : ' || v_txt || ' — total=' || v_n_bo ||
          ' succès=' || v_n_fe || ' conflits=' || v_i || ' échecs=' || v_j ||
          ' exclus=' || v_code);

    titre('Détail dry run (opérations qui SERAIENT appliquées)');
    ligne(RPAD('TABLE', 30) || RPAD('STATUT', 25) || 'INSERT->B  UPDATE->B  CONFLITS  ERREURS');
    FOR r IN (SELECT table_name, status, rows_inserted_a_to_b, rows_updated_a_to_b,
                     conflict_count, error_count
                FROM sync_log WHERE run_id = v_dry_id ORDER BY table_name) LOOP
        ligne(RPAD(r.table_name, 30) || RPAD(r.status, 25) ||
              LPAD(r.rows_inserted_a_to_b, 9) || '  ' || LPAD(r.rows_updated_a_to_b, 8) || '  ' ||
              LPAD(r.conflict_count, 7) || '  ' || LPAD(r.error_count, 7));
    END LOOP;

    -- ========================================================================
    -- ÉTAPE 6 — RUN RÉEL (uniquement si c_dry_seul = 'N')
    -- ========================================================================
    IF c_dry_seul = 'N' THEN
        titre('ÉTAPE 6 — Run réel (p_dry_run => FALSE)');
        PKG_SCHEMA_SYNC.SYNC_TABLES(
            p_table_list => v_list,
            p_dry_run    => FALSE,
            p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE,
            p_run_id     => v_reel_id
        );
        ligne('RÉEL RUN_ID : ' || v_reel_id);
        SELECT status, total_tables, tables_success, tables_conflict, tables_failed, tables_excluded
          INTO v_txt, v_n_bo, v_n_fe, v_i, v_j, v_code
          FROM sync_run_header WHERE run_id = v_reel_id;
        ligne('Statut réel : ' || v_txt || ' — total=' || v_n_bo ||
              ' succès=' || v_n_fe || ' conflits=' || v_i || ' échecs=' || v_j ||
              ' exclus=' || v_code);

        titre('Détail run réel (opérations APPLIQUÉES)');
        ligne(RPAD('TABLE', 30) || RPAD('STATUT', 25) || 'INSERT->B  UPDATE->B  CONFLITS  ERREURS');
        FOR r IN (SELECT table_name, status, rows_inserted_a_to_b, rows_updated_a_to_b,
                         conflict_count, error_count
                    FROM sync_log WHERE run_id = v_reel_id ORDER BY table_name) LOOP
            ligne(RPAD(r.table_name, 30) || RPAD(r.status, 25) ||
                  LPAD(r.rows_inserted_a_to_b, 9) || '  ' || LPAD(r.rows_updated_a_to_b, 8) || '  ' ||
                  LPAD(r.conflict_count, 7) || '  ' || LPAD(r.error_count, 7));
        END LOOP;
    ELSE
        titre('ÉTAPE 6 — Run réel');
        ligne('c_dry_seul=''' || c_dry_seul || ''' : run réel NON exécuté. '
           || 'Passer c_dry_seul = ''N'' après validation du dry run pour lancer le run réel.');
    END IF;

    -- ========================================================================
    -- ÉTAPE 7 — VÉRIFICATIONS POST-RUN (volumes BO vs FE)
    -- ========================================================================
    titre('ÉTAPE 7 — Vérification des volumes (A vs B)');
    ligne(RPAD('TABLE', 32) || RPAD('VOL BO', 9) || RPAD('VOL FE', 9) || 'ÉCART');
    FOR k IN 1 .. v_list.COUNT LOOP
        v_txt := v_list(k);
        SELECT COUNT(*) INTO v_in_a FROM all_tables WHERE owner = c_schema_a AND table_name = v_txt;
        SELECT COUNT(*) INTO v_in_b FROM all_tables WHERE owner = c_schema_b AND table_name = v_txt;
        v_n_bo := 0; v_n_fe := 0;

        IF v_in_a = 1 THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || c_schema_a || '"."' || v_txt || '"' INTO v_n_bo;
        END IF;
        IF v_in_b = 1 THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || c_schema_b || '"."' || v_txt || '"' INTO v_n_fe;
        END IF;

        IF v_n_bo = v_n_fe THEN
            v_ligne := '== ALIGNÉ';
        ELSIF v_n_fe > v_n_bo THEN
            v_ligne := 'FE>BO (surnum. conservées)';
        ELSE
            v_ligne := '!! BO>FE (à investiguer)';
        END IF;
        ligne(RPAD(v_txt, 32) || RPAD(TO_CHAR(v_n_bo), 9) || RPAD(TO_CHAR(v_n_fe), 9) || v_ligne);
    END LOOP;

    titre('FIN — Rappel des RUN_ID (voir détails dans SYNC_LOG / SYNC_CONFLICT / '
       || 'SYNC_COMPATIBILITY_REPORT)');
    ligne('dry  : ' || NVL(TO_CHAR(v_dry_id), '-'));
    ligne('réel : ' || NVL(TO_CHAR(v_reel_id), '(non exécuté)'));

EXCEPTION
    WHEN OTHERS THEN
        v_code := SQLCODE;
        v_msg  := SUBSTR(SQLERRM, 1, 2000);
        titre('ARRÊT SUR ERREUR');
        ligne('SQLCODE=' || v_code || '  SQLERRM=' || v_msg);
        ligne('Si erreur de compile du bloc : vérifier la section PARAMÈTRES '
           || 'et les constantes compilées du package (ÉTAPE 1).');
        -- Remontée pour que le runner / sqlplus rendent un code différent de zéro.
        RAISE_APPLICATION_ERROR(-20050, 'Script 12 interrompu : ' || v_msg);
END;
/