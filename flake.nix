{
  description = "Rootless Nix-built OCI images for Nebula Commander";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      version = "0.8.1";
      source = pkgs.fetchFromGitHub {
        owner = "NixRTR";
        repo = "nebula-commander";
        rev = "v${version}";
        hash = "sha256-JcYg1N4YlGHHshyFxEQoiIkN85//4wo4q5KjrcuFXbk=";
      };

      nebula = assert pkgs.nebula.version == "1.11.2"; pkgs.nebula;
      nebulaCert = pkgs.runCommand "nebula-cert" { } ''
        mkdir -p "$out/bin"
        cp ${nebula}/bin/nebula-cert "$out/bin/nebula-cert"
        chmod +x "$out/bin/nebula-cert"
      '';

      # Drop websockets' unused Bash-wrapped CLI from the runtime closure.
      websocketsNoCli = pkgs.python313Packages.websockets.overridePythonAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          rm "$out/bin/websockets"
        '';
      });

      python = pkgs.python313.withPackages (ps: with ps; [
        fastapi
        uvicorn
        uvloop
        httptools
        websocketsNoCli
        python-multipart
        sqlalchemy
        greenlet
        aiosqlite
        pydantic
        pydantic-settings
        email-validator
        pyyaml
        python-jose
        cryptography
        httpx
        authlib
        itsdangerous
        aiosmtplib
        jinja2
      ]);

      fakeNss = pkgs.dockerTools.fakeNss.override {
        extraPasswdLines = [ "nebula-commander:x:10001:10001:Nebula Commander:/tmp:/sbin/nologin" ];
        extraGroupLines = [ "nebula-commander:x:10001:" ];
      };

      backendApp = pkgs.runCommand "nebula-commander-backend-${version}" { } ''
        mkdir -p "$out"
        cp -r ${source}/backend "$out/backend"
        chmod -R u+w "$out/backend"
        rm -rf "$out/backend/tests"
      '';

      frontendDeps = pkgs.stdenvNoCC.mkDerivation {
        name = "nebula-commander-frontend-bun-deps-${version}";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.bun ];
        outputHashMode = "recursive";
        outputHash = "sha256-ouF8kqngvXUxFvMaTgmdWSQXC8g0IoKWnY2LxDJnMRY=";
        dontFixup = true;
        installPhase = ''
          export HOME="$TMPDIR/home"
          export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
          mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR" "$TMPDIR/frontend"
          cd "$TMPDIR/frontend"
          cp ${source}/frontend/package.json package.json
          cp ${./frontend.bun.lock} bun.lock
          bun install --frozen-lockfile --ignore-scripts --backend=copyfile
          mkdir -p "$out"
          cp -a node_modules "$out/"
        '';
      };

      frontend = pkgs.stdenvNoCC.mkDerivation {
        pname = "nebula-commander-frontend";
        inherit version;
        src = "${source}/frontend";
        nativeBuildInputs = [ pkgs.bun ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          cp -a ${frontendDeps}/node_modules ./node_modules
          mkdir -p "$TMPDIR/bin"
          ln -s ${pkgs.bun}/bin/bun "$TMPDIR/bin/node"
          export PATH="$TMPDIR/bin:$PATH"
          patchShebangs node_modules
          export VITE_APP_VERSION=${version}
          bun run --bun build
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -r dist "$out/"
          runHook postInstall
        '';
      };

      frontendSite = pkgs.runCommand "nebula-commander-webroot-${version}" { } ''
        mkdir -p "$out/html/downloads"
        cp -r ${frontend}/dist/. "$out/html/"
      '';

      nginxConf = pkgs.writeText "nebula-commander-nginx.conf" ''
        worker_processes 1;
        pid /tmp/nginx.pid;
        error_log /dev/stderr warn;

        events {
          worker_connections 1024;
        }

        http {
          include ${pkgs.nginx}/conf/mime.types;
          default_type application/octet-stream;
          access_log /dev/stdout;
          server_tokens off;
          sendfile on;
          gzip on;
          gzip_vary on;
          gzip_min_length 1024;
          gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json application/javascript;

          map $http_x_forwarded_proto $forwarded_proto {
            default $scheme;
            http http;
            https https;
          }

          client_body_temp_path /tmp/client_body;
          proxy_temp_path /tmp/proxy_temp;
          fastcgi_temp_path /tmp/fastcgi_temp;
          uwsgi_temp_path /tmp/uwsgi_temp;
          scgi_temp_path /tmp/scgi_temp;

          server {
            listen 8080;
            server_name _;
            root ${frontendSite}/html;
            index index.html;

            location / {
              try_files $uri $uri/ /index.html;
            }

            location /api {
              proxy_pass http://backend:8081;
              proxy_set_header Host $http_host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $forwarded_proto;
              proxy_set_header X-Forwarded-Host $http_host;
              proxy_set_header X-Forwarded-Port $server_port;
              proxy_http_version 1.1;
              proxy_buffering off;
              proxy_cache off;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
            }

            location /ws {
              proxy_pass http://backend:8081;
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $forwarded_proto;
              proxy_read_timeout 86400;
              proxy_send_timeout 86400;
            }

            location /health {
              access_log off;
              default_type text/plain;
              return 200 "healthy\n";
            }

            # Client packages redirect to the version-matched upstream release.
            location ~ ^/downloads/(.+)$ {
              return 302 https://github.com/NixRTR/nebula-commander/releases/download/v${version}/$1$is_args$args;
            }

            location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
              expires 1y;
              add_header Cache-Control "public, immutable";
            }
          }
        }
      '';

      backendImage = pkgs.dockerTools.buildLayeredImage {
        name = "nebula-commander-backend";
        tag = version;
        created = "1970-01-01T00:00:01Z";
        contents = [ backendApp python nebulaCert fakeNss pkgs.cacert pkgs.tzdata ];
        config = {
          User = "10001:10001";
          WorkingDir = "/app";
          Entrypoint = [ "${python}/bin/python" "-m" "uvicorn" "backend.main:app" ];
          Cmd = [ "--host" "0.0.0.0" "--port" "8081" "--proxy-headers" "--forwarded-allow-ips=*" ];
          Env = [
            "HOME=/tmp"
            "PYTHONPATH=/app"
            "PYTHONUNBUFFERED=1"
            "PATH=${nebulaCert}/bin:${python}/bin"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "TZDIR=${pkgs.tzdata}/share/zoneinfo"
            "NEBULA_COMMANDER_DATABASE_URL=sqlite+aiosqlite:////var/lib/nebula-commander/db.sqlite"
            "NEBULA_COMMANDER_CERT_STORE_PATH=/var/lib/nebula-commander/certs"
            "NEBULA_COMMANDER_SERVER_HOST=0.0.0.0"
            "NEBULA_COMMANDER_SERVER_PORT=8081"
          ];
          ExposedPorts = { "8081/tcp" = { }; };
          Volumes = { "/var/lib/nebula-commander" = { }; };
          Labels = {
            "org.opencontainers.image.title" = "Nebula Commander Backend";
            "org.opencontainers.image.version" = version;
            "org.opencontainers.image.licenses" = "MIT";
            "org.opencontainers.image.source" = "https://github.com/NixRTR/nebula-commander";
            "org.opencontainers.image.description" = "Rootless Nix-built Nebula Commander API backend";
          };
          Healthcheck = {
            Test = [
              "CMD"
              "${python}/bin/python"
              "-c"
              "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/api/health', timeout=2)"
            ];
            Interval = 30000000000;
            Timeout = 10000000000;
            StartPeriod = 5000000000;
            Retries = 3;
          };
        };
        fakeRootCommands = ''
          mkdir -p ./app ./var/lib/nebula-commander/certs ./tmp
          ln -s ${backendApp}/backend ./app/backend
          chown -R 10001:10001 ./var/lib/nebula-commander
          chmod 0700 ./var/lib/nebula-commander
          chmod 1777 ./tmp
        '';
      };

      frontendImage = pkgs.dockerTools.buildLayeredImage {
        name = "nebula-commander-frontend";
        tag = version;
        created = "1970-01-01T00:00:01Z";
        contents = [ frontendSite fakeNss pkgs.nginx ];
        config = {
          User = "10001:10001";
          WorkingDir = "/tmp";
          Entrypoint = [ "${pkgs.nginx}/bin/nginx" ];
          Cmd = [ "-g" "daemon off;" "-c" "${nginxConf}" ];
          Env = [ "HOME=/tmp" "PATH=${pkgs.nginx}/bin" ];
          ExposedPorts = { "8080/tcp" = { }; };
          Labels = {
            "org.opencontainers.image.title" = "Nebula Commander Frontend";
            "org.opencontainers.image.version" = version;
            "org.opencontainers.image.licenses" = "MIT";
            "org.opencontainers.image.source" = "https://github.com/NixRTR/nebula-commander";
            "org.opencontainers.image.description" = "Rootless Nix-built Nebula Commander frontend and reverse proxy";
          };
        };
        fakeRootCommands = ''
          mkdir -p ./tmp
          chmod 1777 ./tmp
        '';
      };

      runtimeContract = pkgs.runCommand "nebula-commander-runtime-contract" {
        nativeBuildInputs = [ pkgs.gnugrep pkgs.gnused pkgs.nginx ];
      } ''
        test -x ${nebulaCert}/bin/nebula-cert
        test -d ${backendApp}/backend
        test -f ${frontendSite}/html/index.html
        grep -F "listen 8080;" ${nginxConf}
        grep -F "proxy_pass http://backend:8081;" ${nginxConf}
        grep -F "releases/download/v${version}/" ${nginxConf}
        sed 's#http://backend:8081#http://127.0.0.1:8081#g' ${nginxConf} > "$TMPDIR/nginx.conf"
        nginx -t -e stderr -c "$TMPDIR/nginx.conf"
        NEBULA_COMMANDER_DATABASE_URL="sqlite+aiosqlite:///$TMPDIR/db.sqlite" \
        NEBULA_COMMANDER_CERT_STORE_PATH="$TMPDIR/certs" \
        NEBULA_COMMANDER_JWT_SECRET_KEY=packaging-self-check \
        NEBULA_COMMANDER_ENCRYPTION_KEY="$(
          ${python}/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'
        )" \
        PYTHONPATH=${backendApp} ${python}/bin/python -c 'import backend.main'
        touch "$out"
      '';
    in {
      packages.${system} = {
        backend = backendImage;
        frontend = frontendImage;
        default = backendImage;
      };

      checks.${system} = {
        backend = backendImage;
        frontend = frontendImage;
        runtime-contract = runtimeContract;
      };
    };
}
