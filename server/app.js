import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const defaultRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.woff': 'font/woff', '.woff2': 'font/woff2'
};

function failure(code, message, status = 400) {
  return Object.assign(new Error(message), { code, status });
}

function normalize(value) {
  return String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
}

function isPublished(item) {
  const timestamp = Date.parse(item.publishedAt);
  return item.status === 'published' && Number.isFinite(timestamp) && timestamp <= Date.now();
}

function publishedArticles(content) {
  return content.articles.filter(isPublished).sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt));
}

// Use an explicit public projection: internal provider payloads and editorial fields stay private.
function publicArticle(article, detail = false) {
  const premium = article.accessLevel === 'premium';
  return {
    id: article.id, slug: article.slug, title: article.title, excerpt: article.excerpt,
    ...(detail ? { body: premium ? [] : (article.body ?? []) } : {}),
    category: article.category, categoryName: article.categoryName, cover: article.cover,
    author: article.author, publishedAt: article.publishedAt,
    readingMinutes: article.readingMinutes, demo: article.demo === true,
    status: 'published', accessLevel: premium ? 'premium' : 'free',
    ...(premium ? { requiresAccess: true } : {})
  };
}

function paginate(items, params) {
  const integer = (key, fallback, max) => {
    const value = params.get(key);
    if (value === null) return fallback;
    if (!/^[1-9]\d*$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) > max) {
      throw failure('INVALID_QUERY', `Le paramètre ${key} doit être un entier entre 1 et ${max}.`);
    }
    return Number(value);
  };
  const page = integer('page', 1, 1000000);
  const limit = integer('limit', 12, 50);
  return { data: items.slice((page - 1) * limit, page * limit), meta: { total: items.length, page, limit, demo: true } };
}

function typedFilter(items, params, allowed) {
  const type = params.get('type');
  if (type !== null && !allowed.includes(type)) throw failure('INVALID_QUERY', `Type attendu : ${allowed.join(', ')}.`);
  return type ? items.filter(item => item.type === type) : items;
}

function publicMedia(item) {
  return {
    id: item.id, slug: item.slug, title: item.title, type: item.type,
    description: item.description, cover: item.cover, durationSeconds: item.durationSeconds,
    status: item.status, demo: item.demo === true,
    playbackUrl: item.accessLevel === 'premium' ? null : (item.playbackUrl ?? null),
    accessLevel: item.accessLevel === 'premium' ? 'premium' : 'free'
  };
}

function safeStreams(channel) {
  if (channel.status !== 'live') return [];
  return (channel.streams ?? []).filter(stream => {
    try { return ['https:'].includes(new URL(stream.url).protocol) && stream.active === true; }
    catch { return false; }
  }).map(({ id, format, url, label }) => ({ id, format, url, label }));
}

function publicChannel(channel) {
  const streams = safeStreams(channel);
  return {
    id: channel.id, name: channel.name, type: channel.type, description: channel.description,
    logo: channel.logo ?? null, status: channel.status, demo: channel.demo === true,
    streams, playbackUrl: streams[0]?.url ?? null
  };
}

function routeApi(pathname, params, content) {
  if (pathname === '/api/v1/health') return { data: { status: 'ok', version: 'v1', contentSource: 'demo-json' }, meta: { demo: true } };
  if (pathname === '/api/v1/home') {
    const articles = publishedArticles(content).map(article => publicArticle(article));
    return { data: { featured: articles[0] ?? null, headlines: articles.slice(1, 4), latest: articles }, meta: { demo: true } };
  }
  if (pathname === '/api/v1/categories') return paginate(content.categories, params);
  if (pathname === '/api/v1/articles') {
    let articles = publishedArticles(content);
    if (params.has('category')) articles = articles.filter(article => article.category === params.get('category'));
    if (params.has('q')) {
      const query = normalize(params.get('q').trim());
      if (query.length > 200) throw failure('INVALID_QUERY', 'La recherche ne doit pas dépasser 200 caractères.');
      // Search public summaries only: premium/private bodies cannot be inferred through search.
      articles = articles.filter(article => normalize(`${article.title} ${article.excerpt}`).includes(query));
    }
    return paginate(articles.map(article => publicArticle(article)), params);
  }
  const articleMatch = pathname.match(/^\/api\/v1\/articles\/([^/]+)$/);
  if (articleMatch) {
    const article = publishedArticles(content).find(item => item.slug === articleMatch[1]);
    if (!article) throw failure('NOT_FOUND', 'Article introuvable.', 404);
    return { data: publicArticle(article, true), meta: { demo: true } };
  }
  if (pathname === '/api/v1/media') {
    // Media must be editorially published, even when playback is not configured.
    const media = content.media.filter(item => item.publicationStatus === 'published' && Date.parse(item.publishedAt) <= Date.now());
    return paginate(typedFilter(media, params, ['video', 'audio']).map(publicMedia), params);
  }
  if (pathname === '/api/v1/channels') return paginate(typedFilter(content.channels.filter(item => item.enabled !== false), params, ['tv', 'radio', 'tnt']).map(publicChannel), params);
  const streamMatch = pathname.match(/^\/api\/v1\/channels\/([^/]+)\/streams$/);
  if (streamMatch) {
    const channel = content.channels.find(item => item.id === streamMatch[1] && item.enabled !== false);
    if (!channel) throw failure('NOT_FOUND', 'Chaîne introuvable.', 404);
    return paginate(safeStreams(channel), params);
  }
  throw failure('NOT_FOUND', 'Route introuvable.', 404);
}

function sendJson(response, request, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  response.end(request.method === 'HEAD' ? undefined : body);
}

async function serveStatic(request, response, pathname, rootDir) {
  const isIndex = pathname === '/' || pathname === '/index.html';
  if (!isIndex && !pathname.startsWith('/assets/lacruche/')) throw failure('NOT_FOUND', 'Page introuvable.', 404);
  const relative = isIndex ? 'index.html' : pathname.slice(1);
  const filePath = resolve(rootDir, relative);
  const allowedRoot = isIndex ? resolve(rootDir) : resolve(rootDir, 'assets/lacruche');
  if (!filePath.startsWith(`${allowedRoot}${sep}`)) throw failure('FORBIDDEN', 'Chemin non autorisé.', 403);
  if (!mimeTypes[extname(filePath)]) throw failure('NOT_FOUND', 'Fichier introuvable.', 404);
  let canonical;
  try { canonical = await realpath(filePath); }
  catch { throw failure('NOT_FOUND', 'Fichier introuvable.', 404); }
  const realRoot = await realpath(allowedRoot);
  if (!canonical.startsWith(`${realRoot}${sep}`)) throw failure('FORBIDDEN', 'Chemin non autorisé.', 403);
  if (!(await stat(canonical)).isFile()) throw failure('NOT_FOUND', 'Fichier introuvable.', 404);
  const body = await readFile(canonical);
  response.writeHead(200, { 'Content-Type': mimeTypes[extname(filePath)], 'Content-Length': body.byteLength, 'Cache-Control': isIndex ? 'no-cache' : 'public, max-age=3600' });
  response.end(request.method === 'HEAD' ? undefined : body);
}

export function createApp({ rootDir = defaultRoot, content } = {}) {
  const repository = content ?? JSON.parse(readFileSync(resolve(rootDir, 'data/content.json'), 'utf8'));
  return createServer(async (request, response) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    response.setHeader('X-Frame-Options', 'SAMEORIGIN');
    try {
      if (!['GET', 'HEAD'].includes(request.method)) {
        response.setHeader('Allow', 'GET, HEAD');
        throw failure('METHOD_NOT_ALLOWED', 'Méthode non autorisée.', 405);
      }
      let url;
      try { url = new URL(request.url, 'http://localhost'); }
      catch { throw failure('INVALID_URL', 'URL invalide.'); }
      let pathname;
      try { pathname = decodeURIComponent(url.pathname); }
      catch { throw failure('INVALID_URL', 'Encodage de chemin invalide.'); }
      if (pathname.includes('\0') || pathname.includes('\\')) throw failure('INVALID_URL', 'Chemin invalide.');
      if (pathname === '/api' || pathname.startsWith('/api/')) {
        sendJson(response, request, 200, routeApi(pathname, url.searchParams, repository));
      } else {
        await serveStatic(request, response, pathname, rootDir);
      }
    } catch (error) {
      const status = Number.isInteger(error.status) ? error.status : 500;
      sendJson(response, request, status, { error: { code: error.code && status < 500 ? error.code : 'INTERNAL_ERROR', message: status < 500 ? error.message : 'Une erreur interne est survenue.' } });
    }
  });
}
