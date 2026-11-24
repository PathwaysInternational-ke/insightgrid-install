# InsightGrid installer

Installs or upgrades InsightGrid on a client-managed Linux server with one command:

```
curl -fsSL https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh | bash
```

## What you need

- An Ubuntu or Debian server (x86_64) and a named administrator account with sudo. Run the command as that account, without sudo: the script asks for sudo itself, so Ctrl+C keeps working (it asks before stopping).
- A registry username and read-only access token from Pathways.
- Outbound HTTPS to `ghcr.io`, Docker Hub and `download.docker.com` (or ask Pathways for the offline bundle).

## What it does

1. Checks the platform and who is running it. A direct root login must confirm.
2. Installs Docker Engine if it is missing.
3. Signs in to Pathways' private registry with your token and downloads the release bundle.
4. Analyses the server (Docker, tools, CPU and memory, free disk, ports, internet access) and stops with a fix for anything that blocks an install.
5. Asks the site questions once: public or private network, hostname, organisation, first admin, email, add-ons.
6. Installs in numbered steps, then prints the address and where the first admin password is stored.

Run the same command again to upgrade: it takes a backup first. Site settings and secrets live in `/opt/insightgrid`; keep a copy of `/opt/insightgrid/secrets.env` safe.

To check a server without changing anything, run the installer's analysis after the first download:

```
sudo /opt/insightgrid-releases/<release>/install.sh check
```

The InsightGrid application and its images are proprietary to Pathways Technologies and licensed separately. This repository holds only the bootstrap script.
