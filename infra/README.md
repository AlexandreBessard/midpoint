# MidPoint 4.10.5 — AWS infrastructure (no Docker)

Terraform that stands up a **single-node, native (non-containerized)** MidPoint deployment on AWS:

- A dedicated VPC (1 public subnet for the EC2 instance, 2 private subnets for RDS).
- One EC2 instance (Amazon Linux 2023) running MidPoint directly under systemd, installed from the
  official `midpoint-4.10.5-dist.tar.gz` distribution (Java 21 / Corretto, native binary launcher —
  no Tomcat/application server to install separately, it's bundled).
- One Amazon RDS for PostgreSQL instance, used as MidPoint's **native PostgreSQL repository**
  (`doc/config/sql/native/postgres.sql` + `postgres-audit.sql` + `postgres-quartz.sql`, run automatically
  on first boot).
- One Amazon EFS filesystem, mounted at `/opt/midpoint/var` (MidPoint's `midpoint-home`: keystore, logs,
  local config). Even with a single node, this keeps `midpoint-home` alive across instance
  termination/replacement, and means a later move to a multi-node HA cluster just adds mount targets
  rather than migrating data off local disk.

## Prerequisites

- Terraform >= 1.5, AWS CLI configured with credentials that can create VPC/EC2/RDS/IAM resources.
- Your own public IP address (for `admin_cidr` — never open the UI or SSH to `0.0.0.0/0`).
- AWS Session Manager plugin for the CLI if you want to use `aws ssm start-session` (recommended instead
  of SSH — no key pair/open port 22 needed).

## Deploy

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in admin_cidr
export TF_VAR_db_password='something-strong'   # don't put real secrets in tfvars if avoidable
terraform init
terraform plan
terraform apply
```

Apply takes a few minutes for RDS; the EC2 instance then needs another few minutes after boot to
download/install MidPoint and initialize the schema. Watch progress with the commands in the outputs:

```bash
terraform output ssm_connect_command   # run this to get a shell on the instance
# once connected:
tail -f /var/log/midpoint-bootstrap.log
journalctl -u midpoint -f
```

When `journalctl -u midpoint` shows the application has started, open the URL from:

```bash
terraform output midpoint_url_http
```

## Importing `objects/` config

`infra/scripts/import-midpoint-config.sh` imports a copy of this repo's `objects/` tree into the running
instance via `bin/ninja.sh` and restarts the service — handling the parts that never survive a move
between servers (connector OIDs, task auto-start). See `infra/scripts/README.md` for full usage,
requirements, and troubleshooting; that file is self-contained and travels with the script if you copy it
to another environment.

Quick start:
```bash
# on the instance, as root, after getting objects/ and the script there:
sudo chmod +x import-midpoint-config.sh
sudo MIDPOINT_ADMIN_PASSWORD='...' ./import-midpoint-config.sh /path/to/objects
```

## First login

- Username: `administrator`.
- MidPoint generates/requires an initial password on first startup rather than shipping a fixed default.
  Check `journalctl -u midpoint` (or `/opt/midpoint/var/log/midpoint.log`) right after the first boot for
  a line mentioning the initial/administrator password. If none is printed, use the bundled `bin/ninja.sh`
  tool on the instance to set it directly (see MidPoint docs: Post-Install Orientation /
  `repository → native-postgresql` for `ninja` usage). Change it immediately after first login either way.

## Notes / things to adjust before treating this as production

- **TLS**: both 8080 (HTTP) and 8443 (HTTPS, self-signed cert) are opened to `admin_cidr`. For real use,
  put this behind a proper certificate (ACM + ALB, or a reverse proxy with Let's Encrypt) rather than
  exposing the instance's self-signed cert directly.
- **DB credentials**: the RDS master user is reused directly as MidPoint's repository JDBC user for
  simplicity. For a hardened setup, create a dedicated least-privilege PostgreSQL role owning the
  `midpoint` schema and use that instead.
- **Sizing**: defaults (`t3.large` EC2, `db.t4g.medium` RDS, 2048m JVM heap in the systemd unit) match
  Evolveum's "< 5,000 users" sizing guidance. Adjust `instance_type`, `db_instance_class`, and the
  `-Xmx` flag in `user_data.sh.tpl` together if you scale up.
- **Backups**: RDS automated backups are enabled (7-day retention). EFS (`midpoint-home`) is not backed
  up by this Terraform — enable AWS Backup for the filesystem if you want point-in-time recovery of
  keystore/logs/local config.
- `db_password` and the generated `terraform.tfstate` contain secrets — both are gitignored from
  `infra/terraform/`; never commit either.

## Destroy

```bash
terraform destroy
```

This deletes the RDS instance (final snapshot is skipped by default — set `db_skip_final_snapshot = false`
first if you want one kept).
