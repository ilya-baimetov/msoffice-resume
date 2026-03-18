import { createApp } from "./OfficeResumeBackend/src/worker.js";

const API_PREFIX = "/api";

function rewriteRequestForBackend(request) {
  const url = new URL(request.url);
  const suffix = url.pathname.slice(API_PREFIX.length) || "/";
  url.pathname = suffix.startsWith("/") ? suffix : `/${suffix}`;
  return new Request(url.toString(), request);
}

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);
    if (url.pathname === API_PREFIX || url.pathname.startsWith(`${API_PREFIX}/`)) {
      if (!globalThis.__officeResumeUnifiedWorkerApp) {
        globalThis.__officeResumeUnifiedWorkerApp = createApp(null, {
          env,
          apiBasePath: API_PREFIX,
        });
      }

      return globalThis.__officeResumeUnifiedWorkerApp(
        rewriteRequestForBackend(request),
        env,
        context,
      );
    }

    return env.ASSETS.fetch(request);
  },
};
