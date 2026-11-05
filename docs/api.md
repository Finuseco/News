# API publique Lacruche.cd — v1

Le site web utilise les routes de lecture ci-dessous. La future application React Native Android/iPhone utilisera la même API. Cette première implémentation lit `data/content.json` : elle ne se connecte pas encore à PostgreSQL et n’importe aucun flux externe.

## Conventions

- Préfixe : `/api/v1`.
- Méthodes : `GET` et `HEAD`. Les écritures et `OPTIONS` répondent `405` avec `Allow: GET, HEAD`.
- Réponses JSON UTF-8, `Cache-Control: no-store`. Aucun CORS ouvert n’est ajouté ; les appels web utilisent la même origine.
- Les dates sont au format ISO 8601 UTC. Les corps d’articles sont des tableaux de paragraphes en texte brut, à rendre comme texte.
- Tous les exemples portent `demo: true`. Une connexion de production devra remplacer ce marqueur et la source de contenu.
- Une modification incompatible du contrat utilisera un nouveau préfixe, par exemple `/api/v2`.

## Routes

| Route | Paramètres | Résultat |
| --- | --- | --- |
| `GET /health` | — | État du service, version et source de contenu |
| `GET /home` | — | Article principal, trois titres et dernières publications |
| `GET /categories` | `page`, `limit` | Rubriques avec `id` et `name` |
| `GET /articles` | `category`, `q`, `page`, `limit` | Articles publiés, résumés sans corps complet |
| `GET /articles/:slug` | — | Article public, avec corps pour le contenu gratuit |
| `GET /media` | `type=video` ou `audio`, `page`, `limit` | Vidéos et audios éditorialement publiés |
| `GET /channels` | `type=tv`, `radio` ou `tnt`, `page`, `limit` | Chaînes et état de configuration |
| `GET /channels/:id/streams` | `page`, `limit` | Flux HTTPS actifs d’une chaîne en direct |

Les routes de ce tableau s’ajoutent au préfixe. Exemple : `/api/v1/articles?category=sante&page=1&limit=12`.

`page` est un entier de 1 à 1 000 000, par défaut 1. `limit` est un entier de 1 à 50, par défaut 12. Les valeurs invalides répondent `400`. Une page au-delà des résultats ou une rubrique inconnue renvoie une liste vide. `q` recherche dans les titres et extraits publics, sans distinction de casse ou d’accents, avec un maximum de 200 caractères. La recherche n’inspecte pas les corps privés ou premium.

## Enveloppes

Les listes partagent cette forme :

```json
{
  "data": [],
  "meta": { "total": 0, "page": 1, "limit": 12, "demo": true }
}
```

Le détail d’un article est `{ "data": { ...article }, "meta": { "demo": true } }`.

L’accueil a une forme spécifique :

```json
{
  "data": {
    "featured": null,
    "headlines": [],
    "latest": []
  },
  "meta": { "demo": true }
}
```

`featured` contient un résumé d’article ou `null`. `headlines` contient jusqu’à trois résumés après l’article principal. `latest` contient les résumés de toutes les publications de démonstration. Les listes et l’accueil n’incluent jamais `body`.

Un résumé d’article expose `id`, `slug`, `title`, `excerpt`, `category`, `categoryName`, `cover`, `author`, `publishedAt`, `readingMinutes`, `demo`, `status` et `accessLevel`. `cover` contient `url`, `alt` et les crédits photographiques disponibles. Le détail gratuit ajoute `body: string[]`.

Un article premium conserve son extrait public et expose `accessLevel: "premium"`, `requiresAccess: true` et `body: []` au détail. Aucun mécanisme d’achat ou d’accès premium n’est actif dans ce prototype.

Un média expose `id`, `slug`, `title`, `type`, `description`, `cover`, `durationSeconds`, `status`, `demo`, `playbackUrl` et `accessLevel`. Les médias de démonstration ont `status: "unconfigured"`, `durationSeconds: null` et `playbackUrl: null`. Une adresse de lecture premium n’est jamais renvoyée.

Une chaîne expose `id`, `name`, `type`, `description`, `logo`, `status`, `demo`, `streams` et `playbackUrl`. Les chaînes actuelles ont `status: "unconfigured"`, `logo: null`, `streams: []` et `playbackUrl: null`. Aucun programme ni indicateur de diffusion réelle ne doit être déduit de ces emplacements.

## Publication et erreurs

Un article doit avoir `status: "published"` et une date `publishedAt` valide, non future, pour être visible. Un média doit avoir `publicationStatus: "published"` et une date de publication non future. Les brouillons et les contenus programmés n’apparaissent ni dans les listes ni dans les détails.

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "Article introuvable."
  }
}
```

Codes usuels : `INVALID_QUERY` et `INVALID_URL` (`400`), `FORBIDDEN` (`403`), `NOT_FOUND` (`404`), `METHOD_NOT_ALLOWED` (`405`) et `INTERNAL_ERROR` (`500`). Une erreur interne ne révèle pas de chemin local ou de détail technique au client.

## Raccordement au schéma PostgreSQL existant

Le schéma de `db/schema.sql` reste la référence. Le remplacement du JSON doit se faire dans une couche de lecture serveur, en gardant les mêmes projections publiques pour le navigateur et React Native.

| Fonction de l’API | Sources PostgreSQL prévues |
| --- | --- |
| Accueil et listes d’articles | `v_published_articles`, avec filtres de rubrique et de publication |
| Détail d’article | `article_content_for(article, user)` ; ne jamais renvoyer directement la ligne `articles` |
| Listes vidéo/audio | `v_published_episodes` et références publiques des médias |
| Lecture d’un épisode | `episode_media_for(episode, user)` pour gérer aperçu et accès premium |
| Rubriques | `sections` et `section_translations` |
| TV, TNT et radio | `channels`, `live_streams` et `epg_entries` pour le guide des programmes |
| Partenaires et import | `media_partners`, `ingestion_sources` et `ingested_items` |
| Synchronisation YouTube | `youtube_channels`, `media_assets` et `episodes` |

Les fonctions d’accès premium de la base doivent être utilisées côté serveur avant toute transmission de texte intégral ou d’adresse vidéo/audio. Les projections de liste ne sont pas une autorisation de lecture complète. Les mutations éditoriales futures devront respecter le circuit de publication et le contexte transactionnel `app.user_id` documentés dans `db/README.md`.

Les connecteurs RSS, API JSON, XMLTV et YouTube seront des tâches serveur, avec import brut dans `ingested_items`, validation et dédoublonnage avant publication. Aucun importateur ni tâche planifiée n’est livré ici. Les flux TNT/radio devront être fournis et configurés dans `live_streams` avant de rendre un lecteur actif.

Le futur dépôt `news-mobile` restera distinct et contiendra une application React Native Android et iPhone. Il consommera les mêmes DTO publics ; les identifiants de base de données, secrets d’import et clés privées resteront côté serveur.
