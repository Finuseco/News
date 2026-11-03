-- =====================================================================
-- Données de base : langues, continents, pays, catégories (domaines), réglages
-- À exécuter après db/schema.sql :  psql "$DATABASE_URL" -f db/seed.sql
-- Le fichier peut être relancé sans créer de doublons, et sans écraser
-- les modifications faites ensuite par l'administrateur.
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
-- Continents (régions du monde), dans l'ordre d'affichage
-- ---------------------------------------------------------------------
INSERT INTO continents (code, name_fr, name_en, position) VALUES
  ('afrique',        'Afrique',        'Africa',       10),
  ('ameriques',      'Amériques',      'Americas',     20),
  ('asie-pacifique', 'Asie-Pacifique', 'Asia-Pacific', 30),
  ('europe',         'Europe',         'Europe',       40),
  ('moyen-orient',   'Moyen-Orient',   'Middle East',  50)
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Pays : les 193 membres de l'ONU, plus le Vatican, la Palestine, le Kosovo,
-- Taïwan et le Sahara occidental. Chaque pays appartient à un seul continent.
-- Le regroupement est une convention éditoriale, modifiable ensuite :
--   UPDATE countries SET continent_code = 'europe' WHERE code = 'TR';
-- ---------------------------------------------------------------------
INSERT INTO countries (code, continent_code, name_fr, name_en) VALUES
  -- Afrique (55)
  ('DZ', 'afrique', 'Algérie', 'Algeria'),
  ('AO', 'afrique', 'Angola', 'Angola'),
  ('BJ', 'afrique', 'Bénin', 'Benin'),
  ('BW', 'afrique', 'Botswana', 'Botswana'),
  ('BF', 'afrique', 'Burkina Faso', 'Burkina Faso'),
  ('BI', 'afrique', 'Burundi', 'Burundi'),
  ('CV', 'afrique', 'Cap-Vert', 'Cape Verde'),
  ('CM', 'afrique', 'Cameroun', 'Cameroon'),
  ('CF', 'afrique', 'Centrafrique', 'Central African Republic'),
  ('TD', 'afrique', 'Tchad', 'Chad'),
  ('KM', 'afrique', 'Comores', 'Comoros'),
  ('CG', 'afrique', 'Congo-Brazzaville', 'Republic of the Congo'),
  ('CD', 'afrique', 'RD Congo', 'DR Congo'),
  ('CI', 'afrique', 'Côte d''Ivoire', 'Ivory Coast'),
  ('DJ', 'afrique', 'Djibouti', 'Djibouti'),
  ('EG', 'afrique', 'Égypte', 'Egypt'),
  ('GQ', 'afrique', 'Guinée équatoriale', 'Equatorial Guinea'),
  ('ER', 'afrique', 'Érythrée', 'Eritrea'),
  ('SZ', 'afrique', 'Eswatini', 'Eswatini'),
  ('ET', 'afrique', 'Éthiopie', 'Ethiopia'),
  ('GA', 'afrique', 'Gabon', 'Gabon'),
  ('GM', 'afrique', 'Gambie', 'Gambia'),
  ('GH', 'afrique', 'Ghana', 'Ghana'),
  ('GN', 'afrique', 'Guinée', 'Guinea'),
  ('GW', 'afrique', 'Guinée-Bissau', 'Guinea-Bissau'),
  ('KE', 'afrique', 'Kenya', 'Kenya'),
  ('LS', 'afrique', 'Lesotho', 'Lesotho'),
  ('LR', 'afrique', 'Liberia', 'Liberia'),
  ('LY', 'afrique', 'Libye', 'Libya'),
  ('MG', 'afrique', 'Madagascar', 'Madagascar'),
  ('MW', 'afrique', 'Malawi', 'Malawi'),
  ('ML', 'afrique', 'Mali', 'Mali'),
  ('MR', 'afrique', 'Mauritanie', 'Mauritania'),
  ('MU', 'afrique', 'Maurice', 'Mauritius'),
  ('MA', 'afrique', 'Maroc', 'Morocco'),
  ('MZ', 'afrique', 'Mozambique', 'Mozambique'),
  ('NA', 'afrique', 'Namibie', 'Namibia'),
  ('NE', 'afrique', 'Niger', 'Niger'),
  ('NG', 'afrique', 'Nigeria', 'Nigeria'),
  ('RW', 'afrique', 'Rwanda', 'Rwanda'),
  ('ST', 'afrique', 'Sao Tomé-et-Principe', 'São Tomé and Príncipe'),
  ('SN', 'afrique', 'Sénégal', 'Senegal'),
  ('SC', 'afrique', 'Seychelles', 'Seychelles'),
  ('SL', 'afrique', 'Sierra Leone', 'Sierra Leone'),
  ('SO', 'afrique', 'Somalie', 'Somalia'),
  ('ZA', 'afrique', 'Afrique du Sud', 'South Africa'),
  ('SS', 'afrique', 'Soudan du Sud', 'South Sudan'),
  ('SD', 'afrique', 'Soudan', 'Sudan'),
  ('TZ', 'afrique', 'Tanzanie', 'Tanzania'),
  ('TG', 'afrique', 'Togo', 'Togo'),
  ('TN', 'afrique', 'Tunisie', 'Tunisia'),
  ('UG', 'afrique', 'Ouganda', 'Uganda'),
  ('ZM', 'afrique', 'Zambie', 'Zambia'),
  ('ZW', 'afrique', 'Zimbabwe', 'Zimbabwe'),
  ('EH', 'afrique', 'Sahara occidental', 'Western Sahara'),

  -- Amériques (35)
  ('AG', 'ameriques', 'Antigua-et-Barbuda', 'Antigua and Barbuda'),
  ('AR', 'ameriques', 'Argentine', 'Argentina'),
  ('BS', 'ameriques', 'Bahamas', 'Bahamas'),
  ('BB', 'ameriques', 'Barbade', 'Barbados'),
  ('BZ', 'ameriques', 'Belize', 'Belize'),
  ('BO', 'ameriques', 'Bolivie', 'Bolivia'),
  ('BR', 'ameriques', 'Brésil', 'Brazil'),
  ('CA', 'ameriques', 'Canada', 'Canada'),
  ('CL', 'ameriques', 'Chili', 'Chile'),
  ('CO', 'ameriques', 'Colombie', 'Colombia'),
  ('CR', 'ameriques', 'Costa Rica', 'Costa Rica'),
  ('CU', 'ameriques', 'Cuba', 'Cuba'),
  ('DM', 'ameriques', 'Dominique', 'Dominica'),
  ('DO', 'ameriques', 'République dominicaine', 'Dominican Republic'),
  ('EC', 'ameriques', 'Équateur', 'Ecuador'),
  ('SV', 'ameriques', 'Salvador', 'El Salvador'),
  ('GD', 'ameriques', 'Grenade', 'Grenada'),
  ('GT', 'ameriques', 'Guatemala', 'Guatemala'),
  ('GY', 'ameriques', 'Guyana', 'Guyana'),
  ('HT', 'ameriques', 'Haïti', 'Haiti'),
  ('HN', 'ameriques', 'Honduras', 'Honduras'),
  ('JM', 'ameriques', 'Jamaïque', 'Jamaica'),
  ('MX', 'ameriques', 'Mexique', 'Mexico'),
  ('NI', 'ameriques', 'Nicaragua', 'Nicaragua'),
  ('PA', 'ameriques', 'Panama', 'Panama'),
  ('PY', 'ameriques', 'Paraguay', 'Paraguay'),
  ('PE', 'ameriques', 'Pérou', 'Peru'),
  ('KN', 'ameriques', 'Saint-Christophe-et-Niévès', 'Saint Kitts and Nevis'),
  ('LC', 'ameriques', 'Sainte-Lucie', 'Saint Lucia'),
  ('VC', 'ameriques', 'Saint-Vincent-et-les-Grenadines', 'Saint Vincent and the Grenadines'),
  ('SR', 'ameriques', 'Suriname', 'Suriname'),
  ('TT', 'ameriques', 'Trinité-et-Tobago', 'Trinidad and Tobago'),
  ('US', 'ameriques', 'États-Unis', 'United States'),
  ('UY', 'ameriques', 'Uruguay', 'Uruguay'),
  ('VE', 'ameriques', 'Venezuela', 'Venezuela'),

  -- Asie-Pacifique (44)
  ('AF', 'asie-pacifique', 'Afghanistan', 'Afghanistan'),
  ('AU', 'asie-pacifique', 'Australie', 'Australia'),
  ('BD', 'asie-pacifique', 'Bangladesh', 'Bangladesh'),
  ('BT', 'asie-pacifique', 'Bhoutan', 'Bhutan'),
  ('BN', 'asie-pacifique', 'Brunei', 'Brunei'),
  ('KH', 'asie-pacifique', 'Cambodge', 'Cambodia'),
  ('CN', 'asie-pacifique', 'Chine', 'China'),
  ('FJ', 'asie-pacifique', 'Fidji', 'Fiji'),
  ('IN', 'asie-pacifique', 'Inde', 'India'),
  ('ID', 'asie-pacifique', 'Indonésie', 'Indonesia'),
  ('JP', 'asie-pacifique', 'Japon', 'Japan'),
  ('KZ', 'asie-pacifique', 'Kazakhstan', 'Kazakhstan'),
  ('KI', 'asie-pacifique', 'Kiribati', 'Kiribati'),
  ('KP', 'asie-pacifique', 'Corée du Nord', 'North Korea'),
  ('KR', 'asie-pacifique', 'Corée du Sud', 'South Korea'),
  ('KG', 'asie-pacifique', 'Kirghizistan', 'Kyrgyzstan'),
  ('LA', 'asie-pacifique', 'Laos', 'Laos'),
  ('MY', 'asie-pacifique', 'Malaisie', 'Malaysia'),
  ('MV', 'asie-pacifique', 'Maldives', 'Maldives'),
  ('MH', 'asie-pacifique', 'Îles Marshall', 'Marshall Islands'),
  ('FM', 'asie-pacifique', 'Micronésie', 'Micronesia'),
  ('MN', 'asie-pacifique', 'Mongolie', 'Mongolia'),
  ('MM', 'asie-pacifique', 'Birmanie', 'Myanmar'),
  ('NR', 'asie-pacifique', 'Nauru', 'Nauru'),
  ('NP', 'asie-pacifique', 'Népal', 'Nepal'),
  ('NZ', 'asie-pacifique', 'Nouvelle-Zélande', 'New Zealand'),
  ('PK', 'asie-pacifique', 'Pakistan', 'Pakistan'),
  ('PW', 'asie-pacifique', 'Palaos', 'Palau'),
  ('PG', 'asie-pacifique', 'Papouasie-Nouvelle-Guinée', 'Papua New Guinea'),
  ('PH', 'asie-pacifique', 'Philippines', 'Philippines'),
  ('WS', 'asie-pacifique', 'Samoa', 'Samoa'),
  ('SG', 'asie-pacifique', 'Singapour', 'Singapore'),
  ('SB', 'asie-pacifique', 'Îles Salomon', 'Solomon Islands'),
  ('LK', 'asie-pacifique', 'Sri Lanka', 'Sri Lanka'),
  ('TJ', 'asie-pacifique', 'Tadjikistan', 'Tajikistan'),
  ('TH', 'asie-pacifique', 'Thaïlande', 'Thailand'),
  ('TL', 'asie-pacifique', 'Timor oriental', 'Timor-Leste'),
  ('TO', 'asie-pacifique', 'Tonga', 'Tonga'),
  ('TM', 'asie-pacifique', 'Turkménistan', 'Turkmenistan'),
  ('TV', 'asie-pacifique', 'Tuvalu', 'Tuvalu'),
  ('UZ', 'asie-pacifique', 'Ouzbékistan', 'Uzbekistan'),
  ('VU', 'asie-pacifique', 'Vanuatu', 'Vanuatu'),
  ('VN', 'asie-pacifique', 'Vietnam', 'Vietnam'),
  ('TW', 'asie-pacifique', 'Taïwan', 'Taiwan'),

  -- Europe (49)
  ('AL', 'europe', 'Albanie', 'Albania'),
  ('AD', 'europe', 'Andorre', 'Andorra'),
  ('AM', 'europe', 'Arménie', 'Armenia'),
  ('AT', 'europe', 'Autriche', 'Austria'),
  ('AZ', 'europe', 'Azerbaïdjan', 'Azerbaijan'),
  ('BY', 'europe', 'Biélorussie', 'Belarus'),
  ('BE', 'europe', 'Belgique', 'Belgium'),
  ('BA', 'europe', 'Bosnie-Herzégovine', 'Bosnia and Herzegovina'),
  ('BG', 'europe', 'Bulgarie', 'Bulgaria'),
  ('HR', 'europe', 'Croatie', 'Croatia'),
  ('CY', 'europe', 'Chypre', 'Cyprus'),
  ('CZ', 'europe', 'Tchéquie', 'Czechia'),
  ('DK', 'europe', 'Danemark', 'Denmark'),
  ('EE', 'europe', 'Estonie', 'Estonia'),
  ('FI', 'europe', 'Finlande', 'Finland'),
  ('FR', 'europe', 'France', 'France'),
  ('GE', 'europe', 'Géorgie', 'Georgia'),
  ('DE', 'europe', 'Allemagne', 'Germany'),
  ('GR', 'europe', 'Grèce', 'Greece'),
  ('HU', 'europe', 'Hongrie', 'Hungary'),
  ('IS', 'europe', 'Islande', 'Iceland'),
  ('IE', 'europe', 'Irlande', 'Ireland'),
  ('IT', 'europe', 'Italie', 'Italy'),
  ('LV', 'europe', 'Lettonie', 'Latvia'),
  ('LI', 'europe', 'Liechtenstein', 'Liechtenstein'),
  ('LT', 'europe', 'Lituanie', 'Lithuania'),
  ('LU', 'europe', 'Luxembourg', 'Luxembourg'),
  ('MT', 'europe', 'Malte', 'Malta'),
  ('MD', 'europe', 'Moldavie', 'Moldova'),
  ('MC', 'europe', 'Monaco', 'Monaco'),
  ('ME', 'europe', 'Monténégro', 'Montenegro'),
  ('NL', 'europe', 'Pays-Bas', 'Netherlands'),
  ('MK', 'europe', 'Macédoine du Nord', 'North Macedonia'),
  ('NO', 'europe', 'Norvège', 'Norway'),
  ('PL', 'europe', 'Pologne', 'Poland'),
  ('PT', 'europe', 'Portugal', 'Portugal'),
  ('RO', 'europe', 'Roumanie', 'Romania'),
  ('RU', 'europe', 'Russie', 'Russia'),
  ('SM', 'europe', 'Saint-Marin', 'San Marino'),
  ('RS', 'europe', 'Serbie', 'Serbia'),
  ('SK', 'europe', 'Slovaquie', 'Slovakia'),
  ('SI', 'europe', 'Slovénie', 'Slovenia'),
  ('ES', 'europe', 'Espagne', 'Spain'),
  ('SE', 'europe', 'Suède', 'Sweden'),
  ('CH', 'europe', 'Suisse', 'Switzerland'),
  ('UA', 'europe', 'Ukraine', 'Ukraine'),
  ('GB', 'europe', 'Royaume-Uni', 'United Kingdom'),
  ('VA', 'europe', 'Vatican', 'Vatican City'),
  ('XK', 'europe', 'Kosovo', 'Kosovo'),

  -- Moyen-Orient (15)
  ('BH', 'moyen-orient', 'Bahreïn', 'Bahrain'),
  ('IR', 'moyen-orient', 'Iran', 'Iran'),
  ('IQ', 'moyen-orient', 'Irak', 'Iraq'),
  ('IL', 'moyen-orient', 'Israël', 'Israel'),
  ('JO', 'moyen-orient', 'Jordanie', 'Jordan'),
  ('KW', 'moyen-orient', 'Koweït', 'Kuwait'),
  ('LB', 'moyen-orient', 'Liban', 'Lebanon'),
  ('OM', 'moyen-orient', 'Oman', 'Oman'),
  ('PS', 'moyen-orient', 'Palestine', 'Palestine'),
  ('QA', 'moyen-orient', 'Qatar', 'Qatar'),
  ('SA', 'moyen-orient', 'Arabie saoudite', 'Saudi Arabia'),
  ('SY', 'moyen-orient', 'Syrie', 'Syria'),
  ('TR', 'moyen-orient', 'Turquie', 'Turkey'),
  ('AE', 'moyen-orient', 'Émirats arabes unis', 'United Arab Emirates'),
  ('YE', 'moyen-orient', 'Yémen', 'Yemen')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Catégories (domaines) : le thème d'un contenu, indépendant du lieu.
-- Un contenu a une catégorie ET un lieu (pays, continent ou monde).
-- Des sous-catégories peuvent s'ajouter avec parent_id.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE tmp_sections (
  slug     text,
  position integer,
  name_fr  text,
  name_en  text
) ON COMMIT DROP;

INSERT INTO tmp_sections (slug, position, name_fr, name_en) VALUES
  ('actualite',     10, 'Actualité',                 'News'),
  ('politique',     20, 'Politique',                 'Politics'),
  ('economie',      30, 'Économie',                  'Economy'),
  ('societe',       40, 'Société',                   'Society'),
  ('diplomatie',    50, 'Diplomatie',                'Diplomacy'),
  ('justice',       60, 'Justice',                   'Justice'),
  ('environnement', 70, 'Environnement',             'Environment'),
  ('sante',         80, 'Santé',                     'Health'),
  ('sciences-tech', 90, 'Sciences et Technologies',  'Science and Technology'),
  ('education',    100, 'Éducation',                 'Education'),
  ('culture',      110, 'Culture',                   'Culture'),
  ('sport',        120, 'Sport',                     'Sport'),
  ('medias',       130, 'Médias',                    'Media'),
  ('opinions',     140, 'Opinions',                  'Opinion');

INSERT INTO sections (slug, position)
SELECT slug, position FROM tmp_sections
ON CONFLICT (slug) DO NOTHING;

INSERT INTO section_translations (section_id, language_code, name)
SELECT s.id, 'fr', t.name_fr FROM tmp_sections t JOIN sections s ON s.slug = t.slug
ON CONFLICT (section_id, language_code) DO NOTHING;

INSERT INTO section_translations (section_id, language_code, name)
SELECT s.id, 'en', t.name_en FROM tmp_sections t JOIN sections s ON s.slug = t.slug
ON CONFLICT (section_id, language_code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Réglages du site (modifiables ensuite par l'administrateur)
-- Aucun prix n'est fixé ici : c'est à l'administrateur de les définir.
-- ---------------------------------------------------------------------
INSERT INTO site_settings (key, value, description) VALUES
  ('require_four_eyes',    'true'::jsonb,
   'Un contenu doit être vérifié par une autre personne que son auteur ou celui qui l''a soumis'),
  ('premium_preview_chars', '600'::jsonb,
   'Longueur (en caractères) de l''extrait gratuit d''un article premium, si l''auteur n''en a pas écrit un'),
  ('purchase_access_days', 'null'::jsonb,
   'Durée de l''accès après un achat, en jours. null = accès illimité'),
  ('default_currency',     '"USD"'::jsonb,
   'Devise des prix par défaut (CashPay cite USD dans sa documentation)'),
  ('default_price_amount', 'null'::jsonb,
   'Prix par défaut d''un contenu premium sans prix propre. À définir par l''administrateur')
ON CONFLICT (key) DO NOTHING;

COMMIT;
