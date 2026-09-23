SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 1000
SET FEEDBACK ON

--------------------------------------------------------------------------------
-- Script 15 — Privilèges système requis par l'état d'écart schéma (livrable v6)
--------------------------------------------------------------------------------
-- À exécuter UNE FOIS avec la connexion SYSDBA (profil `sys`), après le
-- Script 14 (tables) et avant (ou en même temps que) la recompilation du
-- package (03/04) — le serveur de jobs ne tolère pas un job de collecte créé
-- par un compte dépourvu des privilèges ci-dessous.
--
-- Rôle : permettre à SYNC_ADMIN de
--   * ANALYZE ANY          : lancer DBMS_STATS.GATHER_SCHEMA_STATS sur les
--                            schémas A et B (les stats ne sont PAS dans le
--                            schéma SYNC_ADMIN — elles portent sur des
--                            schémas tiers) ;
--   * CREATE JOB           : créer puis lancer les jobs de collecte
--                            DBMS_SCHEDULER (SUBMIT_STATS_JOBS) ;
--   * EXECUTE sur DBMS_STATS / DBMS_SCHEDULER / DBMS_LOCK : appeler le moteur
--                            de stats, les API de job et le "pulse" du
--                            sondage d'attente (WAIT_FOR_STATS_JOBS —
--                            DBMS_SCHEDULER.WAIT_FOR absent de certaines
--                            distributions, d'où le sondage DBMS_LOCK.SLEEP) ;
--   * SELECT ANY TABLE     : garantir la visibilité de ALL_TAB_STATISTICS /
--                            ALL_TABLES sur les DEUX schémas depuis
--                            REPORT_COUNTS_GAP (indépendamment des grants
--                            par objet éventuellement accordés aux tables
--                            métier). Lecture seule, sans effet de bord.
--
-- Fallback de lecture (documenté, non codé) : si ALL_TAB_STATISTICS ne
-- devait pas exposer les stats attendues malgré SELECT ANY TABLE, lire
-- DBA_TAB_STATISTICS à la place (grant SELECT sur SYS.DBA_TAB_STATISTICS).
--------------------------------------------------------------------------------

PROMPT ==>

DECLARE
    v_cmd VARCHAR2(200);
BEGIN
    FOR rec IN (
        SELECT 'ANALYZE ANY'        AS p_get_priv FROM DUAL UNION ALL
        SELECT 'CREATE JOB'              FROM DUAL UNION ALL
        SELECT 'SELECT ANY TABLE'        FROM DUAL
    ) LOOP
        BEGIN
            v_cmd := 'GRANT ' || rec.p_get_priv || ' TO SYNC_ADMIN';
            EXECUTE IMMEDIATE v_cmd;
            DBMS_OUTPUT.PUT_LINE('OK   : ' || v_cmd);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('SKIP : ' || v_cmd || ' -> ' || SQLERRM);
        END;
    END LOOP;

    FOR rec IN (
        SELECT 'SYS.DBMS_STATS'     AS p_obj FROM DUAL UNION ALL
        SELECT 'SYS.DBMS_SCHEDULER'      FROM DUAL UNION ALL
        SELECT 'SYS.DBMS_LOCK'           FROM DUAL
    ) LOOP
        BEGIN
            v_cmd := 'GRANT EXECUTE ON ' || rec.p_obj || ' TO SYNC_ADMIN';
            EXECUTE IMMEDIATE v_cmd;
            DBMS_OUTPUT.PUT_LINE('OK   : ' || v_cmd);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('SKIP : ' || v_cmd || ' -> ' || SQLERRM);
        END;
    END LOOP;
END;
/

PROMPT ==>

COMMIT;

PROMPT => Fin du script 15 (grants SYS) - privileges d'etat d'ecart octroyes.