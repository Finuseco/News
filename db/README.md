# Base de données PostgreSQL

Base unique pour le site, l'API et l'application Android.

## Installation

```bash
createdb news
psql news -f db/schema.sql   # tables, index, vues, fonctions
psql news -f db/seed.sql     # langues, pays, rubriques (relançable sans doublons)
```

Testé sur PostgreSQL 16. Les extensions `pgcrypto`, `citext`, `pg_trgm`, `unaccent` et `btree_gist` sont fournies avec le paquet `postgresql-contrib`.

## Organisation des tables

| Domaine | Tables |
|---|---|
| Référentiels | `languages`, `countries` |
| Comptes et accès | `users`, `refresh_tokens`, `api_clients`, `audit_log` |
| Rédaction | `authors`, `sections`, `section_translations`, `tags` |
| Médias | `media_assets`, `media_subtitles` |
| Articles | `articles`, `article_authors`, `article_tags`, `article_countries`, `article_media`, `article_related`, `article_revisions` |
| Vidéo et audio | `programs`, `episodes`, `episode_tags` |
| Chaînes et direct | `channels`, `live_streams`, `epg_entries` |
| Connexion à d'autres médias | `media_partners`, `ingestion_sources`, `ingested_items` |
| Lecteurs | `bookmarks`, `section_follows`, `comments` |
| Application mobile | `devices`, `device_section_subscriptions`, `push_notifications` |
| Mise en avant | `collections`, `collection_items` |
| Audience | `content_views` |

Vues pour l'API : `v_published_articles`, `v_published_episodes`, `v_live_now`.
Fonction à planifier chaque minute : `publish_scheduled_articles()`.

## Choix de conception

- **Multilingue** : un article est écrit dans une seule langue. Ses traductions partagent le même `translation_group_id`, ce qui permet à l'application de proposer « lire en anglais ».
- **Vidéos** : une vidéo est un `episode` de type `video`. Sans `program_id`, c'est une vidéo isolée ; avec, c'est un épisode d'émission. Les audios (podcasts) suivent le même modèle.
- **TNT et lives** : chaque chaîne (`channels`) a son numéro TNT par pays, un ou plusieurs flux (`live_streams`, HLS en priorité) et son guide des programmes (`epg_entries`), dont les créneaux ne peuvent pas se chevaucher.
- **Connecter un média ou une chaîne** : créer un `media_partners`, puis une `ingestion_sources` (RSS, API JSON ou XMLTV). Les éléments récupérés sont gardés bruts dans `ingested_items` avant d'être transformés en articles ou en guide des programmes.
- **Accès API** : l'application Android et les partenaires utilisent des clés (`api_clients`) avec des droits (`scopes`) et une limite de requêtes. Seul le hash de la clé est stocké.
- **Recherche** : plein texte sans accents, adapté à la langue de l'article, plus recherche approximative sur les titres.
- **Volumes** : `content_views` pourra être partitionnée par mois quand l'audience le justifiera.
