// Public API used by the responsive website. The future React Native client can use the same /api/v1 contract.
const BASE = '/api/v1';
export async function request(path, params = {}, signal) {
  const url = new URL(`${BASE}${path}`, window.location.origin);
  for (const [key, value] of Object.entries(params)) if (value !== '' && value != null) url.searchParams.set(key, String(value));
  const response = await fetch(url, { headers: { Accept: 'application/json' }, signal });
  if (!response.ok) throw new Error(`Le service est momentanément indisponible (${response.status}).`);
  return response.json();
}
export const api = {
  home: () => request('/home'),
  articles: (params, signal) => request('/articles', params, signal),
  article: slug => request(`/articles/${encodeURIComponent(slug)}`),
  media: () => request('/media'),
  channels: type => request('/channels', { type }),
};
