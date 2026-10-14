import { join } from 'node:path';
import express, { type RequestHandler, type Router } from 'express';
import helmet from 'helmet';

/**
 * What the Flutter web app may load. Everything comes from this server, except the rendering
 * engine (CanvasKit, from www.gstatic.com) and fonts (fonts.gstatic.com), which Flutter loads
 * from Google. CanvasKit is WebAssembly, hence 'wasm-unsafe-eval' (it does not allow eval()).
 */
export const webAppContentSecurityPolicy = helmet.contentSecurityPolicy({
  useDefaults: false,
  directives: {
    defaultSrc: ["'self'"],
    scriptSrc: ["'self'", "'wasm-unsafe-eval'", 'https://www.gstatic.com'],
    connectSrc: ["'self'", 'https://www.gstatic.com', 'https://fonts.gstatic.com'],
    fontSrc: ["'self'", 'https://fonts.gstatic.com', 'data:'],
    // Flutter sets styles on the elements it creates.
    styleSrc: ["'self'", "'unsafe-inline'"],
    imgSrc: ["'self'", 'data:', 'blob:'],
    workerSrc: ["'self'", 'blob:'],
    manifestSrc: ["'self'"],
    objectSrc: ["'none'"],
    baseUri: ["'self'"],
    formAction: ["'self'"],
    frameAncestors: ["'none'"],
  },
});

/**
 * Serves the built Flutter web app (flutter build web) from `dir`, so the app and the API share
 * one address: no CORS, one HTTPS certificate. Any page address that is not a file gets
 * index.html, so reloading the app works. Every file is revalidated on each visit (cheap, with
 * ETags), so staff get a new version as soon as it is deployed.
 */
export function webAppRouter(dir: string): Router {
  const router = express.Router();
  const noCache: RequestHandler = (_req, res, next) => {
    res.setHeader('Cache-Control', 'no-cache');
    next();
  };

  router.use(webAppContentSecurityPolicy, noCache);
  router.use(express.static(dir, { index: 'index.html', redirect: false }));
  router.get(/^(?!\/api(\/|$)).*/, (_req, res) => {
    res.sendFile(join(dir, 'index.html'));
  });
  return router;
}
