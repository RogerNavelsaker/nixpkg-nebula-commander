# Nebula Commander OCI images

Nix-built, rootless OCI images for the separate Nebula Commander backend and frontend services. Images target x86_64 Linux, run as UID/GID 10001:10001, and expose no package manager or shell on the configured PATH.

The images package upstream Nebula Commander v0.8.1. The backend includes only the Nixpkgs Nebula cert-signing executable, nebula-cert 1.11.2.

## Build

~~~sh
nix flake check
nix build .#backend
nix build .#frontend
~~~

The frontend bundle is built with Bun from the checked-in `frontend.bun.lock`.

Each build produces a Podman/Docker-loadable archive in result:

~~~sh
podman load --input result
~~~

The frontend listens on port 8080 so it can run without root or privileged-port capabilities. It proxies /api and /ws to a backend service discoverable as backend:8081 on the same container network. Client downloads under /downloads/ redirect to the matching upstream GitHub release rather than enlarging the frontend image.

## Runtime contract

### Backend

- Image: nebula-commander-backend:0.8.1
- Listen: 0.0.0.0:8081 (TCP; keep it private)
- Persistent data: /var/lib/nebula-commander (SQLite database and certificate store)
- Runtime note: Python's Nix closure retains Bash at a store path for subprocess shell support; it is not on the configured PATH.
- Required secrets: set NEBULA_COMMANDER_JWT_SECRET_FILE and NEBULA_COMMANDER_ENCRYPTION_KEY_FILE to readable secret-file paths. The backend intentionally refuses to start with the insecure JWT default or without a valid Fernet encryption key.
- Optional configuration uses upstream NEBULA_COMMANDER_* environment variables, including OIDC, public URL, and SMTP settings.

Generate separate keys (requires OpenSSL):

~~~sh
umask 077
openssl rand -base64 48 > jwt-secret
openssl rand -base64 32 | tr '/+' '_-' > encryption-key
podman secret create nebula-jwt jwt-secret
podman secret create nebula-encryption encryption-key
~~~

Mount those secrets read-only at /run/secrets/jwt-secret and /run/secrets/encryption-key, and set the corresponding *_FILE variables. Back up the encryption key with the database; losing it makes encrypted data unreadable. Do not regenerate either key for an existing deployment.

The backend trusts forwarded client headers because the frontend is expected to be its only network peer. Keep the backend on a private container network and do not publish port 8081 directly to untrusted clients.

### Frontend and ingress

- Image: nebula-commander-frontend:0.8.1
- Listen: 0.0.0.0:8080 (TCP)
- Put it behind the existing Cloudflare/Caddy ingress for HTTPS access. Caddy should forward the original X-Forwarded-Proto value; Nginx preserves http/https from that trusted ingress when proxying to the backend.
- A Nebula mesh gateway is not part of these images. If you decide to provide tailnet-gateway-equivalent routing over Nebula, keep that gateway as a separate project/image.

### Rootless Podman example

Create the data directory, map ownership for rootless Podman, and create a private service network:

~~~sh
mkdir -p data
podman unshare chown -R 10001:10001 data
podman network create nebula-commander

podman run -d --name commander-backend \
  --network nebula-commander --network-alias backend \
  --volume "$PWD/data:/var/lib/nebula-commander" \
  --secret nebula-jwt,target=jwt-secret,uid=10001,gid=10001,mode=0400 \
  --secret nebula-encryption,target=encryption-key,uid=10001,gid=10001,mode=0400 \
  --env NEBULA_COMMANDER_JWT_SECRET_FILE=/run/secrets/jwt-secret \
  --env NEBULA_COMMANDER_ENCRYPTION_KEY_FILE=/run/secrets/encryption-key \
  nebula-commander-backend:0.8.1

podman run -d --name commander-frontend \
  --network nebula-commander --publish 127.0.0.1:8080:8080 \
  nebula-commander-frontend:0.8.1
~~~

Connect the existing Caddy ingress to the frontend on host port 8080 (or attach it to the same container network). Only the frontend port is published. A separate database, OIDC provider, SMTP server, and reverse proxy are not bundled in these images.
