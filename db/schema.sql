-- =====================================================================
-- News Platform : schéma PostgreSQL
-- Plateforme d'actualité média (type RFI / France 24) :
--   * articles multilingues, classés par continent > pays et par catégorie (domaine),
--     tags, auteurs (signature)
--   * équipe : administrateurs, modérateurs, auteurs, relecteurs, publicateurs
--   * circuit de publication : l'auteur soumet, un autre vérifie, puis on publie
--   * contenus gratuits ou premium (extrait, puis paiement CashPay)
--   * vidéos et audios, chaînes YouTube synchronisées
--   * chaînes (TV, radio, TNT, externes), lives et guide des programmes
--   * connecteurs vers d'autres médias
--   * application Android : appareils, notifications push, favoris
--   * accès API (clés pour l'app mobile et les partenaires)
--
-- Utilisation :  psql "$DATABASE_URL" -f db/schema.sql
-- Les données de base (langues, pays, rubriques, réglages) sont dans db/seed.sql
--
-- IMPORTANT pour le back-end : dans chaque transaction, indiquer qui agit :
--     SET LOCAL app.user_id = '<uuid de l''utilisateur connecté>';
--     SET LOCAL app.workflow_comment = '<commentaire>';   -- optionnel
-- La base applique alors les règles de rôles, de relecture et de monétisation.
-- Sans app.user_id (tâches planifiées), seules les transitions valides sont contrôlées.
-- SET LOCAL app.bypass_workflow = 'on' désactive les contrôles (migrations, imports).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;       -- emails insensibles à la casse
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- recherche approximative sur les titres
CREATE EXTENSION IF NOT EXISTS unaccent;     -- recherche sans accents
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- contrainte anti-chevauchement de l'EPG

-- ---------------------------------------------------------------------
-- Types énumérés
-- ---------------------------------------------------------------------
-- Rôles de l'équipe (tout inscrit est lecteur : pas de rôle à lui donner)
CREATE TYPE user_role AS ENUM ('author', 'reviewer', 'publisher', 'moderator', 'admin');
CREATE TYPE account_status AS ENUM ('active', 'suspended', 'blocked');

-- Circuit de publication
--   draft -> submitted -> approved -> published
--   submitted -> changes_requested -> submitted (corrections demandées)
CREATE TYPE content_status AS ENUM (
  'draft', 'submitted', 'changes_requested', 'approved', 'scheduled', 'published', 'archived'
);
CREATE TYPE access_level AS ENUM ('free', 'premium');

-- Portée géographique d'un contenu : un pays, tout un continent, ou le monde entier
CREATE TYPE geo_scope AS ENUM ('country', 'continent', 'world');

CREATE TYPE article_kind        AS ENUM ('article', 'brief', 'dossier', 'reportage', 'interview', 'opinion', 'live_blog');
CREATE TYPE media_kind          AS ENUM ('image', 'video', 'audio', 'document');
CREATE TYPE episode_kind        AS ENUM ('video', 'audio');
CREATE TYPE channel_kind        AS ENUM ('tv', 'radio', 'tnt', 'web');
CREATE TYPE channel_ownership   AS ENUM ('own', 'partner', 'external');
CREATE TYPE stream_protocol     AS ENUM ('hls', 'dash', 'rtmp', 'rtsp', 'youtube', 'other');
CREATE TYPE stream_status       AS ENUM ('scheduled', 'live', 'ended', 'offline');
CREATE TYPE comment_status      AS ENUM ('pending', 'approved', 'rejected', 'spam');
CREATE TYPE platform_kind       AS ENUM ('android', 'ios', 'web');
CREATE TYPE ingest_format       AS ENUM ('rss', 'atom', 'json_api', 'xmltv', 'youtube', 'manual');
CREATE TYPE ingest_status       AS ENUM ('pending', 'imported', 'skipped', 'failed');
CREATE TYPE notification_status AS ENUM ('draft', 'scheduled', 'sent', 'failed');
-- CashPay ne documente que « completed » et « failed » ; les autres sont gérés par nous
CREATE TYPE payment_status      AS ENUM ('pending', 'completed', 'failed', 'cancelled', 'expired', 'refunded');

-- ---------------------------------------------------------------------
-- Fonctions de base (ne dépendent d'aucune table)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Utilisateur qui agit, fourni par le back-end (SET LOCAL app.user_id)
CREATE OR REPLACE FUNCTION current_actor() RETURNS uuid AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION workflow_bypass() RETURNS boolean AS $$
  SELECT coalesce(current_setting('app.bypass_workflow', true), '') = 'on';
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- 1. RÉFÉRENTIELS
-- =====================================================================

-- Langues de publication (une rédaction par langue, comme RFI)
CREATE TABLE languages (
  code          text PRIMARY KEY CHECK (code ~ '^[a-z]{2,3}$'),
  name          text NOT NULL,
  native_name   text NOT NULL,
  is_rtl        boolean NOT NULL DEFAULT false,
  is_active     boolean NOT NULL DEFAULT true,
  search_config regconfig NOT NULL DEFAULT 'simple'   -- configuration de recherche plein texte
);

-- Continents (régions du monde) : Afrique, Amériques, Asie-Pacifique, Europe, Moyen-Orient.
-- Le regroupement suit celui des grands médias internationaux comme RFI.
-- `names` accueille les noms dans les autres langues, ex. {"sw": "Afrika"}.
CREATE TABLE continents (
  code      text PRIMARY KEY CHECK (code ~ '^[a-z]+(-[a-z]+)*$'),   -- sert aussi dans les adresses
  name_fr   text NOT NULL,
  name_en   text NOT NULL,
  names     jsonb NOT NULL DEFAULT '{}',
  position  integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true
);

-- Chaque pays appartient à un seul continent (modifiable par l'administrateur)
CREATE TABLE countries (
  code           char(2) PRIMARY KEY CHECK (code = upper(code)),
  continent_code text NOT NULL REFERENCES continents(code) ON UPDATE CASCADE,
  name_fr        text NOT NULL,
  name_en        text NOT NULL,
  names          jsonb NOT NULL DEFAULT '{}',
  is_active      boolean NOT NULL DEFAULT true
);
CREATE INDEX idx_countries_continent ON countries (continent_code) WHERE is_active;

-- =====================================================================
-- 2. UTILISATEURS, RÔLES, SESSIONS, ACCÈS API, RÉGLAGES
-- =====================================================================

CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email             citext NOT NULL UNIQUE,
  password_hash     text,                                  -- NULL si connexion sociale
  display_name      text NOT NULL,
  language_code     text REFERENCES languages(code),
  avatar_url        text,
  -- Contrôle du compte par l'administrateur
  status            account_status NOT NULL DEFAULT 'active',
  status_reason     text,
  suspended_until   timestamptz,                           -- fin d'une suspension temporaire
  status_changed_by uuid REFERENCES users(id) ON DELETE SET NULL,
  status_changed_at timestamptz,
  email_verified_at timestamptz,
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_users_status ON users (status) WHERE status <> 'active';

-- Un utilisateur peut cumuler plusieurs rôles (ex. auteur et relecteur)
CREATE TABLE user_roles (
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       user_role NOT NULL,
  granted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role)
);
CREATE INDEX idx_user_roles_role ON user_roles (role);

CREATE TABLE refresh_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,
  user_agent  text,
  ip          inet,
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens (user_id);

-- Clés d'API : application Android, partenaires, chaînes TNT connectées
CREATE TABLE api_clients (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  key_prefix         text NOT NULL,                  -- début de la clé, affichable
  key_hash           text NOT NULL UNIQUE,           -- la clé complète n'est jamais stockée
  scopes             text[] NOT NULL DEFAULT '{}',   -- ex. {'articles:read','live:read'}
  rate_limit_per_min integer NOT NULL DEFAULT 60,
  is_active          boolean NOT NULL DEFAULT true,
  expires_at         timestamptz,
  last_used_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- Réglages du site modifiables par l'administrateur
CREATE TABLE site_settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  updated_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Journal d'audit des actions de la rédaction
CREATE TABLE audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  action      text NOT NULL,                  -- ex. 'user.block'
  entity_type text NOT NULL,
  entity_id   text,
  changes     jsonb,
  ip          inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_entity ON audit_log (entity_type, entity_id);
CREATE INDEX idx_audit_log_user   ON audit_log (user_id, created_at DESC);

-- =====================================================================
-- 3. RÉDACTION : auteurs (signature), rubriques, tags
-- =====================================================================

-- Profil public de l'auteur : c'est lui qui signe les articles et vidéos.
-- Créé automatiquement quand on donne le rôle « author » à un utilisateur.
CREATE TABLE authors (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid UNIQUE REFERENCES users(id) ON DELETE SET NULL,
  name       text NOT NULL,
  slug       text NOT NULL UNIQUE,
  bio        text,
  photo_url  text,
  email      citext,
  social     jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Rubriques (Monde, Afrique, Économie...) avec hiérarchie
CREATE TABLE sections (
  id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_id  integer REFERENCES sections(id) ON DELETE SET NULL,
  slug       text NOT NULL UNIQUE,
  position   integer NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE section_translations (
  section_id    integer NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  language_code text NOT NULL REFERENCES languages(code),
  name          text NOT NULL,
  description   text,
  PRIMARY KEY (section_id, language_code)
);

CREATE TABLE tags (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  language_code text NOT NULL REFERENCES languages(code),
  name          text NOT NULL,
  slug          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug)
);

-- =====================================================================
-- 4. MÉDIAS (images, vidéos, audios, documents)
-- Un média peut être un fichier envoyé chez nous (vidéo filmée par la
-- rédaction) ou une vidéo hébergée ailleurs (YouTube).
-- =====================================================================

CREATE TABLE media_assets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              media_kind NOT NULL,
  provider          text NOT NULL DEFAULT 'upload' CHECK (provider IN ('upload', 'youtube', 'vimeo', 'external')),
  provider_id       text,                          -- identifiant de la vidéo chez YouTube, etc.
  processing_status text NOT NULL DEFAULT 'ready' CHECK (processing_status IN ('pending', 'processing', 'ready', 'failed')),
  storage_key       text,                          -- chemin dans le stockage (S3, disque...)
  url               text NOT NULL,                 -- fichier source ou lien principal
  hls_url           text,                          -- flux adaptatif pour les vidéos
  thumbnail_url     text,
  mime_type         text,
  size_bytes        bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  width             integer,
  height            integer,
  duration_seconds  integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  alt_text          text,
  caption           text,
  credit            text,
  metadata          jsonb NOT NULL DEFAULT '{}',
  uploaded_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_media_assets_kind ON media_assets (kind, created_at DESC);
CREATE UNIQUE INDEX uq_media_assets_provider ON media_assets (provider, provider_id) WHERE provider_id IS NOT NULL;
CREATE INDEX idx_media_assets_processing ON media_assets (processing_status) WHERE processing_status <> 'ready';

-- Sous-titres des vidéos, une ligne par langue
CREATE TABLE media_subtitles (
  media_id      uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
  language_code text NOT NULL REFERENCES languages(code),
  url           text NOT NULL,
  PRIMARY KEY (media_id, language_code)
);

-- =====================================================================
-- 5. PARTENAIRES ET CHAÎNES (TV, radio, TNT, chaînes externes)
-- =====================================================================

CREATE TABLE media_partners (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text NOT NULL UNIQUE,
  name          text NOT NULL,
  website_url   text,
  contact_email citext,
  logo_url      text,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ownership : 'own' = nos chaînes, 'partner' = chaîne TNT ou média partenaire connecté,
--             'external' = chaîne tierce ajoutée à l'application (ex. flux public)
CREATE TABLE channels (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text NOT NULL UNIQUE,
  name          text NOT NULL,
  kind          channel_kind NOT NULL,
  ownership     channel_ownership NOT NULL DEFAULT 'own',
  partner_id    uuid REFERENCES media_partners(id) ON DELETE SET NULL,
  country_code  char(2) REFERENCES countries(code),
  language_code text REFERENCES languages(code),
  logo_url      text,
  website_url   text,
  description   text,
  tnt_number    integer,                       -- numéro de chaîne sur la TNT (LCN)
  is_active     boolean NOT NULL DEFAULT true,
  is_featured   boolean NOT NULL DEFAULT false,
  sort_order    integer NOT NULL DEFAULT 0,
  metadata      jsonb NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_channels_tnt_number ON channels (country_code, tnt_number) WHERE tnt_number IS NOT NULL;
CREATE INDEX idx_channels_kind ON channels (kind, sort_order) WHERE is_active;

-- Chaînes YouTube synchronisées : les nouvelles vidéos deviennent des épisodes
CREATE TABLE youtube_channels (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  youtube_channel_id      text NOT NULL UNIQUE,        -- identifiant « UC... »
  title                   text NOT NULL,
  handle                  text,                        -- ex. @nom
  uploads_playlist_id     text,
  partner_id              uuid REFERENCES media_partners(id) ON DELETE SET NULL,
  channel_id              uuid REFERENCES channels(id) ON DELETE SET NULL,
  language_code           text REFERENCES languages(code),
  default_section_id      integer REFERENCES sections(id) ON DELETE SET NULL,
  default_country_code    char(2) REFERENCES countries(code),   -- pays attribué aux vidéos importées
  sync_enabled            boolean NOT NULL DEFAULT true,
  sync_lives              boolean NOT NULL DEFAULT false,   -- importer aussi les directs YouTube
  -- true : le job fait passer les vidéos importées jusqu'à la publication sans relecture humaine
  auto_publish            boolean NOT NULL DEFAULT false,
  sync_interval_minutes   integer NOT NULL DEFAULT 30 CHECK (sync_interval_minutes > 0),
  last_synced_at          timestamptz,
  last_video_published_at timestamptz,
  last_error              text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_youtube_channels_due ON youtube_channels (last_synced_at) WHERE sync_enabled;

-- =====================================================================
-- 6. ARTICLES
-- Un article = une langue. Les traductions d'un même sujet partagent
-- le même translation_group_id (ex. article FR, EN et SW liés).
-- =====================================================================

CREATE TABLE articles (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  translation_group_id uuid NOT NULL DEFAULT gen_random_uuid(),
  language_code        text NOT NULL REFERENCES languages(code),
  kind                 article_kind NOT NULL DEFAULT 'article',
  title                text NOT NULL,
  slug                 text NOT NULL,
  subtitle             text,
  summary              text,                      -- chapô
  body                 text NOT NULL DEFAULT '',  -- contenu complet (Markdown ou HTML)
  cover_media_id       uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  -- Catégorie (domaine : politique, économie...) : obligatoire pour soumettre
  section_id           integer REFERENCES sections(id) ON DELETE SET NULL,
  -- Où : le pays concerné (le continent s'en déduit tout seul), ou tout un continent,
  -- ou le monde. D'autres pays secondaires peuvent s'ajouter dans article_countries.
  geo_scope            geo_scope NOT NULL DEFAULT 'country',
  country_code         char(2) REFERENCES countries(code),
  continent_code       text REFERENCES continents(code) ON UPDATE CASCADE,
  -- Circuit de publication (rempli automatiquement par la base)
  status               content_status NOT NULL DEFAULT 'draft',
  submitted_by         uuid REFERENCES users(id) ON DELETE SET NULL,
  submitted_at         timestamptz,
  reviewer_id          uuid REFERENCES users(id) ON DELETE SET NULL,   -- relecteur qui a pris l'article
  approved_by          uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_at          timestamptz,
  published_by         uuid REFERENCES users(id) ON DELETE SET NULL,
  published_at         timestamptz,
  scheduled_at         timestamptz,
  -- Monétisation : réservée à l'administrateur
  access_level         access_level NOT NULL DEFAULT 'free',
  price_amount         numeric(12,2) CHECK (price_amount IS NULL OR price_amount > 0),
  price_currency       char(3),                   -- NULL = prix et devise par défaut du site
  preview_body         text,                      -- extrait choisi par l'auteur (sinon calculé)
  access_changed_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  access_changed_at    timestamptz,
  is_breaking          boolean NOT NULL DEFAULT false,   -- dernière minute
  is_featured          boolean NOT NULL DEFAULT false,   -- à la une
  allow_comments       boolean NOT NULL DEFAULT true,
  reading_time_min     integer,
  view_count           bigint NOT NULL DEFAULT 0,
  source_name          text,                      -- agence ou média d'origine
  external_url         text,
  seo_title            text,
  seo_description      text,
  created_by           uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_by           uuid REFERENCES users(id) ON DELETE SET NULL,
  search_vector        tsvector,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug),
  UNIQUE (translation_group_id, language_code),
  CONSTRAINT articles_published_has_date CHECK (status <> 'published' OR published_at IS NOT NULL),
  CONSTRAINT articles_scheduled_has_date CHECK (status <> 'scheduled' OR scheduled_at IS NOT NULL),
  CONSTRAINT articles_price_pair         CHECK ((price_amount IS NULL) = (price_currency IS NULL)),
  CONSTRAINT articles_free_has_no_price  CHECK (access_level = 'premium' OR price_amount IS NULL),
  CONSTRAINT articles_geo_consistent     CHECK (
       (geo_scope = 'world'     AND country_code IS NULL AND continent_code IS NULL)
    OR (geo_scope = 'continent' AND country_code IS NULL)
    OR  geo_scope = 'country')
);

CREATE INDEX idx_articles_lang_pub     ON articles (language_code, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_articles_section_pub  ON articles (section_id, published_at DESC)    WHERE status = 'published';
CREATE INDEX idx_articles_country_pub  ON articles (country_code, published_at DESC)   WHERE status = 'published';
CREATE INDEX idx_articles_continent_pub ON articles (continent_code, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_articles_status       ON articles (status, updated_at DESC);
CREATE INDEX idx_articles_review_queue ON articles (submitted_at)  WHERE status = 'submitted';
CREATE INDEX idx_articles_publish_queue ON articles (approved_at)  WHERE status = 'approved';
CREATE INDEX idx_articles_breaking     ON articles (published_at DESC) WHERE status = 'published' AND is_breaking;
CREATE INDEX idx_articles_featured     ON articles (published_at DESC) WHERE status = 'published' AND is_featured;
CREATE INDEX idx_articles_premium      ON articles (published_at DESC) WHERE status = 'published' AND access_level = 'premium';
CREATE INDEX idx_articles_scheduled    ON articles (scheduled_at)      WHERE status = 'scheduled';
CREATE INDEX idx_articles_group        ON articles (translation_group_id);
CREATE INDEX idx_articles_created_by   ON articles (created_by);
CREATE INDEX idx_articles_search       ON articles USING gin (search_vector);
CREATE INDEX idx_articles_title_trgm   ON articles USING gin (title gin_trgm_ops);

-- Recherche plein texte : configuration choisie selon la langue de l'article
CREATE OR REPLACE FUNCTION articles_search_vector_update() RETURNS trigger AS $$
DECLARE
  cfg regconfig;
BEGIN
  SELECT search_config INTO cfg FROM languages WHERE code = NEW.language_code;
  cfg := COALESCE(cfg, 'simple'::regconfig);
  NEW.search_vector :=
    setweight(to_tsvector(cfg, unaccent(coalesce(NEW.title, ''))),    'A') ||
    setweight(to_tsvector(cfg, unaccent(coalesce(NEW.subtitle, ''))), 'B') ||
    setweight(to_tsvector(cfg, unaccent(coalesce(NEW.summary, ''))),  'B') ||
    setweight(to_tsvector(cfg, unaccent(coalesce(NEW.body, ''))),     'C');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_articles_search_vector
  BEFORE INSERT OR UPDATE OF title, subtitle, summary, body, language_code ON articles
  FOR EACH ROW EXECUTE FUNCTION articles_search_vector_update();

-- Signature : un ou plusieurs auteurs par article (obligatoire dès la soumission)
CREATE TABLE article_authors (
  article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  author_id  uuid NOT NULL REFERENCES authors(id)  ON DELETE CASCADE,
  position   integer NOT NULL DEFAULT 0,
  PRIMARY KEY (article_id, author_id)
);
CREATE INDEX idx_article_authors_author ON article_authors (author_id);

CREATE TABLE article_tags (
  article_id uuid    NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  tag_id     integer NOT NULL REFERENCES tags(id)     ON DELETE CASCADE,
  PRIMARY KEY (article_id, tag_id)
);
CREATE INDEX idx_article_tags_tag ON article_tags (tag_id);

-- Pays concernés par l'article (filtre « Afrique > RDC » par exemple)
CREATE TABLE article_countries (
  article_id   uuid    NOT NULL REFERENCES articles(id)  ON DELETE CASCADE,
  country_code char(2) NOT NULL REFERENCES countries(code),
  PRIMARY KEY (article_id, country_code)
);
CREATE INDEX idx_article_countries_country ON article_countries (country_code);

-- Galerie d'images ou vidéos attachées à l'article
CREATE TABLE article_media (
  article_id uuid NOT NULL REFERENCES articles(id)     ON DELETE CASCADE,
  media_id   uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
  position   integer NOT NULL DEFAULT 0,
  PRIMARY KEY (article_id, media_id)
);

CREATE TABLE article_related (
  article_id         uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  related_article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  position           integer NOT NULL DEFAULT 0,
  PRIMARY KEY (article_id, related_article_id),
  CHECK (article_id <> related_article_id)
);

-- Historique des versions (relecture, retour en arrière)
CREATE TABLE article_revisions (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  version    integer NOT NULL,
  snapshot   jsonb NOT NULL,
  edited_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (article_id, version)
);

-- =====================================================================
-- 7. CIRCUIT DE PUBLICATION (articles et épisodes)
-- =====================================================================

-- Qui a le droit de faire passer un contenu d'un statut à un autre.
-- Modifiable sans toucher au code : ajouter ou retirer des lignes.
CREATE TABLE workflow_transitions (
  from_status content_status NOT NULL,
  to_status   content_status NOT NULL,
  role        user_role NOT NULL,
  PRIMARY KEY (from_status, to_status, role)
);

-- Historique de toutes les étapes : qui a soumis, vérifié, publié, et pourquoi
CREATE TABLE content_workflow_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content_type text NOT NULL CHECK (content_type IN ('article', 'episode')),
  content_id   uuid NOT NULL,
  from_status  content_status,
  to_status    content_status NOT NULL,
  actor_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  comment      text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_workflow_events_content ON content_workflow_events (content_type, content_id, created_at);
CREATE INDEX idx_workflow_events_actor   ON content_workflow_events (actor_id, created_at DESC);

-- =====================================================================
-- 8. VIDÉO / AUDIO, LIVES ET GUIDE DES PROGRAMMES
-- =====================================================================

-- Émissions (programmes récurrents)
CREATE TABLE programs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug           text NOT NULL,
  language_code  text NOT NULL REFERENCES languages(code),
  channel_id     uuid REFERENCES channels(id) ON DELETE SET NULL,
  title          text NOT NULL,
  description    text,
  cover_media_id uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug)
);

-- Épisodes : vidéos et audios publiés. Une vidéo seule (hors émission)
-- est un épisode avec program_id NULL. Même circuit de publication et
-- même monétisation que les articles.
CREATE TABLE episodes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id        uuid REFERENCES programs(id) ON DELETE SET NULL,
  language_code     text NOT NULL REFERENCES languages(code),
  kind              episode_kind NOT NULL,
  title             text NOT NULL,
  slug              text NOT NULL,
  description       text,
  media_id          uuid REFERENCES media_assets(id) ON DELETE SET NULL,   -- vidéo complète
  section_id        integer REFERENCES sections(id) ON DELETE SET NULL,    -- catégorie (domaine)
  geo_scope         geo_scope NOT NULL DEFAULT 'country',                  -- même logique que les articles
  country_code      char(2) REFERENCES countries(code),
  continent_code    text REFERENCES continents(code) ON UPDATE CASCADE,
  article_id        uuid REFERENCES articles(id) ON DELETE SET NULL,       -- article lié éventuel
  youtube_channel_id uuid REFERENCES youtube_channels(id) ON DELETE SET NULL,  -- si importé de YouTube
  status            content_status NOT NULL DEFAULT 'draft',
  submitted_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  submitted_at      timestamptz,
  reviewer_id       uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_at       timestamptz,
  published_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  published_at      timestamptz,
  scheduled_at      timestamptz,
  -- Monétisation : réservée à l'administrateur
  access_level      access_level NOT NULL DEFAULT 'free',
  price_amount      numeric(12,2) CHECK (price_amount IS NULL OR price_amount > 0),
  price_currency    char(3),
  preview_seconds   integer CHECK (preview_seconds IS NULL OR preview_seconds > 0),  -- durée gratuite
  trailer_media_id  uuid REFERENCES media_assets(id) ON DELETE SET NULL,            -- bande-annonce gratuite
  access_changed_by uuid REFERENCES users(id) ON DELETE SET NULL,
  access_changed_at timestamptz,
  season            integer,
  episode_number    integer,
  duration_seconds  integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  view_count        bigint NOT NULL DEFAULT 0,
  created_by        uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug),
  CONSTRAINT episodes_published_has_date CHECK (status <> 'published' OR published_at IS NOT NULL),
  CONSTRAINT episodes_scheduled_has_date CHECK (status <> 'scheduled' OR scheduled_at IS NOT NULL),
  CONSTRAINT episodes_price_pair         CHECK ((price_amount IS NULL) = (price_currency IS NULL)),
  CONSTRAINT episodes_free_has_no_price  CHECK (access_level = 'premium' OR price_amount IS NULL),
  CONSTRAINT episodes_geo_consistent     CHECK (
       (geo_scope = 'world'     AND country_code IS NULL AND continent_code IS NULL)
    OR (geo_scope = 'continent' AND country_code IS NULL)
    OR  geo_scope = 'country')
);
CREATE INDEX idx_episodes_pub     ON episodes (language_code, kind, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_episodes_program ON episodes (program_id, published_at DESC);
CREATE INDEX idx_episodes_section ON episodes (section_id, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_episodes_country   ON episodes (country_code, published_at DESC)   WHERE status = 'published';
CREATE INDEX idx_episodes_continent ON episodes (continent_code, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_episodes_review_queue ON episodes (submitted_at) WHERE status = 'submitted';
CREATE INDEX idx_episodes_scheduled    ON episodes (scheduled_at) WHERE status = 'scheduled';
CREATE INDEX idx_episodes_youtube ON episodes (youtube_channel_id) WHERE youtube_channel_id IS NOT NULL;

CREATE TABLE episode_authors (
  episode_id uuid NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  author_id  uuid NOT NULL REFERENCES authors(id)  ON DELETE CASCADE,
  position   integer NOT NULL DEFAULT 0,
  PRIMARY KEY (episode_id, author_id)
);
CREATE INDEX idx_episode_authors_author ON episode_authors (author_id);

CREATE TABLE episode_tags (
  episode_id uuid    NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  tag_id     integer NOT NULL REFERENCES tags(id)     ON DELETE CASCADE,
  PRIMARY KEY (episode_id, tag_id)
);

CREATE TABLE live_streams (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id        uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  title             text NOT NULL,
  description       text,
  protocol          stream_protocol NOT NULL DEFAULT 'hls',
  stream_url        text NOT NULL,                 -- flux HLS, ou lien du direct YouTube
  external_id       text,                          -- identifiant de la vidéo YouTube en direct
  backup_url        text,
  thumbnail_url     text,
  is_primary        boolean NOT NULL DEFAULT false,   -- flux principal de la chaîne dans l'application
  status            stream_status NOT NULL DEFAULT 'offline',
  starts_at         timestamptz,
  ends_at           timestamptz,
  is_geo_restricted boolean NOT NULL DEFAULT false,
  allowed_countries char(2)[] NOT NULL DEFAULT '{}',   -- utilisé si is_geo_restricted
  requires_auth     boolean NOT NULL DEFAULT false,
  peak_viewers      integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX idx_live_streams_status  ON live_streams (status);
CREATE INDEX idx_live_streams_channel ON live_streams (channel_id, starts_at DESC);
CREATE UNIQUE INDEX uq_live_streams_primary ON live_streams (channel_id) WHERE is_primary;

-- Guide des programmes (EPG) : les créneaux d'une même chaîne ne peuvent pas se chevaucher
CREATE TABLE epg_entries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id    uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  program_id    uuid REFERENCES programs(id) ON DELETE SET NULL,
  title         text NOT NULL,
  description   text,
  category      text,
  age_rating    text,
  language_code text REFERENCES languages(code),
  starts_at     timestamptz NOT NULL,
  ends_at       timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at),
  EXCLUDE USING gist (channel_id WITH =, tstzrange(starts_at, ends_at) WITH &&)
);
CREATE INDEX idx_epg_channel_time ON epg_entries (channel_id, starts_at);

-- =====================================================================
-- 9. CONNECTEURS VERS D'AUTRES MÉDIAS
-- Un partenaire (média, chaîne TNT...) possède une ou plusieurs sources
-- (flux RSS, API JSON, XMLTV). Les éléments importés sont conservés
-- bruts puis transformés en articles ou en EPG.
-- =====================================================================

CREATE TABLE ingestion_sources (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id             uuid NOT NULL REFERENCES media_partners(id) ON DELETE CASCADE,
  name                   text NOT NULL,
  format                 ingest_format NOT NULL,
  endpoint_url           text,
  language_code          text REFERENCES languages(code),
  default_section_id     integer REFERENCES sections(id) ON DELETE SET NULL,
  default_country_code   char(2) REFERENCES countries(code),   -- pays attribué aux contenus importés
  channel_id             uuid REFERENCES channels(id) ON DELETE SET NULL,   -- pour les flux EPG
  config                 jsonb NOT NULL DEFAULT '{}',   -- en-têtes, mapping des champs...
  fetch_interval_minutes integer NOT NULL DEFAULT 15 CHECK (fetch_interval_minutes > 0),
  is_active              boolean NOT NULL DEFAULT true,
  last_fetched_at        timestamptz,
  last_error             text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ingestion_sources_due ON ingestion_sources (last_fetched_at) WHERE is_active;

CREATE TABLE ingested_items (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id   uuid NOT NULL REFERENCES ingestion_sources(id) ON DELETE CASCADE,
  external_id text NOT NULL,
  payload     jsonb NOT NULL,
  status      ingest_status NOT NULL DEFAULT 'pending',
  article_id  uuid REFERENCES articles(id) ON DELETE SET NULL,
  error       text,
  fetched_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, external_id)
);
CREATE INDEX idx_ingested_items_status ON ingested_items (status, fetched_at);

-- =====================================================================
-- 10. PAIEMENTS CASHPAY ET ACCÈS AUX CONTENUS PREMIUM
-- Flux : le lecteur veut lire un contenu premium -> on crée un paiement
-- « pending » -> on appelle CashPay (Hosted Checkout) -> le lecteur paie
-- -> CashPay prévient par webhook -> le paiement passe à « completed »
-- -> la base crée toute seule l'accès (access_grants).
-- =====================================================================

CREATE TABLE payments (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference              text NOT NULL UNIQUE,       -- notre référence de commande, envoyée à CashPay
  user_id                uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,   -- anonymiser plutôt que supprimer
  provider               text NOT NULL DEFAULT 'cashpay',
  content_type           text NOT NULL CHECK (content_type IN ('article', 'episode')),
  content_id             uuid NOT NULL,
  amount                 numeric(14,2) NOT NULL CHECK (amount > 0),
  currency               char(3) NOT NULL CHECK (currency = upper(currency)),
  status                 payment_status NOT NULL DEFAULT 'pending',
  description            text,
  payment_methods        text,                       -- ex. 'Card,MobileMoney,Wallet'
  cashpay_session_id     text UNIQUE,                -- sessionId renvoyé par le Hosted Checkout
  cashpay_transaction_id text UNIQUE,                -- identifiant de transaction reçu par webhook
  checkout_url           text,                       -- redirectUrl de la page de paiement CashPay
  failure_reason         text,
  paid_at                timestamptz,
  metadata               jsonb NOT NULL DEFAULT '{}',
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_payments_user    ON payments (user_id, created_at DESC);
CREATE INDEX idx_payments_content ON payments (content_type, content_id);
CREATE INDEX idx_payments_pending ON payments (created_at) WHERE status = 'pending';

-- Notifications reçues de CashPay, conservées telles quelles.
-- body_sha256 évite de traiter deux fois la même notification (CashPay réessaie pendant 24 h).
CREATE TABLE payment_webhook_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider        text NOT NULL DEFAULT 'cashpay',
  event           text,                              -- payment.succeeded, payment.failed
  payment_id      uuid REFERENCES payments(id) ON DELETE SET NULL,
  reference       text,
  signature_valid boolean NOT NULL,                  -- en-tête X-CashPay-Signature vérifié
  body_sha256     text NOT NULL UNIQUE,
  payload         jsonb NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz,
  error           text
);
CREATE INDEX idx_webhook_events_payment ON payment_webhook_events (payment_id);

-- Droit de lire un contenu premium : achat, cadeau de l'administrateur ou promotion
CREATE TABLE access_grants (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content_type text NOT NULL CHECK (content_type IN ('article', 'episode')),
  content_id   uuid NOT NULL,
  payment_id   uuid REFERENCES payments(id) ON DELETE SET NULL,
  source       text NOT NULL DEFAULT 'purchase' CHECK (source IN ('purchase', 'admin_gift', 'promo')),
  granted_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  granted_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz,                          -- NULL = accès illimité
  revoked_at   timestamptz,
  UNIQUE (user_id, content_type, content_id)
);
CREATE INDEX idx_access_grants_content ON access_grants (content_type, content_id);

-- =====================================================================
-- 11. LECTEURS : favoris, abonnements, commentaires
-- =====================================================================

CREATE TABLE bookmarks (
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, article_id)
);

CREATE TABLE section_follows (
  user_id    uuid    NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  section_id integer NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, section_id)
);

CREATE TABLE comments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  article_id   uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  parent_id    uuid REFERENCES comments(id) ON DELETE CASCADE,
  body         text NOT NULL CHECK (length(body) BETWEEN 1 AND 5000),
  status       comment_status NOT NULL DEFAULT 'pending',
  moderated_by uuid REFERENCES users(id) ON DELETE SET NULL,
  moderated_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_comments_article ON comments (article_id, created_at) WHERE status = 'approved';
CREATE INDEX idx_comments_status  ON comments (status, created_at);

-- =====================================================================
-- 12. APPLICATION MOBILE : appareils et notifications push
-- =====================================================================

CREATE TABLE devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES users(id) ON DELETE SET NULL,   -- NULL si lecteur anonyme
  platform      platform_kind NOT NULL,
  push_token    text UNIQUE,
  language_code text REFERENCES languages(code),
  country_code  char(2) REFERENCES countries(code),
  app_version   text,
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_devices_user ON devices (user_id);

CREATE TABLE device_section_subscriptions (
  device_id  uuid    NOT NULL REFERENCES devices(id)  ON DELETE CASCADE,
  section_id integer NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  PRIMARY KEY (device_id, section_id)
);

CREATE TABLE push_notifications (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title             text NOT NULL,
  body              text NOT NULL,
  article_id        uuid REFERENCES articles(id)     ON DELETE SET NULL,
  episode_id        uuid REFERENCES episodes(id)     ON DELETE SET NULL,
  live_stream_id    uuid REFERENCES live_streams(id) ON DELETE SET NULL,
  target_section_id integer REFERENCES sections(id)  ON DELETE SET NULL,
  language_code     text REFERENCES languages(code),
  status            notification_status NOT NULL DEFAULT 'draft',
  scheduled_at      timestamptz,
  sent_at           timestamptz,
  created_by        uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_push_due ON push_notifications (scheduled_at) WHERE status = 'scheduled';

-- =====================================================================
-- 13. MISE EN AVANT ÉDITORIALE (une, dossiers, playlists)
-- =====================================================================

CREATE TABLE collections (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug           text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('homepage_top', 'dossier', 'playlist', 'topic')),
  language_code  text NOT NULL REFERENCES languages(code),
  title          text NOT NULL,
  description    text,
  cover_media_id uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  is_active      boolean NOT NULL DEFAULT true,
  starts_at      timestamptz,
  ends_at        timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug)
);

CREATE TABLE collection_items (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  collection_id  uuid NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  position       integer NOT NULL DEFAULT 0,
  article_id     uuid REFERENCES articles(id)     ON DELETE CASCADE,
  episode_id     uuid REFERENCES episodes(id)     ON DELETE CASCADE,
  live_stream_id uuid REFERENCES live_streams(id) ON DELETE CASCADE,
  CHECK (num_nonnulls(article_id, episode_id, live_stream_id) = 1)
);
CREATE INDEX idx_collection_items_collection ON collection_items (collection_id, position);

-- =====================================================================
-- 14. STATISTIQUES D'AUDIENCE
-- (à partitionner par mois si le volume devient important)
-- =====================================================================

CREATE TABLE content_views (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content_type text NOT NULL CHECK (content_type IN ('article', 'episode', 'live')),
  content_id   uuid NOT NULL,
  user_id      uuid REFERENCES users(id)   ON DELETE SET NULL,
  device_id    uuid REFERENCES devices(id) ON DELETE SET NULL,
  country_code char(2),
  viewed_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_content_views_content ON content_views (content_type, content_id, viewed_at DESC);
CREATE INDEX idx_content_views_time    ON content_views (viewed_at DESC);

-- =====================================================================
-- 15. FONCTIONS MÉTIER (dépendent des tables ci-dessus)
-- =====================================================================

CREATE OR REPLACE FUNCTION user_has_role(p_user uuid, p_role user_role) RETURNS boolean AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = p_user AND role = p_role);
$$ LANGUAGE sql STABLE;

-- Début d'un texte coupé proprement, sans couper un mot
CREATE OR REPLACE FUNCTION text_preview(p_body text, p_chars integer) RETURNS text AS $$
  SELECT CASE
    WHEN p_body IS NULL OR length(p_body) <= p_chars THEN p_body
    ELSE regexp_replace(left(p_body, p_chars), '\s+\S*$', '') || '…'
  END;
$$ LANGUAGE sql IMMUTABLE;

-- Le lecteur a-t-il le droit de voir le contenu complet ?
--   * contenu gratuit : oui
--   * équipe du site (tout rôle) : oui
--   * lecteur avec un achat valide (non remboursé, non expiré) : oui
-- p_user NULL = visiteur anonyme.
CREATE OR REPLACE FUNCTION user_has_access(p_user uuid, p_content_type text, p_content_id uuid)
RETURNS boolean AS $$
  SELECT COALESCE(
           CASE p_content_type
             WHEN 'article' THEN (SELECT a.access_level = 'free' FROM articles a WHERE a.id = p_content_id)
             WHEN 'episode' THEN (SELECT e.access_level = 'free' FROM episodes e WHERE e.id = p_content_id)
           END, false)
      OR (
           p_user IS NOT NULL
           AND EXISTS (SELECT 1 FROM users u WHERE u.id = p_user AND u.status = 'active')
           AND (
             EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = p_user)
             OR EXISTS (
               SELECT 1 FROM access_grants g
                WHERE g.user_id = p_user
                  AND g.content_type = p_content_type
                  AND g.content_id = p_content_id
                  AND g.revoked_at IS NULL
                  AND (g.expires_at IS NULL OR g.expires_at > now()))
           )
         );
$$ LANGUAGE sql STABLE;

-- Texte d'un article à envoyer à ce lecteur : complet ou extrait.
-- À utiliser pour la page de l'article : le contenu premium ne part jamais sans passer par ici.
CREATE OR REPLACE FUNCTION article_content_for(p_article uuid, p_user uuid DEFAULT NULL)
RETURNS TABLE (is_locked boolean, content text) AS $$
DECLARE
  a articles%ROWTYPE;
  n integer;
BEGIN
  SELECT * INTO a FROM articles WHERE id = p_article;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF user_has_access(p_user, 'article', p_article) THEN
    RETURN QUERY SELECT false, a.body;
    RETURN;
  END IF;

  SELECT (value #>> '{}')::integer INTO n FROM site_settings WHERE key = 'premium_preview_chars';
  n := COALESCE(n, 600);
  -- l'extrait ne dépasse jamais la moitié du texte, pour ne pas livrer un article court en entier
  n := LEAST(n, GREATEST(length(a.body) / 2, 1));
  RETURN QUERY SELECT true, COALESCE(a.preview_body, text_preview(a.body, n));
END;
$$ LANGUAGE plpgsql STABLE;

-- Média d'un épisode à envoyer à ce lecteur : vidéo complète, ou bande-annonce
-- (et durée d'aperçu gratuite) si le contenu est premium et non acheté.
CREATE OR REPLACE FUNCTION episode_media_for(p_episode uuid, p_user uuid DEFAULT NULL)
RETURNS TABLE (is_locked boolean, media_id uuid, preview_seconds integer) AS $$
  SELECT NOT x.ok,
         CASE WHEN x.ok THEN e.media_id ELSE e.trailer_media_id END,
         CASE WHEN x.ok THEN NULL ELSE e.preview_seconds END
    FROM episodes e
   CROSS JOIN LATERAL (SELECT user_has_access(p_user, 'episode', e.id) AS ok) x
   WHERE e.id = p_episode;
$$ LANGUAGE sql STABLE;

-- Levée automatique des suspensions arrivées à échéance (tâche planifiée)
CREATE OR REPLACE FUNCTION lift_expired_suspensions() RETURNS integer AS $$
DECLARE
  n integer;
BEGIN
  UPDATE users SET status = 'active'
   WHERE status = 'suspended' AND suspended_until IS NOT NULL AND suspended_until <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql;

-- Publie les articles et épisodes programmés dont l'heure est arrivée.
-- À appeler toutes les minutes depuis une tâche planifiée du back-end.
CREATE OR REPLACE FUNCTION publish_scheduled_content() RETURNS integer AS $$
DECLARE
  n_articles integer;
  n_episodes integer;
BEGIN
  UPDATE articles
     SET status = 'published', published_at = COALESCE(published_at, scheduled_at)
   WHERE status = 'scheduled' AND scheduled_at <= now();
  GET DIAGNOSTICS n_articles = ROW_COUNT;

  UPDATE episodes
     SET status = 'published', published_at = COALESCE(published_at, scheduled_at)
   WHERE status = 'scheduled' AND scheduled_at <= now();
  GET DIAGNOSTICS n_episodes = ROW_COUNT;

  RETURN n_articles + n_episodes;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- 16. RÈGLES AUTOMATIQUES (triggers)
-- =====================================================================

-- ---- Circuit de publication : articles et épisodes ------------------
-- * un nouveau contenu commence toujours en brouillon
-- * seules les transitions de workflow_transitions sont possibles, et seulement
--   par un utilisateur qui a l'un des rôles autorisés
-- * le contenu doit avoir au moins un auteur pour être soumis (signature)
-- * la personne qui vérifie n'est ni l'auteur ni celui qui a soumis (réglage require_four_eyes)
-- * une demande de corrections doit être expliquée
-- * chaque étape est enregistrée dans content_workflow_events
CREATE OR REPLACE FUNCTION content_workflow_guard() RETURNS trigger AS $$
DECLARE
  actor      uuid := current_actor();
  ctype      text := CASE TG_TABLE_NAME WHEN 'articles' THEN 'article' ELSE 'episode' END;
  cmt        text := nullif(current_setting('app.workflow_comment', true), '');
  roles      user_role[];
  has_author boolean;
  is_author  boolean;
  four_eyes  boolean;
BEGIN
  IF workflow_bypass() THEN
    RETURN NEW;
  END IF;

  IF actor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE id = actor AND status = 'active') THEN
    RAISE EXCEPTION 'Compte suspendu ou bloqué : action refusée' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'Un nouveau contenu doit commencer en brouillon (statut demandé : %)', NEW.status
        USING ERRCODE = '23514';
    END IF;
    NEW.created_by := COALESCE(NEW.created_by, actor);
    INSERT INTO content_workflow_events (content_type, content_id, from_status, to_status, actor_id)
    VALUES (ctype, NEW.id, NULL, NEW.status, NEW.created_by);
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT array_agg(role) INTO roles
    FROM workflow_transitions
   WHERE from_status = OLD.status AND to_status = NEW.status;

  IF roles IS NULL THEN
    RAISE EXCEPTION 'Passage interdit : % vers %', OLD.status, NEW.status USING ERRCODE = '23514';
  END IF;

  IF actor IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = actor AND role = ANY (roles)) THEN
    RAISE EXCEPTION 'Droits insuffisants pour passer de % à % (rôles requis : %)', OLD.status, NEW.status, roles
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status IN ('submitted', 'approved', 'scheduled', 'published') THEN
    IF TG_TABLE_NAME = 'articles' THEN
      has_author := EXISTS (SELECT 1 FROM article_authors WHERE article_id = NEW.id);
    ELSE
      has_author := EXISTS (SELECT 1 FROM episode_authors WHERE episode_id = NEW.id);
    END IF;
    IF NOT has_author THEN
      RAISE EXCEPTION 'Au moins un auteur est requis pour signer le contenu' USING ERRCODE = '23514';
    END IF;
  END IF;

  -- Classement obligatoire avant la soumission : catégorie (domaine) et lieu (pays, continent ou monde)
  IF NEW.status = 'submitted' THEN
    IF NEW.section_id IS NULL THEN
      RAISE EXCEPTION 'Choisissez la catégorie (domaine) du contenu avant de le soumettre' USING ERRCODE = '23514';
    END IF;
    IF (NEW.geo_scope = 'country'   AND NEW.country_code   IS NULL)
    OR (NEW.geo_scope = 'continent' AND NEW.continent_code IS NULL) THEN
      RAISE EXCEPTION 'Choisissez le pays concerné (ou le continent, ou « monde ») avant de soumettre'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.status = 'changes_requested' AND actor IS NOT NULL AND cmt IS NULL THEN
    RAISE EXCEPTION 'Un commentaire est obligatoire pour demander des corrections' USING ERRCODE = '23514';
  END IF;

  -- Principe des quatre yeux : celui qui vérifie n'est pas celui qui a écrit ou soumis
  IF actor IS NOT NULL AND OLD.status = 'submitted' AND NEW.status IN ('approved', 'changes_requested') THEN
    SELECT (value #>> '{}')::boolean INTO four_eyes FROM site_settings WHERE key = 'require_four_eyes';
    IF COALESCE(four_eyes, true) THEN
      is_author := NEW.created_by = actor OR OLD.submitted_by = actor;
      IF NOT is_author THEN
        IF TG_TABLE_NAME = 'articles' THEN
          is_author := EXISTS (
            SELECT 1 FROM article_authors aa JOIN authors au ON au.id = aa.author_id
             WHERE aa.article_id = NEW.id AND au.user_id = actor);
        ELSE
          is_author := EXISTS (
            SELECT 1 FROM episode_authors ea JOIN authors au ON au.id = ea.author_id
             WHERE ea.episode_id = NEW.id AND au.user_id = actor);
        END IF;
      END IF;
      IF is_author THEN
        RAISE EXCEPTION 'Un contenu doit être vérifié par une autre personne que son auteur ou celui qui l''a soumis'
          USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;

  IF NEW.status = 'submitted' THEN
    NEW.submitted_by := COALESCE(actor, NEW.submitted_by);
    NEW.submitted_at := now();
    NEW.approved_by  := NULL;
    NEW.approved_at  := NULL;
  ELSIF NEW.status = 'approved' AND OLD.status = 'submitted' THEN
    NEW.approved_by := COALESCE(actor, NEW.approved_by);
    NEW.approved_at := now();
  ELSIF NEW.status = 'published' THEN
    NEW.published_by := COALESCE(actor, NEW.published_by, NEW.approved_by);
    NEW.published_at := COALESCE(NEW.published_at, now());
  END IF;

  INSERT INTO content_workflow_events (content_type, content_id, from_status, to_status, actor_id, comment)
  VALUES (ctype, NEW.id, OLD.status, NEW.status, actor, cmt);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_articles_workflow
  BEFORE INSERT OR UPDATE OF status ON articles
  FOR EACH ROW EXECUTE FUNCTION content_workflow_guard();

CREATE TRIGGER trg_episodes_workflow
  BEFORE INSERT OR UPDATE OF status ON episodes
  FOR EACH ROW EXECUTE FUNCTION content_workflow_guard();

-- L'auteur connecté qui crée un contenu en devient automatiquement le signataire
CREATE OR REPLACE FUNCTION default_content_author() RETURNS trigger AS $$
DECLARE
  actor uuid := current_actor();
  aid   uuid;
BEGIN
  IF actor IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT id INTO aid FROM authors WHERE user_id = actor;
  IF aid IS NULL THEN
    RETURN NULL;
  END IF;
  IF TG_TABLE_NAME = 'articles' THEN
    INSERT INTO article_authors (article_id, author_id, position) VALUES (NEW.id, aid, 0)
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO episode_authors (episode_id, author_id, position) VALUES (NEW.id, aid, 0)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_articles_default_author
  AFTER INSERT ON articles
  FOR EACH ROW EXECUTE FUNCTION default_content_author();

CREATE TRIGGER trg_episodes_default_author
  AFTER INSERT ON episodes
  FOR EACH ROW EXECUTE FUNCTION default_content_author();

-- ---- Lieu du contenu : le continent se déduit du pays ----------------
--   * portée « pays »      : le continent est celui du pays choisi
--   * portée « continent » : on choisit le continent, pas de pays
--   * portée « monde »     : ni pays ni continent
CREATE OR REPLACE FUNCTION content_geo_guard() RETURNS trigger AS $$
BEGIN
  IF NEW.geo_scope = 'world' THEN
    NEW.country_code   := NULL;
    NEW.continent_code := NULL;
  ELSIF NEW.geo_scope = 'continent' THEN
    NEW.country_code := NULL;
  ELSIF NEW.country_code IS NOT NULL THEN
    SELECT continent_code INTO NEW.continent_code FROM countries WHERE code = NEW.country_code;
  ELSE
    NEW.continent_code := NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Les triggers se déclenchent dans l'ordre alphabétique : « geo » passe avant « workflow »
CREATE TRIGGER trg_articles_geo
  BEFORE INSERT OR UPDATE OF geo_scope, country_code, continent_code ON articles
  FOR EACH ROW EXECUTE FUNCTION content_geo_guard();

CREATE TRIGGER trg_episodes_geo
  BEFORE INSERT OR UPDATE OF geo_scope, country_code, continent_code ON episodes
  FOR EACH ROW EXECUTE FUNCTION content_geo_guard();

-- Si l'administrateur change un pays de continent, ses contenus suivent
CREATE OR REPLACE FUNCTION countries_continent_changed() RETURNS trigger AS $$
BEGIN
  UPDATE articles SET continent_code = NEW.continent_code
   WHERE country_code = NEW.code AND geo_scope = 'country';
  UPDATE episodes SET continent_code = NEW.continent_code
   WHERE country_code = NEW.code AND geo_scope = 'country';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_countries_continent
  AFTER UPDATE OF continent_code ON countries
  FOR EACH ROW WHEN (OLD.continent_code IS DISTINCT FROM NEW.continent_code)
  EXECUTE FUNCTION countries_continent_changed();

-- ---- Monétisation : réservée à l'administrateur ---------------------
CREATE OR REPLACE FUNCTION monetization_guard() RETURNS trigger AS $$
DECLARE
  actor uuid := current_actor();
BEGIN
  IF workflow_bypass() OR actor IS NULL THEN
    RETURN NEW;
  END IF;

  IF (TG_OP = 'INSERT' AND (NEW.access_level <> 'free' OR NEW.price_amount IS NOT NULL))
     OR (TG_OP = 'UPDATE' AND (NEW.access_level, NEW.price_amount, NEW.price_currency)
                              IS DISTINCT FROM (OLD.access_level, OLD.price_amount, OLD.price_currency)) THEN
    IF NOT user_has_role(actor, 'admin') THEN
      RAISE EXCEPTION 'Seul un administrateur peut rendre un contenu premium ou modifier son prix'
        USING ERRCODE = '42501';
    END IF;
    NEW.access_changed_by := actor;
    NEW.access_changed_at := now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_articles_monetization
  BEFORE INSERT OR UPDATE OF access_level, price_amount, price_currency ON articles
  FOR EACH ROW EXECUTE FUNCTION monetization_guard();

CREATE TRIGGER trg_episodes_monetization
  BEFORE INSERT OR UPDATE OF access_level, price_amount, price_currency ON episodes
  FOR EACH ROW EXECUTE FUNCTION monetization_guard();

-- ---- Comptes : blocage réservé à l'administrateur --------------------
CREATE OR REPLACE FUNCTION users_status_guard() RETURNS trigger AS $$
DECLARE
  actor uuid := current_actor();
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF actor IS NOT NULL AND NOT workflow_bypass() THEN
    IF NOT user_has_role(actor, 'admin') THEN
      RAISE EXCEPTION 'Seul un administrateur peut suspendre, bloquer ou réactiver un compte'
        USING ERRCODE = '42501';
    END IF;
    IF actor = NEW.id AND NEW.status <> 'active' THEN
      RAISE EXCEPTION 'Un administrateur ne peut pas bloquer son propre compte' USING ERRCODE = '42501';
    END IF;
  END IF;

  NEW.status_changed_by := COALESCE(actor, NEW.status_changed_by);
  NEW.status_changed_at := now();

  IF NEW.status = 'active' THEN
    NEW.suspended_until := NULL;
  ELSE
    -- le compte est déconnecté partout
    UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = NEW.id AND revoked_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_status
  BEFORE UPDATE OF status ON users
  FOR EACH ROW EXECUTE FUNCTION users_status_guard();

-- ---- Rôles : attribution réservée à l'administrateur -----------------
-- * donner le rôle « author » crée le profil public de signature
-- * on ne peut pas retirer le dernier administrateur
CREATE OR REPLACE FUNCTION user_roles_guard() RETURNS trigger AS $$
DECLARE
  actor uuid := current_actor();
BEGIN
  IF actor IS NOT NULL AND NOT workflow_bypass() AND NOT user_has_role(actor, 'admin') THEN
    RAISE EXCEPTION 'Seul un administrateur peut attribuer ou retirer des rôles' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.role = 'admin'
       AND NOT EXISTS (SELECT 1 FROM user_roles WHERE role = 'admin' AND user_id <> OLD.user_id) THEN
      RAISE EXCEPTION 'Impossible de retirer le dernier administrateur' USING ERRCODE = '23514';
    END IF;
    RETURN OLD;
  END IF;

  NEW.granted_by := COALESCE(NEW.granted_by, actor);

  IF NEW.role = 'author' THEN
    INSERT INTO authors (user_id, name, slug)
    SELECT u.id,
           u.display_name,
           trim(both '-' FROM lower(regexp_replace(unaccent(u.display_name), '[^a-zA-Z0-9]+', '-', 'g')))
             || '-' || substr(u.id::text, 1, 6)
      FROM users u
     WHERE u.id = NEW.user_id
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_user_roles_guard
  BEFORE INSERT OR DELETE ON user_roles
  FOR EACH ROW EXECUTE FUNCTION user_roles_guard();

-- ---- Paiements : statut final, accès créé automatiquement ------------
CREATE OR REPLACE FUNCTION payments_status_effects() RETURNS trigger AS $$
DECLARE
  days integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' AND NOT workflow_bypass() THEN
      RAISE EXCEPTION 'Un paiement doit être créé au statut pending' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- un paiement réussi ne peut plus que être remboursé ; un remboursement est définitif
  IF OLD.status = 'refunded' OR (OLD.status = 'completed' AND NEW.status <> 'refunded') THEN
    RAISE EXCEPTION 'Le paiement % ne peut pas passer de % à %', OLD.reference, OLD.status, NEW.status
      USING ERRCODE = '23514';
  END IF;

  IF NEW.status = 'completed' THEN
    NEW.paid_at := COALESCE(NEW.paid_at, now());
    SELECT (value #>> '{}')::integer INTO days FROM site_settings WHERE key = 'purchase_access_days';
    INSERT INTO access_grants (user_id, content_type, content_id, payment_id, source, expires_at)
    VALUES (NEW.user_id, NEW.content_type, NEW.content_id, NEW.id, 'purchase',
            CASE WHEN days IS NULL THEN NULL ELSE now() + make_interval(days => days) END)
    ON CONFLICT (user_id, content_type, content_id) DO UPDATE
      SET payment_id = EXCLUDED.payment_id,
          source     = 'purchase',
          granted_at = now(),
          expires_at = EXCLUDED.expires_at,
          revoked_at = NULL;
  ELSIF NEW.status = 'refunded' THEN
    UPDATE access_grants SET revoked_at = now() WHERE payment_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_status
  BEFORE INSERT OR UPDATE OF status ON payments
  FOR EACH ROW EXECUTE FUNCTION payments_status_effects();

-- ---- updated_at automatique ------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'users', 'api_clients', 'authors', 'sections', 'media_assets', 'articles',
    'channels', 'youtube_channels', 'live_streams', 'programs', 'episodes',
    'media_partners', 'ingestion_sources', 'payments', 'comments', 'collections'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON %1$I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t);
  END LOOP;
END $$;

-- =====================================================================
-- 17. VUES POUR L'API
-- Les vues publiques n'exposent jamais le texte complet ni l'adresse de la
-- vidéo : pour cela, passer par article_content_for() et episode_media_for().
-- =====================================================================

-- Articles visibles par le public, avec la signature (auteurs)
CREATE VIEW v_published_articles AS
SELECT a.id, a.translation_group_id, a.language_code, a.kind, a.title, a.slug,
       a.subtitle, a.summary, a.cover_media_id, a.section_id,
       a.geo_scope, a.country_code, a.continent_code, a.published_at,
       a.is_breaking, a.is_featured, a.allow_comments, a.reading_time_min,
       a.view_count, a.source_name, a.access_level, a.price_amount, a.price_currency,
       a.created_at, a.updated_at,
       (SELECT jsonb_agg(jsonb_build_object('id', au.id, 'name', au.name, 'slug', au.slug,
                                            'photo_url', au.photo_url) ORDER BY aa.position)
          FROM article_authors aa JOIN authors au ON au.id = aa.author_id
         WHERE aa.article_id = a.id) AS authors
  FROM articles a
 WHERE a.status = 'published' AND a.published_at <= now();

-- Épisodes (vidéos et audios) visibles par le public, avec la signature
CREATE VIEW v_published_episodes AS
SELECT e.id, e.program_id, e.language_code, e.kind, e.title, e.slug, e.description,
       e.section_id, e.geo_scope, e.country_code, e.continent_code,
       e.article_id, e.published_at, e.season, e.episode_number,
       e.duration_seconds, e.view_count, e.access_level, e.price_amount, e.price_currency,
       e.preview_seconds, e.youtube_channel_id, e.created_at, e.updated_at,
       (SELECT m.thumbnail_url FROM media_assets m WHERE m.id = e.media_id) AS thumbnail_url,
       (SELECT jsonb_agg(jsonb_build_object('id', au.id, 'name', au.name, 'slug', au.slug,
                                            'photo_url', au.photo_url) ORDER BY ea.position)
          FROM episode_authors ea JOIN authors au ON au.id = ea.author_id
         WHERE ea.episode_id = e.id) AS authors
  FROM episodes e
 WHERE e.status = 'published' AND e.published_at <= now();

-- Lives en cours, avec les informations de la chaîne
CREATE VIEW v_live_now AS
SELECT ls.*,
       c.slug      AS channel_slug,
       c.name      AS channel_name,
       c.kind      AS channel_kind,
       c.ownership AS channel_ownership,
       c.logo_url  AS channel_logo_url
  FROM live_streams ls
  JOIN channels c ON c.id = ls.channel_id
 WHERE ls.status = 'live' AND c.is_active;

-- File d'attente des relecteurs : contenus soumis, en attente de vérification
CREATE VIEW v_review_queue AS
SELECT 'article'::text AS content_type, a.id, a.title, a.language_code,
       a.submitted_by, a.submitted_at, a.reviewer_id
  FROM articles a WHERE a.status = 'submitted'
UNION ALL
SELECT 'episode', e.id, e.title, e.language_code,
       e.submitted_by, e.submitted_at, e.reviewer_id
  FROM episodes e WHERE e.status = 'submitted';

-- File d'attente des publicateurs : contenus vérifiés, prêts à être publiés
CREATE VIEW v_publish_queue AS
SELECT 'article'::text AS content_type, a.id, a.title, a.language_code,
       a.approved_by, a.approved_at, a.scheduled_at
  FROM articles a WHERE a.status IN ('approved', 'scheduled')
UNION ALL
SELECT 'episode', e.id, e.title, e.language_code,
       e.approved_by, e.approved_at, e.scheduled_at
  FROM episodes e WHERE e.status IN ('approved', 'scheduled');

-- Nom d'un continent, d'un pays ou d'une catégorie dans la langue demandée
-- (français par défaut, anglais, ou traduction du champ `names`)
CREATE OR REPLACE FUNCTION localized_name(p_names jsonb, p_fr text, p_en text, p_lang text)
RETURNS text AS $$
  SELECT COALESCE(p_names ->> p_lang, CASE WHEN p_lang = 'en' THEN p_en ELSE p_fr END);
$$ LANGUAGE sql IMMUTABLE;

-- Pays avec leur continent (formulaire de publication, filtres de l'application)
CREATE VIEW v_countries AS
SELECT c.code, c.name_fr, c.name_en, c.names, c.continent_code,
       k.name_fr AS continent_name_fr, k.name_en AS continent_name_en,
       k.position AS continent_position
  FROM countries c
  JOIN continents k ON k.code = c.continent_code
 WHERE c.is_active AND k.is_active;

-- Arbre complet « continent > pays » en un seul appel, dans la langue demandée :
--   SELECT geo_tree('fr');
--   -> [{"code":"afrique","name":"Afrique","countries":[{"code":"CD","name":"RD Congo"}, ...]}, ...]
CREATE OR REPLACE FUNCTION geo_tree(p_lang text DEFAULT 'fr') RETURNS jsonb AS $$
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'code', k.code,
             'name', localized_name(k.names, k.name_fr, k.name_en, p_lang),
             'countries', (
               SELECT COALESCE(jsonb_agg(
                        jsonb_build_object('code', c.code,
                                           'name', localized_name(c.names, c.name_fr, c.name_en, p_lang))
                        ORDER BY localized_name(c.names, c.name_fr, c.name_en, p_lang)), '[]'::jsonb)
                 FROM countries c
                WHERE c.continent_code = k.code AND c.is_active))
           ORDER BY k.position), '[]'::jsonb)
    FROM continents k
   WHERE k.is_active;
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- 18. RÈGLES DU CIRCUIT DE PUBLICATION (qui peut faire quoi)
-- =====================================================================
INSERT INTO workflow_transitions (from_status, to_status, role)
SELECT v.f::content_status, v.t::content_status, r.role::user_role
  FROM (VALUES
    -- l'auteur soumet son travail
    ('draft',             'submitted',         ARRAY['author', 'reviewer', 'publisher', 'admin']),
    ('draft',             'archived',          ARRAY['publisher', 'admin']),
    ('submitted',         'draft',             ARRAY['author', 'admin']),
    -- un relecteur vérifie : il valide ou demande des corrections
    ('submitted',         'approved',          ARRAY['reviewer', 'publisher', 'admin']),
    ('submitted',         'changes_requested', ARRAY['reviewer', 'publisher', 'admin']),
    ('changes_requested', 'submitted',         ARRAY['author', 'reviewer', 'publisher', 'admin']),
    ('changes_requested', 'draft',             ARRAY['author', 'admin']),
    ('changes_requested', 'archived',          ARRAY['publisher', 'admin']),
    -- un publicateur met en ligne ce qui a été vérifié
    ('approved',          'published',         ARRAY['publisher', 'admin']),
    ('approved',          'scheduled',         ARRAY['publisher', 'admin']),
    ('approved',          'changes_requested', ARRAY['publisher', 'admin']),
    ('approved',          'archived',          ARRAY['publisher', 'admin']),
    ('scheduled',         'published',         ARRAY['publisher', 'admin']),
    ('scheduled',         'approved',          ARRAY['publisher', 'admin']),
    ('scheduled',         'archived',          ARRAY['publisher', 'admin']),
    -- retrait de la publication
    ('published',         'approved',          ARRAY['publisher', 'admin']),
    ('published',         'archived',          ARRAY['publisher', 'admin']),
    ('archived',          'draft',             ARRAY['publisher', 'admin'])
  ) AS v(f, t, roles)
  CROSS JOIN LATERAL unnest(v.roles) AS r(role);

COMMIT;
