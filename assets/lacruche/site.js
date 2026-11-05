import { api } from './api.js';

const $ = selector => document.querySelector(selector);
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = value => new Intl.DateTimeFormat('fr-CD', { day:'numeric', month:'short', year:'numeric', timeZone:'Africa/Kinshasa' }).format(new Date(value));
const safeUrl = value => {
  try { const url = new URL(value, location.origin); return url.protocol === 'https:' || (url.origin === location.origin && ['http:','https:'].includes(url.protocol)) ? url.href : ''; }
  catch { return ''; }
};
const icon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h12v18l-6-4-6 4z"/></svg>';
const clock = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/></svg>';
const state = { category:'all', query:'', favorites:false, page:1, total:0, serial:0, controller:null, readerSerial:0 };
let saved;
try { const value = JSON.parse(localStorage.getItem('lacruche:bookmarks:v1') || '[]'); saved = new Set(Array.isArray(value) ? value.filter(x => typeof x === 'string').slice(0,300) : []); }
catch { saved = new Set(); }
let toastTimeout;
function toast(message) { const node = $('#toast'); ($('#article-dialog').open ? $('#article-dialog') : document.body).append(node); node.textContent = message; node.hidden = false; clearTimeout(toastTimeout); toastTimeout = setTimeout(() => { node.hidden = true; }, 3500); }
function photo(cover, eager = false) { return `<img src="${escape(safeUrl(cover?.url) || '/assets/lacruche/image-placeholder.svg')}" alt="${escape(cover?.alt || 'Photographie d’illustration')}" loading="${eager ? 'eager' : 'lazy'}" ${eager ? 'fetchpriority="high"' : ''} decoding="async">`; }
function credit(cover) {
  if (!cover?.credit) return '';
  const source = safeUrl(cover.source), license = safeUrl(cover.licenseUrl);
  return `<p class="image-credit">Photo : ${source ? `<a href="${escape(source)}" target="_blank" rel="noreferrer">${escape(cover.credit)}</a>` : escape(cover.credit)}${license ? ` · <a href="${escape(license)}" target="_blank" rel="noreferrer">Licence</a>` : ''}</p>`;
}
function meta(article) { return `<div class="meta">${clock}<time datetime="${escape(article.publishedAt)}">${escape(date(article.publishedAt))}</time><span class="separator">·</span><span>${escape(article.readingMinutes)} min de lecture</span></div>`; }
function bookmark(article, label = false) { const active = saved.has(article.slug); return `<button class="bookmark ${active ? 'saved' : ''}" data-bookmark="${escape(article.slug)}" aria-pressed="${active}" aria-label="${active ? 'Retirer des favoris' : 'Ajouter aux favoris'} : ${escape(article.title)}">${icon}${label ? `<span>${active ? 'Enregistré' : 'Enregistrer'}</span>` : ''}</button>`; }
function articleUrl(article) { return `?article=${encodeURIComponent(article.slug)}`; }
function card(article) { return `<article class="news-card"><a class="card-image" data-article="${escape(article.slug)}" href="${escape(articleUrl(article))}" tabindex="-1" aria-hidden="true">${photo(article.cover)}</a><span class="category-name">${escape(article.categoryName)}</span><a data-article="${escape(article.slug)}" href="${escape(articleUrl(article))}"><h3>${escape(article.title)}</h3></a><p class="excerpt">${escape(article.excerpt)}</p><div class="card-bottom">${meta(article)}${bookmark(article)}</div>${credit(article.cover)}</article>`; }
function empty(title, description, retry = false) { return `<div class="empty-state"><h3>${escape(title)}</h3><p>${escape(description)}</p>${retry ? '<button class="button outline" data-retry>Réessayer</button>' : ''}</div>`; }

async function loadHome() {
  try {
    const { data } = await api.home();
    const article = data.featured;
    $('#featured').innerHTML = article ? `<article class="feature-card">${photo(article.cover,true)}<a class="article-link" href="${escape(articleUrl(article))}" data-article="${escape(article.slug)}" aria-label="${escape(article.title)}"></a><div class="feature-content"><span class="category-tag">${escape(article.categoryName)}</span><h2>${escape(article.title)}</h2>${meta(article)}</div>${bookmark(article)}</article>${credit(article.cover)}` : empty('La une se prépare', 'Les premiers articles publiés apparaîtront ici.');
    $('#headlines').innerHTML = data.headlines.map(article => `<article class="headline"><a href="${escape(articleUrl(article))}" data-article="${escape(article.slug)}" aria-label="${escape(article.title)}">${photo(article.cover)}</a><div><span class="category-name">${escape(article.categoryName)}</span><a href="${escape(articleUrl(article))}" data-article="${escape(article.slug)}"><h3>${escape(article.title)}</h3></a><div class="meta">${clock}<time datetime="${escape(article.publishedAt)}">${escape(date(article.publishedAt))}</time></div></div></article>`).join('');
  } catch { $('#featured').innerHTML = empty('La une est indisponible', 'Veuillez réessayer dans quelques instants.', true); $('#headlines').textContent = 'Le fil sera disponible dès le retour du service.'; }
}

async function loadArticles(append = false) {
  const serial = ++state.serial;
  state.controller?.abort(); state.controller = new AbortController();
  const signal = state.controller.signal;
  $('#articles').setAttribute('aria-busy','true'); $('#load-more').disabled = true;
  if (!append) $('#articles').innerHTML = '<p class="loading">Chargement des articles…</p>';
  try {
    let response;
    if (state.favorites) {
      const results = await Promise.allSettled([...saved].map(slug => api.article(slug)));
      const articles = results.filter(x => x.status === 'fulfilled').map(x => x.value.data);
      response = { data:articles, meta:{ total:articles.length, limit:300 } };
      if (saved.size && results.every(x=>x.status==='rejected')) throw new Error('Favoris indisponibles');
    } else response = await api.articles({ category: state.category === 'all' ? '' : state.category, q:state.query, page:state.page, limit:6 }, signal);
    if (serial !== state.serial) return;
    state.total = response.meta.total;
    const markup = response.data.map(card).join('');
    if (append) $('#articles').insertAdjacentHTML('beforeend', markup);
    else $('#articles').innerHTML = markup || empty(state.favorites ? 'Vos lectures, à retrouver ici' : 'Aucun article pour le moment', state.favorites ? 'Enregistrez un article avec le symbole de favori pour le retrouver sur cet appareil.' : 'Essayez une autre rubrique ou modifiez votre recherche.');
    $('#results-status').textContent = `${state.total} article${state.total > 1 ? 's' : ''} ${state.favorites ? 'dans vos favoris' : 'disponible'+(state.total > 1 ? 's' : '')}.`;
    $('#load-more').hidden = state.favorites || state.page * response.meta.limit >= state.total;
  } catch (error) {
    if (error.name === 'AbortError' || serial !== state.serial) return;
    if (append) { state.page = Math.max(1,state.page-1); toast('Impossible de charger la suite. Veuillez réessayer.'); }
    else $('#articles').innerHTML = empty('Les articles sont indisponibles', 'Vérifiez votre connexion puis relancez le chargement.', true);
  } finally { if (serial === state.serial) { $('#articles').setAttribute('aria-busy','false'); $('#load-more').disabled = false; } }
}

function filter(category = 'all', home = false, favorites = false, query = '') {
  Object.assign(state,{ category, favorites, query, page:1 });
  $('#home-view').hidden = !home;
  $('#latest-title').textContent = favorites ? 'Mes favoris' : query ? `Recherche : « ${query} »` : category === 'all' ? 'Actualités récentes' : document.querySelector(`[data-category="${category}"]`)?.textContent || 'Actualités';
  $('#reset-filter').hidden = home || (category === 'all' && !favorites && !query);
  $('#latest-caption').hidden = !$('#reset-filter').hidden;
  $('#category-chips').hidden = favorites || Boolean(query);
  $('#search-input').value = query;
  document.querySelectorAll('[data-category]').forEach(button => { const active = !favorites && !query && button.dataset.category === (home ? '' : category); button.classList.toggle('active',active); button.setAttribute('aria-pressed',String(active)); });
  document.querySelectorAll('[data-filter]').forEach(button => { const active = button.dataset.filter === category; button.classList.toggle('selected',active); button.setAttribute('aria-pressed',String(active)); });
  $('#bottom-home').classList.toggle('selected',home); $('#bottom-favorites').classList.toggle('selected',favorites);
  loadArticles();
}
function toggleMenu() { const expanded = $('#menu-toggle').getAttribute('aria-expanded') !== 'true'; $('#menu-toggle').setAttribute('aria-expanded',String(expanded)); $('#menu-toggle').setAttribute('aria-label', expanded ? 'Fermer le menu' : 'Ouvrir le menu'); $('#main-nav').classList.toggle('menu-open',expanded); }
function closeMenu() { $('#menu-toggle').setAttribute('aria-expanded','false'); $('#menu-toggle').setAttribute('aria-label','Ouvrir le menu'); $('#main-nav').classList.remove('menu-open'); }

let channelSerial = 0;
async function loadChannels(type = 'tv') {
  const serial = ++channelSerial;
  document.querySelectorAll('[data-stream]').forEach(button => { const active = button.dataset.stream === type; button.classList.toggle('selected',active); button.setAttribute('aria-pressed',String(active)); });
  $('#channels').innerHTML = '<p class="loading">Chargement…</p>';
  try { const {data} = await api.channels(type); if (serial !== channelSerial) return; $('#channels').innerHTML = data.map(channel=>`<article class="channel"><span class="channel-icon" aria-hidden="true">${type === 'radio' ? 'FM' : type.toUpperCase()}</span><div><h3>${escape(channel.name)}</h3><p>${escape(channel.description)}</p></div><span class="channel-state">À connecter</span></article>`).join('') || empty('Aucune chaîne disponible','Les chaînes partenaires apparaîtront ici après leur configuration.'); }
  catch { if (serial === channelSerial) $('#channels').innerHTML = '<p class="connection-note">Le catalogue est momentanément indisponible. Sélectionnez un onglet pour réessayer.</p>'; }
}
async function loadMedia() {
  try { const {data} = await api.media(); $('#media').innerHTML = data.map(item=>`<article class="media-card"><div class="media-picture">${photo(item.cover)}<span class="media-play" aria-hidden="true">${item.type === 'audio' ? '♫' : '▶'}</span></div><div><span class="category-name">${item.type === 'audio' ? 'LES RENDEZ-VOUS AUDIO' : 'LES VIDÉOS DE LA RÉDACTION'}</span><h3>${escape(item.title)}</h3><p>${escape(item.description)}</p><p class="media-status">Source à connecter</p></div></article>`).join('') || empty('Les reportages se préparent','Les vidéos publiées apparaîtront ici.'); }
  catch { $('#media').innerHTML = empty('Le catalogue est indisponible','Les vidéos seront accessibles dès le retour du service.'); }
}

async function openArticle(slug, changeUrl = true) {
  const serial = ++state.readerSerial;
  $('#reader-content').innerHTML = '<h1 id="reader-title" class="sr-only">Lecture de l’article</h1><p class="loading">Ouverture de l’article…</p>';
  if (!$('#article-dialog').open) $('#article-dialog').showModal();
  document.body.style.overflow = 'hidden';
  if (changeUrl) { const url = new URL(location.href); url.searchParams.set('article',slug); history.pushState({reader:true},'',url); }
  try {
    const {data:article} = await api.article(slug);
    if (serial !== state.readerSerial || !$('#article-dialog').open) return;
    $('#reader-content').innerHTML = `<article class="reader-body"><span class="category-name">${escape(article.categoryName)}</span><h1 id="reader-title">${escape(article.title)}</h1>${meta(article)}<p class="reader-excerpt">${escape(article.excerpt)}</p><div class="meta">Par ${escape(article.author)}</div>${photo(article.cover,true)}${credit(article.cover)}${article.demo ? '<aside class="reader-demo">Contenu de démonstration : cet article illustre la présentation du site et ne constitue pas une information récente vérifiée.</aside>' : ''}${article.requiresAccess ? '<p>Ce contenu nécessite un accès. Le service d’abonnement sera raccordé ultérieurement.</p>' : (Array.isArray(article.body) ? article.body : []).map(paragraph=>`<p>${escape(paragraph)}</p>`).join('')}<div class="reader-actions">${bookmark(article,true)}<button class="button outline" data-share="${escape(article.slug)}">Partager le lien</button></div></article>`;
    $('#article-dialog').scrollTop = 0;
  } catch { if (serial === state.readerSerial) $('#reader-content').innerHTML = '<div class="reader-body"><h1 id="reader-title">Article indisponible</h1><p>L’article a peut-être été retiré ou la connexion est interrompue. Fermez cette fenêtre pour poursuivre la lecture.</p></div>'; }
}
function closeReader(updateUrl = true) { state.readerSerial++; if ($('#article-dialog').open) $('#article-dialog').close(); document.body.style.overflow=''; const notice=$('#toast'); notice.hidden=true; document.body.append(notice); if (updateUrl && new URL(location.href).searchParams.has('article')) { const url = new URL(location.href); url.searchParams.delete('article'); history.replaceState({},'',url); } }

document.addEventListener('error',event=>{ if (event.target instanceof HTMLImageElement && !event.target.src.endsWith('/image-placeholder.svg')) { event.target.src='/assets/lacruche/image-placeholder.svg'; event.target.alt='Photographie temporairement indisponible'; } },true);
document.addEventListener('click',async event=>{
  const bookmarkButton = event.target.closest('[data-bookmark]');
  if (bookmarkButton) {
    const slug = bookmarkButton.dataset.bookmark;
    if (!saved.has(slug) && saved.size >= 300) { toast('Vous avez atteint la limite de 300 favoris.'); return; }
    saved.has(slug) ? saved.delete(slug) : saved.add(slug);
    let persisted = true; try { localStorage.setItem('lacruche:bookmarks:v1',JSON.stringify([...saved])); } catch { persisted = false; }
    document.querySelectorAll('[data-bookmark]').forEach(button=>{ if(button.dataset.bookmark!==slug)return; const active=saved.has(slug); button.classList.toggle('saved',active); button.setAttribute('aria-pressed',String(active)); button.setAttribute('aria-label',button.getAttribute('aria-label').replace(/^(Ajouter aux favoris|Retirer des favoris)/,active?'Retirer des favoris':'Ajouter aux favoris')); if(button.querySelector('span'))button.querySelector('span').textContent=active?'Enregistré':'Enregistrer'; });
    toast(persisted ? saved.has(slug) ? 'Article ajouté à vos favoris sur cet appareil.' : 'Article retiré de vos favoris.' : 'Favoris conservés pour cette session ; le stockage est indisponible.');
    if(state.favorites)loadArticles(); return;
  }
  const articleLink=event.target.closest('[data-article]');
  if(articleLink && !event.ctrlKey && !event.metaKey && !event.shiftKey && event.button===0){event.preventDefault();openArticle(articleLink.dataset.article);return;}
  const category=event.target.closest('[data-category]');
  if(category){const value=category.dataset.category;filter(value||'all',value==='');closeMenu();if(value!=='')$('#actualites').scrollIntoView();return;}
  const chip=event.target.closest('[data-filter]');if(chip){filter(chip.dataset.filter,false);return;}
  const stream=event.target.closest('[data-stream]');if(stream){loadChannels(stream.dataset.stream);return;}
  if(event.target.closest('[data-retry]')){loadArticles();loadHome();return;}
  const share=event.target.closest('[data-share]');if(share){const url=new URL('/',location.origin);url.searchParams.set('article',share.dataset.share);try{await navigator.clipboard.writeText(url.href);toast('Lien de l’article copié.');}catch{toast('Copiez le lien depuis la barre d’adresse pour partager cet article.');}}
});
$('#menu-toggle').addEventListener('click',toggleMenu);
$('#bottom-menu').addEventListener('click',()=>{toggleMenu();window.scrollTo({top:0,behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});});
$('#main-nav').addEventListener('keydown',event=>{if(event.key==='Escape'){closeMenu();$('#menu-toggle').focus();}});
$('#search-toggle').addEventListener('click',()=>{const open=$('#search-panel').hidden;$('#search-panel').hidden=!open;$('#search-toggle').setAttribute('aria-expanded',String(open));if(open)$('#search-input').focus();});
$('#search-form').addEventListener('submit',event=>{event.preventDefault();const query=$('#search-input').value.trim();filter('all',false,false,query);$('#actualites').scrollIntoView();});
$('#reset-filter').addEventListener('click',()=>filter('all',false));
$('#load-more').addEventListener('click',()=>{state.page++;loadArticles(true);});
function favorites(){filter('all',false,true);$('#actualites').scrollIntoView();}
$('#bottom-favorites').addEventListener('click',favorites);$('#footer-favorites').addEventListener('click',favorites);
$('#bottom-home').addEventListener('click',()=>filter('all',true));
$('#close-reader').addEventListener('click',()=>closeReader());
$('#article-dialog').addEventListener('cancel',event=>{event.preventDefault();closeReader();});
$('#article-dialog').addEventListener('click',event=>{if(event.target===$('#article-dialog')){const rect=event.target.getBoundingClientRect();if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom)closeReader();}});
window.addEventListener('popstate',()=>{const slug=new URL(location.href).searchParams.get('article');if(slug)openArticle(slug,false);else closeReader(false);});
$('#edition-date').textContent=new Intl.DateTimeFormat('fr-CD',{weekday:'long',day:'numeric',month:'long',year:'numeric',timeZone:'Africa/Kinshasa'}).format(new Date());
$('#year').textContent=new Date().getFullYear();
loadHome();loadArticles();loadChannels();loadMedia();
const initialArticle=new URL(location.href).searchParams.get('article');if(initialArticle)openArticle(initialArticle,false);
