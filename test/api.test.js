import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../server/app.js';

const publishedAt = '2026-10-01T09:00:00.000Z';
const categories = [
  { id: 'politique', name: 'Politique' },
  { id: 'economie', name: 'Économie' },
  { id: 'sante', name: 'Santé' },
];
const article = (id, extra = {}) => ({
  id,
  slug: id,
  title: `Article ${id}`,
  excerpt: `Extrait ${id}`,
  body: [`Texte public ${id}`],
  category: 'politique',
  categoryName: 'Politique',
  cover: { url: '/assets/lacruche/city.jpg', alt: 'Illustration' },
  author: 'Rédaction de démonstration',
  publishedAt,
  readingMinutes: 3,
  demo: true,
  status: 'published',
  accessLevel: 'free',
  ...extra,
});
const media = (id, type, extra = {}) => ({
  id,
  title: `Média ${id}`,
  type,
  status: 'unconfigured',
  publicationStatus: 'published',
  publishedAt,
  playbackUrl: `https://example.org/${id}.mp4`,
  accessLevel: 'free',
  demo: true,
  ...extra,
});
const content = {
  categories,
  articles: [
    article('alpha', { title: 'Développement et débat public', body: ['Le financement des écoles.'] }),
    article('beta', { category: 'economie', categoryName: 'Économie' }),
    article('gamma', { category: 'sante', categoryName: 'Santé' }),
    article('premium', { accessLevel: 'premium', body: ['ARTICLE_PREMIUM_CONFIDENTIEL'], providerPayload: { fullText: 'SOURCE_PREMIUM_PRIVEE' } }),
    article('brouillon', { status: 'draft' }),
    article('programme', { publishedAt: '2999-01-01T00:00:00.000Z' }),
  ],
  media: [
    media('video', 'video'),
    media('audio', 'audio'),
    media('premium-video', 'video', { accessLevel: 'premium', playbackUrl: 'https://example.org/SECRET_PREMIUM.mp4', providerPayload: { original: 'SOURCE_MEDIA_PRIVEE' } }),
    media('video-draft', 'video', { publicationStatus: 'draft' }),
    media('video-future', 'video', { publishedAt: '2999-01-01T00:00:00.000Z' }),
  ],
  channels: ['tv', 'radio', 'tnt'].map((type) => ({
    id: `channel-${type}`,
    name: `Chaîne ${type}`,
    type,
    status: 'unconfigured',
    streams: [],
    playbackUrl: null,
    demo: true,
  })),
};

let app;
const origin = 'http://in-process.local';
let rootDir;

before(async () => {
  rootDir = await mkdtemp(join(tmpdir(), 'lacruche-api-'));
  await mkdir(join(rootDir, 'assets', 'lacruche'), { recursive: true });
  await writeFile(join(rootDir, 'index.html'), '<!doctype html><title>Lacruche test</title>');
  await writeFile(join(rootDir, 'assets', 'lacruche', 'fixture.css'), 'body { color: navy; }');
  await writeFile(join(rootDir, 'secret.txt'), 'FICHIER_PRIVE_NE_PAS_SERVIR');
  app = createApp({ rootDir, content });
});

after(async () => {
  if (rootDir) await rm(rootDir, { recursive: true, force: true });
});

// Exercise the real HTTP request handler without TCP sockets, which are blocked
// by the managed execution sandbox. Transport/browser integration is separate QA.
async function fetch(input, options = {}) {
  const headers = new Headers();
  let status = 200;
  let responseBody;
  const response = {
    setHeader(name, value) { headers.set(name, String(value)); },
    writeHead(code, values) {
      status = code;
      for (const [name, value] of Object.entries(values ?? {})) headers.set(name, String(value));
    },
    end(body) { responseBody = body; },
  };
  const rawPath = String(input).startsWith(origin) ? String(input).slice(origin.length) : String(input);
  await app.listeners('request')[0]({ method: options.method ?? 'GET', url: rawPath }, response);
  return new Response(responseBody ?? null, { status, headers });
}

async function get(path, options) {
  const response = await fetch(`${origin}${path}`, options);
  const payload = await response.json();
  return { response, payload };
}

test('article lists expose published, nonfuture articles and bounded pagination', async () => {
  const { response, payload } = await get('/api/v1/articles?page=1&limit=2');
  assert.equal(response.status, 200);
  assert.equal(payload.data.length, 2);
  assert.deepEqual(payload.meta, { total: 4, page: 1, limit: 2, demo: true });
  const second = await get('/api/v1/articles?page=2&limit=2');
  assert.equal(second.payload.data.length, 2);
  assert.equal(new Set([...payload.data, ...second.payload.data].map((item) => item.id)).size, 4);
  const all = await get('/api/v1/articles?limit=50');
  assert.equal(all.payload.data.some((item) => ['brouillon', 'programme'].includes(item.id)), false);
  assert.equal(JSON.stringify(all.payload).includes('ARTICLE_PREMIUM_CONFIDENTIEL'), false);
});

test('category and accent-insensitive text filters can be combined', async () => {
  const filtered = await get('/api/v1/articles?category=politique&q=DEVELOPPEMENT');
  assert.deepEqual(filtered.payload.data.map((item) => item.id), ['alpha']);
  const privateBody = await get('/api/v1/articles?q=ARTICLE_PREMIUM_CONFIDENTIEL');
  assert.deepEqual(privateBody.payload.data, []);
  const mismatch = await get('/api/v1/articles?category=economie&q=developpement');
  assert.equal(mismatch.payload.meta.total, 0);
  const unknown = await get('/api/v1/articles?category=inconnue');
  assert.deepEqual(unknown.payload.data, []);
});

test('article detail is readable, while draft, future and unknown slugs return 404', async () => {
  const { response, payload } = await get('/api/v1/articles/alpha');
  assert.equal(response.status, 200);
  assert.equal(payload.data.slug, 'alpha');
  assert.deepEqual(payload.data.body, ['Le financement des écoles.']);
  assert.equal(payload.meta.demo, true);
  for (const slug of ['brouillon', 'programme', 'absent']) {
    const result = await get(`/api/v1/articles/${slug}`);
    assert.equal(result.response.status, 404);
    assert.equal(typeof result.payload.error.code, 'string');
    assert.equal(typeof result.payload.error.message, 'string');
    assert.equal('data' in result.payload, false);
  }
});

test('premium article text is never returned in a public detail response', async () => {
  const { response, payload } = await get('/api/v1/articles/premium');
  assert.equal(response.status, 200);
  assert.equal(payload.data.accessLevel, 'premium');
  assert.deepEqual(payload.data.body, []);
  assert.equal(payload.data.excerpt, 'Extrait premium');
  assert.equal(JSON.stringify(payload).includes('ARTICLE_PREMIUM_CONFIDENTIEL'), false);
});

test('home uses the shared publication and premium protections', async () => {
  const { response, payload } = await get('/api/v1/home');
  assert.equal(response.status, 200);
  assert.equal(payload.meta.demo, true);
  assert.ok(payload.data.featured);
  assert.ok(Array.isArray(payload.data.headlines));
  assert.ok(Array.isArray(payload.data.latest));
  const visible = [payload.data.featured, ...payload.data.headlines, ...payload.data.latest];
  assert.equal(visible.some((item) => ['brouillon', 'programme'].includes(item.id)), false);
  assert.equal(JSON.stringify(payload).includes('ARTICLE_PREMIUM_CONFIDENTIEL'), false);
});

test('home, article lists and media lists expose no private premium provider payload', async () => {
  for (const path of ['/api/v1/home', '/api/v1/articles', '/api/v1/media']) {
    const { response, payload } = await get(path);
    assert.equal(response.status, 200);
    const serialized = JSON.stringify(payload);
    for (const secret of ['ARTICLE_PREMIUM_CONFIDENTIEL', 'SOURCE_PREMIUM_PRIVEE', 'SOURCE_MEDIA_PRIVEE', 'SECRET_PREMIUM']) {
      assert.equal(serialized.includes(secret), false, `${path} exposed ${secret}`);
    }
    assert.equal(serialized.includes('providerPayload'), false, path);
  }
});

test('categories retain the same list envelope', async () => {
  const { response, payload } = await get('/api/v1/categories');
  assert.equal(response.status, 200);
  assert.deepEqual(payload.data, categories);
  assert.equal(payload.meta.total, categories.length);
  assert.equal(payload.meta.demo, true);
});

test('media filters omit unpublished and future items and redact premium playback', async () => {
  const video = await get('/api/v1/media?type=video');
  assert.equal(video.response.status, 200);
  assert.equal(video.payload.meta.total, 2);
  assert.ok(video.payload.data.every((item) => item.type === 'video'));
  assert.equal(video.payload.data.find((item) => item.id === 'premium-video').playbackUrl, null);
  assert.equal(JSON.stringify(video.payload).includes('SECRET_PREMIUM'), false);
  const audio = await get('/api/v1/media?type=audio');
  assert.deepEqual(audio.payload.data.map((item) => item.id), ['audio']);
});

test('TV, radio and TNT channels return honest unconfigured stream state', async () => {
  for (const type of ['tv', 'radio', 'tnt']) {
    const result = await get(`/api/v1/channels?type=${type}`);
    assert.equal(result.response.status, 200);
    assert.equal(result.payload.data.length, 1);
    assert.equal(result.payload.data[0].type, type);
    assert.equal(result.payload.data[0].status, 'unconfigured');
    assert.equal(result.payload.data[0].playbackUrl, null);
    const streams = await get(`/api/v1/channels/channel-${type}/streams`);
    assert.equal(streams.response.status, 200);
    assert.deepEqual(streams.payload.data, []);
  }
  assert.equal((await get('/api/v1/channels/absent/streams')).response.status, 404);
});

test('invalid pagination and unsupported media types return structured errors', async () => {
  const paths = [
    '/api/v1/articles?page=0',
    '/api/v1/articles?page=1.5',
    '/api/v1/articles?page=abc',
    '/api/v1/articles?limit=0',
    '/api/v1/articles?limit=51',
    '/api/v1/articles?limit=2abc',
    '/api/v1/media?type=image',
    '/api/v1/channels?type=podcast',
  ];
  for (const path of paths) {
    const { response, payload } = await get(path);
    assert.equal(response.status, 400, path);
    assert.equal(typeof payload.error.code, 'string', path);
    assert.equal(typeof payload.error.message, 'string', path);
  }
});

test('public API supports HEAD, rejects writes and does not enable wildcard CORS', async () => {
  const head = await fetch(`${origin}/api/v1/articles`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  assert.match(head.headers.get('content-type'), /application\/json/);
  assert.notEqual(head.headers.get('access-control-allow-origin'), '*');
  const write = await get('/api/v1/articles', { method: 'POST' });
  assert.equal(write.response.status, 405);
  assert.match(write.response.headers.get('allow'), /GET/);
  assert.match(write.response.headers.get('allow'), /HEAD/);
  assert.equal(typeof write.payload.error.code, 'string');
});

test('health and unknown API routes have explicit responses', async () => {
  const health = await get('/api/v1/health');
  assert.equal(health.response.status, 200);
  assert.equal(health.response.headers.get('x-content-type-options'), 'nosniff');
  const missing = await get('/api/v1/not-a-route');
  assert.equal(missing.response.status, 404);
  assert.equal(typeof missing.payload.error.message, 'string');
});

test('static serving is limited to the homepage and designated public assets', async () => {
  const homepage = await fetch(`${origin}/`);
  assert.equal(homepage.status, 200);
  assert.match(await homepage.text(), /Lacruche test/);
  const asset = await fetch(`${origin}/assets/lacruche/fixture.css`);
  assert.equal(asset.status, 200);
  assert.match(asset.headers.get('content-type'), /text\/css/);
  const privateFile = await fetch(`${origin}/secret.txt`);
  assert.equal(privateFile.status, 404);
  assert.equal((await privateFile.text()).includes('FICHIER_PRIVE_NE_PAS_SERVIR'), false);
  const data = await fetch(`${origin}/data/content.json`);
  assert.equal(data.status, 404);
  const head = await fetch(`${origin}/index.html`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
});

test('encoded traversal cannot disclose files outside the public asset directory', async () => {
  const result = await fetch(`${origin}/assets/lacruche/%2e%2e%2f%2e%2e%2fsecret.txt`);
  assert.ok([403, 404].includes(result.status));
  assert.equal((await result.text()).includes('FICHIER_PRIVE_NE_PAS_SERVIR'), false);
});
