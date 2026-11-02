-- =====================================================================
-- News Platform : schéma PostgreSQL
-- Plateforme d'actualité média (type RFI / France 24) :
--   * articles multilingues, rubriques, tags, auteurs
--   * vidéos et audios (émissions, épisodes, podcasts)
--   * chaînes (TV, radio, TNT), lives et guide des programmes (EPG)
--   * connecteurs vers d'autres médias (flux RSS, API, XMLTV)
--   * application Android : appareils, notifications push, favoris
--   * accès API (clés pour l'app mobile et les partenaires)
--
-- Utilisation :  psql "$DATABASE_URL" -f db/schema.sql
-- Les données de base (langues, pays, rubriques) sont dans db/seed.sql
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
CREATE TYPE user_role           AS ENUM ('admin', 'editor', 'journalist', 'moderator', 'reader');
CREATE TYPE content_status      AS ENUM ('draft', 'in_review', 'scheduled', 'published', 'archived');
CREATE TYPE article_kind        AS ENUM ('article', 'brief', 'dossier', 'reportage', 'interview', 'opinion', 'live_blog');
CREATE TYPE media_kind          AS ENUM ('image', 'video', 'audio', 'document');
CREATE TYPE episode_kind        AS ENUM ('video', 'audio');
CREATE TYPE channel_kind        AS ENUM ('tv', 'radio', 'tnt', 'web');
CREATE TYPE stream_protocol     AS ENUM ('hls', 'dash', 'rtmp', 'rtsp', 'youtube', 'other');
CREATE TYPE stream_status       AS ENUM ('scheduled', 'live', 'ended', 'offline');
CREATE TYPE comment_status      AS ENUM ('pending', 'approved', 'rejected', 'spam');
CREATE TYPE platform_kind       AS ENUM ('android', 'ios', 'web');
CREATE TYPE ingest_format       AS ENUM ('rss', 'atom', 'json_api', 'xmltv', 'manual');
CREATE TYPE ingest_status       AS ENUM ('pending', 'imported', 'skipped', 'failed');
CREATE TYPE notification_status AS ENUM ('draft', 'scheduled', 'sent', 'failed');

-- ---------------------------------------------------------------------
-- Fonction générique : mise à jour automatique de updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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

CREATE TABLE countries (
  code      char(2) PRIMARY KEY CHECK (code = upper(code)),
  name_fr   text NOT NULL,
  name_en   text NOT NULL,
  continent text
);

-- =====================================================================
-- 2. UTILISATEURS, SESSIONS, ACCÈS API
-- =====================================================================

CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email             citext NOT NULL UNIQUE,
  password_hash     text,                                  -- NULL si connexion sociale
  display_name      text NOT NULL,
  role              user_role NOT NULL DEFAULT 'reader',
  language_code     text REFERENCES languages(code),
  avatar_url        text,
  is_active         boolean NOT NULL DEFAULT true,
  email_verified_at timestamptz,
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

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

-- Journal d'audit des actions de la rédaction
CREATE TABLE audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  action      text NOT NULL,                  -- ex. 'article.publish'
  entity_type text NOT NULL,
  entity_id   text,
  changes     jsonb,
  ip          inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_entity ON audit_log (entity_type, entity_id);
CREATE INDEX idx_audit_log_user   ON audit_log (user_id, created_at DESC);

-- =====================================================================
-- 3. RÉDACTION : auteurs, rubriques, tags
-- =====================================================================

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
-- =====================================================================

CREATE TABLE media_assets (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind             media_kind NOT NULL,
  storage_key      text,                         -- chemin dans le stockage (S3, disque...)
  url              text NOT NULL,                -- fichier source ou principal
  hls_url          text,                         -- flux adaptatif pour les vidéos
  thumbnail_url    text,
  mime_type        text,
  size_bytes       bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  width            integer,
  height           integer,
  duration_seconds integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  alt_text         text,
  caption          text,
  credit           text,
  metadata         jsonb NOT NULL DEFAULT '{}',
  uploaded_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_media_assets_kind ON media_assets (kind, created_at DESC);

-- Sous-titres des vidéos, une ligne par langue
CREATE TABLE media_subtitles (
  media_id      uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
  language_code text NOT NULL REFERENCES languages(code),
  url           text NOT NULL,
  PRIMARY KEY (media_id, language_code)
);

-- =====================================================================
-- 5. ARTICLES
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
  body                 text NOT NULL DEFAULT '',  -- contenu (Markdown ou HTML)
  cover_media_id       uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  section_id           integer REFERENCES sections(id) ON DELETE SET NULL,
  status               content_status NOT NULL DEFAULT 'draft',
  published_at         timestamptz,
  scheduled_at         timestamptz,
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
  CONSTRAINT articles_published_has_date  CHECK (status <> 'published' OR published_at IS NOT NULL),
  CONSTRAINT articles_scheduled_has_date  CHECK (status <> 'scheduled' OR scheduled_at IS NOT NULL)
);

CREATE INDEX idx_articles_lang_pub     ON articles (language_code, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_articles_section_pub  ON articles (section_id, published_at DESC)    WHERE status = 'published';
CREATE INDEX idx_articles_status       ON articles (status, updated_at DESC);
CREATE INDEX idx_articles_breaking     ON articles (published_at DESC) WHERE status = 'published' AND is_breaking;
CREATE INDEX idx_articles_featured     ON articles (published_at DESC) WHERE status = 'published' AND is_featured;
CREATE INDEX idx_articles_scheduled    ON articles (scheduled_at)      WHERE status = 'scheduled';
CREATE INDEX idx_articles_group        ON articles (translation_group_id);
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
-- 6. CHAÎNES, LIVES ET GUIDE DES PROGRAMMES (TV, radio, TNT)
-- =====================================================================

CREATE TABLE channels (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text NOT NULL UNIQUE,
  name          text NOT NULL,
  kind          channel_kind NOT NULL,
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

CREATE TABLE live_streams (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id        uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  title             text NOT NULL,
  description       text,
  protocol          stream_protocol NOT NULL DEFAULT 'hls',
  stream_url        text NOT NULL,
  backup_url        text,
  thumbnail_url     text,
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

-- Émissions (programmes récurrents) et leurs épisodes
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
-- est un épisode avec program_id NULL.
CREATE TABLE episodes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id       uuid REFERENCES programs(id) ON DELETE SET NULL,
  language_code    text NOT NULL REFERENCES languages(code),
  kind             episode_kind NOT NULL,
  title            text NOT NULL,
  slug             text NOT NULL,
  description      text,
  media_id         uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  section_id       integer REFERENCES sections(id) ON DELETE SET NULL,
  article_id       uuid REFERENCES articles(id) ON DELETE SET NULL,   -- article lié éventuel
  status           content_status NOT NULL DEFAULT 'draft',
  published_at      timestamptz,
  season           integer,
  episode_number   integer,
  duration_seconds integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  view_count       bigint NOT NULL DEFAULT 0,
  created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, slug),
  CONSTRAINT episodes_published_has_date CHECK (status <> 'published' OR published_at IS NOT NULL)
);
CREATE INDEX idx_episodes_pub     ON episodes (language_code, kind, published_at DESC) WHERE status = 'published';
CREATE INDEX idx_episodes_program ON episodes (program_id, published_at DESC);
CREATE INDEX idx_episodes_section ON episodes (section_id, published_at DESC) WHERE status = 'published';

CREATE TABLE episode_tags (
  episode_id uuid    NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  tag_id     integer NOT NULL REFERENCES tags(id)     ON DELETE CASCADE,
  PRIMARY KEY (episode_id, tag_id)
);

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
-- 7. CONNECTEURS VERS D'AUTRES MÉDIAS
-- Un partenaire (média, chaîne TNT...) possède une ou plusieurs sources
-- (flux RSS, API JSON, XMLTV). Les éléments importés sont conservés
-- bruts puis transformés en articles ou en EPG.
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

CREATE TABLE ingestion_sources (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id             uuid NOT NULL REFERENCES media_partners(id) ON DELETE CASCADE,
  name                   text NOT NULL,
  format                 ingest_format NOT NULL,
  endpoint_url           text,
  language_code          text REFERENCES languages(code),
  default_section_id     integer REFERENCES sections(id) ON DELETE SET NULL,
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
-- 8. LECTEURS : favoris, abonnements, commentaires
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
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  parent_id  uuid REFERENCES comments(id) ON DELETE CASCADE,
  body       text NOT NULL CHECK (length(body) BETWEEN 1 AND 5000),
  status     comment_status NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_comments_article ON comments (article_id, created_at) WHERE status = 'approved';
CREATE INDEX idx_comments_status  ON comments (status, created_at);

-- =====================================================================
-- 9. APPLICATION MOBILE : appareils et notifications push
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
-- 10. MISE EN AVANT ÉDITORIALE (une, dossiers, playlists)
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
-- 11. STATISTIQUES D'AUDIENCE
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
-- 12. TRIGGERS updated_at
-- =====================================================================

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'users', 'api_clients', 'authors', 'sections', 'media_assets', 'articles',
    'channels', 'live_streams', 'programs', 'episodes', 'media_partners',
    'ingestion_sources', 'comments', 'collections'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON %1$I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t);
  END LOOP;
END $$;

-- =====================================================================
-- 13. VUES ET FONCTIONS UTILES À L'API
-- =====================================================================

-- Articles visibles par le public
CREATE VIEW v_published_articles AS
SELECT *
FROM articles
WHERE status = 'published' AND published_at <= now();

-- Épisodes (vidéos et audios) visibles par le public
CREATE VIEW v_published_episodes AS
SELECT *
FROM episodes
WHERE status = 'published' AND published_at <= now();

-- Lives en cours, avec les informations de la chaîne
CREATE VIEW v_live_now AS
SELECT ls.*,
       c.slug     AS channel_slug,
       c.name     AS channel_name,
       c.kind     AS channel_kind,
       c.logo_url AS channel_logo_url
FROM live_streams ls
JOIN channels c ON c.id = ls.channel_id
WHERE ls.status = 'live' AND c.is_active;

-- Publie les articles programmés dont l'heure est arrivée.
-- À appeler toutes les minutes depuis une tâche planifiée du back-end.
CREATE OR REPLACE FUNCTION publish_scheduled_articles() RETURNS integer AS $$
DECLARE
  n integer;
BEGIN
  UPDATE articles
     SET status = 'published',
         published_at = COALESCE(published_at, scheduled_at)
   WHERE status = 'scheduled' AND scheduled_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql;

COMMIT;
