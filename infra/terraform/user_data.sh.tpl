#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/midpoint-bootstrap.log) 2>&1

MIDPOINT_VERSION="${midpoint_version}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
DB_NAME="${db_name}"
DB_USER="${db_username}"
DB_PASSWORD="${db_password}"
PG_MAJOR="${pg_major_version}"
EFS_ID="${efs_id}"

dnf install -y java-21-amazon-corretto "postgresql$PG_MAJOR" tar wget amazon-efs-utils

id -u midpoint &>/dev/null || useradd --system --create-home --home-dir /opt/midpoint --shell /sbin/nologin midpoint

mkdir -p /opt/midpoint /tmp/midpoint-extract
cd /tmp
wget -q "https://download.evolveum.com/midpoint/$MIDPOINT_VERSION/midpoint-$MIDPOINT_VERSION-dist.tar.gz"
tar xzf "midpoint-$MIDPOINT_VERSION-dist.tar.gz" -C /tmp/midpoint-extract

# The dist tarball may or may not wrap its contents in a single top-level
# directory depending on version; handle both layouts.
top_count=$(find /tmp/midpoint-extract -mindepth 1 -maxdepth 1 | wc -l)
src_dir=$(find /tmp/midpoint-extract -mindepth 1 -maxdepth 1 -type d | head -n1)
if [ "$top_count" = "1" ] && [ -n "$src_dir" ]; then
  cp -a "$src_dir"/. /opt/midpoint/
else
  cp -a /tmp/midpoint-extract/. /opt/midpoint/
fi
rm -rf /tmp/midpoint-extract "/tmp/midpoint-$MIDPOINT_VERSION-dist.tar.gz"

# midpoint-home (var/) lives on EFS, not local disk: drop the dist's default
# var/ and mount the shared filesystem in its place.
rm -rf /opt/midpoint/var
mkdir -p /opt/midpoint/var
echo "$EFS_ID:/ /opt/midpoint/var efs _netdev,tls 0 0" >> /etc/fstab
for i in $(seq 1 30); do
  if mount /opt/midpoint/var; then
    break
  fi
  sleep 10
done
mountpoint -q /opt/midpoint/var

export PGPASSWORD="$DB_PASSWORD"

# Wait for the RDS instance to accept connections (it can still be
# finishing initialization when this instance boots).
for i in $(seq 1 60); do
  if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS intarray;"
psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

cd /opt/midpoint/doc/config/sql/native
psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -f postgres.sql
psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -f postgres-audit.sql
psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -v ON_ERROR_STOP=1 -f postgres-quartz.sql

cat > /opt/midpoint/var/config.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <midpoint>
        <repository>
            <type>native</type>
            <jdbcUrl>jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME</jdbcUrl>
            <jdbcUsername>$DB_USER</jdbcUsername>
            <jdbcPassword>$DB_PASSWORD</jdbcPassword>
        </repository>
    </midpoint>
</configuration>
EOF
chmod 600 /opt/midpoint/var/config.xml

chown -R midpoint:midpoint /opt/midpoint

cat > /etc/systemd/system/midpoint.service <<'EOF'
[Unit]
Description=MidPoint Standalone Service
After=network.target remote-fs.target
RequiresMountsFor=/opt/midpoint/var

[Service]
User=midpoint
WorkingDirectory=/opt/midpoint
ExecStart=/usr/bin/java -Xmx2048m -Dmidpoint.home=/opt/midpoint/var -jar /opt/midpoint/lib/midpoint.jar
SuccessExitStatus=143
TimeoutStopSec=120s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now midpoint
