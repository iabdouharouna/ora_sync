--------------------------------------------------------------------------------
-- SCRIPT 7 — HARNAS DE VALIDATION AUTOMATISEE (PASS/FAIL)
--
-- A exécuter connecté en SYNC_ADMIN, APRES les Scripts 1 à 6.
-- SET SERVEROUTPUT ON obligatoire : la synthèse est émise via DBMS_OUTPUT,
-- ligne "HARNESS RESULT : ..." (grep-able).
--
-- Nature : contrairement au Script 6 (test manuel guidé), ce script enchaîne
-- des assertions et lève une erreur applicative à la fin si au moins une a
-- échoué, pour un usage en CI / smoke-test.
--
-- Non destructif : aucun DML sur les tables métier. Les seuls SYNC * lancés
-- ici sont en DRY_RUN : le diagnostic et le calcul de hachage s'exécutent
-- réellement (c'est ce qu'on valide), mais aucune écriture métier n'est
-- faite — seules les tables d'audit SYNC_* reçoivent les lignes de synthèse
-- du run (comportement normal du package).
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED;

--------------------------------------------------------------------------------
-- Mini infrastructure d'assertions (package local au harnais)
--------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE T_HARNESS AS
    PROCEDURE ASSERT_TRUE(p_name IN VARCHAR2, p_cond IN BOOLEAN, p_why IN VARCHAR2 DEFAULT NULL);
    PROCEDURE RESULT(p_context IN VARCHAR2);
END T_HARNESS;
/
CREATE OR REPLACE PACKAGE BODY T_HARNESS AS
    g_nb       NUMBER := 0;   -- assertions de la section courante
    g_fail     NUMBER := 0;   -- echecs de la section courante

    PROCEDURE ASSERT_TRUE(p_name IN VARCHAR2, p_cond IN BOOLEAN, p_why IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_nb := g_nb + 1;
        IF p_cond THEN
            DBMS_OUTPUT.PUT_LINE('  PASS - ' || p_name);
        ELSE
            g_fail := g_fail + 1;
            DBMS_OUTPUT.PUT_LINE('  FAIL - ' || p_name ||
                CASE WHEN p_why IS NULL THEN '' ELSE '  [' || p_why || ']' END);
        END IF;
    END ASSERT_TRUE;

    -- Cloture la section courante : imprime son bilan, remet les compteurs de
    -- section a zero, et leve une erreur si la section a echoue (propagee au
    -- script appelant ; le harnais poursuit les sections suivantes car
    -- sqlplus n'interrompt pas le script sur erreur par defaut).
    PROCEDURE RESULT(p_context IN VARCHAR2) IS
        v_fail_section NUMBER := g_fail;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('----------------------------------------------');
        DBMS_OUTPUT.PUT_LINE('SECTION [' || p_context || '] : '
            || TO_CHAR(g_nb - g_fail) || '/' || TO_CHAR(g_nb) || ' assertions PASS');
        g_nb   := 0;
        g_fail := 0;
        IF v_fail_section > 0 THEN
            RAISE_APPLICATION_ERROR(-20999, 'T_HARNESS [' || p_context || '] : ' ||
                TO_CHAR(v_fail_section) || ' assertion(s) echouee(s) -- voir DBMS_OUTPUT');
        END IF;
    END RESULT;
END T_HARNESS;
/

--------------------------------------------------------------------------------
-- Bloc 1 : état de compilation et présence des objets attendus
--------------------------------------------------------------------------------
DECLARE
    v_pkg_valid    NUMBER;
    v_tables_audit NUMBER;
    v_active_cfg   NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 1 : compilation et objets ==');

    -- Spec + body compilés, tous deux VALID
    SELECT COUNT(*) INTO v_pkg_valid
      FROM USER_OBJECTS
     WHERE OBJECT_NAME = 'PKG_SCHEMA_SYNC' AND OBJECT_TYPE LIKE 'PACKAGE%' AND STATUS = 'VALID';
    T_HARNESS.ASSERT_TRUE('Package PKG_SCHEMA_SYNC compile (spec + body) et VALID',
        v_pkg_valid = 2, 'COUNT=' || v_pkg_valid);

    -- Tables d'audit et de config présentes dans SYNC_ADMIN
    SELECT COUNT(*) INTO v_tables_audit
      FROM USER_TABLES
     WHERE TABLE_NAME IN ('SYNC_TABLE_CONFIG','SYNC_COLUMN_CONFIG','SYNC_KEY_CONFIG',
                          'SYNC_RUN_HEADER','SYNC_LOG','SYNC_CONFLICT','SYNC_COMPATIBILITY_REPORT');
    T_HARNESS.ASSERT_TRUE('Tables config + audit presentes (7 attendues)',
        v_tables_audit = 7, 'COUNT=' || v_tables_audit);

    -- GTT de travail (vues dans USER_TABLES egalement)
    SELECT COUNT(*) INTO v_tables_audit
      FROM USER_TABLES
     WHERE TABLE_NAME IN ('SYNC_WORK_HASH_A','SYNC_WORK_HASH_B','SYNC_WORK_DIFF');
    T_HARNESS.ASSERT_TRUE('GTT de travail presentes (3 attendues)',
        v_tables_audit = 3, 'COUNT=' || v_tables_audit);

    -- Au moins une table active configuree
    SELECT COUNT(*) INTO v_active_cfg
      FROM SYNC_TABLE_CONFIG
     WHERE ENABLED = 'Y' AND SYNC_DIRECTION != 'DISABLED';
    T_HARNESS.ASSERT_TRUE('Au moins une table active configuree', v_active_cfg >= 1,
        'COUNT=' || v_active_cfg);

    -- Evolutions v3 : colonne SYNC_MODE et sa contrainte
    SELECT COUNT(*) INTO v_tables_audit
      FROM USER_TAB_COLUMNS
     WHERE TABLE_NAME = 'SYNC_TABLE_CONFIG' AND COLUMN_NAME = 'SYNC_MODE';
    T_HARNESS.ASSERT_TRUE('Colonne SYNC_MODE presente dans SYNC_TABLE_CONFIG',
        v_tables_audit = 1, 'COUNT=' || v_tables_audit);

    SELECT COUNT(*) INTO v_tables_audit
      FROM USER_CONSTRAINTS
     WHERE CONSTRAINT_NAME = 'CK_STC_SYNC_MODE';
    T_HARNESS.ASSERT_TRUE('Contrainte CK_STC_SYNC_MODE presente',
        v_tables_audit = 1, 'COUNT=' || v_tables_audit);

    -- RUN_TYPE doit accepter SYNC_TABLES (contrainte CK_SRH_RUN_TYPE mise a jour)
    SELECT COUNT(*) INTO v_tables_audit
      FROM USER_CONSTRAINTS c
     WHERE c.CONSTRAINT_NAME = 'CK_SRH_RUN_TYPE'
       AND INSTR(c.SEARCH_CONDITION_VC, 'SYNC_TABLES') > 0;
    T_HARNESS.ASSERT_TRUE('CK_SRH_RUN_TYPE accepte SYNC_TABLES',
        v_tables_audit = 1, 'COUNT=' || v_tables_audit);

    T_HARNESS.RESULT('objet');
END;
/

--------------------------------------------------------------------------------
-- Bloc 2 : validation des paramètres (rejet des valeurs invalides)
--------------------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 2 : validation des parametres ==');

    -- p_error_mode inconnu -> E_INVALID_PARAMETER (-20011), sans run lancé
    DECLARE
        v_run_id NUMBER;
        v_err    VARCHAR2(2000);
    BEGIN
        BEGIN
            PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => TRUE, p_error_mode => 'BOBOGUS', p_run_id => v_run_id);
            v_err := NULL;
        EXCEPTION
            WHEN PKG_SCHEMA_SYNC.E_INVALID_PARAMETER THEN
                v_err := SQLERRM;
            WHEN OTHERS THEN
                v_err := 'AUTRE_ERREUR: ' || SQLERRM;
        END;
        T_HARNESS.ASSERT_TRUE('p_error_mode inconnu rejete (E_INVALID_PARAMETER)',
            v_err IS NOT NULL AND INSTR(v_err, '-20011') > 0, v_err);
    END;

    -- PURGE_HISTORY(0) -> E_INVALID_PARAMETER
    DECLARE
        v_err VARCHAR2(2000);
    BEGIN
        BEGIN
            PKG_SCHEMA_SYNC.PURGE_HISTORY(0);
            v_err := NULL;
        EXCEPTION
            WHEN PKG_SCHEMA_SYNC.E_INVALID_PARAMETER THEN
                v_err := SQLERRM;
            WHEN OTHERS THEN
                v_err := 'AUTRE_ERREUR: ' || SQLERRM;
        END;
        T_HARNESS.ASSERT_TRUE('PURGE_HISTORY(0) rejete (E_INVALID_PARAMETER)',
            v_err IS NOT NULL AND INSTR(v_err, '-20011') > 0, v_err);
    END;

    -- p_db_link malformé -> rejet par sanitize_ident (-20010)
    DECLARE
        v_run_id NUMBER;
        v_err    VARCHAR2(2000);
    BEGIN
        BEGIN
            PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => TRUE, p_db_link => '2MAUVAIS', p_run_id => v_run_id);
            v_err := NULL;
        EXCEPTION
            WHEN OTHERS THEN
                v_err := SQLERRM;
        END;
        T_HARNESS.ASSERT_TRUE('p_db_link malforme rejete (-20010)',
            v_err IS NOT NULL AND INSTR(v_err, '-20010') > 0, v_err);
    END;

    T_HARNESS.RESULT('parametres');
END;
/

--------------------------------------------------------------------------------
-- Bloc 3 : CHECK_COMPATIBILITY sur tout le périmètre configuré
--------------------------------------------------------------------------------
DECLARE
    v_check_id  NUMBER;
    v_blocking  BOOLEAN;
    v_nb_block  NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 3 : CHECK_COMPATIBILITY ==');

    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => NULL, p_check_id => v_check_id, p_has_blocking_issues => v_blocking);
    T_HARNESS.ASSERT_TRUE('CHECK_COMPATIBILITY(NULL) execute sans erreur', v_check_id IS NOT NULL);

    -- Aucun blocage structurel sur les tables actives
    SELECT COUNT(*) INTO v_nb_block
      FROM SYNC_COMPATIBILITY_REPORT r
     WHERE r.CHECK_ID = v_check_id AND r.SEVERITY = 'BLOCKING'
       AND EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG c
                    WHERE c.TABLE_NAME = r.TABLE_NAME AND c.ENABLED = 'Y');
    T_HARNESS.ASSERT_TRUE('Aucun blocking structurel sur les tables actives',
        v_nb_block = 0, 'nb_block=' || v_nb_block);

    T_HARNESS.RESULT('compat');
END;
/

--------------------------------------------------------------------------------
-- Bloc 4 : DRY RUN SYNC_TABLE (pathologie hachage LOB regressée) + GET_RUN_STATUS
--
-- CLIENT contient un CLOB (NOTES) : un SYNC_TABLE dry-run dessus force le
-- chemin per-row DBMS_CRYPTO. Un échec ici (ORA-00904/ORA-00932) signerait la
-- régression du correctif v2. En dry run, rien n'est écrit côté métier.
--------------------------------------------------------------------------------
DECLARE
    v_run_id        NUMBER;
    v_status        VARCHAR2(30);
    v_cnt_header    NUMBER;
    v_cnt_detail    NUMBER;
    v_cur_h         SYS_REFCURSOR;
    v_cur_d         SYS_REFCURSOR;
    v_hdr           SYNC_RUN_HEADER%ROWTYPE;
    v_dtl           SYNC_LOG%ROWTYPE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 4 : SYNC_TABLE dry-run CLIENT (LOB) + GET_RUN_STATUS ==');

    -- Le run peut laisser des diff réelles selon l'état des données ; ce qui
    -- compte ici c'est l'absence d'erreur applicative (hachage LOB OK) et un
    -- statut de run cohérent.
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE, p_run_id => v_run_id);
    T_HARNESS.ASSERT_TRUE('SYNC_TABLE CLIENT (dry) execute sans erreur', v_run_id IS NOT NULL);

    SELECT status INTO v_status FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
    T_HARNESS.ASSERT_TRUE('Statut de run coherent (pas FAILED)',
        v_status IN ('SUCCESS','SUCCESS_WITH_CONFLICTS','PARTIAL'), 'status=' || v_status);

    -- Aucune table en échec sur ce run de diagnostic
    SELECT COUNT(*) INTO v_cnt_detail
      FROM SYNC_LOG WHERE run_id = v_run_id AND status = 'FAILED';
    T_HARNESS.ASSERT_TRUE('Aucune table en FAILED sur le run dry', v_cnt_detail = 0,
        'nb_failed=' || v_cnt_detail);

    -- GET_RUN_STATUS restitue header + détail (curseurs SELECT * -> %ROWTYPE)
    PKG_SCHEMA_SYNC.GET_RUN_STATUS(p_run_id => v_run_id, p_header_cursor => v_cur_h, p_detail_cursor => v_cur_d);
    FETCH v_cur_h INTO v_hdr;
    v_cnt_header := CASE WHEN v_cur_h%FOUND THEN 1 ELSE 0 END;
    v_cnt_detail := 0;
    LOOP
        FETCH v_cur_d INTO v_dtl;
        EXIT WHEN v_cur_d%NOTFOUND;
        v_cnt_detail := v_cnt_detail + 1;
    END LOOP;
    CLOSE v_cur_h;
    CLOSE v_cur_d;
    T_HARNESS.ASSERT_TRUE('GET_RUN_STATUS : header 1 ligne', v_cnt_header = 1, 'header=' || v_cnt_header);
    T_HARNESS.ASSERT_TRUE('GET_RUN_STATUS : detail >= 1 ligne', v_cnt_detail >= 1, 'detail=' || v_cnt_detail);

    T_HARNESS.RESULT('run_status');
END;
/

--------------------------------------------------------------------------------
-- Bloc 5 : DRY RUN SYNC_ALL (intégration grappes FK) + SET_DB_LINK round-trip
--------------------------------------------------------------------------------
DECLARE
    v_run_id     NUMBER;
    v_status     VARCHAR2(30);
    v_nb_failed  NUMBER;
    v_link_before VARCHAR2(128);
    v_link_after  VARCHAR2(128);
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 5 : SYNC_ALL dry-run + SET_DB_LINK ==');

    PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => TRUE, p_run_id => v_run_id);
    T_HARNESS.ASSERT_TRUE('SYNC_ALL (dry) execute sans erreur', v_run_id IS NOT NULL);

    SELECT status INTO v_status FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
    T_HARNESS.ASSERT_TRUE('Statut global coherent (pas FAILED)',
        v_status IN ('SUCCESS','SUCCESS_WITH_CONFLICTS','PARTIAL'), 'status=' || v_status);

    SELECT COUNT(*) INTO v_nb_failed FROM SYNC_LOG WHERE run_id = v_run_id AND status = 'FAILED';
    T_HARNESS.ASSERT_TRUE('Aucune table en FAILED sur le run dry', v_nb_failed = 0,
        'nb_failed=' || v_nb_failed);

    -- SET_DB_LINK / GET_DB_LINK : round-trip sans changement de valeur
    v_link_before := PKG_SCHEMA_SYNC.GET_DB_LINK;
    PKG_SCHEMA_SYNC.SET_DB_LINK(v_link_before);
    v_link_after := PKG_SCHEMA_SYNC.GET_DB_LINK;
    T_HARNESS.ASSERT_TRUE('SET_DB_LINK/GET_DB_LINK round-trip coherent',
        NVL(v_link_after, '<NULL>') = NVL(v_link_before, '<NULL>'),
        'before=' || NVL(v_link_before, '<NULL>') || ' after=' || NVL(v_link_after, '<NULL>'));

    T_HARNESS.RESULT('sync_all');
END;
/

--------------------------------------------------------------------------------
-- Bloc 6 : PURGE_HISTORY (conservateur, non destructif des données recentes)
--------------------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 6 : PURGE_HISTORY ==');

    PKG_SCHEMA_SYNC.PURGE_HISTORY(365);
    T_HARNESS.ASSERT_TRUE('PURGE_HISTORY(365) execute sans erreur', TRUE);

    T_HARNESS.RESULT('purge');
END;
/

--------------------------------------------------------------------------------
-- Bloc 7 : mode de synchronisation (SYNC_MODE par table + override de run)
--------------------------------------------------------------------------------
DECLARE
    v_run_id    NUMBER;
    v_mode      VARCHAR2(20);
    v_err       VARCHAR2(2000);
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 7 : mode de synchronisation (SYNC_MODE) ==');

    -- Défaut de configuration : SYNC_TABLE SANS p_sync_mode -> le mode
    -- résolu doit être INSERT_UPDATE (défaut de la colonne SYNC_MODE).
    PKG_SCHEMA_SYNC.SYNC_TABLE('CLIENT', p_dry_run => TRUE, p_run_id => v_run_id);
    T_HARNESS.ASSERT_TRUE('SYNC_TABLE CLIENT (dry, sans mode) execute sans erreur',
        v_run_id IS NOT NULL);

    SELECT sync_mode INTO v_mode FROM SYNC_LOG
     WHERE run_id = v_run_id AND table_name = 'CLIENT' AND ROWNUM = 1;
    T_HARNESS.ASSERT_TRUE('Mode par defaut = INSERT_UPDATE (sans override)',
        v_mode = 'INSERT_UPDATE', 'mode=' || NVL(v_mode, '<null>'));

    -- Override de run : SYNC_TABLE en mode INSERT (dry) -> SYNC_LOG trace le
    -- mode effectif de la table (evolutions v3).
    PKG_SCHEMA_SYNC.SYNC_TABLE('COMMANDE', p_dry_run => TRUE,
        p_sync_mode => PKG_SCHEMA_SYNC.C_SYNC_MODE_INSERT, p_run_id => v_run_id);
    T_HARNESS.ASSERT_TRUE('SYNC_TABLE COMMANDE (dry, mode INSERT) execute sans erreur',
        v_run_id IS NOT NULL);

    SELECT sync_mode INTO v_mode FROM SYNC_LOG
     WHERE run_id = v_run_id AND table_name = 'COMMANDE' AND ROWNUM = 1;
    T_HARNESS.ASSERT_TRUE('SYNC_LOG.SYNC_MODE = INSERT (mode effectif journalise)',
        v_mode = 'INSERT', 'mode=' || NVL(v_mode, '<null>'));

    -- L'override de run ne doit PAS persister dans la configuration.
    SELECT sync_mode INTO v_mode FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
    T_HARNESS.ASSERT_TRUE('Override de run non persiste (config COMMANDE = INSERT_UPDATE)',
        v_mode = 'INSERT_UPDATE', 'mode=' || NVL(v_mode, '<null>'));

    -- p_sync_mode inconnu -> E_INVALID_PARAMETER (-20011)
    BEGIN
        PKG_SCHEMA_SYNC.SYNC_ALL(p_dry_run => TRUE, p_sync_mode => 'DUP', p_run_id => v_run_id);
        v_err := NULL;
    EXCEPTION
        WHEN PKG_SCHEMA_SYNC.E_INVALID_PARAMETER THEN
            v_err := SQLERRM;
        WHEN OTHERS THEN
            v_err := 'AUTRE_ERREUR: ' || SQLERRM;
    END;
    T_HARNESS.ASSERT_TRUE('p_sync_mode invalide rejete (E_INVALID_PARAMETER)',
        v_err IS NOT NULL AND INSTR(v_err, '-20011') > 0, v_err);

    T_HARNESS.RESULT('mode');
END;
/

--------------------------------------------------------------------------------
-- Bloc 8 : SYNC_TABLES + résolution implicite des dépendances FK (parents)
--
-- Le jeu d'exemple porte la chaîne CLIENT <- COMMANDE <- COMMANDE_LIGNE et
-- PRODUIT <- COMMANDE_LIGNE. En ne demandant QUE COMMANDE_LIGNE, la fermeture
-- transitive des parents doit injecter COMMANDE, PRODUIT et CLIENT : le run
-- (en dry) couvre donc 4 tables. C'est le cœur de la nouvelle feature.
--------------------------------------------------------------------------------
DECLARE
    v_run_id     NUMBER;
    v_run_type   VARCHAR2(20);
    v_total      NUMBER;
    v_status     VARCHAR2(30);
    v_cnt        NUMBER;
    v_check_id   NUMBER;
    v_blocking   BOOLEAN;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 8 : SYNC_TABLES + expansion FK (parents) ==');

    PKG_SCHEMA_SYNC.SYNC_TABLES(
        p_table_list => PKG_SCHEMA_SYNC.t_tab_name_list('COMMANDE_LIGNE'),
        p_dry_run    => TRUE,
        p_run_id     => v_run_id
    );
    T_HARNESS.ASSERT_TRUE('SYNC_TABLES(COMMANDE_LIGNE) dry execute sans erreur',
        v_run_id IS NOT NULL);

    SELECT run_type, total_tables, status INTO v_run_type, v_total, v_status
      FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
    T_HARNESS.ASSERT_TRUE('RUN_TYPE = SYNC_TABLES', v_run_type = 'SYNC_TABLES',
        'run_type=' || v_run_type);
    T_HARNESS.ASSERT_TRUE('Statut de run coherent (pas FAILED)',
        v_status IN ('SUCCESS','SUCCESS_WITH_CONFLICTS','PARTIAL'), 'status=' || v_status);

    -- Expansion FK : 1 table demandee -> 4 tables executees (parents implicites).
    T_HARNESS.ASSERT_TRUE('total_tables = 4 (COMMANDE_LIGNE + PRODUIT + COMMANDE + CLIENT)',
        v_total = 4, 'total=' || v_total);

    SELECT COUNT(*) INTO v_cnt FROM SYNC_LOG WHERE run_id = v_run_id
      AND table_name IN ('CLIENT','COMMANDE','PRODUIT','COMMANDE_LIGNE');
    T_HARNESS.ASSERT_TRUE('SYNC_LOG couvre les 4 tables du perimetre etendu',
        v_cnt = 4, 'nb=' || v_cnt);

    SELECT COUNT(*) INTO v_cnt FROM SYNC_LOG WHERE run_id = v_run_id
      AND table_name NOT IN ('CLIENT','COMMANDE','PRODUIT','COMMANDE_LIGNE');
    T_HARNESS.ASSERT_TRUE('Aucune table hors perimetre dans le run', v_cnt = 0, 'nb=' || v_cnt);

    -- Une table sans parent doit rester seule (CLIENT n'a pas de parent FK).
    PKG_SCHEMA_SYNC.SYNC_TABLES(
        p_table_list => PKG_SCHEMA_SYNC.t_tab_name_list('CLIENT'),
        p_dry_run    => TRUE,
        p_run_id     => v_run_id
    );
    SELECT total_tables INTO v_total FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
    T_HARNESS.ASSERT_TRUE('SYNC_TABLES(CLIENT) : total = 1 (aucun parent)',
        v_total = 1, 'total=' || v_total);

    -- Surcharge CHECK_COMPATIBILITY sur liste (type public t_tab_name_list).
    PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(
        p_table_list          => PKG_SCHEMA_SYNC.t_tab_name_list('COMMANDE','CLIENT'),
        p_check_id            => v_check_id,
        p_has_blocking_issues => v_blocking
    );
    T_HARNESS.ASSERT_TRUE('CHECK_COMPATIBILITY(liste) execute (check_id <> null)',
        v_check_id IS NOT NULL, 'check_id=' || NVL(TO_CHAR(v_check_id), '<null>'));

    T_HARNESS.RESULT('sync_tables');
END;
/

--------------------------------------------------------------------------------
-- Bloc 9 : (v4) enrôlement automatique de la lignée FK
--
-- Scénario temporaire, auto-réparant (état restauré en fin de bloc) :
--   * suppression de la configuration de COMMANDE  -> parent FK ABSENT de
--     COMMANDE_LIGNE, à ré-enrôler automatiquement ;
--   * désactivation de PRODUIT                     -> parent FK PRÉSENT MAIS
--     DÉSACTIVÉ, à signaler (WARNING) sans jamais être forcé ;
--   * COMMANDE_LIGNE passé en mode A_TO_B          -> la direction du parent
--     enrôlé doit en être HÉRITÉE.
--
-- Points validés : SYNC_TABLE (mono) ne mute pas la config ; l'enrôlement
-- rattache FK_PARENT_ENROLLED au CHECK_ID courant ; priorité/direction du
-- profil AUTO_FK_LINEAGE ; FK_PARENT_DISABLED sans forçage ; idempotence
-- d'un second contrôle ; un run SYNC_TABLES dry post-enrôlement passe sans
-- FAILED ni ORA-02291 (ordre parent -> enfant garanti).
--------------------------------------------------------------------------------
DECLARE
    v_cmd_cfg      SYNC_TABLE_CONFIG%ROWTYPE;
    v_prod_enabled CHAR(1);
    v_prod_now     CHAR(1);
    v_clig_dir     VARCHAR2(20);
    v_check_id1    NUMBER;
    v_check_id2    NUMBER;
    v_blocking     BOOLEAN;
    v_cnt          NUMBER;
    v_cnt_enr      NUMBER;
    v_run_id       NUMBER;
    v_status       VARCHAR2(30);
    v_dir          VARCHAR2(20);
    v_prio         NUMBER;
    PROCEDURE restore_state IS
    BEGIN
        DELETE FROM SYNC_TABLE_CONFIG
        WHERE table_name = 'COMMANDE' AND NVL(updated_by, ' ') = 'AUTO_FK_LINEAGE';

        INSERT INTO SYNC_TABLE_CONFIG (
            TABLE_NAME, ENABLED, SYNC_DELETE, SYNC_DIRECTION, SYNC_MODE,
            CONFLICT_STRATEGY, PRIORITY, UPDATED_BY
        ) VALUES (
            v_cmd_cfg.table_name, v_cmd_cfg.enabled, v_cmd_cfg.sync_delete,
            v_cmd_cfg.sync_direction, v_cmd_cfg.sync_mode,
            v_cmd_cfg.conflict_strategy, v_cmd_cfg.priority, v_cmd_cfg.updated_by
        );

        UPDATE SYNC_TABLE_CONFIG SET enabled = v_prod_enabled WHERE table_name = 'PRODUIT';
        UPDATE SYNC_TABLE_CONFIG SET sync_direction = v_clig_dir WHERE table_name = 'COMMANDE_LIGNE';
        COMMIT;
    END restore_state;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 9 : (v4) enrollement automatique de la lignee FK ==');

    ------------------------------------------------------------
    -- 1) Sauvegarde de l'état config, puis mise en place du scénario.
    ------------------------------------------------------------
    SELECT * INTO v_cmd_cfg FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
    -- structure identique attendue des deux côtés : inutile d'auditionner
    SELECT enabled INTO v_prod_enabled FROM SYNC_TABLE_CONFIG WHERE table_name = 'PRODUIT';
    SELECT sync_direction INTO v_clig_dir FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE_LIGNE';

    DELETE FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
    UPDATE SYNC_TABLE_CONFIG SET enabled = 'N' WHERE table_name = 'PRODUIT';
    UPDATE SYNC_TABLE_CONFIG SET sync_direction = 'A_TO_B' WHERE table_name = 'COMMANDE_LIGNE';
    COMMIT;

    BEGIN
        ----------------------------------------------------
        -- 2) SYNC_TABLE (mono) ne doit PAS muter la configuration.
        ----------------------------------------------------
        PKG_SCHEMA_SYNC.SYNC_TABLE('COMMANDE_LIGNE', p_dry_run => TRUE, p_run_id => v_run_id);
        T_HARNESS.ASSERT_TRUE('SYNC_TABLE dry execute sans erreur', v_run_id IS NOT NULL);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
        T_HARNESS.ASSERT_TRUE('SYNC_TABLE ne re-enrole pas le parent absent',
            v_cnt = 0, 'nb_config_COMMANDE=' || v_cnt);

        ----------------------------------------------------
        -- 3) CHECK_COMPATIBILITY(NULL) : enrôlement du parent absent.
        ----------------------------------------------------
        PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => NULL, p_check_id => v_check_id1,
            p_has_blocking_issues => v_blocking);
        T_HARNESS.ASSERT_TRUE('CHECK_COMPATIBILITY(NULL) execute sans erreur', v_check_id1 IS NOT NULL);

        SELECT COUNT(*) INTO v_cnt_enr FROM SYNC_COMPATIBILITY_REPORT
        WHERE check_id = v_check_id1 AND table_name = 'COMMANDE' AND issue_type = 'FK_PARENT_ENROLLED'
          AND severity = 'WARNING';
        T_HARNESS.ASSERT_TRUE('FK_PARENT_ENROLLED emis (WARNING) pour COMMANDE',
            v_cnt_enr = 1, 'nb=' || v_cnt_enr);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
        T_HARNESS.ASSERT_TRUE('COMMANDE re-enrolee automatiquement dans SYNC_TABLE_CONFIG',
            v_cnt = 1, 'nb=' || v_cnt);

        SELECT sync_direction, priority, enabled
        INTO v_dir, v_prio, v_cmd_cfg.enabled
        FROM SYNC_TABLE_CONFIG WHERE table_name = 'COMMANDE';
        T_HARNESS.ASSERT_TRUE('Direction du parent enrolee = A_TO_B (heritee de COMMANDE_LIGNE)',
            v_dir = 'A_TO_B', 'dir=' || v_dir);
        T_HARNESS.ASSERT_TRUE('Profil AUTO_FK_LINEAGE : PRIORITY=100',
            v_prio = 100, 'prio=' || v_prio);
        T_HARNESS.ASSERT_TRUE('Profil AUTO_FK_LINEAGE : ENABLED=Y', v_cmd_cfg.enabled = 'Y',
            'enabled=' || v_cmd_cfg.enabled);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_TABLE_CONFIG
        WHERE table_name = 'COMMANDE' AND updated_by = 'AUTO_FK_LINEAGE';
        T_HARNESS.ASSERT_TRUE('updated_by = AUTO_FK_LINEAGE (traillabilite)',
            v_cnt = 1, 'nb=' || v_cnt);

        ----------------------------------------------------
        -- 4) Parent PRÉSENT mais DÉSACTIVÉ : WARNING, jamais forcé.
        ----------------------------------------------------
        SELECT COUNT(*) INTO v_cnt FROM SYNC_COMPATIBILITY_REPORT
        WHERE check_id = v_check_id1 AND table_name = 'PRODUIT' AND issue_type = 'FK_PARENT_DISABLED'
          AND severity = 'WARNING';
        T_HARNESS.ASSERT_TRUE('FK_PARENT_DISABLED emis (WARNING) pour PRODUIT',
            v_cnt = 1, 'nb=' || v_cnt);

        SELECT enabled INTO v_prod_now FROM SYNC_TABLE_CONFIG WHERE table_name = 'PRODUIT';
        T_HARNESS.ASSERT_TRUE('PRODUIT non force (reste desactive)',
            v_prod_now = 'N', 'enabled=' || v_prod_now);

        ----------------------------------------------------
        -- 5) Idempotence : un second contrôle n'enrôle plus rien.
        ----------------------------------------------------
        PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(p_table_name => NULL, p_check_id => v_check_id2,
            p_has_blocking_issues => v_blocking);
        SELECT COUNT(*) INTO v_cnt FROM SYNC_COMPATIBILITY_REPORT
        WHERE check_id = v_check_id2 AND table_name = 'COMMANDE' AND issue_type = 'FK_PARENT_ENROLLED';
        T_HARNESS.ASSERT_TRUE('Second controle : aucun re-enrolement (idempotent)',
            v_cnt = 0, 'nb=' || v_cnt);

        ----------------------------------------------------
        -- 6) Run SYNC_TABLES post-enrôlement : tout passe, order garanti.
        ----------------------------------------------------
        PKG_SCHEMA_SYNC.SYNC_TABLES(
            p_table_list => PKG_SCHEMA_SYNC.t_tab_name_list('COMMANDE_LIGNE'),
            p_dry_run    => TRUE,
            p_run_id     => v_run_id
        );
        SELECT status INTO v_status FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
        T_HARNESS.ASSERT_TRUE('SYNC_TABLES post-enrolement : statut coherent',
            v_status IN ('SUCCESS','SUCCESS_WITH_CONFLICTS','PARTIAL'), 'status=' || v_status);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_LOG
        WHERE run_id = v_run_id AND status = 'FAILED';
        T_HARNESS.ASSERT_TRUE('Aucune table en FAILED sur le run dry (pas d''ORA-02291)',
            v_cnt = 0, 'nb_failed=' || v_cnt);

        ----------------------------------------------------
        -- 7) Restauration de l'état config initial.
        ----------------------------------------------------
        restore_state;
        T_HARNESS.RESULT('fk_lineage_v4');
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                restore_state;
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('  RESTORE partiel impossible : ' || SQLERRM);
            END;
            RAISE;
    END;
END;
/

--------------------------------------------------------------------------------
-- Chaque section a déjà émis son propre bilan (RESULT), qui lève une erreur
-- si la section a échoué. sqlplus n'interrompant pas le script sur erreur par
-- défaut, les sections suivantes s'exécutent quand même : la sortie complète
-- permet de voir toutes les conclusions. Côté CI, se fier à l'absence de
-- "FAIL" (le script reste aussi utilisable avec WHENEVER SQLERROR EXIT FAILURE).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Nettoyage de l'infrastructure du harnais (optionnel)
--------------------------------------------------------------------------------
-- DROP PACKAGE T_HARNESS;

--------------------------------------------------------------------------------
-- Fin Script 7
--------------------------------------------------------------------------------