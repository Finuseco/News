import { createApp } from './app.js';

const port = Number(process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT doit être un entier entre 1 et 65535.');
const server = createApp();
server.listen(port, process.env.HOST ?? '0.0.0.0', () => {
  console.log(`Lacruche.cd : http://localhost:${port} (contenus de démonstration)`);
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
