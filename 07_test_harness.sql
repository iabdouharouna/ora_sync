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
-- Périmètre : les Blocs 1 à 9 sont NON DESTRUCTIFS (aucun DML métier ; les
-- SYNC * y sont en DRY_RUN : le diagnostic et le calcul de hachage
-- s'exécutent réellement, seules les tables d'audit SYNC_* reçoivent les
-- lignes de synthèse). Le Bloc 10 (v5) exécute lui deux SYNC_TABLE RÉELS
-- (p_dry_run => FALSE) sur un scénario auto-réparant strictement ADDITIF
-- (CLIENT 901 / COMMANDE 9901) : c'est le seul moyen d'exercer le backfill
-- des parents FK, neutralisé en dry run (p_allow_ddl = NOT p_dry_run). Les
-- lignes de scénario sont supprimées des deux côtés en fin de bloc — le
-- moteur ne propageant jamais les suppressions, l'état initial est restauré
-- à l'identique.
--
-- Le Bloc 11 (v6) exerce l'état d'écart schéma : collecte RÉELLE des stats
-- par jobs DBMS_SCHEDULER sur les schémas de test (SCHEMA_A/SCHEMA_B, petits),
-- attente asynchrone, génération du rapport persistant (SYNC_STATS_GAP),
-- lecture des anomalies (SYNC_STATS_GAP_DETAIL) et de la garde de fraîcheur
-- (E_STATS_NOT_FRESH). Pour rendre l'écart DÉTERMINISTE quelle que soit la
-- dérive du jeu d'exemple, une ligne PRODUIT 900 est temporairement INSÉRÉE
-- côté A seul puis RETIRÉE en fin de bloc (et les stats de PRODUIT
-- re-collectées) : l'état initial est restauré à l'identique — seules les
-- stats Oracle et les tables SYNC_STATS_GAP(_DETAIL) reçoivent des lignes.
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
-- Bloc 10 : (v5) auto-réparation RÉELLE (backfill des parents FK manquants)
--
-- Scénario auto-réparant, intégralement ré-exécutable (le harnais peut être
-- relancé sans préparation ni nettoyage manuel) :
--   * prérequis : les privilèges SYS d'auto-réparation (Script 09) sont
--     effectivement accordés au compte exécutant ;
--   * API v5    : SET_RUN_OPTION / GET_RUN_OPTION (round-trip), rejet d'une
--     option inconnue (E_INVALID_PARAMETER, -20011) et d'une valeur interdite
--     (validation API -20011, doublée en base par CK_SRO_VALUE), sans altérer
--     la valeur en place ;
--   * scénario  : un parent CLIENT absent de SCHEMA_B alors que son enfant
--     COMMANDE existe côté A -> SYNC_TABLE RÉEL sur COMMANDE : ORA-02291
--     intercepté, backfill du parent depuis SCHEMA_A (PARENT_BACKFILLED),
--     retentative (FK_CHILD_RETRIED), puis insertion de l'enfant réussie ;
--   * garanties : SYNC_TABLE ne mute ni SYNC_TABLE_CONFIG ni
--     SYNC_COLUMN_CONFIG (empreinte inchangée) ; aucun conflit ; second run
--     réel = 0 écriture (idempotence) et plus aucune réparation tentée ;
--   * restauration : options remises à leur valeur d'origine, lignes de
--     scénario supprimées des DEUX côtés (enfant d'abord, clé étrangère).
--
-- NB : c'est le seul bloc à exécuter des runs RÉELS — l'auto-réparation
-- (backfill, auto-création de table) est neutralisée en dry run.
--------------------------------------------------------------------------------
DECLARE
    v_opt_orig   VARCHAR2(256);
    v_opt_flip   VARCHAR2(256);
    v_cycle_orig VARCHAR2(256);
    v_err        VARCHAR2(2000);
    v_run_id     NUMBER;
    v_run2_id    NUMBER;
    v_start      TIMESTAMP;
    v_status     VARCHAR2(30);
    v_dry        CHAR(1);
    v_cnt        NUMBER;
    v_failed     NUMBER;
    v_bf1        NUMBER;
    v_retry1     NUMBER;
    v_repair2    NUMBER;
    v_ins2       NUMBER;
    v_priv       NUMBER;
    v_fp_before  NUMBER;
    v_fp_after   NUMBER;

    PROCEDURE restore_state IS
        -- Règle : une valeur d'origine HORS PÉRIMÈTRE (persistée par une
        -- version antérieure du package, cf. CYCLE_HANDLING='BIDON') ne doit
        -- pas faire échouer la restauration — on retombe alors sur la valeur
        -- par défaut de l'option.
        FUNCTION sane_default(p_name IN VARCHAR2, p_value IN VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            IF p_value IS NULL THEN
                RETURN NULL;
            END IF;
            IF p_name = 'AUTO_BACKFILL_PARENTS' AND p_value IN ('Y', 'N') THEN
                RETURN p_value;
            ELSIF p_name = 'CYCLE_HANDLING' AND p_value IN ('DISABLE_FK', 'BLOCK') THEN
                RETURN p_value;
            ELSIF p_name = 'AUTO_CREATE_MISSING_TABLE' AND p_value IN ('Y', 'N') THEN
                RETURN p_value;
            ELSIF p_name = 'MAX_FK_RETRY' AND REGEXP_LIKE(p_value, '^[1-9][0-9]{0,9}$') THEN
                RETURN p_value;
            END IF;
            RETURN CASE p_name
                WHEN 'AUTO_BACKFILL_PARENTS'     THEN 'Y'
                WHEN 'AUTO_CREATE_MISSING_TABLE' THEN 'N'
                WHEN 'CYCLE_HANDLING'            THEN 'DISABLE_FK'
                WHEN 'MAX_FK_RETRY'              THEN '3'
            END;
        END sane_default;
    BEGIN
        -- Options restaurées à leur valeur CAPTURÉE en début de bloc (avant
        -- toute mutation) ; en cas de processus différent, retombée sur le défaut.
        IF v_opt_orig IS NOT NULL THEN
            BEGIN
                PKG_SCHEMA_SYNC.SET_RUN_OPTION('AUTO_BACKFILL_PARENTS',
                    sane_default('AUTO_BACKFILL_PARENTS', v_opt_orig));
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('  RESTORE option partiel : ' || SQLERRM);
            END;
        END IF;

        IF v_cycle_orig IS NOT NULL THEN
            BEGIN
                PKG_SCHEMA_SYNC.SET_RUN_OPTION('CYCLE_HANDLING',
                    sane_default('CYCLE_HANDLING', v_cycle_orig));
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('  RESTORE CYCLE_HANDLING partiel : ' || SQLERRM);
            END;
        END IF;

        -- Enfant d'abord (clé étrangère), puis parent, des deux côtés.
        DELETE FROM SCHEMA_A.COMMANDE WHERE COMMANDE_ID = 9901;
        DELETE FROM SCHEMA_B.COMMANDE WHERE COMMANDE_ID = 9901;
        DELETE FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 901;
        DELETE FROM SCHEMA_B.CLIENT WHERE CLIENT_ID = 901;
        COMMIT;
    END restore_state;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 10 : (v5) auto-reparation reelle (backfill) ==');

    BEGIN
        ------------------------------------------------------------
        -- 1) Prérequis SYS et API d'options (v5)
        ------------------------------------------------------------
        SELECT COUNT(*) INTO v_priv
          FROM SESSION_PRIVS
         WHERE privilege IN ('ALTER ANY TABLE','CREATE ANY TABLE','CREATE ANY INDEX',
                             'INSERT ANY TABLE','UPDATE ANY TABLE','DELETE ANY TABLE',
                             'CREATE ANY TRIGGER');
        T_HARNESS.ASSERT_TRUE('Privileges SYS auto-reparation presents (7 attendus)',
            v_priv = 7, 'nb=' || v_priv);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_RUN_OPTION
         WHERE option_name IN ('AUTO_BACKFILL_PARENTS','MAX_FK_RETRY','CYCLE_HANDLING',
                               'AUTO_CREATE_MISSING_TABLE');
        T_HARNESS.ASSERT_TRUE('SYNC_RUN_OPTION : 4 options v5 presentes', v_cnt = 4, 'nb=' || v_cnt);

        v_opt_orig   := PKG_SCHEMA_SYNC.GET_RUN_OPTION('AUTO_BACKFILL_PARENTS');
        v_cycle_orig := PKG_SCHEMA_SYNC.GET_RUN_OPTION('CYCLE_HANDLING');
        T_HARNESS.ASSERT_TRUE('GET_RUN_OPTION(AUTO_BACKFILL_PARENTS) renvoie une valeur',
            v_opt_orig IS NOT NULL, 'val=' || NVL(v_opt_orig, '<null>'));

        v_opt_flip := CASE WHEN v_opt_orig = 'Y' THEN 'N' ELSE 'Y' END;
        PKG_SCHEMA_SYNC.SET_RUN_OPTION('AUTO_BACKFILL_PARENTS', v_opt_flip);
        T_HARNESS.ASSERT_TRUE('SET_RUN_OPTION / GET_RUN_OPTION : round-trip coherent',
            PKG_SCHEMA_SYNC.GET_RUN_OPTION('AUTO_BACKFILL_PARENTS') = v_opt_flip,
            'flip=' || v_opt_flip);

        -- Le scénario exige l'auto-backfill actif (valeur par défaut 'Y').
        PKG_SCHEMA_SYNC.SET_RUN_OPTION('AUTO_BACKFILL_PARENTS', 'Y');
        T_HARNESS.ASSERT_TRUE('AUTO_BACKFILL_PARENTS force a Y pour le scenario',
            PKG_SCHEMA_SYNC.GET_RUN_OPTION('AUTO_BACKFILL_PARENTS') = 'Y');

        BEGIN
            PKG_SCHEMA_SYNC.SET_RUN_OPTION('OPTION_BIDON_V5', 'X');
            v_err := NULL;
        EXCEPTION
            WHEN PKG_SCHEMA_SYNC.E_INVALID_PARAMETER THEN
                v_err := SQLERRM;
            WHEN OTHERS THEN
                v_err := 'AUTRE_ERREUR: ' || SQLERRM;
        END;
        T_HARNESS.ASSERT_TRUE('Option inconnue rejetee (E_INVALID_PARAMETER -20011)',
            v_err IS NOT NULL AND INSTR(v_err, '-20011') > 0, v_err);

        BEGIN
            PKG_SCHEMA_SYNC.SET_RUN_OPTION('CYCLE_HANDLING', 'BIDON');
            v_err := NULL;
        EXCEPTION
            WHEN PKG_SCHEMA_SYNC.E_INVALID_PARAMETER THEN
                v_err := SQLERRM;
            WHEN OTHERS THEN
                v_err := 'AUTRE_ERREUR: ' || SQLERRM;
        END;
        T_HARNESS.ASSERT_TRUE('Valeur interdite rejetee (SET_RUN_OPTION, -20011 explicite)',
            v_err IS NOT NULL AND INSTR(v_err, '-20011') > 0, v_err);
        T_HARNESS.ASSERT_TRUE('CYCLE_HANDLING inchange apres tentative invalide',
            PKG_SCHEMA_SYNC.GET_RUN_OPTION('CYCLE_HANDLING') = v_cycle_orig,
            'orig=' || NVL(v_cycle_orig, '<null>'));

        ------------------------------------------------------------
        -- 2) Scénario auto-réparant (ajoutatif, reconstruit à chaque run)
        ------------------------------------------------------------
        SELECT (SELECT COUNT(*) FROM SYNC_TABLE_CONFIG) * 1000000
             + (SELECT NVL(SUM(ORA_HASH(NVL(TABLE_NAME, '') || '/' || NVL(ENABLED, '') || '/'
                             || NVL(SYNC_DIRECTION, '') || '/' || NVL(SYNC_MODE, '') || '/'
                             || NVL(CONFLICT_STRATEGY, '') || '/'
                             || NVL(TO_CHAR(PRIORITY), '') || '/' || NVL(UPDATED_BY, ''))), 0)
                  FROM SYNC_TABLE_CONFIG)
             + (SELECT COUNT(*) * 1000
                     + NVL(SUM(ORA_HASH(NVL(TABLE_NAME, '') || '/' || NVL(COLUMN_NAME, '') || '/'
                             || NVL(SYNC_ENABLED, ''))), 0)
                  FROM SYNC_COLUMN_CONFIG)
          INTO v_fp_before
          FROM DUAL;

        INSERT INTO SCHEMA_A.CLIENT (CLIENT_ID, NOM, EMAIL)
        SELECT 901, 'Harnais v5 auto-reparation', 'harnais.v5@example.com' FROM DUAL
        WHERE NOT EXISTS (SELECT 1 FROM SCHEMA_A.CLIENT WHERE CLIENT_ID = 901);

        INSERT INTO SCHEMA_A.COMMANDE (COMMANDE_ID, CLIENT_ID, STATUT)
        SELECT 9901, 901, 'EN_COURS' FROM DUAL
        WHERE NOT EXISTS (SELECT 1 FROM SCHEMA_A.COMMANDE WHERE COMMANDE_ID = 9901);

        -- Etat cible : enfant et parent absents de SCHEMA_B (parent manquant).
        DELETE FROM SCHEMA_B.COMMANDE WHERE COMMANDE_ID = 9901;
        DELETE FROM SCHEMA_B.CLIENT WHERE CLIENT_ID = 901;
        COMMIT;

        ------------------------------------------------------------
        -- 3) Run RÉEL 1 : ORA-02291 -> backfill -> retentative
        ------------------------------------------------------------
        PKG_SCHEMA_SYNC.SYNC_TABLE('COMMANDE', p_dry_run => FALSE, p_run_id => v_run_id);
        T_HARNESS.ASSERT_TRUE('Run reel 1 : SYNC_TABLE execute sans erreur',
            v_run_id IS NOT NULL);

        SELECT status, start_date, dry_run INTO v_status, v_start, v_dry
          FROM SYNC_RUN_HEADER WHERE run_id = v_run_id;
        T_HARNESS.ASSERT_TRUE('Run reel 1 : statut coherent (pas FAILED)',
            v_status IN ('SUCCESS', 'SUCCESS_WITH_CONFLICTS'), 'status=' || v_status);
        T_HARNESS.ASSERT_TRUE('Run reel 1 : DRY_RUN = N (execution reelle)',
            v_dry = 'N', 'dry=' || v_dry);

        SELECT COUNT(*), NVL(SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END), 0)
          INTO v_cnt, v_failed
          FROM SYNC_LOG WHERE run_id = v_run_id AND table_name = 'COMMANDE';
        T_HARNESS.ASSERT_TRUE('Run reel 1 : table COMMANDE non FAILED (pas d''ORA-02291)',
            v_cnt = 1 AND v_failed = 0, 'rows=' || v_cnt || ' failed=' || v_failed);

        SELECT COUNT(*) INTO v_bf1 FROM SYNC_COMPATIBILITY_REPORT
         WHERE check_date >= v_start AND issue_type = 'PARENT_BACKFILLED';
        T_HARNESS.ASSERT_TRUE('PARENT_BACKFILLED emis (backfill du parent CLIENT)',
            v_bf1 >= 1, 'nb=' || v_bf1);

        SELECT COUNT(*) INTO v_retry1 FROM SYNC_COMPATIBILITY_REPORT
         WHERE check_date >= v_start AND issue_type = 'FK_CHILD_RETRIED';
        T_HARNESS.ASSERT_TRUE('FK_CHILD_RETRIED emis (retentative apres backfill)',
            v_retry1 >= 1, 'nb=' || v_retry1);

        SELECT COUNT(*) INTO v_cnt FROM SCHEMA_B.CLIENT WHERE CLIENT_ID = 901;
        T_HARNESS.ASSERT_TRUE('Parent CLIENT 901 repare (reinsere) dans SCHEMA_B',
            v_cnt = 1, 'nb=' || v_cnt);

        SELECT COUNT(*) INTO v_cnt FROM SCHEMA_B.COMMANDE WHERE COMMANDE_ID = 9901;
        T_HARNESS.ASSERT_TRUE('Enfant COMMANDE 9901 insere dans SCHEMA_B',
            v_cnt = 1, 'nb=' || v_cnt);

        SELECT COUNT(*) INTO v_cnt FROM SYNC_CONFLICT WHERE run_id = v_run_id;
        T_HARNESS.ASSERT_TRUE('Aucun conflit journalise sur le run reel',
            v_cnt = 0, 'nb=' || v_cnt);

        SELECT (SELECT COUNT(*) FROM SYNC_TABLE_CONFIG) * 1000000
             + (SELECT NVL(SUM(ORA_HASH(NVL(TABLE_NAME, '') || '/' || NVL(ENABLED, '') || '/'
                             || NVL(SYNC_DIRECTION, '') || '/' || NVL(SYNC_MODE, '') || '/'
                             || NVL(CONFLICT_STRATEGY, '') || '/'
                             || NVL(TO_CHAR(PRIORITY), '') || '/' || NVL(UPDATED_BY, ''))), 0)
                  FROM SYNC_TABLE_CONFIG)
             + (SELECT COUNT(*) * 1000
                     + NVL(SUM(ORA_HASH(NVL(TABLE_NAME, '') || '/' || NVL(COLUMN_NAME, '') || '/'
                             || NVL(SYNC_ENABLED, ''))), 0)
                  FROM SYNC_COLUMN_CONFIG)
          INTO v_fp_after
          FROM DUAL;
        T_HARNESS.ASSERT_TRUE('Configuration non mutee (empreinte SYNC_*_CONFIG inchangee)',
            v_fp_after = v_fp_before, 'av=' || v_fp_before || ' ap=' || v_fp_after);

        ------------------------------------------------------------
        -- 4) Run RÉEL 2 : idempotence (0 écriture, plus rien à réparer)
        ------------------------------------------------------------
        PKG_SCHEMA_SYNC.SYNC_TABLE('COMMANDE', p_dry_run => FALSE, p_run_id => v_run2_id);

        SELECT status INTO v_status FROM SYNC_RUN_HEADER WHERE run_id = v_run2_id;
        T_HARNESS.ASSERT_TRUE('Run reel 2 : statut coherent (pas FAILED)',
            v_status IN ('SUCCESS', 'SUCCESS_WITH_CONFLICTS'), 'status=' || v_status);

        SELECT rows_inserted_a_to_b + rows_inserted_b_to_a
             + rows_updated_a_to_b + rows_updated_b_to_a
          INTO v_ins2
          FROM SYNC_LOG WHERE run_id = v_run2_id AND table_name = 'COMMANDE';
        T_HARNESS.ASSERT_TRUE('Run 2 idempotent : aucune ecriture sur COMMANDE',
            v_ins2 = 0, 'ecritures=' || v_ins2);

        SELECT start_date INTO v_start FROM SYNC_RUN_HEADER WHERE run_id = v_run2_id;
        SELECT COUNT(*) INTO v_repair2 FROM SYNC_COMPATIBILITY_REPORT
         WHERE check_date >= v_start
           AND issue_type IN ('PARENT_BACKFILLED', 'FK_CHILD_RETRIED');
        T_HARNESS.ASSERT_TRUE('Run 2 : plus aucune reparation (backfill/retry nuls)',
            v_repair2 = 0, 'nb=' || v_repair2);

        SELECT (SELECT COUNT(*) FROM SCHEMA_B.CLIENT WHERE CLIENT_ID = 901)
             + (SELECT COUNT(*) FROM SCHEMA_B.COMMANDE WHERE COMMANDE_ID = 9901)
          INTO v_cnt FROM DUAL;
        T_HARNESS.ASSERT_TRUE('Pas de doublon : CLIENT 901 + COMMANDE 9901 en B',
            v_cnt = 2, 'nb=' || v_cnt);

        ------------------------------------------------------------
        -- 5) Restauration complète (options + lignes de scénario)
        ------------------------------------------------------------
        restore_state;
        T_HARNESS.RESULT('auto_repair_v5');
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
-- Bloc 11 : (v6) état d'écart schéma — collecte stats + rapport persistant
--
-- Exerce le workflow de la v6 sur les schémas de TEST. Le scénario est
-- DÉTERMINISTE (indépendant de la dérive du jeu d'exemple) :
--   * une ligne PRODUIT 900 est INSÉRÉE côté A SEUL (jamais côté B) avant la
--     collecte : après un GATHER complet des stats (jobs DBMS_SCHEDULER
--     asynchrones), le rapport doit classer PRODUIT en écart DIFF (A plus
--     fourni que B : DIFF = B - A <= -1 — le signe est vérifié ici) et
--     n'avoir AUCUNE anomalie NO_STATS ;
--   * API v6    : SUBMIT_STATS_JOBS -> WAIT_FOR_STATS_JOBS ->
--     GET_STATS_JOB_STATUS / ARE_STATS_JOBS_DONE -> REPORT_COUNTS_GAP (REF
--     CURSOR + persistance + COMMIT) -> GET_LAST_GAP_ID ; garde de fraîcheur
--     E_STATS_NOT_FRESH ; détection des NO_STATS_* après suppression ciblée
--     des stats d'une table (DELETE_TABLE_STATS) ;
--   * garantir  : le rapport ne reçoit QUE des anomalies en détail ; les
--     totaux de l'en-tête sont cohérents ; GET_LAST_GAP_ID pointe le dernier
--     rapport ; absence totale d'effet sur SYNC_TABLE_CONFIG /
--     SYNC_COLUMN_CONFIG (le bloc n'y touche pas) ;
--   * restauration : suppression de la ligne PRODUIT 900 côté A, puis
--     re-collecte des stats de PRODUIT (GATHER_TABLE_STATS) pour ne pas
--     laisser le jeu de test dégradé (aucune ligne métier créée en dur par ce
--     bloc — la ligne d'injection est retirée quoi qu'il arrive).
--
-- NB : nécessite les privilèges SYS du Script 15 (ANALYZE ANY, CREATE JOB,
-- EXECUTE DBMS_STATS/DBMS_SCHEDULER/DBMS_LOCK) comme le Bloc 10 exige ceux
-- du 09.
--------------------------------------------------------------------------------
DECLARE
    TYPE t_hdr IS RECORD (
        gap_id             NUMBER,
        collect_date       TIMESTAMP,
        job_name_a         VARCHAR2(128),
        job_name_b         VARCHAR2(128),
        stats_date_a       TIMESTAMP,
        stats_date_b       TIMESTAMP,
        total_tables       NUMBER,
        tables_ok          NUMBER,
        tables_gap         NUMBER,
        tables_no_stats_a  NUMBER,
        tables_no_stats_b  NUMBER,
        executed_by        VARCHAR2(128)
    );

    v_job_a    VARCHAR2(128);
    v_job_b    VARCHAR2(128);
    v_ok       BOOLEAN;
    v_status_a VARCHAR2(30);
    v_status_b VARCHAR2(30);
    v_gap_id   NUMBER;
    v_gap_id2  NUMBER;
    v_hdr      SYS_REFCURSOR;
    v_dtl      SYS_REFCURSOR;
    v_hr       t_hdr;
    v_total    NUMBER;
    v_ok_cnt   NUMBER;
    v_gap_cnt  NUMBER;
    v_ns_a     NUMBER;
    v_ns_b     NUMBER;
    v_err      NUMBER;
    v_cnt      NUMBER;
    v_diff     NUMBER;

    PROCEDURE restore_state IS
    BEGIN
        -- Ligne d'injection retirée + stats de PRODUIT re-collectées.
        BEGIN
            EXECUTE IMMEDIATE 'DELETE FROM SCHEMA_A.PRODUIT WHERE PRODUIT_ID = 900';
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  RESTORE donnees PRODUIT/A partiel : ' || SQLERRM);
        END;
        BEGIN
            DBMS_STATS.GATHER_TABLE_STATS(ownname => 'SCHEMA_A', tabname => 'PRODUIT');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  RESTORE stats PRODUIT/A partiel : ' || SQLERRM);
        END;
        COMMIT;
    END restore_state;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== Bloc 11 : (v6) etat d''ecart schema (stats) ==');

    ------------------------------------------------------------
    -- 0) Scénario : une ligne présente en A SEUL (jamais en B)
    ------------------------------------------------------------
    DELETE FROM SCHEMA_A.PRODUIT WHERE PRODUIT_ID = 900;
    INSERT INTO SCHEMA_A.PRODUIT (PRODUIT_ID, LIBELLE, PRIX_UNITAIRE)
    VALUES (900, 'Produit du bloc 11 (injection A seul)', 1.00);
    COMMIT;

    ------------------------------------------------------------
    -- 1) Collecte asynchrone des stats (jobs DBMS_SCHEDULER)
    ------------------------------------------------------------
    PKG_SCHEMA_SYNC.SUBMIT_STATS_JOBS(
        p_job_name_a => v_job_a,
        p_job_name_b => v_job_b
    );
    T_HARNESS.ASSERT_TRUE('SUBMIT_STATS_JOBS : deux noms de jobs rendus',
        v_job_a IS NOT NULL AND v_job_b IS NOT NULL,
        'A=' || v_job_a || ' B=' || v_job_b);

    PKG_SCHEMA_SYNC.WAIT_FOR_STATS_JOBS(
        p_job_name_a    => v_job_a,
        p_job_name_b    => v_job_b,
        p_timeout_sec   => 1800,
        p_all_succeeded => v_ok
    );
    T_HARNESS.ASSERT_TRUE('WAIT_FOR_STATS_JOBS : les deux collectes ont reussi',
        v_ok, 'ok=' || CASE WHEN v_ok THEN 'TRUE' ELSE 'FALSE' END);

    v_status_a := PKG_SCHEMA_SYNC.GET_STATS_JOB_STATUS(v_job_a);
    v_status_b := PKG_SCHEMA_SYNC.GET_STATS_JOB_STATUS(v_job_b);
    T_HARNESS.ASSERT_TRUE('GET_STATS_JOB_STATUS : A et B en SUCCEEDED',
        v_status_a = 'SUCCEEDED' AND v_status_b = 'SUCCEEDED',
        'A=' || v_status_a || ' B=' || v_status_b);
    T_HARNESS.ASSERT_TRUE('ARE_STATS_JOBS_DONE : TRUE apres la collecte',
        PKG_SCHEMA_SYNC.ARE_STATS_JOBS_DONE(v_job_a, v_job_b));

    ------------------------------------------------------------
    -- 2) Rapport d'écart (avec garde de fraîcheur : stats fraîches)
    ------------------------------------------------------------
    PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP(
        p_max_age_hours => 48,
        p_gap_id        => v_gap_id,
        p_header_cursor => v_hdr,
        p_detail_cursor => v_dtl
    );
    -- Le REF CURSOR d'en-tête doit restituer le rapport généré (12 colonnes).
    FETCH v_hdr INTO v_hr;
    CLOSE v_hdr;
    CLOSE v_dtl;
    T_HARNESS.ASSERT_TRUE('REPORT_COUNTS_GAP : gap_id genere et cursor coherent',
        v_gap_id IS NOT NULL AND v_hr.gap_id = v_gap_id,
        'gap_id=' || v_gap_id || ' cursor=' || v_hr.gap_id);

    SELECT total_tables, tables_ok, tables_gap, tables_no_stats_a, tables_no_stats_b
      INTO v_total, v_ok_cnt, v_gap_cnt, v_ns_a, v_ns_b
      FROM SYNC_STATS_GAP WHERE gap_id = v_gap_id;

    T_HARNESS.ASSERT_TRUE('Rapport : les tables d''exemple sont dans le perimetre',
        v_total >= 4, 'total=' || v_total);
    T_HARNESS.ASSERT_TRUE('Rapport : au moins un ecart DIFF', v_gap_cnt >= 1,
        'gap=' || v_gap_cnt);
    T_HARNESS.ASSERT_TRUE('Rapport : aucune anomalie NO_STATS apres collecte complete',
        v_ns_a = 0 AND v_ns_b = 0, 'nsA=' || v_ns_a || ' nsB=' || v_ns_b);
    T_HARNESS.ASSERT_TRUE('Rapport : coherence des totaux (ok+gap=total)',
        v_ok_cnt + v_gap_cnt = v_total,
        'ok=' || v_ok_cnt || ' gap=' || v_gap_cnt || ' total=' || v_total);

    -- PRODUIT : ligne 900 présente en A seul -> anomalie DIFF au détail.
    SELECT COUNT(*), NVL(MAX(diff), -1) INTO v_cnt, v_diff
      FROM SYNC_STATS_GAP_DETAIL
     WHERE gap_id = v_gap_id AND table_name = 'PRODUIT' AND gap_flag = 'DIFF';
    T_HARNESS.ASSERT_TRUE('Detail : PRODUIT en ecart DIFF (B-A <= -1)',
        v_cnt = 1 AND v_diff <= -1, 'nb=' || v_cnt || ' diff=' || v_diff);

    ------------------------------------------------------------
    -- 3) Re-consultation : GET_LAST_GAP_ID pointe le rapport
    ------------------------------------------------------------
    T_HARNESS.ASSERT_TRUE('GET_LAST_GAP_ID : dernier rapport retrouve',
        PKG_SCHEMA_SYNC.GET_LAST_GAP_ID = v_gap_id,
        'last=' || PKG_SCHEMA_SYNC.GET_LAST_GAP_ID || ' attendu=' || v_gap_id);

    ------------------------------------------------------------
    -- 4) Garde de fraîcheur : stats trop anciennes -> E_STATS_NOT_FRESH
    ------------------------------------------------------------
    BEGIN
        PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP(
            p_max_age_hours => 0.000001,   -- plus anciennes que ~3,6 ms
            p_gap_id        => v_gap_id2,
            p_header_cursor => v_hdr,
            p_detail_cursor => v_dtl
        );
        v_err := 0;   -- pas d'erreur : le test devrait échouer
    EXCEPTION
        WHEN OTHERS THEN
            v_err := SQLCODE;
    END;
    T_HARNESS.ASSERT_TRUE('Rapport : stats trop anciennes rejetees (E_STATS_NOT_FRESH)',
        v_err = -20013, 'sqlcode=' || v_err);

    ------------------------------------------------------------
    -- 5) Stats absentes d'un côté : NO_STATS_A détecté, puis restauration
    ------------------------------------------------------------
    DBMS_STATS.DELETE_TABLE_STATS(ownname => 'SCHEMA_A', tabname => 'PRODUIT');

    PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP(
        p_gap_id        => v_gap_id2,
        p_header_cursor => v_hdr,
        p_detail_cursor => v_dtl
    );
    CLOSE v_hdr;
    CLOSE v_dtl;

    SELECT COUNT(*) INTO v_cnt
      FROM SYNC_STATS_GAP_DETAIL
     WHERE gap_id = v_gap_id2 AND table_name = 'PRODUIT' AND gap_flag = 'NO_STATS_A';
    T_HARNESS.ASSERT_TRUE('Detail : PRODUIT en NO_STATS_A apres purge des stats A',
        v_cnt = 1, 'nb=' || v_cnt);

    SELECT tables_no_stats_a INTO v_ns_a
      FROM SYNC_STATS_GAP WHERE gap_id = v_gap_id2;
    T_HARNESS.ASSERT_TRUE('En-tete : TABLES_NO_STATS_A compte l''anomalie',
        v_ns_a >= 1, 'nsA=' || v_ns_a);

    -- Restauration : ligne 900 retirée + stats de PRODUIT re-collectées.
    restore_state;
    T_HARNESS.RESULT('stats_gap_v6');
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            restore_state;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  RESTORE partiel : ' || SQLERRM);
        END;
        RAISE;
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