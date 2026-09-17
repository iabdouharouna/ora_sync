"""Outillage Python industrialise du projet ora_sync.

Le package expose une CLI permettant de :

* verifier les connexions Oracle (``check``) ;
* installer / migrer les composants PL/SQL (``install``, ``migrate``) ;
* charger les donnees et la configuration d'exemple (``sample``) ;
* executer le harnais de tests (``test``) ;
* executer un script SQL*Plus arbitraire (``sql``) ;
* afficher l'etat des synchronisations (``status``).
"""

__all__ = ["__version__"]
__version__ = "1.0.0"
