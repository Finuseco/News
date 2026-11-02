-- =====================================================================
-- Données de base : langues, pays, rubriques
-- À exécuter après db/schema.sql :  psql "$DATABASE_URL" -f db/seed.sql
-- Le fichier peut être relancé sans créer de doublons.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Langues de publication
-- ---------------------------------------------------------------------
INSERT INTO languages (code, name, native_name, is_rtl, search_config) VALUES
  ('fr', 'French',     'Français',  false, 'french'),
  ('en', 'English',    'English',   false, 'english'),
  ('es', 'Spanish',    'Español',   false, 'spanish'),
  ('pt', 'Portuguese', 'Português', false, 'portuguese'),
  ('ru', 'Russian',    'Русский',   false, 'russian'),
  ('ar', 'Arabic',     'العربية',   true,  'simple'),
  ('sw', 'Swahili',    'Kiswahili', false, 'simple'),
  ('ln', 'Lingala',    'Lingála',   false, 'simple'),
  ('ha', 'Hausa',      'Hausa',     false, 'simple')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Pays (sélection de départ, à compléter selon les besoins)
-- ---------------------------------------------------------------------
INSERT INTO countries (code, name_fr, name_en, continent) VALUES
  ('CD', 'RD Congo',            'DR Congo',       'Afrique'),
  ('CG', 'Congo-Brazzaville',   'Republic of the Congo', 'Afrique'),
  ('CM', 'Cameroun',            'Cameroon',       'Afrique'),
  ('CI', 'Côte d''Ivoire',      'Ivory Coast',    'Afrique'),
  ('SN', 'Sénégal',             'Senegal',        'Afrique'),
  ('ML', 'Mali',                'Mali',           'Afrique'),
  ('BF', 'Burkina Faso',        'Burkina Faso',   'Afrique'),
  ('NE', 'Niger',               'Niger',          'Afrique'),
  ('TD', 'Tchad',               'Chad',           'Afrique'),
  ('GA', 'Gabon',               'Gabon',          'Afrique'),
  ('BJ', 'Bénin',               'Benin',          'Afrique'),
  ('TG', 'Togo',                'Togo',           'Afrique'),
  ('GN', 'Guinée',              'Guinea',         'Afrique'),
  ('MG', 'Madagascar',          'Madagascar',     'Afrique'),
  ('RW', 'Rwanda',              'Rwanda',         'Afrique'),
  ('BI', 'Burundi',             'Burundi',        'Afrique'),
  ('MA', 'Maroc',               'Morocco',        'Afrique'),
  ('DZ', 'Algérie',             'Algeria',        'Afrique'),
  ('TN', 'Tunisie',             'Tunisia',        'Afrique'),
  ('EG', 'Égypte',              'Egypt',          'Afrique'),
  ('NG', 'Nigeria',             'Nigeria',        'Afrique'),
  ('KE', 'Kenya',               'Kenya',          'Afrique'),
  ('TZ', 'Tanzanie',            'Tanzania',       'Afrique'),
  ('UG', 'Ouganda',             'Uganda',         'Afrique'),
  ('ZA', 'Afrique du Sud',      'South Africa',   'Afrique'),
  ('AO', 'Angola',              'Angola',         'Afrique'),
  ('FR', 'France',              'France',         'Europe'),
  ('BE', 'Belgique',            'Belgium',        'Europe'),
  ('CH', 'Suisse',              'Switzerland',    'Europe'),
  ('GB', 'Royaume-Uni',         'United Kingdom', 'Europe'),
  ('DE', 'Allemagne',           'Germany',        'Europe'),
  ('RU', 'Russie',              'Russia',         'Europe'),
  ('US', 'États-Unis',          'United States',  'Amériques'),
  ('CA', 'Canada',              'Canada',         'Amériques'),
  ('HT', 'Haïti',               'Haiti',          'Amériques'),
  ('BR', 'Brésil',              'Brazil',         'Amériques'),
  ('CN', 'Chine',               'China',          'Asie'),
  ('IN', 'Inde',                'India',          'Asie'),
  ('LB', 'Liban',               'Lebanon',        'Moyen-Orient'),
  ('IL', 'Israël',              'Israel',         'Moyen-Orient')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Rubriques inspirées des grands médias d'information
-- ---------------------------------------------------------------------
CREATE TEMP TABLE tmp_sections (
  slug     text,
  position integer,
  name_fr  text,
  name_en  text
) ON COMMIT DROP;

INSERT INTO tmp_sections (slug, position, name_fr, name_en) VALUES
  ('monde',         10, 'Monde',                'World'),
  ('afrique',       20, 'Afrique',              'Africa'),
  ('europe',        30, 'Europe',               'Europe'),
  ('ameriques',     40, 'Amériques',            'Americas'),
  ('asie-pacifique',50, 'Asie-Pacifique',       'Asia-Pacific'),
  ('moyen-orient',  60, 'Moyen-Orient',         'Middle East'),
  ('france',        70, 'France',               'France'),
  ('politique',     80, 'Politique',            'Politics'),
  ('economie',      90, 'Économie',             'Business'),
  ('sport',        100, 'Sport',                'Sport'),
  ('culture',      110, 'Culture',              'Culture'),
  ('environnement',120, 'Environnement',        'Environment'),
  ('sante',        130, 'Santé',                'Health'),
  ('sciences-tech',140, 'Sciences et Tech',     'Science and Tech'),
  ('opinions',     150, 'Opinions',             'Opinion');

INSERT INTO sections (slug, position)
SELECT slug, position FROM tmp_sections
ON CONFLICT (slug) DO NOTHING;

INSERT INTO section_translations (section_id, language_code, name)
SELECT s.id, 'fr', t.name_fr FROM tmp_sections t JOIN sections s ON s.slug = t.slug
ON CONFLICT (section_id, language_code) DO NOTHING;

INSERT INTO section_translations (section_id, language_code, name)
SELECT s.id, 'en', t.name_en FROM tmp_sections t JOIN sections s ON s.slug = t.slug
ON CONFLICT (section_id, language_code) DO NOTHING;

COMMIT;
