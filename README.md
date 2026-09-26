# SPÉCIFICATIONS TECHNO-FONCTIONNELLES

## Package PL/SQL de synchronisation bidirectionnelle Oracle

# PKG_SCHEMA_SYNC

Architecture générique, bidirectionnelle, idempotente, configurable, auditable et performante de synchronisation de données Oracle entre deux schémas via DB LINK.

**Version 5.0 — Document de spécifications** (correctifs et durcissements v2, évolutions v3, enrôlement de la lignée FK en v4, auto-réparation ascendante en v5 — cf. [§7](#7-changelog-v2), [§8](#8-changelog-v3), [§9](#9-changelog-v4) et [§10](#10-changelog-v5))

---

## Sommaire

1. [Introduction et contexte](#1-introduction-et-contexte)
2. [Décisions d'architecture](#2-décisions-darchitecture)
3. [Spécifications fonctionnelles](#3-spécifications-fonctionnelles)
4. [Architecture technique](#4-architecture-technique)
5. [Limites connues et risques assumés](#5-limites-connues-et-risques-assumés)
6. [Annexes](#6-annexes)
7. [Changelog v2](#7-changelog-v2)
8. [Changelog v3](#8-changelog-v3)
9. [Changelog v4](#9-changelog-v4)
10. [Changelog v5](#10-changelog-v5)
11. [Outillage de déploiement et industrialisation](#11-outillage-de-déploiement-et-industrialisation)
12. [Changelog v6](#12-changelog-v6)

> **Procédure opérationnelle** : pour configurer et lancer une synchronisation
> d'une liste de tables (scripts étape par étape), voir
> [`11_PROCEDURE_SYNCHRONISATION.md`](11_PROCEDURE_SYNCHRONISATION.md) ;
> pour une exécution « tout-en-un » paramétrable, voir
> [`12_SYNC_UNE_LISTE.sql`](12_SYNC_UNE_LISTE.sql) ; pour une remise à zéro de
> la configuration/historique (séquences incluses, options conservées), voir
> [`13_RESET_CONFIG_HISTORIQUE.sql`](13_RESET_CONFIG_HISTORIQUE.sql).
>
> **État d'écart schéma (v6)** : pour comparer les volumétries A/B à partir
> des statistiques Oracle (collecte explicite en amont), utiliser
> `python setup_project.py gap --schema-a <A> --schema-b <B>` (voir
> [§12 Changelog v6](#12-changelog-v6)).
>
> **Synchro niveau schéma (v6.1)** : pour *réaligner* la volumétrie des tables
> en écart (dry run d'abord, réel avec `--real`), utiliser
> `python setup_project.py schema-sync --schema-a <A> --schema-b <B>` (voir
> [§12.6](#126-synchro-niveau-schéma--schema-sync) et la
> [procédure §11](11_PROCEDURE_SYNCHRONISATION.md)).

---

## 1. Introduction et contexte

Ce document décrit les spécifications technico-fonctionnelles complètes du package PL/SQL `PKG_SCHEMA_SYNC`, dont l'objectif est de maintenir un jeu de données identique entre deux schémas Oracle jumeaux (`SCHEMA_A` et `SCHEMA_B`), reliés par un DB LINK, sans modification du schéma métier existant.

La solution est conçue comme un outil de réconciliation périodique (traitement par lot, non temps réel), générique — il ne contient aucun code spécifique à une table métier donnée — et découvre dynamiquement les tables, colonnes, clés et contraintes via le dictionnaire de données Oracle (`ALL_TAB_COLUMNS`, `ALL_CONSTRAINTS`, `ALL_CONS_COLUMNS`, `ALL_TABLES`).

### 1.1. Objectifs

- Synchroniser bidirectionnellement des tables jumelles entre `SCHEMA_A` et `SCHEMA_B`.
- Détecter et tracer les conflits de données réels, sans jamais les résoudre silencieusement.
- Garantir l'idempotence : une exécution sans changement intermédiaire ne produit aucune écriture.
- Rester générique, configurable, auditable et robuste face aux erreurs partielles.
- Respecter les dépendances d'intégrité référentielle (clés étrangères) dans l'ordre d'application des écritures.

### 1.2. Périmètre et non-objectifs

Ce périmètre (v1) exclut volontairement certains éléments, par choix d'architecture assumé et documenté dans ce document :

- La synchronisation des suppressions n'est pas implémentée (voir [§3.4](#34-gestion-des-suppressions)).
- Aucune modification du schéma métier existant (pas de trigger, pas de colonne technique ajoutée).
- Pas de réplication temps réel : le package est un outil de réconciliation périodique.
- La stratégie de résolution de conflit `LAST_UPDATE_WINS` (basée sur un horodatage applicatif) n'est pas retenue en v1.
- Les types de données `LONG`, `LONG RAW`, `BFILE`, `XMLType`, et les types utilisateur (objets, VARRAY, nested tables) ne sont pas synchronisables.

### 1.3. Public visé

Ce document s'adresse aux administrateurs de bases de données Oracle, architectes techniques et développeurs PL/SQL en charge de l'installation, de l'exploitation ou de la maintenance évolutive de `PKG_SCHEMA_SYNC`.

---

## 2. Décisions d'architecture

Le tableau suivant récapitule l'ensemble des décisions d'architecture actées au cours de la phase de cadrage, avant tout développement. Chaque décision engage une hypothèse ou un compromis explicite ; leur remise en cause ultérieure doit être traitée comme une évolution d'architecture, pas comme une simple modification de configuration.

| # | Décision | Choix retenu |
|---|----------|--------------|
| 1 | Topologie | DB LINK unique `SYNC_LINK_B` ; `SYNC_ADMIN` colocalisé avec l'instance de `SCHEMA_A` (Option 1) |
| 2 | Modification du schéma métier | Interdite : aucun trigger ni colonne technique sur les tables applicatives |
| 3 | Détection des suppressions | Aucune : une ligne absente d'un côté est systématiquement réinsérée, jamais interprétée comme une suppression à propager |
| 4 | `SYNC_DELETE` | Conservée dans le modèle de données, verrouillée à `'N'` par CHECK constraint, réservée à une v2 |
| 5 | Fréquence d'exécution | Réconciliation périodique (batch), pas de temps réel |
| 6 | `SYNC_DIRECTION` | `BIDIRECTIONAL` / `A_TO_B` / `B_TO_A` / `DISABLED` |
| 7 | `PRIORITY` vs ordre FK | Ordre FK (tri topologique) prioritaire à l'intérieur d'une grappe ; `PRIORITY` n'ordonne que les grappes entre elles (moyenne des tables membres) |
| 8 | `LAST_UPDATE_WINS` | Retirée du périmètre v1 (fiabilité d'horloge et de colonne non garantie) |
| 9 | Statuts de run | `SUCCESS` / `SUCCESS_WITH_CONFLICTS` / `PARTIAL` / `FAILED` |
| 10 | Cycles FK non déferrables | Exclusion automatique de la grappe entière, journalisée `BLOCKING` |
| 11 | Cycles FK déferrables | Grappe acceptée, `SET CONSTRAINTS ALL DEFERRED` (portée locale `SCHEMA_A` uniquement — limite documentée) |
| 12 | Granularité transactionnelle | Commit par grappe FK ; SAVEPOINT par table à l'intérieur de la grappe (décision prise par l'architecte, déléguée) |
| 13 | `STOP_ON_ERROR` | Les grappes déjà commitées restent commitées ; la grappe en cours interrompt son traitement |
| 14 | Droits d'exécution | `AUTHID DEFINER`, compte technique `SYNC_ADMIN`, grants larges sur les deux schémas |
| 15 | Types de données exclus | `LONG`, `LONG RAW`, `BFILE`, `XMLType`, types objet / VARRAY / nested table |
| 16 | Cible du graphe FK | Découvert uniquement côté `SCHEMA_A`, utilisé comme référence pour les deux sens de propagation |
| 17 | Cible d'écriture distante | Jamais de MERGE vers une table distante ; `INSERT` + `UPDATE` distribués à la place (portabilité) |
| 18 | Rapports (`CHECK_COMPATIBILITY` / `GET_RUN_STATUS`) | Tables persistées, pas de fonction pipelined |

> **Point d'attention** — Deux décisions n'ont pas fait l'objet d'une validation explicite par le commanditaire et ont été tranchées par l'architecte selon la recommandation la plus sûre, à relire en priorité : la granularité SAVEPOINT par table à l'intérieur d'une grappe (décision 12), et le choix d'éviter tout MERGE vers une cible distante au profit d'`INSERT`+`UPDATE` distribués (décision 17).

---

## 3. Spécifications fonctionnelles

### 3.1. Principe général de synchronisation

Pour chaque table configurée, le package compare l'état de `SCHEMA_A` et de `SCHEMA_B` à l'instant du run, et classe chaque ligne (identifiée par sa clé de correspondance) dans l'un des cas suivants :

| Cas | Situation | Action |
|-----|-----------|--------|
| 1 | Ligne présente uniquement dans A | Insérée dans B (sauf si `SYNC_DIRECTION = B_TO_A`) |
| 2 | Ligne présente uniquement dans B | Insérée dans A (sauf si `SYNC_DIRECTION = A_TO_B`) |
| 3 | Ligne présente des deux côtés, valeurs identiques | Aucune action (garantit l'idempotence) |
| 4 | Ligne présente des deux côtés, valeurs différentes | Résolution de conflit appliquée ([§3.3](#33-résolution-de-conflit)) |
| 5 | Ligne supprimée d'un côté | Réinsérée au run suivant ([§3.4](#34-gestion-des-suppressions)) — aucune suppression propagée |

### 3.2. Sens de synchronisation (SYNC_DIRECTION)

| Valeur | Comportement |
|--------|--------------|
| `BIDIRECTIONAL` | Les deux sens sont actifs. Un conflit réel déclenche la stratégie de résolution configurée (`CONFLICT_STRATEGY`). |
| `A_TO_B` | `SCHEMA_B` est purement subordonné à `SCHEMA_A`. Tout écart est écrasé au profit de A. Une ligne présente uniquement dans B reste orpheline (jamais supprimée, jamais remontée vers A). |
| `B_TO_A` | Symétrique de `A_TO_B`. |
| `DISABLED` | Table présente en configuration mais ignorée par `SYNC_ALL`. |

### 3.3. Résolution de conflit

Un conflit réel est une ligne dont la valeur a changé des deux côtés depuis le dernier état identique connu. Le package distingue explicitement un conflit réel d'une simple différence unilatérale, et ne l'écrase jamais silencieusement.

| Stratégie | Comportement |
|-----------|--------------|
| `SOURCE_A_WINS` | La valeur de `SCHEMA_A` est propagée vers `SCHEMA_B`, quel que soit le côté réellement modifié. |
| `SOURCE_B_WINS` | Symétrique de `SOURCE_A_WINS`. |
| `ERROR_ON_CONFLICT` | Aucune valeur n'est appliquée. Le conflit est journalisé dans `SYNC_CONFLICT` et reste non résolu jusqu'à intervention manuelle. |

Tout conflit — résolu automatiquement ou non — est systématiquement journalisé dans `SYNC_CONFLICT` avec la valeur complète de la ligne des deux côtés (sérialisation JSON), la stratégie appliquée et le côté retenu, à des fins d'audit.

### 3.4. Gestion des suppressions

**Décision fondamentale (validée)** : le package ne propage jamais de suppression. Une ligne absente d'un côté est systématiquement réinsérée au run suivant, y compris si son absence résulte d'une suppression métier volontaire de l'autre côté.

> **Comportement assumé** — Ce comportement doit être compris et accepté par les utilisateurs métier avant mise en production : toute suppression effectuée sur l'une des deux bases sera annulée par la synchronisation suivante, indéfiniment. Ce n'est pas un défaut, mais un choix d'architecture délibéré.

Le paramètre `SYNC_DELETE` est conservé dans le modèle de données (verrouillé à `'N'` par contrainte CHECK) en prévision d'une éventuelle version 2 dotée d'un mécanisme de détection de suppression fiable (tombstone ou journal de changement), qui nécessiterait une modification du schéma métier actuellement exclue.

### 3.5. Vérification de compatibilité structurelle

Avant toute synchronisation, le package compare les métadonnées des tables entre `SCHEMA_A` et `SCHEMA_B` (colonnes, types, tailles, précision, échelle, nullabilité, clés) et produit un rapport d'anomalies avec deux niveaux de sévérité :

- **BLOCKING** : la table est automatiquement exclue du run tant que l'anomalie n'est pas corrigée (ex. table absente d'un côté, type ou longueur incompatible sur une colonne synchronisée, absence de clé exploitable, clé configurée non unique en pratique, clés A/B divergentes).
- **WARNING** : la table reste synchronisable, l'anomalie est seulement signalée (ex. colonne surnuméraire exclue de fait, nullabilité différente, absence de clé déclarée côté B alors que A en a une).

Typologie des anomalies journalisées (`SYNC_COMPATIBILITY_REPORT.ISSUE_TYPE`) : `MISSING_IN_A`, `MISSING_IN_B`, `TYPE_MISMATCH`, `LENGTH_MISMATCH`, `NULLABLE_MISMATCH`, `PK_MISSING`, `PK_MISMATCH`, `UNSUPPORTED_TYPE`, `KEY_NOT_UNIQUE`, `FK_CYCLE_DEFERRABLE`, `FK_CYCLE_NOT_DEFERRABLE`, `FK_PARENT_ENROLLED`, `FK_PARENT_DISABLED`. Les deux `FK_CYCLE_*` portent sur les cycles FK (cf. [§4.5](#45-ordonnancement-des-écritures-dépendances-fk)) ; `PK_MISMATCH` (correctif v2) compare les clés de correspondance réellement retenues des deux côtés (`WARNING` si B n'a aucune clé détectable, `BLOCKING` si les clés diffèrent). Les deux `FK_PARENT_*` (v4) portent sur la lignée FK hors périmètre configuré (cf. [§3.9](#39-périmètre-par-liste-de-tables-et-expansion-implicite-des-dépendances-fk)) : `FK_PARENT_ENROLLED` signale un parent FK absent de `SYNC_TABLE_CONFIG` **enrôlé automatiquement** avec sa lignée (`WARNING`) ; `FK_PARENT_DISABLED` signale un parent présent mais désactivé (`ENABLED='N'` ou `SYNC_DIRECTION='DISABLED'`), **jamais forcé** (`WARNING`). Les six types v5 (`PARENT_BACKFILLED`, `FK_CHILD_RETRIED`, `FK_CYCLE_HANDLED_BY_DISABLE`, `TABLE_CREATED_IN_B`, `PARENT_BACKFILL_FAILED`, `FK_REPAIR_FAILED`) tracent l'auto-réparation ascendante : backfill des parents FK manquants et retentative enfant (`PARENT_BACKFILLED`/`FK_CHILD_RETRIED`, `WARNING`), traitement des cycles FK par désactivation (`FK_CYCLE_HANDLED_BY_DISABLE`, `WARNING`), auto-création des tables manquantes en B (`TABLE_CREATED_IN_B`, `WARNING`), et leurs échecs éventuels (`PARENT_BACKFILL_FAILED`, `FK_REPAIR_FAILED`, `BLOCKING`) — cf. [§10](#10-changelog-v5).

### 3.6. Mode simulation (DRY_RUN)

Le package peut s'exécuter en mode simulation (`p_dry_run = TRUE`) : le diagnostic et la classification des différences sont effectués et journalisés normalement, mais aucune écriture n'est appliquée sur les tables métier.

### 3.7. Idempotence

**Exigence fondamentale** : après une synchronisation réussie (A = B), une deuxième exécution immédiate ne doit produire aucune modification. Cette propriété est garantie par construction : une ligne dont le hash est identique des deux côtés ne génère aucune entrée dans la structure de diagnostic, donc aucune écriture réelle.

> **Limite de la garantie** — L'idempotence n'est garantie qu'en l'absence de conflit non résolu. Un run avec des conflits en attente (`ERROR_ON_CONFLICT`) reste par nature divergent tant qu'aucune intervention manuelle n'a tranché — le statut de run `SUCCESS_WITH_CONFLICTS` reflète explicitement cet état.

### 3.8. Mode de synchronisation (INSERT / UPDATE / INSERT_UPDATE)

Le mode d'application détermine quelles opérations le package est autorisé à propager :

| Mode | Comportement |
|------|--------------|
| `INSERT` | Seules les créations sont propagées ; les divergences de lignes existantes sont ignorées |
| `UPDATE` | Seules les mises à jour de lignes existantes sont propagées ; les créations sont ignorées |
| `INSERT_UPDATE` | Comportement complet (défaut) : créations **et** mises à jour |

Le mode se règle à deux niveaux, dans cet ordre de priorité :

1. **Par table** — colonne `SYNC_MODE` de `SYNC_TABLE_CONFIG` (défaut `INSERT_UPDATE`, contrainte `CK_STC_SYNC_MODE`).
2. **Par run** — paramètre `p_sync_mode` sur `SYNC_ALL`, `SYNC_TABLE` et `SYNC_TABLES`. Un override de run **ne persiste pas** en configuration.

La sentinelle `C_SYNC_MODE_KEEP_CURRENT` (valeur par défaut) signifie « utiliser le mode configuré par table ». Un mode inconnu est rejeté en entrée (`E_INVALID_PARAMETER`, `-20011`), avant tout effet de bord. Le mode **effectif** de chaque table est journalisé dans `SYNC_LOG.SYNC_MODE`.

### 3.9. Périmètre par liste de tables et expansion implicite des dépendances FK

`SYNC_TABLES` prend une **liste** de tables logiques (`t_tab_name_list`) et applique la **résolution implicite des dépendances FK** : la fermeture transitive des **tables parentes** (ancêtres FK) est automatiquement ajoutée au périmètre. Depuis la v4, cette résolution est couplée à un **enrôlement automatique de la lignée** : tout parent FK absent de `SYNC_TABLE_CONFIG` est ajouté (et son propre parent récursivement), pour garantir l'ordre parent → enfant et éviter les `ORA-02291` côté `SCHEMA_B`.

Règles (v4) :

- Chaque table demandée doit exister en configuration et être active (`ENABLED='Y'`, `SYNC_DIRECTION != 'DISABLED'`), sinon `E_TABLE_NOT_CONFIGURED` (`-20002`).
- Seuls les **parents** sont ajoutés (jamais les enfants ni les tables sans lien).
- Un parent **absent** de `SYNC_TABLE_CONFIG` est **enrôlé automatiquement** : profil `AUTO_FK_LINEAGE` (`ENABLED='Y'`, `SYNC_DELETE='N'`, `SYNC_MODE='INSERT_UPDATE'`, `CONFLICT_STRATEGY='ERROR_ON_CONFLICT'`, `PRIORITY=100`, `UPDATED_BY='AUTO_FK_LINEAGE'`), avec `SYNC_DIRECTION` **héritée de l'enfant** (repli `BIDIRECTIONAL` si sens multiples/absents), WARNING `FK_PARENT_ENROLLED` rattaché au `CHECK_ID` courant. L'enrôlement est **persisté** (`COMMIT`) et **idempotent** (jamais dupliqué).
- Un parent **présent mais désactivé** (`ENABLED='N'` ou `SYNC_DIRECTION='DISABLED'`) n'est **jamais forcé** : WARNING `FK_PARENT_DISABLED`, la table reste respectable mais n'est **pas exécutée** par le run.
- L'ensemble résolu (demandées + parents enrôlés/y compris les parents désactivés en signalement) est exécuté par grappes, dans l'ordre topologique (parents avant enfants), exactement comme `SYNC_ALL` ; TOTAL_TABLES englobe la fermeture, TABLES_EXCLUDED comptabilise bloqueurs et parents désactivés non exécutés.

> **Différence avec `SYNC_TABLE`** — `SYNC_TABLE` ne traite que la table demandée (rattrapage ciblé) et **ne mute jamais** la configuration (pas d'enrôlement). `SYNC_TABLES` étend ce périmètre aux parents FK nécessaires à la cohérence, tout en restant plus restreint qu'un `SYNC_ALL` complet. `CHECK_COMPATIBILITY(NULL)` applique le même enrôlement (et le persiste) en contrôle autonome ; les surcharges mono-table et liste restent non mutantes.

---

## 4. Architecture technique

### 4.1. Topologie d'implantation

Le schéma technique `SYNC_ADMIN` est colocalisé sur l'instance hébergeant `SCHEMA_A`. `SCHEMA_A` est accédé localement (synonymes/grants directs). `SCHEMA_B`, hébergé sur une instance distincte, est accédé exclusivement via un DB LINK unique nommé `SYNC_LINK_B`.

```
SYNC_ADMIN (+ SCHEMA_A) ──────────────────────────────────▶ SCHEMA_B
                       (instance 1)  SYNC_LINK_B   (instance 2)
```

### 4.2. Modèle de données

#### 4.2.1. Tables de configuration

| Table | Rôle |
|-------|------|
| `SYNC_TABLE_CONFIG` | Liste pilote des tables synchronisées : activation, sens, stratégie de conflit, priorité, mode (`SYNC_MODE`) |
| `SYNC_COLUMN_CONFIG` | Colonnes explicitement exclues de la comparaison et de l'écriture, par table |
| `SYNC_KEY_CONFIG` | Clé de correspondance explicite pour les tables sans PK/UNIQUE détectable automatiquement |

#### 4.2.2. Tables de journalisation et d'audit

| Table | Rôle |
|-------|------|
| `SYNC_RUN_HEADER` | Statut global d'une exécution de `SYNC_ALL`, `SYNC_TABLE` ou `SYNC_TABLES`, agrégé depuis `SYNC_LOG` |
| `SYNC_LOG` | Détail par table pour un run : volumétrie, statut, erreurs, mode effectif (`SYNC_MODE`) |
| `SYNC_CONFLICT` | Historique des conflits réels et des écarts forcés (sens unique), avec résolution appliquée |
| `SYNC_COMPATIBILITY_REPORT` | Anomalies de structure détectées par `CHECK_COMPATIBILITY` |

#### 4.2.3. Tables de travail (Global Temporary Tables)

| Table | Rôle |
|-------|------|
| `SYNC_WORK_HASH_A` / `SYNC_WORK_HASH_B` | Paires (clé, hash de ligne) rapatriées localement pour comparaison, par run |
| `SYNC_WORK_DIFF` | Classification par clé après comparaison des hash, avant application |

Les GTT sont déclarées `ON COMMIT PRESERVE ROWS` (et non `DELETE ROWS`), car la granularité transactionnelle par grappe implique plusieurs COMMIT au sein d'une même session avant la fin du run. Une purge explicite par `(RUN_ID, TABLE_NAME)` est effectuée après traitement de chaque table.

### 4.3. API publique

```sql
PKG_SCHEMA_SYNC.SYNC_ALL(
    p_dry_run     IN BOOLEAN  DEFAULT FALSE,
    p_error_mode  IN VARCHAR2 DEFAULT 'CONTINUE',
    p_db_link     IN VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
    p_sync_mode   IN VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT,
    p_run_id      OUT NUMBER);

PKG_SCHEMA_SYNC.SYNC_TABLE(
    p_table_name  IN VARCHAR2,
    p_dry_run     IN BOOLEAN DEFAULT FALSE,
    p_db_link     IN VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
    p_sync_mode   IN VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT,
    p_run_id      OUT NUMBER);

-- Liste de tables + expansion implicite des parents FK (v3)
PKG_SCHEMA_SYNC.SYNC_TABLES(
    p_table_list  IN t_tab_name_list,
    p_dry_run     IN BOOLEAN  DEFAULT FALSE,
    p_error_mode  IN VARCHAR2 DEFAULT 'CONTINUE',
    p_db_link     IN VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
    p_sync_mode   IN VARCHAR2 DEFAULT C_SYNC_MODE_KEEP_CURRENT,
    p_run_id      OUT NUMBER);

PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(
    p_table_name           IN VARCHAR2 DEFAULT NULL,
    p_db_link              IN VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
    p_check_id             OUT NUMBER,
    p_has_blocking_issues  OUT BOOLEAN);

-- Surcharge sur liste (v3) : même contrôle sur un sous-ensemble de tables
PKG_SCHEMA_SYNC.CHECK_COMPATIBILITY(
    p_table_list           IN t_tab_name_list,
    p_db_link              IN VARCHAR2 DEFAULT C_DB_LINK_KEEP_CURRENT,
    p_check_id             OUT NUMBER,
    p_has_blocking_issues  OUT BOOLEAN);

PKG_SCHEMA_SYNC.GET_RUN_STATUS(
    p_run_id         IN NUMBER,
    p_header_cursor  OUT SYS_REFCURSOR,
    p_detail_cursor  OUT SYS_REFCURSOR);

PKG_SCHEMA_SYNC.SET_DB_LINK(p_db_link IN VARCHAR2);
PKG_SCHEMA_SYNC.GET_DB_LINK RETURN VARCHAR2;
PKG_SCHEMA_SYNC.PURGE_HISTORY(p_keep_days IN NUMBER);

-- Options globales de run (v5)
PKG_SCHEMA_SYNC.SET_RUN_OPTION(p_option_name IN VARCHAR2, p_option_value IN VARCHAR2);
PKG_SCHEMA_SYNC.GET_RUN_OPTION(p_option_name IN VARCHAR2) RETURN VARCHAR2;
```

Les schémas A et B ne sont pas des paramètres d'appel : ils sont fixés par des constantes de package (`C_SCHEMA_A`, `C_SCHEMA_B`, `C_DB_LINK_B`), pour éviter qu'un appelant ne redirige accidentellement la synchronisation.

La cible distante (`p_db_link`, ajouté en v2) peut être surchargée à l'exécution, sans recompilation : soit ponctuellement via `p_db_link` sur `SYNC_ALL`/`SYNC_TABLE`/`SYNC_TABLES`/`CHECK_COMPATIBILITY`, soit pour toute la session via `SET_DB_LINK` (`GET_DB_LINK` restitue la valeur active ; `NULL` = mode « même instance », sans DB LINK). La sentinelle `C_DB_LINK_KEEP_CURRENT` (valeur par défaut) signifie « ne rien changer à la valeur courante ». Un paramètre invalide (`p_error_mode` hors périmètre, `p_db_link` malformé, `p_sync_mode` inconnu, `p_keep_days <= 0`) est rejeté en entrée (`E_INVALID_PARAMETER`, ou `-20010` pour un identifiant SQL non conforme), **avant** tout effet de bord.

`SYNC_TABLES(p_table_list, ...)` (v3) synchronise une liste de tables en étendant automatiquement le périmètre aux parents FK nécessaires (cf. § 3.9). Le type public `t_tab_name_list` s'utilise par exemple : `PKG_SCHEMA_SYNC.SYNC_TABLES(p_table_list => PKG_SCHEMA_SYNC.t_tab_name_list('COMMANDE_LIGNE'));`

`PURGE_HISTORY(p_keep_days)` (implémenté en v2) purge les tables d'audit à croissance illimitée : `SYNC_CONFLICT` (base `RESOLVED_DATE`), `SYNC_COMPATIBILITY_REPORT` (base `CHECK_DATE`), puis `SYNC_LOG`/`SYNC_RUN_HEADER` (base `START_DATE`, l'en-tête n'étant supprimé que si plus aucun log ne s'y rattache). `p_keep_days <= 0` est refusé : une purge totale doit rester une décision explicite hors du mode de maintenance.

`SET_RUN_OPTION`/`GET_RUN_OPTION` (v5) pilotent les options globales de run stockées dans `SYNC_RUN_OPTION` : `AUTO_BACKFILL_PARENTS` (`Y`/`N`, défaut `Y`), `AUTO_CREATE_MISSING_TABLE` (`Y`/`N`, défaut `N`), `CYCLE_HANDLING` (`DISABLE_FK`/`BLOCK`, défaut `BLOCK`) et `MAX_FK_RETRY` (entier positif, défaut `3`). Le nom **et** la valeur sont validés avant toute persistance (`E_INVALID_PARAMETER`, `-20011`), contrôles doublés en base par `CK_SRO_NAME` (noms) et `CK_SRO_VALUE` (valeurs, « défense en profondeur ») — cf. [§10](#10-changelog-v5).

> **Point d'attention** — `SYNC_TABLE` ne traite que la table demandée, jamais le reste de sa grappe de dépendances FK. Si la table appartient à une grappe de plusieurs tables, cela peut introduire une incohérence référentielle transitoire. À réserver aux rattrapages ciblés ; préférer `SYNC_ALL` (grappe complète) ou `SYNC_TABLES` (périmètre étendu aux parents FK) pour un traitement cohérent.

### 4.4. Découverte des métadonnées

#### 4.4.1. Clé de correspondance

La clé de correspondance d'une table est déterminée dans l'ordre de priorité suivant :

1. Contrainte `PRIMARY KEY` active côté `SCHEMA_A`.
2. À défaut, première contrainte `UNIQUE` active (ordre alphabétique déterministe si plusieurs existent — signalé en WARNING).
3. À défaut, clé explicitement déclarée dans `SYNC_KEY_CONFIG`.

Une clé issue de `SYNC_KEY_CONFIG` fait l'objet d'une vérification d'unicité effective sur les données réelles (`COUNT(*)` vs `COUNT(DISTINCT clé)`), des deux côtés indépendamment. Une clé configurée mais non unique en pratique est systématiquement rejetée.

#### 4.4.2. Colonnes synchronisées

La liste des colonnes réellement synchronisées pour une table résulte d'un `FULL OUTER JOIN` entre les métadonnées de colonnes de `SCHEMA_A` et `SCHEMA_B` (par nom), filtré par : présence des deux côtés, absence d'exclusion dans `SYNC_COLUMN_CONFIG`, type de données supporté. Les colonnes de clé ne sont jamais exclues, même par erreur de configuration.

### 4.5. Ordonnancement des écritures (dépendances FK)

Le graphe des contraintes FK est découvert uniquement côté `SCHEMA_A` (hypothèse assumée : topologie identique côté `SCHEMA_B`) et sert de référence pour les deux sens de propagation.

- Les tables actives sont regroupées en grappes (composantes connexes du graphe FK non orienté).
- À l'intérieur de chaque grappe, un tri topologique (algorithme de Kahn) détermine l'ordre d'insertion (parent avant enfant).
- Un cycle détecté dont toutes les arêtes sont `DEFERRABLE` est accepté : la grappe est traitée sous `SET CONSTRAINTS ALL DEFERRED` (portée locale à `SCHEMA_A` uniquement).
- Un cycle comportant au moins une contrainte non déferrable entraîne l'exclusion automatique de la grappe entière, journalisée en anomalie `BLOCKING`.
- Les grappes sont traitées entre elles par ordre croissant de `PRIORITY` moyenne des tables membres.

### 4.6. Détection des différences (hash de ligne)

Pour éviter une jointure distribuée coûteuse à travers le DB LINK, chaque ligne est réduite à un couple (clé, hash SHA-256) calculé indépendamment de chaque côté et rapatrié dans les tables de travail locales. Seules les clés dont le hash diffère déclenchent un rapatriement des colonnes complètes.

Normalisation des valeurs (indépendante des paramètres NLS de session, pour éviter des faux conflits liés à une divergence de configuration NLS entre les deux instances) :

- `DATE` / `TIMESTAMP [WITH [LOCAL] TIME ZONE]` : `TO_CHAR` avec masque de format explicite et fixe.
- `NUMBER` / `FLOAT` : `TO_CHAR` avec `TM9` et `NLS_NUMERIC_CHARACTERS` forcés.
- `RAW` : `RAWTOHEX` ; `VARCHAR2` / `CHAR` / `INTERVAL` : conversion directe.
- Valeur `NULL` : normalisée en sentinelle déterministe `<NULL>` (`NVL`), pour qu'une concaténation ne devienne jamais globalement `NULL` (ce qui ferait conclure à tort à l'égalité).

**Double voie de hachage (correctif v2).** La fonction de hachage retenue dépend de la nature de la concaténation :

- **Concaténation courte sans LOB** (borne pessimiste `< 4000` octets) : `RAWTOHEX(STANDARD_HASH(...,'SHA256'))`, chemin rapide et ensembliste, exécuté dans une unique instruction SQL.
- **Concaténation longue ou présence de LOB** : `RAWTOHEX(DBMS_CRYPTO.HASH(..., 4))` sur une concaténation `CLOB`. Limite Oracle vérifiée empiriquement : ni `STANDARD_HASH` ni `DBMS_CRYPTO.HASH` ne peuvent consommer le **locator LOB d'une colonne de table** directement en SQL (`ORA-00902` / `ORA-00932`) ; un CLOB *construit en SQL* (concaténation de scalaires) est en revanche hashable. En conséquence :
  - pour une table **sans colonne LOB**, tout est calculé en une passe SQL ensembliste (concaténation CLOB si nécessaire) ;
  - pour une table **avec colonne LOB**, le hash est calculé **ligne par ligne en PL/SQL** (curseur dynamique `DBMS_SQL`), seul contexte où le locator LOB est exploitable ; `CLOB`/`NCLOB` entrent dans la concaténation `CLOB`, `BLOB` sont réduits à `RAWTOHEX(DBMS_CRYPTO.HASH(...))` avant intégration.

> **Prérequis d'installation v2** — Le hachage LOB appelle `DBMS_CRYPTO.HASH` sous le compte `SYNC_ADMIN` : exécuter une fois, avec un compte privilégié, `GRANT EXECUTE ON DBMS_CRYPTO TO SYNC_ADMIN;`. Sans ce grant, toute table contenant un LOB échoue au run (`ORA-00904: "DBMS_CRYPTO"."HASH": invalid identifier`).

> **Coût de performance assumé** — Le hash SHA-256 est recalculé pour l'intégralité des lignes, y compris les colonnes LOB volumineuses, à chaque exécution — et pas seulement pour les lignes suspectes. Sur des tables à fort volume de LOB, ce peut devenir le poste de coût dominant du run ; c'est de surcroît la seule voie où le traitement est ligne par ligne (et non ensembliste), limite intrinsèque à l'usage de `DBMS_CRYPTO` sur un LOB.

### 4.7. Application des écritures

Règle de conception distinctive : **aucune instruction MERGE n'est utilisée lorsque la table cible est distante** (`SCHEMA_B`), le comportement de MERGE avec une cible distante n'étant pas garanti de façon portable selon les versions et configurations Oracle.

| Cible | Mécanisme |
|-------|-----------|
| `SCHEMA_A` (locale) | Un unique MERGE, source = sous-requête distante via `SYNC_LINK_B` (pattern standard et sûr) |
| `SCHEMA_B` (distante) | Deux instructions DML distribuées distinctes : `INSERT` (lignes nouvelles) puis `UPDATE` avec sous-requête corrélée (lignes modifiées) |

> **Point à valider en test de charge** — La clause `UPDATE ... SET (...) = (sous-requête corrélée)` exécutée à travers un DB LINK peut, selon le plan choisi par l'optimiseur distribué, s'exécuter ligne par ligne plutôt qu'en jointure ensembliste. À valider par un test de charge réel sur les volumes de production avant mise en service.

### 4.8. Stratégie transactionnelle

- Commit strictement par grappe FK (décision validée) : une grappe peut engager une transaction distribuée (2PC) si elle couvre des tables des deux schémas.
- SAVEPOINT par table à l'intérieur de la transaction de grappe : en cas d'échec d'une table, seul son travail est annulé (`ROLLBACK TO SAVEPOINT`) ; les autres tables de la même grappe déjà traitées avec succès restent dans la transaction et sont commitées normalement en fin de grappe.
- `STOP_ON_ERROR` interrompt le traitement des grappes suivantes ; les grappes déjà commitées restent acquises.

> **Risque opérationnel accepté** — Le risque de transaction distribuée (2PC) via DB LINK est accepté. Il implique une supervision opérationnelle de `DBA_2PC_PENDING` sur les deux instances et une procédure de résolution manuelle (`COMMIT FORCE` / `ROLLBACK FORCE`) en cas de transaction in-doubt suite à une coupure réseau pendant le commit.

### 4.9. Statuts de run

| Statut | Signification |
|--------|---------------|
| `SUCCESS` | Toutes les tables traitées, aucun conflit, aucun échec |
| `SUCCESS_WITH_CONFLICTS` | Toutes les tables traitées, au moins un conflit réel journalisé (résolu ou en attente). Les écarts forcés des tables en sens unique (`RESOLUTION_STRATEGY = 'DIRECTION_FORCED'`) ne comptent pas comme conflits. |
| `PARTIAL` | Au moins une table en échec (que le run ait été interrompu par `STOP_ON_ERROR` ou qu'il soit allé au bout en `CONTINUE`). Le décompte `TOTAL_TABLES` couvre toutes les tables actives configurées ; `TABLES_EXCLUDED` isole celles écartées (incompatibilité structurelle ou grappe FK en cycle non déferrable). |
| `FAILED` | Toutes les tables traitées ont échoué, ou erreur structurelle avant tout traitement |

### 4.10. Sécurité

- Package en `AUTHID DEFINER`, exécuté par le compte technique `SYNC_ADMIN`.
- Grants directs (SELECT, INSERT, UPDATE) sur les deux schémas — pas de DELETE, aucune suppression n'étant jamais nécessaire en v1.
- Prérequis v2 : `GRANT EXECUTE ON DBMS_CRYPTO TO SYNC_ADMIN;` (hachage des colonnes LOB, cf. [§4.6](#46-détection-des-différences-hash-de-ligne)).
- Tout identifiant (schéma, table, colonne) injecté dans du SQL dynamique passe systématiquement par `DBMS_ASSERT.SIMPLE_SQL_NAME`, y compris ceux lus depuis les tables de configuration.
- Jamais de concaténation directe d'un paramètre non validé dans une instruction SQL dynamique.

---

## 5. Limites connues et risques assumés

Cette section consolide, en un seul endroit, l'ensemble des limites et risques signalés au fil de la conception. Elle doit être relue avant toute mise en production.

| # | Limite / risque | Statut |
|---|-----------------|--------|
| 1 | Le graphe de dépendances FK n'est découvert que côté `SCHEMA_A` ; une topologie FK différente côté `SCHEMA_B` n'est pas détectée ni réconciliée. | Assumé |
| 2 | `SET CONSTRAINTS ALL DEFERRED` (cycles FK déferrables) ne couvre que le schéma local `SCHEMA_A` ; un cycle déferrable côté `SCHEMA_B` distant n'est pas couvert par cette instruction. | Assumé, à valider en environnement réel |
| 3 | Le hash SHA-256 est calculé sur l'intégralité des lignes à chaque run, y compris les LOB volumineux, sans mécanisme d'exclusion configurable par table. De plus, les tables contenant un LOB sont hachées ligne par ligne (limite `DBMS_CRYPTO` sur les locators LOB en SQL). | Assumé |
| 4 | La clause `UPDATE` distribuée avec sous-requête corrélée vers `SCHEMA_B` peut s'exécuter ligne par ligne selon le plan d'exécution retenu par l'optimiseur. | À valider en test de charge |
| 5 | Le risque de transaction distribuée in-doubt (2PC) via DB LINK est accepté sans automatisation de la résolution (nécessite une supervision manuelle `DBA_2PC_PENDING`). | Accepté, supervision manuelle requise |
| 6 | Toute suppression métier d'un côté est annulée (ligne réinsérée) par la synchronisation suivante, indéfiniment. | Assumé, comportement voulu |
| 7 | La granularité SAVEPOINT par table au sein d'une grappe est un choix pris par l'architecte, non explicitement validé par le commanditaire. | À confirmer |
| 8 | Le choix d'éviter tout MERGE vers une cible distante (INSERT+UPDATE à la place) est un choix pris par l'architecte pour des raisons de portabilité, non explicitement validé par le commanditaire. | À confirmer |
| 9 | Le code n'a pas été compilé ni exécuté contre une instance Oracle réelle au moment de sa livraison ; une phase de compilation et de correction des éventuelles erreurs de syntaxe est indispensable avant toute utilisation. | Levée en v2 (cf. note ci-dessous) |

> **Note de mise à jour (v5.2 / v5.3)** — La limite n° 9 a été levée : le code a depuis été intégré dans `03_sync_package_spec.sql`/`04_sync_package_body.sql`, compilé sur une instance Oracle réelle (`SYNC_ADMIN@172.16.5.124:1521/TPWCPROPRY`, Oracle 19.16) et validé fonctionnellement (dry-run et runs réels, dont l'auto-réparation v5). Le package est actuellement `VALID`, 0 objet `INVALID`. La v2 → v5.2 est couverte par le harnais automatisé `07_test_harness.sql` (10 sections, 72 assertions, toutes PASS — dont le Bloc 10 : runs `SYNC_TABLE` RÉELS auto-réparants) et par le jeu de scénarios `06_test_scenarios.sql`. Le correctif v5.2 de traçabilité (`SYNC_CONFLICT`) a en outre été validé sur deux schémas réels (`PCARDIMPBO`→`PCARDIMPFE`) : dry run révélant 84 écarts journalisés (49 colonnes d'insertion ré-estampées par trigger + 35 colonnes d'audit divergentes), puis état convergeant 0/0/0 après opt-out de `DATE_CREATE`/`DATE_MODIF`/`USER_MODIF`. Le correctif v5.3 (graphes FK divergents entre A et B : `disable_cluster_fks` ignore les FK absentes de `SCHEMA_B`, cf. [§10 Changelog](#10-changelog-v5)) a été validé sur le harnais (72/72, comportement inchangé sur schémas à graphe identique) puis sur le même binôme réel : run `SYNC_TABLES` de 20 tables du référentiel `PCARDIMP` (54 tables exécutées, 46 `SUCCESS`, 0 échec, 8 exclues — dont 4 191 `UPDATE_TO_B` sur `POS_ISO_PREFIXES_DT`, 945 sur `HSM_KEY_MEMBER`), volumes BO/FE alignés à l'issue du run.

---

## 6. Annexes

### 6.1. Glossaire

| Terme | Définition |
|-------|------------|
| **Grappe (cluster)** | Ensemble de tables reliées entre elles par des contraintes FK, traité comme une seule unité transactionnelle (un commit par grappe) |
| **Clé de correspondance** | Colonne(s) identifiant de façon unique une ligne pour la faire correspondre entre `SCHEMA_A` et `SCHEMA_B` |
| **Conflit réel** | Ligne dont la valeur a divergé des deux côtés depuis le dernier état identique connu, nécessitant une stratégie de résolution |
| **Écart forcé** | Différence entre A et B sur une table en sens unique (`A_TO_B` ou `B_TO_A`) : toujours résolue en faveur de la source, sans notion de conflit |
| **Idempotence** | Propriété garantissant qu'une exécution sans changement intermédiaire ne produit aucune écriture |
| **Tombstone** | Mécanisme de marquage logique d'une suppression (hors périmètre v1), envisageable pour une v2 |

### 6.2. Livrables associés

Ce document de spécifications accompagne les livrables techniques suivants, produits séparément :

- **Script 1** — Tables de configuration (`SYNC_TABLE_CONFIG`, `SYNC_COLUMN_CONFIG`, `SYNC_KEY_CONFIG`)
- **Script 2** — Tables de journalisation, conflits, compatibilité et tables de travail
- **Script 3** — Spécification du package (`CREATE PACKAGE`)
- **Script 4** — Corps du package (`CREATE PACKAGE BODY`)
- **Script 5** — Tables métier d'exemple, données et configuration (+ prérequis `GRANT EXECUTE ON DBMS_CRYPTO`)
- **Script 6** — Jeu de tests fonctionnels guidés (18 scénarios)
- **Script 7** — Harnais de validation automatisée (assertions PASS/FAIL ; Blocs 1→10 : découverte, paramètres, modes, migration, et — à partir du Bloc 9 (v4) — mutations **réelles auto-nettoyées** : enrôlement de lignée FK persisté puis restauré, runs `SYNC_TABLE` réels avec backfill)
- **Script 8** — Migration v1 → v2/v3 (idempotente : contraintes, colonne `PK_HASH_KEY` élargie, GTT, `SYNC_MODE` / `RUN_TYPE`)
- **Script 9 (démo)** — `09_test_sync_mode.sql` : démonstration manuelle des modes de synchronisation (`INSERT`, `UPDATE`, `INSERT_UPDATE` et mode par table), avec remise à l'état initial (optionnel)
- **Script 10** — Migration v4 → v5 (idempotente : auto-réparation des FK parents absents / cycles / auto-création de tables manquantes, table `SYNC_RUN_OPTION`, `CHECK` de `SYNC_COMPATIBILITY_REPORT` élargi)
- **Script 9 (grants SYS)** — `09_sys_auto_repair_grants.sql` : octroi idempotent, avec le profil `sys` (SYSDBA), des privilèges système nécessaires à l'auto-réparation v5 (ALTER / CREATE ANY TABLE / INDEX, CREATE ANY TRIGGER) — à exécuter **avant** le Script 8/10 côté `admin` (cf. [§11.3](#113-commandes))
- **Outillage** — `setup_project.py` + package `tools/orasync` (déploiement, tests et diagnostic en ligne de commande, cf. [§11](#11-outillage-de-déploiement-et-industrialisation))

---

## 7. Changelog v2

Récapitulatif des correctifs et durcissements apportés en v2 par rapport au document/à la livraison v1 :

- **Hachage** : décision explicite `STANDARD_HASH` (chemin rapide, sans LOB et concaténation `< 4000`) vs `DBMS_CRYPTO.HASH` sur CLOB construit ; normalisation `NULL` par sentinelle ; les colonnes LOB participent désormais réellement au hash de ligne (en v1 elles étaient exclues, ce qui masquait les changements portant uniquement sur un LOB) ; tables avec LOB traitées ligne par ligne en PL/SQL (`DBMS_SQL`) faute de pouvoir hasher un locator LOB en SQL.
- **Compatibilité** : réécriture de `CHECK_COMPATIBILITY` avec résolution explicite de la clé de chaque côté, nouveau contrôle `PK_MISMATCH` (`WARNING` si B sans clé, `BLOCKING` si clés divergentes) et contrôle `KEY_NOT_UNIQUE` `BLOCKING` sur les clés configurées, des deux côtés.
- **Clé de correspondance** : résolution `PRIMARY KEY` puis `UNIQUE` puis `SYNC_KEY_CONFIG`, factorisée pour un accès local ou distant (DB LINK).
- **Performance** : suppression du N+1 dans la journalisation des conflits (une requête ensembliste par table), décision de résolution calculée une fois par table (UPDATE ensembliste de `SYNC_WORK_DIFF`), `get_column_comparison` en colonnes explicites.
- **Cycle de vie / robustesse** : `PURGE_HISTORY` implémenté (rétention configurable) ; `compute_run_clusters` aligné sur les constantes d'`ISSUE_TYPE` ; compteurs de `SYNC_ALL` corrigés (tables actives vs exclues) ; `ROLLBACK` de l'en-tête en cas d'échec global ; validation des paramètres d'entrée (`p_error_mode`, `p_db_link`, `p_keep_days`) **avant** tout effet de bord (corrige la corruption de `g_db_link_b` de session par un `p_db_link` invalide).
- **Surcharge du DB LINK sans recompilation** : `SET_DB_LINK` / `GET_DB_LINK` et paramètre `p_db_link` sur l'API.
- **Tests / documentation** : Script 6 enrichi et scindé pour les étapes DDL manuelles, test de découverte non destructif (snapshot/restauration), nouveau harnais Script 7, README resynchronisé.

---

## 8. Changelog v3

Évolutions fonctionnelles apportées en v3 :

- **Mode de synchronisation** : colonne `SYNC_MODE` sur `SYNC_TABLE_CONFIG` (`INSERT` / `UPDATE` / `INSERT_UPDATE`, défaut `INSERT_UPDATE`, contrainte `CK_STC_SYNC_MODE`) et override ponctuel `p_sync_mode` sur `SYNC_ALL`/`SYNC_TABLE`/`SYNC_TABLES` (sentinelle `C_SYNC_MODE_KEEP_CURRENT`). Le mode effectif est journalisé dans `SYNC_LOG.SYNC_MODE` ; un mode inconnu est rejeté (`E_INVALID_PARAMETER`, `-20011`).
- **Périmètre par liste + expansion FK** : nouvelle procédure `SYNC_TABLES(p_table_list …)` s'appuyant sur le type public `t_tab_name_list` ; fermeture transitive des **parents** FK configurés et actifs, exécution par grappes dans l'ordre topologique (parents avant enfants). `RUN_TYPE` élargi à `SYNC_TABLES`.
- **CHECK_COMPATIBILITY sur liste** : surcharge acceptant `t_tab_name_list`, contrôle d'un sous-ensemble de tables en un seul `CHECK_ID` (cœur factorisé `compat_check_core`).
- **Refactoring interne** : phase d'exécution des grappes factorisée (`execute_clusters`) entre `SYNC_ALL` et `SYNC_TABLES` ; résolution du mode effectif (`resolve_effective_mode`) et expansion des ancêtres FK (`expand_fk_ancestors`).
- **Migration** : Script 8 étendu (idempotent) — ajout de `SYNC_TABLE_CONFIG.SYNC_MODE`, `SYNC_LOG.SYNC_MODE` et élargissement de `CK_SRH_RUN_TYPE`.
- **Tests** : harnais Script 7 porté à 8 sections et 36 assertions (dont mode + expansion FK) ; Script 6 enrichi des scénarios `SYNC_TABLES` et `SYNC_MODE`. Validation : run réel `SYNC_TABLES(['COMMANDE_LIGNE'])` → 4 tables synchronisées `SUCCESS`.

---

## 9. Changelog v4

Évolutions fonctionnelles apportées en v4 :

- **Enrôlement automatique de la lignée FK** : nouvelle procédure privée `enroll_fk_lineage` + fermeture basse du dictionnaire `build_fk_ancestors_raw`. Tout parent FK (fermeture transitive côté `SCHEMA_A`) absent de `SYNC_TABLE_CONFIG` est **enrôlé automatiquement** (profil `AUTO_FK_LINEAGE`, direction **héritée de l'enfant**, WARNING `FK_PARENT_ENROLLED`) lors de `CHECK_COMPATIBILITY(NULL)` (contrôle autonome), `SYNC_ALL` et `SYNC_TABLES`. L'enrôlement est persisté (`COMMIT`) et idempotent.
- **Parents désactivés jamais forcés** : un parent présent mais `ENABLED='N'` / `SYNC_DIRECTION='DISABLED'` est signalé en WARNING (`FK_PARENT_DISABLED`) sans être activé, et **exclu du périmètre exécuté** (il n'est plus injecté dans le run, contrairement aux ancêtres actifs).
- **Périmètre de validation élargi** : le contrôle de compatibilité porte désormais sur la **fermeture complète** (seeds ∪ ancêtres) au sein d'un unique `CHECK_ID` ; chaque parent nouvellement enrôlé est structurellement validé dans le même contrôle.
- **`SYNC_TABLE` inchangé** : le rattrapage mono-table ne mute pas `SYNC_TABLE_CONFIG` (ni la surcharge `CHECK_COMPATIBILITY` mono-table / liste).
- **Migration** : Script 8 étendu (toujours idempotent) — `CK_SCR_ISSUE_TYPE` accepte `FK_PARENT_ENROLLED` et `FK_PARENT_DISABLED` ; le Script 2 (installation neuve) est aligné sur le même périmètre.
- **Tests** : harnais Script 7 enrichi d'un Bloc 9 (9 sections) — scénario auto-réparant : `SYNC_TABLE` non mutant, enrôlement + direction héritée, profil `AUTO_FK_LINEAGE`, `FK_PARENT_DISABLED` sans forçage, idempotence d'un second contrôle, run `SYNC_TABLES` post-enrôlement sans `FAILED`. Validation attendue : run réel `SYNC_TABLES` post-enrôlement en ordre topologique garantissant l'absence d'`ORA-02291`.

---

## 10. Changelog v5

Enrichissements fonctionnels apportés en v5 (auto-réparation ascendante), et correctifs v5.1 / v5.2 / v5.3 :

- **Backfill des parents FK absents** — si l'insertion A→B d'un enfant échoue sur `ORA-02291` (parent absent de `SCHEMA_B`), le run ré-insère automatiquement le parent depuis `SCHEMA_A` (copie des colonnes synchronisées, issue `PARENT_BACKFILLED`, `WARNING`), puis retente l'enfant — jusqu'à `MAX_FK_RETRY` tentatives (issue `FK_CHILD_RETRIED`, `WARNING`). Piloté par l'option `AUTO_BACKFILL_PARENTS` (`Y`/`N`, défaut `Y`). Un échec du backfill (`PARENT_BACKFILL_FAILED`, `BLOCKING`) ou la saturation des tentatives laisse la table en `FAILED` (comportement historique préservé avec `AUTO_BACKFILL_PARENTS='N'`).
- **Cycles FK** — option `CYCLE_HANDLING` : `BLOCK` (défaut : exclusion de la grappe en cycle non déferrable, comportement historique) ou `DISABLE_FK` : désactivation temporaire idempotente du FK de cycle côté `SCHEMA_B` pour permettre le traitement (issue `FK_CYCLE_HANDLED_BY_DISABLE`, `WARNING`) ; un échec est tracé en `FK_REPAIR_FAILED` (`BLOCKING`).
- **Auto-création des tables manquantes** — option `AUTO_CREATE_MISSING_TABLE` (`Y`/`N`, défaut `N`) : une table active absente de `SCHEMA_B` est créée automatiquement lors d'un run RÉEL (`p_dry_run=FALSE` ; neutralisée en dry run), issue `TABLE_CREATED_IN_B` (`WARNING`).
- **`SYNC_RUN_OPTION`** — table des options globales de run (`AUTO_BACKFILL_PARENTS`, `MAX_FK_RETRY`, `CYCLE_HANDLING`, `AUTO_CREATE_MISSING_TABLE`), créée par le Script 10 (idempotent), lue via `GET_RUN_OPTION` et modifiée via `SET_RUN_OPTION` (API publique, cf. [§4.3](#43-api-publique)).
- **Validation des options (correctif v5.1)** — `SET_RUN_OPTION` valide désormais le nom **et** la valeur (`E_INVALID_PARAMETER`, `-20011`) ; la contrainte `CK_SRO_VALUE` applique la même règle en base (« défense en profondeur ») ; la migration 10 répare idempotemment toute valeur hors périmètre persistée par une version antérieure (ex. `CYCLE_HANDLING='BIDON'`).
- **Correctif backfill (v5.1)** — le SQL de backfill passait le préfixe d'alias de la clé enfante avec son point final (`'ch.'`), produisant `ch..<colonne>` (`ORA-01747`) avalé silencieusement : le backfill rendait 0 ligne et le run échouait en `ORA-02291` sans trace exploitable. Corrigé (préfixe sans point) et validé par le Bloc 10 du harnais (run réel auto-réparant).
- **`CHECK` de `SYNC_COMPATIBILITY_REPORT` élargi** — les issue types v5 (`PARENT_BACKFILLED`, `FK_CHILD_RETRIED`, `FK_CYCLE_HANDLED_BY_DISABLE`, `TABLE_CREATED_IN_B`, `PARENT_BACKFILL_FAILED`, `FK_REPAIR_FAILED`) sont acceptés — Script 10 idempotent, aligné sur le Script 2 (installation neuve).
- **Prérequis SYS (une fois)** — `09_sys_auto_repair_grants.sql` octroie, avec le profil `sys` (SYSDBA), les privilèges nécessaires à l'auto-réparation v5 (`ALTER ANY TABLE`, `CREATE ANY TABLE`, `CREATE ANY INDEX`, `CREATE ANY TRIGGER`) — à exécuter avant le Script 10 côté `admin` (cf. [§11.3](#113-commandes)).
- **Tests** — harnais Script 7 étendu d'un Bloc 10 (10 sections, 72 assertions au total) : round-trip `SET_RUN_OPTION`/`GET_RUN_OPTION`, rejet d'une option inconnue et d'une valeur interdite (`-20011` explicite) sans altérer la valeur en place, run `SYNC_TABLE` RÉEL (dry=`FALSE`) avec backfill du parent (`PARENT_BACKFILLED` + `FK_CHILD_RETRIED`) puis insertion enfant réussie, second run réel idempotent (0 écriture, 0 réparation), restauration complète (options + lignes de scénario).
- **Traçabilité `SYNC_CONFLICT` (correctif v5.2)** — `log_conflicts_for_table` était appelé *après* la conversion ensembliste des `CONFLICT_CANDIDATE` (vers `UPDATE_TO_B`/`UPDATE_TO_A`/`CONFLICT`) : son `INSERT…SELECT` filtrant sur `'CONFLICT_CANDIDATE'` ne matchait plus aucune ligne, `SYNC_CONFLICT` restait vide et `conflict_count` était systématiquement nul — les dry runs masquaient les vrais conflits (cas réel : 35 écarts invisibles en dry run, révélés seulement à l'application en direction forcée). Corrigé en déplaçant la journalisation **avant** la résolution (snapshot des deux côtés au diagnostic) : `SYNC_CONFLICT` est alimenté — y compris pour les écarts forcés `DIRECTION_FORCED`, qui restent exclus de `conflict_count` (cf. [§4.9](#49-statuts-de-run)) — et les dry runs reflètent enfin la réalité.
- **Graphe FK divergent entre A et B (correctif v5.3)** — le traitement des cycles FK (`CYCLE_HANDLING='DISABLE_FK'`) rejouait par NOM, côté `SCHEMA_B`, les contraintes FK de `SCHEMA_A` dans `disable_cluster_fks` : une FK présente côté A mais absente côté B (deux bases jumelles dont les structures de contraintes ont divergé) levait `ORA-02431` (« no such constraint ») et, par le repli all-or-nothing des grappes cycliques, faisait exclure **toute** la grappe en `BLOCKING` — cas réel observé : 36 tables de grappe bloquées pour 2 FK de `CORPORATE` absentes de `PCARDIMPFE`. Corrigé en vérifiant l'existence de la FK côté B (`ALL_CONSTRAINTS`, nouvelle fonction privée `fk_exists_at_b`) avant toute désactivation : la FK absente est ignorée avec une trace `DBMS_OUTPUT`, et cela sans risque pour l'intégrité (une FK inexistante ne peut violer aucun `INSERT`). Comme pour `exec_ddl_at_b`, la vérification n'est active qu'en mode « même instance » (`g_db_link_b IS NULL`) ; en mode DB LINK le comportement historique est préservé. Validé par le harnais (`72/72` — schémas de test au graphe identique : aucun skip, comportement inchangé) et sur deux schémas réels (`PCARDIMPBO`→`PCARDIMPFE`) : run réel `SYNC_TABLES` de 20 tables du référentiel — 54 tables exécutées (20 demandées + parents enrôlés), 46 `SUCCESS`, 0 échec, 8 exclues (parents `MISSING_IN_B`), grappe cyclique traitée intégralement.

---

## 11. Outillage de déploiement et industrialisation

Le projet fournit un outillage Python autonome qui remplace le client `sqlplus` pour le déploiement et les tests : création de l'environnement virtuel, installation des dépendances, exécution des scripts SQL\*Plus, contrôle des connexions et diagnostic.

### 11.1. Fichiers

| Chemin | Rôle |
|--------|------|
| `setup_project.py` | Lanceur *bootstrap* (bibliothèque standard uniquement) : crée `.venv`, installe `requirements.txt`, puis délègue à la CLI |
| `tools/orasync/` | Package applicatif : `config`, `db`, `sqlplus` (mini-interpréteur SQL\*Plus), `project`, `cli` |
| `requirements.txt` | Dépendances Python (`oracledb`) |
| `.env.example` | Modèle de configuration des connexions (à copier en `.env`) |

### 11.2. Démarrage rapide

```bash
cp .env.example .env          # renseigner les mots de passe
python3 setup_project.py check
python3 setup_project.py setup --with-sample --run-tests
```

Le premier appel crée `.venv/`, installe `oracledb` et se ré-exécute automatiquement dans l'environnement virtuel. Aucune installation manuelle n'est requise.

### 11.3. Commandes

| Commande | Rôle | Profil(s) utilisé(s) |
|----------|------|----------------------|
| `check` | Teste chaque connexion et affiche version/utilisateur | tous |
| `install [--no-migrate]` | Crée les tables (Scripts 1→2), applique les migrations idempotentes (8 et 10), puis compile le package (Scripts 3→4) — le package est compilé **en dernier**, les migrations (DDL) l'invalidant sinon | `admin` |
| `migrate` | Applique les migrations idempotentes (Scripts 8 et 10) puis recompile la spécification et le corps (3→4) | `admin` |
| `sample [--link-user X]` | Charge données et configuration d'exemple (Script 5, sections A/B/CONFIG) | `schema_a`, `schema_b`, `admin` |
| `test` | Exécute le harnais de validation (Script 7) | `admin` |
| `setup [--with-sample] [--run-tests]` | Enchaîne `install` [+ `sample`] [+ `test`] | selon étape |
| `sql <fichier> [--profile P] [--continue-on-error]` | Exécute un script SQL\*Plus arbitraire | `admin` par défaut |
| `sql 09_sys_auto_repair_grants.sql --profile sys` | Octroi idempotent des privilèges SYS d'auto-réparation v5 (une fois, **avant** `install`/`migrate`) | `sys` |
| `sql 15_sys_stats_gap_grants.sql --profile sys` | Octroi idempotent des privilèges SYS de l'état d'écart v6 (une fois, avant le premier `gap`) | `sys` |
| `status [--limit N]` | Affiche les dernières exécutions (`SYNC_RUN_HEADER`) | `admin` |
| `gap [--schema-a A] [--schema-b B] [--max-age-hours N] [--no-collect] [--wait-timeout S] [--limit N]` | État d'écart des comptes de lignes A/B (stats Oracle) : collecte asynchrone des stats (sauf `--no-collect`), attente de fin, génération du rapport persistant puis affichage trié par écart décroissant | `admin` |
| `schema-sync [--schema-a A] [--schema-b B] [--direction D] [--sync-mode M] [--conflicts C] [--priority N] [--exclusions "c1,c2"] [--collect] [--max-age-hours N] [--wait-timeout S] [--max-tables N] [--min-diff-pct P] [--exclude-tables "masques"] [--max-table-rows N] [--real]` | **Synchro niveau schéma** : tables en écart détectées par stats (v6), config idempotente des tables en écart puis `SYNC_TABLES` — dry run systématique, run réel uniquement avec `--real` ; patch temporaire des constantes `C_SCHEMA_A/B` avec restauration garantie | `admin` |

Options globales : `--env-file`, `-v`/`-vv` (verbosité), `--dry-run` (affiche les actions sans exécuter les scripts).

### 11.4. Configuration par variables d'environnement

Les connexions sont décrites par des variables préfixées `ORASYNC_`, chargées depuis `.env` (sans écraser l'environnement du shell) :

| Variable | Rôle |
|----------|------|
| `ORASYNC_DSN` | DSN commun (Easy Connect `hote:port/service`) |
| `ORASYNC_<PROFIL>_USER` / `_PASSWORD` / `_DSN` / `_ROLE` | Paramètres par profil (`admin`, `schema_a`, `schema_b`, `sys`) |
| `ORASYNC_PROFILES` | Liste des profils (défaut `admin,schema_a,schema_b,sys`) |
| `ORASYNC_LINK_NAME` / `ORASYNC_LINK_USER` | Lien de base de données et utilisateur pour la section B du Script 5 |
| `ORASYNC_VENV`, `ORASYNC_ENV_FILE`, `ORASYNC_SCRIPTS_DIR`, `ORASYNC_LOG_FILE` | Options de l'outillage |

### 11.5. Comportement et garanties

- **Sémantique SQL\*Plus fidèle** : les commandes (`SET`, `PROMPT`, `COLUMN`, `SHOW`, `@`, `EXEC`…) ne sont reconnues que hors tampon de requête ; les blocs PL/SQL sont terminés par `/`, les instructions SQL par `;` ; `DBMS_OUTPUT` est restitué et les erreurs de compilation sont lues dans `USER_ERRORS`.
- **Installation tolérante** : `install`, `migrate` et `sample` ignorent les erreurs DDL d'idempotence (`ORA-00955`, `ORA-00942`, `ORA-14452`, …) et n'échouent que sur une erreur inattendue. En particulier, la recréation des GTT peut être ignorée si une session tierce (ex. SQL Developer) les utilise — `ORA-14452`.
- **Tests stricts** : `test` ne tolère aucune erreur ; toute assertion en échec est remontée par le harnais (`RAISE_APPLICATION_ERROR -20999`) et le code de retour du processus est non nul.
- **Codes de retour** : `0` succès, `1` échec fonctionnel, `2` erreur de configuration/usage.
- **Sans `ensurepip`** (certaines distributions) : l'environnement est créé sans `pip` puis amorcé via le `pip` de l'hôte (`pip --python`), qui doit être ≥ 22.3. `ORASYNC_NO_VENV=1` force l'utilisation de l'interpréteur courant.

---

## 12. Changelog v6

Enrichissement fonctionnel apporté en v6 : **état d'écart schéma A/B basé sur les statistiques Oracle** (rapport des écarts de comptes de lignes entre les deux schémas, collecte explicite en amont).

### 12.1. Principe et périmètre

- **Critère v1** : différence de **nombre de records par table**, mesurée sur les statistiques Oracle (`NUM_ROWS` de l'optimiseur, niveau table via `ALL_TAB_STATISTICS` : `object_type='TABLE'` et `partition_name IS NULL`, soit les stats globales — table partitionnée comprise).
- **Périmètre** : tables de base (`TEMP='N'`) **présentes à la fois dans A et B**. Les tables absentes d'un côté sont hors rapport (comme les tables configurées `MISSING_IN_B` de la synchro) — elles font l'objet de la synchro classique, pas du diagnostic de volumétrie.
- **Collecte explicite en amont** : les stats sont fraîches par construction — deux jobs `DBMS_SCHEDULER` asynchrones (`GATHER_SCHEMA_STATS`) lancés par `SUBMIT_STATS_JOBS`, surveillés par `ARE_STATS_JOBS_DONE` / `WAIT_FOR_STATS_JOBS`. À lancer **hors pic d'activité**.
- **Limite assumée (documentée)** : `NUM_ROWS` est une **estimation** de l'optimiseur, pas un `COUNT(*)` exact — l'écart rapporté est « statistique », indicatif de dérive, pas une photographie exacte.

### 12.2. Décisions utilisateur appliquées

- Jobs `DBMS_SCHEDULER` **asynchrones** (pilotage : `SUBMIT_STATS_JOBS` → `WAIT_FOR_STATS_JOBS`).
- Livraison : **package + tables + CLI** (commande `gap`).
- **Tout écart > 0** est rapporté avec `DIFF` **signé** (`DIFF = NUM_ROWS_B - NUM_ROWS_A` : positif si B a plus de lignes que A, négatif sinon) et `DIFF_PCT` (base `GREATEST(A,B)`, arrondi 2 décimales).
- Tables à `NUM_ROWS` **NULL** d'un côté : flag `NO_STATS_A` / `NO_STATS_B` / `NO_STATS_BOTH`, **exclues du calcul** des écarts et **comptées dans l'en-tête** du rapport.

### 12.3. Modèle de données

- `SYNC_STATS_GAP` (en-tête, Script 14) : `GAP_ID` (séquence), `COLLECT_DATE`, `JOB_NAME_A/B`, `STATS_DATE_A/B` (MAX `LAST_ANALYZED` constaté), `TOTAL_TABLES`, `TABLES_OK`, `TABLES_GAP`, `TABLES_NO_STATS_A/B`, `EXECUTED_BY` — une ligne = un rapport.
- `SYNC_STATS_GAP_DETAIL` (détail) : **uniquement les anomalies** (`DIFF`, `NO_STATS_*`) — aucune ligne pour une table en écart nul ; `TABLE_NAME`, `NUM_ROWS_A/B`, `DIFF` (signé, `B - A`), `DIFF_PCT`, `LAST_ANALYZED_A/B`, `GAP_FLAG` (contrainte `CK_SSGD_FLAG`).
- Séquences dédiées : `SYNC_STATS_GAP_ID_SEQ`, `SYNC_STATS_GAP_DETAIL_ID_SEQ`.
- Purge intégrée à `PURGE_HISTORY` (détail d'abord — FK — puis en-têtes, sur `COLLECT_DATE`).

### 12.4. API publique ajoutée (Scripts 3/4)

```sql
PKG_SCHEMA_SYNC.SUBMIT_STATS_JOBS(p_schema_a, p_schema_b, p_job_name_a, p_job_name_b);
PKG_SCHEMA_SYNC.GET_STATS_JOB_STATUS(p_job_name)          RETURN VARCHAR2;  -- SUCCEEDED/RUNNING/...
PKG_SCHEMA_SYNC.ARE_STATS_JOBS_DONE(p_job_name_a, p_job_name_b) RETURN BOOLEAN;
PKG_SCHEMA_SYNC.WAIT_FOR_STATS_JOBS(p_job_name_a, p_job_name_b, p_timeout_sec, p_all_succeeded);
PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP(p_schema_a, p_schema_b, p_job_name_a, p_job_name_b,
                                  p_max_age_hours, p_gap_id, p_header_cursor, p_detail_cursor);
PKG_SCHEMA_SYNC.GET_LAST_GAP_ID()                         RETURN NUMBER;
```

- `REPORT_COUNTS_GAP` **persiste** (COMMIT) puis rend deux REF CURSOR (en-tête, détail trié `|DIFF| DESC NULLS LAST`) ; `p_max_age_hours` renseigné et stats absentes/trop anciennes d'un côté → `E_STATS_NOT_FRESH` (`-20013`).
- Constantes : `C_GAP_FLAG_*`, `C_JOB_STATUS_*` ; exception `E_STATS_NOT_FRESH`.
- **Mode DB LINK (v1)** : la *lecture* du rapport sait lire les stats distantes via le DB LINK (`ALL_TAB_STATISTICS@…`) ; la *collecte* distante n'est pas supportée (`SUBMIT_STATS_JOBS` lève `-20014`) — en multi-instances, collecter les stats de B dans la session de suivi de B.

### 12.5. Scripts et validation

- **Scripts 14/15** : tables+séquences (14), grants SYS idempotents (15 : `ANALYZE ANY`, `CREATE JOB`, `EXECUTE DBMS_STATS/SCHEDULER`, `SELECT ANY TABLE` — lecture du dictionnaire des stats).
- **Script 13 étendu** : purge complète des rapports d'écart + remise à 1 des 2 séquences (options `SYNC_RUN_OPTION` toujours conservées).
- **Harnais 07 étendu** : Bloc 11 (v6) — collecte réelle par jobs sur les schémas de test, attente asynchrone, génération et re-consultation du rapport (`GET_LAST_GAP_ID`), garde de fraîcheur (`-20013`), détection `NO_STATS_A` après purge ciblée des stats, restauration des stats — **86 assertions** au total (72 + 14).
- **CLI** : commande `gap` — `python setup_project.py gap --schema-a A --schema-b B [--max-age-hours N] [--no-collect] [--wait-timeout S] [--limit N]`.
- **Limites v1 assumées** : `NUM_ROWS` estimé (pas `COUNT(*)`) ; collecte distante non supportée ; la fraîcheur n'est contrôlée que si `p_max_age_hours` est fourni (sinon l'opérateur s'appuie sur `STATS_DATE_A/B` de l'en-tête).

### 12.6. Synchro niveau schéma — `schema-sync`

Chaîne la v6 (écarts par stats) avec le run de synchro pour **réaligner la
volumétrie à l'échelle du schéma** :

- **Périmètre** : tables communes aux deux schémas ; tables en écart = `DIFF`
  signé (`NUM_ROWS_B - NUM_ROWS_A ≠ 0`) ; `NO_STATS_*` exclus de la synchro
  mais comptés/signalés.
- **Profil des tables en écart** (défauts) : `BIDIRECTIONAL` / `INSERT` seul /
  `ERROR_ON_CONFLICT` / priorité 10 / exclusions d'audit standard.
- **Déroulé** : patch temporaire des constantes `C_SCHEMA_A/B` (Annexe C) →
  stats courantes (ou `--collect` par jobs) → `REPORT_COUNTS_GAP` → filtres
  optionnels (`--max-tables`, `--min-diff-pct`) → config idempotente
  (`NOT EXISTS`, l'existant n'est jamais écrasé) → `SYNC_TABLES` **dry run
  systématique** → run réel **uniquement** avec `--real` → restauration
  garantie du package (mode test) en `finally`.
- **CLI** : `python setup_project.py schema-sync --schema-a A --schema-b B [--direction BIDIRECTIONAL] [--sync-mode INSERT] [--conflicts ERROR_ON_CONFLICT] [--priority 10] [--exclusions "..."] [--collect] [--max-age-hours N] [--wait-timeout S] [--max-tables N] [--min-diff-pct P] [--real]`.
- **Lecture** : bilan par run (`status`, `total`, `succ`, `conf`, `fail`,
  `excl` dans `SYNC_RUN_HEADER`) et détail par table (`INS->B`, `INS->A`,
  `UPD->B`, `UPD->A`, `conf`, `err`, `statut` dans `SYNC_LOG`) ; procédure
  complète au §11 de `11_PROCEDURE_SYNCHRONISATION.md`.