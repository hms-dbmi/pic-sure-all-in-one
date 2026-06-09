# Frontend dev build — generates .env from build args so the developer
# doesn't have to manually create one. Values come from the all-in-one .env
# via docker-compose.dev-httpd.yml build args.
#
# Falls back to .env.example defaults for anything not provided.

FROM node:24.14.1-alpine3.23@sha256:01743339035a5c3c11a373cd7c83aeab6ed1457b55da6a69e014a95ac4e4700b AS env-builder

WORKDIR /app
COPY .env.example .env

# Values injected from the all-in-one .env at build time
ARG VITE_RESOURCE_HPDS
ARG VITE_RESOURCE_OPEN_HPDS
ARG VITE_RESOURCE_VIZ
ARG VITE_AUTH0_TENANT
ARG VITE_AUTH_PROVIDER_MODULE_GOOGLE_CLIENTID
ARG VITE_AUTH_PROVIDER_MODULE_GOOGLE_CONNECTION=google-oauth2
ARG THEME=picsure

# Overwrite .env values with build args (only if non-empty)
RUN set -e; \
    update_env() { \
      key="$1"; val="$2"; \
      if [ -n "$val" ]; then \
        if grep -q "^${key}=" .env; then \
          sed -i "s|^${key}=.*|${key}=${val}|" .env; \
        else \
          echo "${key}=${val}" >> .env; \
        fi; \
      fi; \
    }; \
    update_env VITE_RESOURCE_HPDS "$VITE_RESOURCE_HPDS"; \
    update_env VITE_RESOURCE_OPEN_HPDS "$VITE_RESOURCE_OPEN_HPDS"; \
    update_env VITE_RESOURCE_VIZ "$VITE_RESOURCE_VIZ"; \
    update_env VITE_AUTH0_TENANT "$VITE_AUTH0_TENANT"; \
    update_env VITE_AUTH_PROVIDER_MODULE_GOOGLE_CLIENTID "$VITE_AUTH_PROVIDER_MODULE_GOOGLE_CLIENTID"; \
    update_env VITE_AUTH_PROVIDER_MODULE_GOOGLE_CONNECTION "$VITE_AUTH_PROVIDER_MODULE_GOOGLE_CONNECTION"

# --- Now do the normal frontend build ---
FROM node:24.14.1-alpine3.23@sha256:01743339035a5c3c11a373cd7c83aeab6ed1457b55da6a69e014a95ac4e4700b AS builder
RUN npm install -g pnpm@10.24.0

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .
RUN pnpm install --prod
COPY src src
COPY static static
COPY --from=env-builder /app/.env .env
COPY svelte.config.js vite.config.ts ./
ARG THEME=picsure
RUN sed -i 's/%sveltekit.assets%\/favicon.ico/%sveltekit.assets%\/'$THEME'-favicon.png/' ./src/app.html
RUN sed -i 's/data-theme="[^"]*"/data-theme=\"'$THEME'\"/' ./src/app.html
RUN pnpm build

# --- Serve with httpd ---
FROM httpd:2.4.66-alpine3.23@sha256:8f26f33a7002658050e9ab2cd6b77502619dfc89d0a6ba2e9e4a202e0ef04596

RUN apk add --no-cache \
  openssl \
  sed \
  nodejs \
  supervisor \
  libexpat=2.7.5-r0 \
  zlib=1.3.2-r0

RUN mkdir -p ${HTTPD_PREFIX}/cert

RUN sed -i '/^#Include conf.extra.httpd-vhosts.conf/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf

RUN sed -i '/^#LoadModule proxy_module/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf
RUN sed -i '/^#LoadModule proxy_http_module/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf
RUN sed -i '/^#LoadModule proxy_connect_module/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf

RUN sed -i '/^#LoadModule ssl_module modules\/mod_ssl.so/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf
RUN sed -i '/^#LoadModule rewrite_module modules\/mod_rewrite.so/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf
RUN sed -i '/^#LoadModule socache_shmcb_module modules\/mod_socache_shmcb.so/s/^#//' ${HTTPD_PREFIX}/conf/httpd.conf
RUN mkdir -p /usr/local/apache2/logs/ssl_mutex
RUN sed -i 's/Options Indexes FollowSymLinks/Options -Indexes +FollowSymLinks/' ${HTTPD_PREFIX}/conf/httpd.conf

WORKDIR /app
RUN mkdir -p logs
COPY --from=builder /app/build build/
COPY --from=builder /app/node_modules node_modules/
COPY package.json .
ENV NODE_ENV=production
ENV XFF_DEPTH=1
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO /dev/null --no-check-certificate https://0.0.0.0:443/picsure/health || exit 1
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
