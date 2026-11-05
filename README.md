# Lacruche.cd — site web et API

Première conception du portail d’actualité Lacruche.cd : interface web pour ordinateur et mobile, avec une API de lecture versionnée que la future application React Native pourra réutiliser.

## Démarrer

Node.js 22 ou plus récent suffit. Aucune dépendance npm n’est nécessaire.

```bash
npm start
```

Ouvrir `http://localhost:3000`. `PORT` et `HOST` peuvent personnaliser l’écoute du serveur. Le navigateur doit utiliser cette adresse HTTP : ouvrir directement `index.html` ne permet pas de charger l’API.

```bash
npm test
```

Les tests vérifient les filtres et la pagination, les règles de publication, les réponses premium, les routes et l’accès aux fichiers publics. Ils appellent le véritable gestionnaire HTTP en mémoire, sans ouvrir de socket. L’écoute TCP étant interdite dans l’environnement d’exécution utilisé, le transport HTTP et le rendu dans un navigateur restent à vérifier sur l’environnement de déploiement.

## État de cette version

- Articles et médias issus de `data/content.json`, explicitement marqués comme démonstration. Les dates des exemples sont absolues ; ils ne constituent pas des informations récentes vérifiées.
- Recherche et rubriques via `/api/v1/articles`, accueil via `/api/v1/home` et lecture via `/api/v1/articles/:slug`.
- Emplacements préparés pour la vidéo, l’audio et les directs TV, TNT et radio. Aucun flux n’est configuré et aucune diffusion n’est annoncée comme active.
- Photographies chargées depuis Wikimedia Commons. Leurs crédits figurent dans les données des articles ; les références complètes sont dans `assets/lacruche/photo-sources.json`. L’affichage de ces images nécessite un accès réseau du navigateur.
- Le serveur expose uniquement la page d’accueil, les ressources de `assets/lacruche/` aux formats autorisés et l’API publique. Les fichiers de données, les sources serveur et le dossier `db/` ne sont pas servis.

## Structure

```text
index.html                  Interface web
assets/lacruche/             Identité visuelle, styles, scripts et crédits
server/app.js                Routes HTTP et projections publiques
server/index.js              Démarrage du serveur
data/content.json            Contenus de démonstration
test/api.test.js             Tests de l’API et des fichiers publics
docs/api.md                  Contrat API et raccordement futur
db/                         Schéma PostgreSQL existant du dépôt
```

Le serveur actuel ne se connecte pas à PostgreSQL et n’écrit pas de contenu. Le schéma existant du dossier `db/` est conservé pour la prochaine étape. Les formulaires de rédaction, l’authentification, les paiements, les importateurs et les tâches planifiées restent à développer.

## Suite du développement

1. Terminer et valider le site web sur ordinateur et navigateur mobile.
2. Raccorder l’API aux vues et fonctions PostgreSQL existantes, puis aux publications réelles de la rédaction.
3. Ajouter les connecteurs partenaires RSS, API JSON, XMLTV et YouTube, puis les lecteurs et les flux autorisés.
4. Créer ensuite le dépôt distinct **news-mobile**, avec une application **React Native pour Android et iPhone** consommant le même contrat `/api/v1`.

Voir [le contrat API](docs/api.md) pour les routes et les précautions de raccordement au schéma existant. L’application native et son dépôt ne sont pas créés à cette étape.

Le modèle HTML d’origine et sa documentation restent dans le dépôt ; leurs mentions de licence et d’attribution sont conservées.
