--------------------------------------------------------------------------------
# Procédure — Configurer et lancer la synchronisation d'une liste de tables

**Package concerné** : `PKG_SCHEMA_SYNC` (v6 — état d'écart inclus) — projet `ora_sync`
**Objet** : procédure opérationnelle complète pour synchroniser une liste de
tables entre deux schémas jumeaux (`SCHEMA_A` →/↔ `SCHEMA_B`), avec les
scripts de chaque étape, prêts à copier-coller.

> Principe fondateur v1 : **aucune suppression n'est jamais propagée**
> (`SYNC_DELETE` verrouillé à `'N'`). Une ligne absente d'un côté est
> réinsérée ; les lignes en trop côté B restent. Les écarts de volumes
> BO/FE observés en fin de run sont donc **normaux** et attendus.

--------------------------------------------------------------------------------
## 0. Prérequis (à faire une fois)

| # | Prérequis | Script / commande |
|---|-----------|--------------------|
| 1 | Base Oracle accessible, 2 schémas jumeaux (`A`, `B`) + schéma technique `SYNC_ADMIN` colocalisé avec A (mode « même instance » recommandé, `C_DB_LINK_B = NULL`) | — |
| 2 | Profils `.env` renseignés (`admin`, `schema_a`, `schema_b`) | cf. `tools/orasync/config.py` |
| 3 | Connexions opérationnelles | `python setup_project.py check` |
| 4 | Schéma technique installé (tables, package, options v5) | `python setup_project.py install` puis `python setup_project.py migrate` |
| 5 | Package compilé et `VALID` | voir Étape 1 |

**Variables à personnaliser dans les scripts ci-dessous :**

| Variable | Exemple (base PCARDIMP) | Description |
|----------|--------------------------|-------------|
| `SCHEMA_A` | `PCARDIMPBO` | Schéma source de référence (côté local) |
| `SCHEMA_B` | `PCARDIMPFE` | Schéma cible / jumeau |
| `MA_LISTE` | `BANK, CARD_RANGE, ...` | Liste des tables à synchroniser |
| `RID` | `p_run_id` retourné | Identifiant du run (header/log) |

--------------------------------------------------------------------------------
## 1. Étape 1 — Vérifier l'état de l'environnement

### 1.1 Connexions

```
python setup_project.py check
python setup_project.py status          # derniers runs (SYNC_RUN_HEADER)
```

### 1.2 État du package et des constantes d'ancrage

Le package est compile pour des `C_SCHEMA_A` / `C_SCHEMA_B` FIXES (décision
d'architecture : pas de paramètre de schéma à l'appel). Il faut donc vérifier
qu'ils correspondent aux schémas cibles :

```sql
-- Exécuté dans SYNC_ADMIN (fichier : 20_check_env.sql, à lancer via
--   python setup_project.py sql 20_check_env.sql)
SET SERVEROUTPUT ON
SELECT object_type, status
FROM user_objects
WHERE object_name = 'PKG_SCHEMA_SYNC'
ORDER BY object_type;                     -- attendu : PACKAGE VALID, PACKAGE BODY VALID

SELECT line, text
FROM user_source
WHERE name = 'PKG_SCHEMA_SYNC'
  AND type = 'PACKAGE'
  AND regexp_like(text, 'C_SCHEMA_[AB]\s+CONSTANT|C_DB_LINK_B\s+CONSTANT')
ORDER BY line;

SELECT option_name, option_value FROM SYNC_RUN_OPTION ORDER BY option_name;
-- attendu : AUTO_BACKFILL_PARENTS=Y, AUTO_CREATE_MISSING_TABLE=N,
--           CYCLE_HANDLING=DISABLE_FK, MAX_FK_RETRY=3

SELECT COUNT(*) FROM SYNC_TABLE_CONFIG;   -- état de la config courante
```

**Si les constantes `C_SCHEMA_A/B` compilées ≠ schémas cibles** : appliquer le
patch temporaire décrit en Annexe C (recompile in-memory, jamais de
modification du dépôt), toujours **avec restauration à la fin de la séquence**.

--------------------------------------------------------------------------------
## 2. Étape 2 — Analyser les tables cibles (découverte)

But : savoir, **avant** toute configuration,
1. quelles tables existent dans A et dans B (une table n'existe que de A →
   `MISSING_IN_B` → exclue) ;
2. quelle clé sera utilisée (PK, puis UNIQUE, puis `SYNC_KEY_CONFIG`) ;
3. quelles colonnes exclure (audit / triggers) ;
4. quels volumes (lignes en trop côté B = resteront).

Script Python (adapter `MA_LISTE` et la 2e ligne) :

```python
# 21_diagnostic.py — python 21_diagnostic.py
import sys; sys.path.insert(0, 'tools')
from orasync.config import from_env
import oracledb

MA_LISTE = ["BANK","BANK_ADDENDUM","BANK_NETWORK","CARD_RANGE","CARD_PRODUCT"]  # <= à remplir
SCHEMA_A, SCHEMA_B = "PCARDIMPBO", "PCARDIMPFE"                                 # <= à remplir

st = from_env()
con = oracledb.connect(user=st.profile('admin').user,
                       password=st.profile('admin').password, dsn=st.profile('admin').dsn)
cur = con.cursor()
def q(sql, *a):
    cur.execute(sql, a); return cur.fetchall()

bo = {r[0] for r in q(f"select table_name from all_tables where owner='{SCHEMA_A}'")}
fe = {r[0] for r in q(f"select table_name from all_tables where owner='{SCHEMA_B}'")}

for name in MA_LISTE:
    up = name.upper()
    in_bo, in_fe = up in bo, up in fe
    etat = "SYNCABLE" if in_bo and in_fe else ("ABSENTE DE B" if in_bo else
            ("ABSENTE DE A" if in_fe else "ABSENTE DES DEUX"))
    pks = q(f"""select c.constraint_type, cc.column_name, cc.position
                from all_constraints c
                join all_cons_columns cc on cc.constraint_name=c.constraint_name
                                          and cc.owner=c.owner
                where c.owner='{SCHEMA_A}' and c.table_name=:1
                  and c.constraint_type in ('P','U')
                order by c.constraint_type, cc.position""", up)
    nbo = q(f"select count(*) from {SCHEMA_A}.{up}")[0][0] if in_bo else 0
    nfe = q(f"select count(*) from {SCHEMA_B}.{up}")[0][0] if in_fe else 0
    cols = [r[0] for r in q(f"""select column_name from all_tab_columns
                                where owner='{SCHEMA_A}' and table_name=:1
                                order by column_id""", up)] if in_bo else []
    aud = [c for c in cols if c in ('DATE_CREATE','DATE_MODIF','USER_MODIF',
                                    'DATE_CREATION','CREATED_DATE','UPDATED_DATE')]
    pk = ";".join(f"{r[1]}" for r in pks) or "AUCUNE PK/UNIQUE -> SYNC_KEY_CONFIG"
    print(f"{up:<32} {etat:<14} BO={nbo:>7} FE={nfe:>7}  PK={pk}  audit={aud}")
cur.close(); con.close()
```

**Lecture du résultat**
- `SYNCABLE` → la table peut être configurée et synchronisée.
- `PK` vide → prévoir `SYNC_KEY_CONFIG` (Étape 3.3).
- colonnes `audit` → à exclure (Étape 3.2) : souvent ré-estampées par les
  triggers de l'application côté B → **divergence perpétuelle** sinon (cas
  réel v5.2 : `DATE_CREATE`/`USER_MODIF`/`DATE_MODIF`).
- `ABSENTE DE B` (`MISSING_IN_B`) → exclue du run ; voir cas particuliers §7.1.

--------------------------------------------------------------------------------
## 3. Étape 3 — Écrire et charger la configuration

### 3.1 `SYNC_TABLE_CONFIG` (une ligne par table, idempotent)

```sql
-- 22_config.sql — python setup_project.py sql 22_config.sql
-- Si besoin, purger l'existant d'abord (attention : détruit la config courante) :
-- DELETE FROM SYNC_COLUMN_CONFIG; DELETE FROM SYNC_KEY_CONFIG; DELETE FROM SYNC_TABLE_CONFIG; COMMIT;

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, SYNC_MODE,
                               CONFLICT_STRATEGY, PRIORITY)
SELECT 'BANK',          'Y', 'A_TO_B', 'INSERT_UPDATE', 'ERROR_ON_CONFLICT', 100 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME='BANK');

INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION, SYNC_MODE,
                               CONFLICT_STRATEGY, PRIORITY)
SELECT 'CARD_RANGE',    'Y', 'A_TO_B', 'INSERT_UPDATE', 'ERROR_ON_CONFLICT', 100 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME='CARD_RANGE');
-- ... une ligne par table de MA_LISTE
COMMIT;
```

**Valeurs autorisées** (cf. Script 1) :

| Colonne | Valeurs | Rôle |
|---------|---------|------|
| `ENABLED` | `Y` / `N` | `N` = config conservée mais ignorée |
| `SYNC_DIRECTION` | `A_TO_B` / `B_TO_A` / `BIDIRECTIONAL` / `DISABLED` | sens de la synchro |
| `SYNC_MODE` | `INSERT` / `UPDATE` / `INSERT_UPDATE` | opérations appliquées |
| `CONFLICT_STRATEGY` | `SOURCE_A_WINS` / `SOURCE_B_WINS` / `ERROR_ON_CONFLICT` | seulement en `BIDIRECTIONAL` |
| `PRIORITY` | nombre > 0 (défaut 100) | ordre inter-grappes (moyenne) uniquement |

> `SYNC_DIRECTION='A_TO_B'` : B est aligné sur A (aucun conflit réel possible,
> seuls des écarts forcés `DIRECTION_FORCED` journalisés). `BIDIRECTIONAL` +
> `ERROR_ON_CONFLICT` : les vrais conflits sont journalisés dans
> `SYNC_CONFLICT` et **bloquent** (`TABLES_CONFLICT`), à résoudre puis relancer.

### 3.2 `SYNC_COLUMN_CONFIG` — exclusions (opt-out : absence = incluse)

Colonnes à exclure typiquement : les colonnes d'audit ré-estampées par
trigger (`DATE_CREATE`, `USER_MODIF`, `DATE_MODIF`, `DATE_CREATION`...), les
colonnes calculées, les LOB non pertinents.

```sql
INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
SELECT 'BANK', 'DATE_CREATE', 'N' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_COLUMN_CONFIG
                   WHERE TABLE_NAME='BANK' AND COLUMN_NAME='DATE_CREATE');
INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
SELECT 'BANK', 'USER_MODIF', 'N' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_COLUMN_CONFIG
                   WHERE TABLE_NAME='BANK' AND COLUMN_NAME='USER_MODIF');
INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
SELECT 'BANK', 'DATE_MODIF', 'N' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_COLUMN_CONFIG
                   WHERE TABLE_NAME='BANK' AND COLUMN_NAME='DATE_MODIF');
-- ... pour chaque table de MA_LISTE
COMMIT;
```

> ⚠️ Jamais exclure une colonne de la PK : le package le refuse au démarrage
> du run (table rejetée avec log explicite).

### 3.3 `SYNC_KEY_CONFIG` — uniquement si aucune PK/UNIQUE

```sql
-- Exemple : clé logique composite sur une table SANS contrainte PK/UNIQUE
INSERT INTO SYNC_KEY_CONFIG (TABLE_NAME, COLUMN_NAME, KEY_POSITION)
SELECT 'MA_TABLE_SANS_PK', 'CODE', 1 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM SYNC_KEY_CONFIG
                   WHERE TABLE_NAME='MA_TABLE_SANS_PK' AND COLUMN_NAME='CODE');
COMMIT;
```

> Le package vérifie l'unicité effective (`COUNT(*)` vs `COUNT(DISTINCT ...)`)
> avant le premier run et refuse si la clé n'est pas unique en pratique.

### 3.4 Options globales v5 (`SYNC_RUN_OPTION`)

Les 4 options par défaut sont déjà présentes après install. À ajuster
volontairement uniquement (API validée) :

```sql
BEGIN
  PKG_SCHEMA_SYNC.SET_RUN_OPTION('AUTO_BACKFILL_PARENTS',  'Y');           -- backfill parents FK absents de B
  PKG_SCHEMA_SYNC.SET_RUN_OPTION('MAX_FK_RETRY',           '3');
  PKG_SCHEMA_SYNC.SET_RUN_OPTION('CYCLE_HANDLING',         'DISABLE_FK');  -- cycles FK : désactivation temporaire
  PKG_SCHEMA_SYNC.SET_RUN_OPTION('AUTO_CREATE_MISSING_TABLE', 'N');        -- 'Y' nécessite CREATE ANY TABLE sur B
END;
/
```

--------------------------------------------------------------------------------
## 4. Étape 4 — Dry run (OBLIGATOIRE avant toute exécution réelle)

Le dry run **n'écrit rien** sur les tables métier : diagnostic complet
(compatibilité, écarts INSERT/UPDATE à venir, conflits) journalisé dans
`SYNC_LOG`, `SYNC_COMPATIBILITY_REPORT`, `SYNC_CONFLICT`, `SYNC_WORK_DIFF`.

```sql
-- 23_dry_run.sql — python setup_project.py sql 23_dry_run.sql
DECLARE
  v_list   PKG_SCHEMA_SYNC.t_tab_name_list
           := PKG_SCHEMA_SYNC.t_tab_name_list('BANK','BANK_ADDENDUM','BANK_NETWORK',
                                              'CARD_RANGE','CARD_PRODUCT');
  v_run_id NUMBER;
BEGIN
  PKG_SCHEMA_SYNC.SYNC_TABLES(
    p_table_list => v_list,                        -- liste demandée
    p_dry_run    => TRUE,                          -- <== DRY
    p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE,  -- CONTINUE (défaut) ou STOP
    p_run_id     => v_run_id
  );
  DBMS_OUTPUT.PUT_LINE('RUN_ID=' || v_run_id);
END;
/
```

> `SYNC_TABLES` (v4) résout automatiquement la lignée FK : l'ensemble exécuté =
> tables demandées **∪ parents (ancêtres)**, dont les parents absents de la
> config sont **auto-enrôlés et persistés** dans `SYNC_TABLE_CONFIG` (profil
> `AUTO_FK_LINEAGE`, direction héritée). → **Après le 1er dry run, relire la
> config** (Étape 6) et ajouter les exclusions souhaitées aux parents enrôlés.
> `SYNC_TABLE(nom)` ne traite QUE la table (rattrapage ciblé) ; `SYNC_ALL`
> traite toutes les tables actives de la config.

### 4.1 Lecture des résultats du dry run

```sql
-- 24_resultats.sql — python setup_project.py sql 24_resultats.sql
-- En-tête du run (RID = valeur RUN_ID affichée)
SELECT run_id, run_type, status, dry_run, total_tables, tables_success,
       tables_conflict, tables_failed, tables_excluded, start_date, end_date
FROM SYNC_RUN_HEADER
WHERE run_id = :RID;  -- remplacer :RID par la valeur retournée

-- Détail par table : opérations qui SERAIENT appliquées
SELECT table_name, status, rows_inserted_a_to_b, rows_updated_a_to_b,
       conflict_count, error_count, error_message
FROM SYNC_LOG
WHERE run_id = :RID
ORDER BY table_name;

-- Tables exclues et raisons (BLOCKING)
SELECT table_name, issue_type, count(*) AS nb
FROM SYNC_COMPATIBILITY_REPORT
WHERE check_id = (SELECT MAX(check_id) FROM SYNC_COMPATIBILITY_REPORT)
  AND severity = 'BLOCKING'
GROUP BY table_name, issue_type
ORDER BY table_name;

-- Conflits / écarts journalisés
SELECT table_name, resolution_strategy, count(*) AS nb
FROM SYNC_CONFLICT
WHERE run_id = :RID
GROUP BY table_name, resolution_strategy
ORDER BY 3 DESC;
```

**Critères avant de passer au réel**
- `status` du run : `SUCCESS` (ou `SUCCESS_WITH_CONFLICTS` si tables en
  `BIDIRECTIONAL` avec de vrais conflits → à résoudre avant).
- `tables_failed` = 0 ; les `tables_excluded` sont comprises (vérifier
  `issue_type` : `MISSING_IN_B`, `FK_CYCLE_NOT_DEFERRABLE`, incompatible...).
- les volumes `INSERT_TO_B` / `UPDATE_TO_B` correspondent à l'attendu.

--------------------------------------------------------------------------------
## 5. Étape 5 — Run réel

Même bloc que l'Étape 4, **`p_dry_run => FALSE`** :

```sql
-- 25_real_run.sql — python setup_project.py sql 25_real_run.sql
DECLARE
  v_list   PKG_SCHEMA_SYNC.t_tab_name_list
           := PKG_SCHEMA_SYNC.t_tab_name_list('BANK','BANK_ADDENDUM','BANK_NETWORK',
                                              'CARD_RANGE','CARD_PRODUCT');
  v_run_id NUMBER;
BEGIN
  PKG_SCHEMA_SYNC.SYNC_TABLES(
    p_table_list => v_list,
    p_dry_run    => FALSE,                         -- <== RÉEL
    p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE,
    p_run_id     => v_run_id
  );
  DBMS_OUTPUT.PUT_LINE('RUN_ID=' || v_run_id);
END;
/
```

Points d'attention
- **Durée** : proportionnelle aux volumes hachés (SHA-256 par ligne) et aux
  opérations appliquées. Sur la base PCARDIMP (20 tables, ~230 k lignes,
  ~5 900 opérations) : ≈ 5 min 30 s.
- **`C_ERROR_MODE_CONTINUE`** (défaut) : une table en échec ne bloque pas les
  autres ; les grappes déjà commitées restent commitées (pas de rollback
  global). `STOP` arrête après la 1re grappe en échec.
- **Reprise / idempotence** : un run peut être relancé sans risque (le second
  run ne réapplique que les écarts restants : cas observé 0/0/0).
- **Restauration** du package si un patch des constantes a été appliqué
  (Annexe C).

--------------------------------------------------------------------------------
## 6. Étape 6 — Vérifications post-run

### 6.1 Bilan du run

```sql
-- python setup_project.py sql 26_verif.sql  (RID = run réel)
SELECT (SELECT status FROM SYNC_RUN_HEADER WHERE run_id = :RID) AS statut_run,
       (SELECT COUNT(*) FROM SYNC_LOG WHERE run_id = :RID) AS tables_success;

SELECT SUM(rows_inserted_a_to_b) AS ins_atob, SUM(rows_updated_a_to_b) AS upd_atob,
       SUM(conflict_count) AS conflits, SUM(error_count) AS erreurs
FROM SYNC_LOG WHERE run_id = :RID;
```

### 6.2 Volumes BO vs FE (alignement)

```python
# 27_volumes.py — même en-tête que 21_diagnostic.py
for name in MA_LISTE:
    nbo = q(f"select count(*) from {SCHEMA_A}.{name.upper()}")[0][0]
    nfe = q(f"select count(*) from {SCHEMA_B}.{name.upper()}")[0][0]
    flag = "OK" if nbo == nfe else ("FE>BO (surnum. conservees)" if nfe > nbo else "!! BO>FE")
    print(f"{name.upper():<32} BO={nbo:>7} FE={nfe:>7}  {flag}")
```

> Attendu : `nbo == nfe` sauf lignes EF surnuméraires (jamais supprimées).
> `BO > FE` serait anormal → investiguer (table absente de B, PK changeante...).

### 6.3 Relire la configuration après un `SYNC_TABLES`

Les parents auto-enrôlés au 1er run sont persistés :

```sql
SELECT table_name, enabled, sync_direction, priority, updated_by
FROM SYNC_TABLE_CONFIG
ORDER BY table_name;
```

Vérifier qu'ils ont bien la direction héritée et qu'aucune exclusion n'est à
compléter pour eux (colonnes audit).

--------------------------------------------------------------------------------
## 7. Cas particuliers et pièges (check-list)

1. **Table absente de B (`MISSING_IN_B`)** → exclue (`TABLES_EXCLUDED`), le
   reste du run continue. Option `AUTO_CREATE_MISSING_TABLE='Y'` = création
   DDL depuis les métadonnées de A **mais** exige `CREATE ANY TABLE` sur B et
   exclut les FK/LONG/LONG RAW : à réserver à un compte DBA et à valider
   (recommandation : préférer un script DDL revu par un DBA, puis re-run).
2. **Cycles FK non déferrables** → `CYCLE_HANDLING='DISABLE_FK'` (défaut) :
   désactivation temporaire des FK du cycle côté B en mode « même instance »
   (exige `ALTER ANY TABLE` sur B). À travers un DB LINK, les DDL
   d'auto-réparation sont impossibles (`E_REMOTE_DDL_UNSUPPORTED`) → le cycle
   replie en `BLOCK`. `'BLOCK'` = comportement historique (exclusion).
3. **Graphe FK divergent A/B (v5.3)** : une FK présente côté A mais absente
   de B est désormais **ignorée** (vérification `ALL_CONSTRAINTS` dans
   `disable_cluster_fks`) au lieu de faire exclure toute la grappe
   (correctif v5.3, valide — cas réel `FK_CORPORATE_03/07`).
4. **Parents enrôlés** : après un 1er `SYNC_TABLES`, vérifier
   `SYNC_TABLE_CONFIG` (nouveaux parents `AUTO_FK_LINEAGE`) et leur appliquer
   les exclusions adéquates.
5. **Exclusions obligatoires** : colonnes ré-estampées par triggers
   (`DATE_CREATE`/`USER_MODIF`/`DATE_MODIF`...), LOB/colonnes calculées.
6. **Direction unique vs bidirectionnelle** : `A_TO_B`/`B_TO_A` = écarts
   forcés (`DIRECTION_FORCED`, exclus du `conflict_count`) ; `BIDIRECTIONAL` =
   vrais conflits journalisés dans `SYNC_CONFLICT` et bloquant
   (`ERROR_ON_CONFLICT`, défaut). Pas de `LAST_WRITE_WINS` en v1.
7. **DB LINK distant** : `C_DB_LINK_B`/`SET_DB_LINK`/`GET_DB_LINK` ; la
   synchro et les métadonnées passent par le lien, mais **aucun DDL** (cycle,
   auto-création) n'est supporté à travers un lien — mode même instance requis.
8. **Suppression jamais propagée** : lignes en trop côté cible = restent ;
   un écart de volume résiduel est le comportement attendu.
9. **Pas de rollback global** : en `STOP`, les grappes déjà commitées restent.
10. **Colonne de PK exclue à tort** → table rejetée au démarrage du run avec
    log explicite (le rejet est attendu, corriger la config).
11. **`E_TABLE_NOT_CONFIGURED`** à l'appel = la table demandée n'est pas (ou
    plus) active dans `SYNC_TABLE_CONFIG` → vérifier `ENABLED`/`SYNC_DIRECTION`.

--------------------------------------------------------------------------------
## 8. Maintenance — purge de l'historique

### 8.1 Rétention contrôlée (API recommandée)

```sql
BEGIN
  PKG_SCHEMA_SYNC.PURGE_HISTORY(90);   -- purge de tout ce qui précède les 90 derniers jours
END;
/
```

### 8.2 Purge totale + remise à zéro (décision explicite, maintenance)

**Script prêt à l'emploi : `13_RESET_CONFIG_HISTORIQUE.sql`**
(`python setup_project.py sql 13_RESET_CONFIG_HISTORIQUE.sql`) — purge complète
de la configuration et de l'historique, remise de toutes les séquences à 1,
avec **`SYNC_RUN_OPTION` conservée telle quelle**. L'ordre ci-dessous est
celui appliqué par ce script (FK : enfants avant parents) :

```sql
-- Ordre imposé par les FK : enfants avant parents
DELETE FROM SYNC_CONFLICT;
DELETE FROM SYNC_COMPATIBILITY_REPORT;
DELETE FROM SYNC_LOG;
DELETE FROM SYNC_RUN_HEADER;
COMMIT;

-- Configuration (si « repartir de zéro ») :
DELETE FROM SYNC_COLUMN_CONFIG;
DELETE FROM SYNC_KEY_CONFIG;
DELETE FROM SYNC_TABLE_CONFIG;
COMMIT;

-- Séquences à 1 (prochain RUN_ID = 1) :
ALTER SEQUENCE SYNC_RUN_ID_SEQ RESTART START WITH 1;
ALTER SEQUENCE SYNC_LOG_ID_SEQ RESTART START WITH 1;
ALTER SEQUENCE SYNC_CONFLICT_ID_SEQ RESTART START WITH 1;
ALTER SEQUENCE SYNC_COMPAT_REPORT_ID_SEQ RESTART START WITH 1;
ALTER SEQUENCE SYNC_COMPAT_CHECK_ID_SEQ RESTART START WITH 1;
```

> `SYNC_RUN_OPTION` (valeurs par défaut canoniques) est **conservée** : ce ne
> sont pas des données d'historique.

--------------------------------------------------------------------------------
## 9. Approche « fichier unique paramétrable »

Pour un besoin simple et rapide (configurer + lancer + vérifier une liste de
tables en un seul geste), le script **`12_SYNC_UNE_LISTE.sql`** regroupe les
Étapes 1 à 7 dans UN fichier : section `PARAMÈTRES` à éditer en tête
(liste des tables, schémas A/B, direction, mode, dry-seul, exclusions de
colonnes), puis découverte, configuration idempotente, contrôle de
compatibilité, dry run, run réel (si `c_dry_seul='N'`) et vérification des
volumes.

```sql
-- Lancement (les paramètres sont à éditer au début du bloc PL/SQL) :
--   python setup_project.py sql 12_SYNC_UNE_LISTE.sql
```

Points clés :
- **dry run par défaut** : `c_dry_seul = 'Y'` (rien n'est écrit sur les tables
  métier) ; passer à `'N'` après validation du dry run pour lancer le réel.
- **idempotent** : la configuration déjà posée n'est jamais écrasée
  (INSERT conditionnels `NOT EXISTS`) — le fichier peut être relancé sans
  risque.
- **garde d'environnement** : le script s'arrête proprement
  (`RAISE_APPLICATION_ERROR`) si les constantes compilées du package ne
  correspondent pas à `c_schema_a`/`c_schema_b`, ou si le package n'est pas
  `VALID`.
- `SYNC_TABLES` étant appelé sur la liste, la **lignée FK** est résolue
  automatiquement : les parents/ancêtres sont enrôlés en config et les tables
  de la même grappe FK sont traitées ensemble (exemple réel : un run demandant
  3 tables a traité la grappe complète de 20 tables, avec 1 parent
  `MISSING_IN_B` exclu — comportement attendu).

--------------------------------------------------------------------------------
## 10. État d'écart schéma A/B (v6, stats Oracle)

La fonctionnalité v6 rapporte les **écarts de comptes de lignes** entre les
deux schémas, à l'échelle du schéma, à partir des statistiques Oracle
(`NUM_ROWS` de l'optimiseur, niveau table). C'est un **état**, pas une
synchronisation : il ne modifie aucune donnée métier — seules les stats sont
(re)collectées et les tables `SYNC_STATS_GAP(_DETAIL)` reçoivent le rapport.

**Limite assumée et documentée** : `NUM_ROWS` est une *estimation* de
l'optimiseur, pas un `COUNT(*)` — l'écart est « statistique », idéal pour
détecter une dérive de volumétrie (ex. insertions non répliquées), pas pour
donner un chiffre exact.

### 10.1 Workflow (asynchrone, hors pic)

```bash
# 0) Prérequis une fois (SYS) :
python setup_project.py sql 14_sync_stats_gap_tables.sql
python setup_project.py sql 15_sys_stats_gap_grants.sql --profile sys
python setup_project.py sql 03_sync_package_spec.sql
python setup_project.py sql 04_sync_package_body.sql

# 1) Collecte + rapport + affichage (un seul geste) :
python setup_project.py gap --schema-a PCARDIMPBO --schema-b PCARDIMPFE
```

Le CLI enchaîne : `SUBMIT_STATS_JOBS` (2 jobs `DBMS_SCHEDULER` asynchrones) →
`WAIT_FOR_STATS_JOBS` (attente de fin, `--wait-timeout`, défaut 3600 s) →
`REPORT_COUNTS_GAP` (rapport persistant + REF CURSOR) → affichage trié par
écart décroissant. Options utiles :

| Option | Rôle |
|--------|------|
| `--no-collect` | ne pas relancer la collecte (lire les stats courantes) |
| `--max-age-hours N` | refuser le rapport si les stats d'un côté sont plus vieilles que N h (`E_STATS_NOT_FRESH`, `-20013`) |
| `--limit N` | nombre de lignes de détail affichées |
| `--schema-a / --schema-b` | schémas comparés (défaut : constantes compilées) |

### 10.2 Lecture du rapport

- En-tête (`SYNC_STATS_GAP`) : périmètre = tables de base présentes des deux
  côtés ; totaux `TABLES_OK` / `TABLES_GAP` / `TABLES_NO_STATS_A/B` ;
  `STATS_DATE_A/B` = fraîcheur constatée.
- Détail (`SYNC_STATS_GAP_DETAIL`) : **anomalies uniquement** — `DIFF`
  **signé** (`NUM_ROWS_B - NUM_ROWS_A` : `+` si B a plus de lignes que A,
  `-` sinon ; `DIFF_PCT` sur la valeur absolue, base `GREATEST(A,B)`) ou
  `NO_STATS_A` / `NO_STATS_B` /
  `NO_STATS_BOTH` (stats absentes : exclues du calcul, comptées dans
  l'en-tête).
- Re-consultation : `PKG_SCHEMA_SYNC.GET_LAST_GAP_ID()` puis lecture des
  tables, ou `sql` sur `SYNC_STATS_GAP(/_DETAIL)` pour historique.
- Purge : intégrée à `PURGE_HISTORY` ; remise à zéro complète : Script 13
  (rapports + 2 séquences, `SYNC_RUN_OPTION` conservée).

Pièges v1 :
- **Multi-instances (DB LINK)** : la *lecture* du rapport sait lire les stats
  distantes via le lien, mais la *collecte* distante n'est pas supportée
  (`SUBMIT_STATS_JOBS` lève `-20014`) — collecter les stats de B dans la
  session de suivi de B, puis `gap --no-collect`.
- **Collecte coûteuse** sur un gros schéma (ex. 6 800+ tables) : à lancer hors
  pic, et suivre l'avancement via `GET_STATS_JOB_STATUS`.

--------------------------------------------------------------------------------
## Annexe A — Rappel de l'API publique (`03_sync_package_spec.sql`)

| Procédure / fonction | Rôle |
|----------------------|------|
| `SYNC_ALL(dry, err_mode, db_link, run_id, sync_mode)` | toutes tables actives de la config |
| `SYNC_TABLE(name, dry, db_link, run_id, sync_mode)` | une seule table (rattrapage ciblé) |
| `SYNC_TABLES(list, dry, err_mode, db_link, sync_mode, run_id)` | **liste de tables + lignée FK** (recommandé) |
| `CHECK_COMPATIBILITY(table \| liste, db_link, check_id, has_blocking)` | contrôle de compatibilité seul |
| `GET_RUN_STATUS(run_id, header_cursor, detail_cursor)` | synthèse + détail d'un run |
| `PURGE_HISTORY(keep_days)` | rétention de l'historique |
| `SET_DB_LINK / GET_DB_LINK` | mode DB LINK distant |
| `SET_RUN_OPTION / GET_RUN_OPTION` | options globales v5 |
| `SUBMIT_STATS_JOBS(A, B, →jobs)` | **v6** : lancement asynchrone des collectes de stats (2 jobs) |
| `GET_STATS_JOB_STATUS(job)` / `ARE_STATS_JOBS_DONE(A,B)` / `WAIT_FOR_STATS_JOBS(A,B,timeout,→ok)` | **v6** : suivi / attente de fin des collectes |
| `REPORT_COUNTS_GAP(A, B, jobs, max_age, →gap_id, →hdr, →dtl)` | **v6** : rapport d'écart persistant + REF CURSOR |
| `GET_LAST_GAP_ID()` | **v6** : dernier rapport généré |

## Annexe B — Références des scripts du projet

| Fichier | Contenu |
|---------|---------|
| `01_sync_config_tables.sql` | tables de configuration + `SYNC_RUN_OPTION` + séquences |
| `02_sync_log_tables.sql` | `SYNC_RUN_HEADER`, `SYNC_LOG`, `SYNC_CONFLICT`, `SYNC_COMPATIBILITY_REPORT`, GTT `SYNC_WORK_*` |
| `03_sync_package_spec.sql` | spécification du package (constantes d'ancrage A/B) |
| `04_sync_package_body.sql` | corps du package (fix v5.2 traçabilité, v5.3 graphe FK divergent) |
| `05_sample_data_and_config.sql` | données + config d'exemple (CLIENT/PRODUIT/COMMANDE) |
| `06_test_scenarios.sql`, `07_test_harness.sql` | scénarios et harnais 86 assertions (Bloc 11 = v6 état d'écart) |
| `08_migration_v2.sql`, `09_*` | migrations et grants (SYS) |
| `11_PROCEDURE_SYNCHRONISATION.md` | procédure opérationnelle (ce document) |
| `12_SYNC_UNE_LISTE.sql` | **fichier unique paramétrable** : config + dry run (+ réel) + vérifs pour une liste de tables (§9) |
| `13_RESET_CONFIG_HISTORIQUE.sql` | **remise à zéro** config + historique + séquences (§8.2, `SYNC_RUN_OPTION` conservée) |
| `14_sync_stats_gap_tables.sql` | **v6** : tables `SYNC_STATS_GAP(_DETAIL)` + 2 séquences (§10) |
| `15_sys_stats_gap_grants.sql` | **v6** : grants SYS de l'état d'écart (`ANALYZE ANY`, `CREATE JOB`, …) |
| `tools/orasync/` | CLI `setup_project.py` (`check`, `install`, `migrate`, `sql`, `sample`, `test`, `status`, `gap`) |

## Annexe C — Patch temporaire des constantes `C_SCHEMA_A/B` (schémas ≠ compilés)

Le package est compilé pour des schémas FIXES. Si les cibles diffèrent
(ex. binôme réel `PCARDIMPBO`/`PCARDIMPFE` vs constantes `SCHEMA_A`/`SCHEMA_B`
du dépôt), recompiler **en mémoire** une spec substituée, puis **restaurer
systématiquement** à la fin (y compris en cas d'erreur) :

```python
# 28_patch_run.py — le run complet (dry ou réel) sous patch, avec restauration garantie
import re, sys
sys.path.insert(0, 'tools')
from orasync.config import from_env
from orasync.db import session
from orasync.sqlplus import SqlPlusRunner

SCHEMA_A, SCHEMA_B = "PCARDIMPBO", "PCARDIMPFE"   # <= à remplir
MA_LISTE = ["BANK","BANK_ADDENDUM","CARD_RANGE"]  # <= à remplir

st = from_env()
spec = (st.scripts_dir / "03_sync_package_spec.sql").read_text(encoding="utf-8")
body = (st.scripts_dir / "04_sync_package_body.sql").read_text(encoding="utf-8")

def patched(text):
    t = re.sub(r"(C_SCHEMA_A\s+CONSTANT VARCHAR2\(128\) := )'[^']*'",
               r"\1'" + SCHEMA_A + "'", text)
    t = re.sub(r"(C_SCHEMA_B\s+CONSTANT VARCHAR2\(128\) := )'[^']*'",
               r"\1'" + SCHEMA_B + "'", t)
    return t

with session(st, "admin") as con:
    try:
        SqlPlusRunner(con, source="spec (patch)", emit=print).run_text(patched(spec, SCHEMA_A, SCHEMA_B))
        SqlPlusRunner(con, source="corps", emit=print).run_text(body)
        lst = ",".join(f"'{t}'" for t in MA_LISTE)
        SqlPlusRunner(con, source="RUN", emit=print).run_text(f"""
DECLARE v PKG_SCHEMA_SYNC.t_tab_name_list := PKG_SCHEMA_SYNC.t_tab_name_list({lst}); r NUMBER;
BEGIN PKG_SCHEMA_SYNC.SYNC_TABLES(v, FALSE, PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE, r);
  DBMS_OUTPUT.PUT_LINE('RUN_ID='||r); END;""")
    finally:
        # RESTAURATION immédiate / systématique
        SqlPlusRunner(con, source="spec (restauration)", emit=print).run_text(spec)
        SqlPlusRunner(con, source="corps (restauration)", emit=print).run_text(body)
```

> La restauration recompile depuis les fichiers du dépôt (canoniques) : le
> dépôt doit donc être à jour (au minimum v5.3) AVANT de lancer ce script.
--------------------------------------------------------------------------------