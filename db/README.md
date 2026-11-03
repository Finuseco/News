# Base de données PostgreSQL

Base unique pour le site, l'API et l'application Android.

## Installation

```bash
createdb news
psql news -f db/schema.sql   # tables, index, vues, fonctions, règles
psql news -f db/seed.sql     # langues, continents, pays, catégories, réglages (relançable sans doublons)
```

Testé sur PostgreSQL 16. Les extensions `pgcrypto`, `citext`, `pg_trgm`, `unaccent` et `btree_gist` sont fournies avec le paquet `postgresql-contrib`.

**Premier administrateur** : à créer à la main après l'installation (le back-end ne peut pas donner le rôle admin tant qu'il n'y en a pas un).

```sql
SET app.bypass_workflow = 'on';
INSERT INTO users (email, password_hash, display_name) VALUES ('admin@exemple.org', '<hash>', 'Administrateur');
INSERT INTO user_roles (user_id, role) SELECT id, 'admin' FROM users WHERE email = 'admin@exemple.org';
```

## Ce que le back-end doit faire à chaque requête

Les règles de rôles sont appliquées par la base elle-même. Le back-end doit donc lui dire qui agit, dans chaque transaction :

```sql
BEGIN;
SET LOCAL app.user_id = '<uuid de l''utilisateur connecté>';
SET LOCAL app.workflow_comment = 'Source à citer';   -- optionnel, obligatoire pour « corrections demandées »
UPDATE articles SET status = 'changes_requested' WHERE id = '...';
COMMIT;
```

Sans `app.user_id` (tâches planifiées), seules les transitions valides sont contrôlées. `SET LOCAL app.bypass_workflow = 'on'` désactive les contrôles : à réserver aux migrations et aux imports.

## Rôles de l'équipe

Tout inscrit est lecteur. Les rôles de l'équipe s'ajoutent dans `user_roles` (une personne peut en cumuler plusieurs) et seul un administrateur peut les attribuer.

| Rôle | Ce qu'il fait |
|---|---|
| `author` | Écrit et soumet. Un profil public de signature (`authors`) est créé automatiquement. |
| `reviewer` | Vérifie les contenus soumis : il valide ou demande des corrections. |
| `publisher` | Met en ligne ou programme ce qui a été vérifié ; peut retirer une publication. |
| `moderator` | Modère les commentaires. |
| `admin` | Contrôle tous les comptes (suspendre, bloquer), attribue les rôles, décide quels contenus sont premium et à quel prix. |

## Circuit de publication

```
brouillon ──soumet──> soumis ──vérifie──> validé ──publie──> publié
 (auteur)             (relecteur)          (publicateur)
                         │
                         └─> corrections demandées ──> l'auteur corrige et resoumet
```

- Les transitions autorisées et les rôles qui peuvent les faire sont dans la table `workflow_transitions` : on change les règles en ajoutant ou retirant des lignes, sans toucher au code.
- Un contenu ne peut pas être soumis sans au moins un auteur : c'est la **signature**, reprise dans `v_published_articles` et `v_published_episodes` (champ `authors`).
- L'auteur connecté qui crée un contenu en devient automatiquement le signataire.
- **Quatre yeux** : celui qui vérifie ne peut pas être l'auteur ni celui qui a soumis (réglage `require_four_eyes`, actif par défaut).
- Toute étape est enregistrée dans `content_workflow_events` : qui, quand, de quel statut à quel statut, avec quel commentaire. `submitted_by`, `approved_by` et `published_by` sont remplis automatiquement.
- Files d'attente prêtes à l'emploi : `v_review_queue` (à vérifier) et `v_publish_queue` (à publier).

## Comptes bloqués

Seul un administrateur peut suspendre (avec une date de fin possible) ou bloquer un compte, avec un motif. Les sessions du compte sont fermées aussitôt, et il ne peut plus rien faire. Un administrateur ne peut pas se bloquer lui-même, ni retirer le dernier administrateur. `lift_expired_suspensions()` lève les suspensions échues : à planifier.

## Contenus gratuits et premium

- `access_level` vaut `free` ou `premium` sur les articles et les épisodes (vidéos, audios). **Seul un administrateur peut le changer**, ainsi que le prix (`price_amount`, `price_currency`).
- **Article premium** : le lecteur reçoit seulement un extrait, celui écrit par l'auteur (`preview_body`) ou, à défaut, le début du texte (réglage `premium_preview_chars`). L'extrait ne dépasse jamais la moitié d'un texte court.
- **Vidéo ou audio premium** : le lecteur reçoit la bande-annonce (`trailer_media_id`) et la durée d'aperçu (`preview_seconds`) au lieu du média complet.
- L'équipe du site (tout rôle) voit toujours le contenu complet.
- **Le back-end doit toujours passer par `article_content_for(article, user)` et `episode_media_for(episode, user)`** pour envoyer un contenu. Les vues publiques n'exposent jamais le texte complet ni l'adresse de la vidéo.

## Paiement CashPay

D'après la documentation de developer.cashpay-all.com :

1. Le lecteur veut lire un contenu premium : le back-end crée une ligne `payments` au statut `pending` avec une `reference` unique.
2. Le back-end appelle `POST /api/v1/b2b/payments/checkout` (Hosted Checkout) avec `amount`, `currency`, `reference`, `description`, `customer`, `redirectUrl` et `paymentMethods`. Il enregistre le `sessionId` reçu dans `cashpay_session_id` et l'URL de paiement dans `checkout_url`, puis redirige le lecteur.
3. CashPay prévient par webhook (`payment.succeeded` ou `payment.failed`, en-tête `X-CashPay-Signature`, HMAC-SHA256 du corps brut avec l'API Secret). Le back-end vérifie la signature, enregistre l'événement dans `payment_webhook_events` (le même corps reçu deux fois est refusé, ce qui évite les doublons des réessais sur 24 h), puis met le paiement à `completed` avec `cashpay_transaction_id`.
4. **La base crée alors toute seule l'accès** (`access_grants`) ; un remboursement le retire. La durée de l'accès se règle avec `purchase_access_days` (illimité par défaut).

Points de la documentation CashPay à confirmer avant de coder cette partie : la liste complète des statuts de transaction (seuls `completed` et `failed` sont documentés), l'URL de rappel des webhooks (`callbackUrl` n'apparaît pas dans l'exemple du Hosted Checkout), le moyen de retrouver une transaction par la suite et le bac à sable de test.

## Classer un contenu : pays, continent et catégorie

Chaque article et chaque vidéo a **un lieu** et **une catégorie** (domaine), choisis par l'auteur à la rédaction. Les deux sont obligatoires pour soumettre.

- **Continents** (`continents`) : Afrique, Amériques, Asie-Pacifique, Europe, Moyen-Orient.
- **Pays** (`countries`) : 198 pays, chacun rattaché à un seul continent. L'arbre complet « continent > pays » s'obtient en un appel, pratique pour le formulaire de publication et l'application Android :
  ```sql
  SELECT geo_tree('fr');   -- ou 'en'
  -- [{"code":"afrique","name":"Afrique","countries":[{"code":"CD","name":"RD Congo"}, ...]}, ...]
  ```
  Le continent d'un contenu se déduit tout seul du pays choisi.
- **Lieu d'un contenu** (`geo_scope`) : `country` (un pays, par défaut), `continent` (tout un continent, par exemple l'Union africaine) ou `world` (international, sans pays). D'autres pays concernés peuvent s'ajouter dans `article_countries`.
- **Catégories** (`sections`) : Actualité, Politique, Économie, Société, Diplomatie, Justice, Environnement, Santé, Sciences et Technologies, Éducation, Culture, Sport, Médias, Opinions. Elles sont indépendantes du lieu : « Économie » + « RD Congo » donne un article d'économie sur la RD Congo. Les noms existent en plusieurs langues (`section_translations`) et des sous-catégories sont possibles avec `parent_id`.
- **Pour l'API** : filtrer `v_published_articles` et `v_published_episodes` par `continent_code`, `country_code` et `section_id`.
- **Modifiable sans code** : le regroupement par continent est une convention éditoriale (Égypte et Maghreb en Afrique, Turquie et Iran au Moyen-Orient, Caucase et Russie en Europe, Asie centrale et Océanie en Asie-Pacifique). Pour changer un pays de continent, ses contenus suivent automatiquement :
  ```sql
  UPDATE countries SET continent_code = 'europe' WHERE code = 'TR';
  ```

## Vidéos, YouTube et chaînes

- **Vidéo filmée** : un `media_assets` (`provider = 'upload'`) relié à un épisode. Le champ `processing_status` suit son traitement (conversion HLS par exemple).
- **Chaînes YouTube synchronisées** : `youtube_channels` décrit la chaîne et sa fréquence de synchronisation ; chaque vidéo importée devient un média (`provider = 'youtube'`, une même vidéo ne peut pas être importée deux fois) et un épisode relié à sa chaîne. Les vidéos importées suivent le circuit de publication, sauf si `auto_publish` est activé : le job de synchronisation doit alors utiliser `SET LOCAL app.bypass_workflow = 'on'` et renseigner lui-même `published_at`. `default_section_id` et `default_country_code` donnent à ces vidéos leur catégorie et leur pays. Les directs YouTube peuvent aussi être importés (`sync_lives`).
- **Chaînes et lives** : `channels` distingue nos chaînes (`own`), les partenaires comme une chaîne TNT (`partner`) et les chaînes tierces ajoutées à l'application (`external`). Chaque chaîne peut avoir plusieurs flux (`live_streams`) dont un flux principal, et un guide des programmes (`epg_entries`) sans chevauchement possible.
- **Connecter un média ou une chaîne TNT** : créer un `media_partners`, puis une `ingestion_sources` (RSS, API JSON, XMLTV ou YouTube). Les éléments récupérés sont gardés bruts dans `ingested_items` avant d'être transformés.

## Autres tables

| Domaine | Tables |
|---|---|
| Référentiels | `languages`, `continents`, `countries` |
| Comptes et accès | `users`, `user_roles`, `refresh_tokens`, `api_clients`, `site_settings`, `audit_log` |
| Rédaction | `authors`, `sections` (catégories), `section_translations`, `tags` |
| Articles | `articles`, `article_authors`, `article_tags`, `article_countries`, `article_media`, `article_related`, `article_revisions` |
| Vidéo et audio | `programs`, `episodes`, `episode_authors`, `episode_tags`, `media_assets`, `media_subtitles` |
| Lecteurs | `bookmarks`, `section_follows`, `comments` |
| Application mobile | `devices`, `device_section_subscriptions`, `push_notifications` |
| Mise en avant | `collections`, `collection_items` |
| Audience | `content_views` |

Fonctions à planifier : `publish_scheduled_content()` (chaque minute) et `lift_expired_suspensions()`.

## Choix de conception

- **Multilingue** : un article est écrit dans une seule langue. Ses traductions partagent le même `translation_group_id`, ce qui permet à l'application de proposer « lire en anglais ».
- **Vidéos** : une vidéo est un `episode` de type `video`. Sans `program_id`, c'est une vidéo isolée ; avec, c'est un épisode d'émission. Les podcasts suivent le même modèle.
- **Accès API** : l'application Android et les partenaires utilisent des clés (`api_clients`) avec des droits (`scopes`) et une limite de requêtes. Seul le hash de la clé est stocké.
- **Recherche** : plein texte sans accents, adapté à la langue de l'article, plus recherche approximative sur les titres.
- **Volumes** : `content_views` pourra être partitionnée par mois quand l'audience le justifiera.
