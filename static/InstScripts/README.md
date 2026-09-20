# All-in-one installation

Run `install.sh` on Linux/macOS or `install.ps1` on Windows. Use the scripts and
assets from the same branch (`alpha` for these installers). The scripts verify
the downloaded Compose and nginx templates before configuring them.
The application images use `:latest`, the tag published by the frontend and
backend build workflows. The documentation branch name is independent of the
image tags; those workflows do not publish an `:alpha` tag.

## Accounts and secrets

On a fresh installation, Portainer's `admin` account is created automatically
using `--admin-password-file`. Sign in at `https://localhost:9443` with the password
in `project/portainer-admin-password.txt`. Keep this file private and in place:
it is mounted read-only into Portainer and reused on subsequent installer runs.
An existing Portainer data volume keeps its accounts and passwords; the file
does not reset them. No setup token is needed for the automatically created account.

This follows Portainer's documented [startup password options](https://docs.portainer.io/advanced/cli)
and [setup-token guidance](https://docs.portainer.io/faqs/installing/setup-token).
There is no need to disable setup-token protection with `--no-setup-token`.

New Django administrator passwords are 16 random URL-safe characters. Find the
username and password in `project/.env` or `project/credentials.txt`. Existing
`.env` files and existing accounts are preserved; rerunning the installer does
not shorten or reset an existing account's password.

`project/.env` contains separately generated `SECRET_KEY`, `SIGNING_KEY`,
`REVALIDATE_SECRET`, and `ADMIN_KEY`, each with a comment explaining its purpose.
Keep their uppercase names: these are the application environment variable names.
`ADMIN_KEY` is the CAP dashboard login key. After creating a CAP site, fill in
`CAP_SECRET` and `CAPTCHA_VERIFY_URL` and recreate the backend container.
Do not commit generated credentials to Git.

## nginx and networks

Enter the public site origin, for example `https://dev.rgsscs.org`, during setup.
The installer writes its hostname to `NGINX_SERVER_NAME` in `.env` and substitutes
it into `project/nginx.conf`. A local installation uses `localhost`. For older
`.env` files, the installer uses the first non-local hostname in `ALLOWED_HOSTS`;
set `NGINX_SERVER_NAME` explicitly if more than one public hostname is listed.
After installation, update `nginx.conf` directly when changing the domain, and
keep `NGINX_SERVER_NAME`, `ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS` consistent.

nginx serves `/media/` from the shared media volume and proxies `/static/` and
`/api/` to Django. Other paths go to Next.js. Requests allow up to 25 MB, with
120-second body/read/send timeouts and eight 128 KB large-header buffers.

The installer creates the shared Docker networks `internetwork` and `external`
if absent. Both nginx and CAP join `external`; existing service networks remain.
Here `external: true` means Docker Compose uses a pre-created network instead of
managing its lifecycle. It does not publish additional ports.

For manual Compose setup, copy `env.txt` to `.env`, fill the secrets with unique
random values, edit nginx's `server_name` to the real hostname, and create both
networks before starting the stack:

```sh
docker network inspect internetwork >/dev/null 2>&1 || docker network create internetwork
docker network inspect external >/dev/null 2>&1 || docker network create external
docker compose --env-file .env -f AIO_compose.yml up -d --wait
```
