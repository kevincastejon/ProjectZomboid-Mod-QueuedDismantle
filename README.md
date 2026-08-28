# Queue Dismantle — Project Zomboid Build 42

Version **1.0.0** — ciblée pour **Build 42.20+**.

## Installation

1. Ferme Project Zomboid.
2. Décompresse le dossier `QueueDismantle` dans :
   `C:\Users\<ton_nom>\Zomboid\mods\`
3. Vérifie que ce fichier existe :
   `C:\Users\<ton_nom>\Zomboid\mods\QueueDismantle\42\mod.info`
4. Active **Queue Dismantle** dans le menu **Mods** du jeu.

## Utilisation

Fais un clic droit sur un meuble ou un objet démontable, puis utilise le sous-menu séparé :

**Queue dismantle → nom de l’objet**

Répète l’opération sur autant de cibles que nécessaire. Chaque cible est ajoutée à la fin de la file d’actions existante.

Le menu vanilla **Démonter / Disassemble** reste inchangé. Le mod ne détourne pas **Shift** et n’altère pas son comportement vanilla.

## Comportement

- Le mod reprend les mêmes cibles, noms, prérequis, infobulles et surbrillances que le menu de démontage vanilla.
- Quand une cible arrive en tête de file, le mod la revalide puis lance les actions vanilla de déplacement, d’équipement des outils et de démontage.
- Une cible supprimée, devenue invalide, inaccessible ou impossible à démonter est ignorée sans effacer les cibles suivantes.
- Les effets du démontage lui-même restent ceux du jeu : durée, outils, XP, chances de récupération, sons et logique multijoueur.

## Diagnostic

En cas d’erreur Lua, consulte :

`C:\Users\<ton_nom>\Zomboid\console.txt`

et cherche le préfixe :

`[QueueDismantle]`

## Validation

La structure du paquet, la compilation Lua et une simulation du menu et de la file d’actions ont été contrôlées. Le jeu Project Zomboid n’est pas disponible dans l’environnement de génération, donc un essai en partie reste nécessaire.
