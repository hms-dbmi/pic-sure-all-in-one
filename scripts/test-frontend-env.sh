#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/frontend-env.sh
source "$SCRIPT_DIR/lib/frontend-env.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/aio.env" <<'ENV'
PICSURE_THEME=local
VITE_CONFIG_MODE=override
VITE_LOGO='/my logo.svg'
VITE_ANALYZE_API=false
VITE_GOOGLE_ANALYTICS_ID=
VITE_ORIGIN=https://demo.example
DB_ROOT_PASSWORD=do-not-forward
AUTH0_CLIENT_SECRET=do-not-forward
VITE_RESOURCE_HPDS=obsolete
ENV
# shellcheck disable=SC1091
source "$tmp/aio.env"
picsure_frontend_env "$tmp/aio.env" > "$tmp/actual"
cat > "$tmp/expected" <<'ENV'
VITE_ANALYZE_API='false'
VITE_CONFIG_MODE='override'
VITE_GOOGLE_ANALYTICS_ID=''
VITE_LOGO='/my logo.svg'
VITE_THEME='local'
VITE_ORIGIN='https://demo.example'
ENV
diff -u "$tmp/expected" "$tmp/actual"
picsure_frontend_env "$tmp/aio.env" hmr > "$tmp/hmr"
sed "s|https://demo.example|http://localhost:3000|" "$tmp/expected" > "$tmp/expected-hmr"
diff -u "$tmp/expected-hmr" "$tmp/hmr"
mkdir "$tmp/frontend"
printf 'developer config\n' > "$tmp/frontend/.env"
cp "$tmp/frontend/.env" "$tmp/original"
check_build() { diff -u "$tmp/expected" "$tmp/frontend/.env"; }
picsure_frontend_with_env "$tmp/frontend" "$tmp/aio.env" check_build
diff -u "$tmp/original" "$tmp/frontend/.env"
if picsure_frontend_with_env "$tmp/frontend" "$tmp/aio.env" false; then exit 1; fi
diff -u "$tmp/original" "$tmp/frontend/.env"
rm "$tmp/frontend/.env"
picsure_frontend_with_env "$tmp/frontend" "$tmp/aio.env" true
[ ! -e "$tmp/frontend/.env" ]
ln -s "$tmp/original" "$tmp/frontend/.env"
picsure_frontend_with_env "$tmp/frontend" "$tmp/aio.env" check_build
[ -L "$tmp/frontend/.env" ]
printf 'developer config\n' | diff -u - "$tmp/original"
export VITE_LOGO="can't-encode"
if picsure_frontend_env "$tmp/aio.env" > /dev/null 2>&1; then exit 1; fi
echo 'Frontend environment tests passed.'

# Exercise the public scripts/CLI entry point with Docker stubbed. Both dev
# modes must receive the same explicit settings and no inherited stack secrets.
export VITE_LOGO='/my logo.svg'
mkdir -p "$tmp/project/scripts/lib" "$tmp/project/config/httpd" "$tmp/project/repos/PIC-SURE-Frontend" "$tmp/bin"
cp "$SCRIPT_DIR/compose.sh" "$SCRIPT_DIR/picsure-compose.sh" "$tmp/project/scripts/"
cp "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/lib/frontend-env.sh" "$tmp/project/scripts/lib/"
cp "$SCRIPT_DIR/../docker-compose.dev-httpd.yml" "$SCRIPT_DIR/../docker-compose.dev-httpd-hmr.yml" "$tmp/project/"
cp "$tmp/aio.env" "$tmp/project/.env"
printf '24.19.0\n' > "$tmp/project/repos/PIC-SURE-Frontend/.nvmrc"
printf 'developer config\n' > "$tmp/project/repos/PIC-SURE-Frontend/.env"
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = compose ]
case "$*" in
  *dev-httpd-hmr.yml*)
    [ "$FRONTEND_NODE_VERSION" = 24.19.0 ]
    diff -u "$EXPECTED_HMR" "$PICSURE_ROOT/.data/frontend/hmr.env"
    ;;
  *dev-httpd.yml*) diff -u "$EXPECTED_COMPILED" "$FRONTEND_SRC/.env" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/docker"
export EXPECTED_HMR="$tmp/expected-hmr" EXPECTED_COMPILED="$tmp/expected"
PATH="$tmp/bin:$PATH" bash "$tmp/project/scripts/compose.sh" dev up httpd
printf 'developer config\n' | diff -u - "$tmp/project/repos/PIC-SURE-Frontend/.env"
PATH="$tmp/bin:$PATH" bash "$tmp/project/scripts/compose.sh" dev up httpd-hmr
printf 'developer config\n' | diff -u - "$tmp/project/repos/PIC-SURE-Frontend/.env"
echo 'Compiled/HMR wrapper tests passed.'
# Public values must not interpolate server credentials during Vite's dotenv
# expansion, even if the operator deliberately used literal dollar characters.
# shellcheck disable=SC2016
picsure_frontend_env_line VITE_LOGO '${DB_ROOT_PASSWORD}' > "$tmp/literal"
cat > "$tmp/literal-expected" <<'ENV'
VITE_LOGO='\${DB_ROOT_PASSWORD}'
ENV
diff -u "$tmp/literal-expected" "$tmp/literal"
