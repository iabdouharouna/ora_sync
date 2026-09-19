SPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 1000
SET FEEDBACK ON

--------------------------------------------------------------------------------
-- Script 09 — Privilèges système requis par l'auto-réparation (livrable v5)
--------------------------------------------------------------------------------
-- À exécuter UNE FOIS avec la connexion SYSDBA (profil `sys`) après le
-- déploiement de la v5 — ou après chaque (ré)installation du profil admin
-- (01→04,07) si l'ordre des profils ne permet pas de le faire plus tôt.
--
-- Rôle : sans ces privilèges, le moteur v5 ne peut pas exécuter le DDL
-- auto-réparateur sur les tables de SCHEMA_A / SCHEMA_B :
--   * ALTER ANY TABLE      : désactivation / réactivation de FK cycles, et
--                            l'amont DDL d'auto-création (livrable v3) ;
--   * CREATE ANY TABLE     : auto-création en B des tables actives absentes ;
--   * CREATE ANY INDEX     : index support de la PK créée avec la table ;
--   * CREATE ANY TRIGGER   : réserve futur (injection / audit).
-- Les privilèges DML ANY (INSERT/UPDATE/DELETE ANY TABLE) sont déjà couverts
-- par les grants profil admin classiques (SYNC_ACCESS). Ils sont redonnés ici
-- par sécurité si Sys n'a pas précédé l'admin dans l'ordre des profils.
--
------------------------------------------------------------------------------

PROMPT ==>

DECLARE
    v_cmd VARCHAR2(200);
BEGIN
    FOR rec IN (
        SELECT 'ALTER ANY TABLE'     AS p GET_PRIV  FROM DUAL UNION ALL
        SELECT 'CREATE ANY TABLE'         FROM DUAL UNION ALL
        SELECT 'CREATE ANY INDEX'         FROM DUAL UNION ALL
        SELECT 'CREATE ANY TRIGGER'       FROM DUAL UNION ALL
        SELECT 'INSERT ANY TABLE'         FROM DUAL UNION ALL
        SELECT 'UPDATE ANY TABLE'         FROM DUAL UNION ALL
        SELECT 'DELETE ANY TABLE'         FROM DUAL
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
END;
/

PROMPT ==>

COMMIT;

EXIT