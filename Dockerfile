FROM evolveum/midpoint:4.10.1-alpine

USER root

# Configuration MidPoint provenant du repository Git
COPY objects/ /opt/midpoint/objects/

# Scripts d'import de la configuration (local direct-repo / ECS REST)
COPY import-config.sh /opt/midpoint/import-config.sh
COPY import-config-ecs.sh /opt/midpoint/import-config-ecs.sh
RUN chmod +x /opt/midpoint/import-config.sh /opt/midpoint/import-config-ecs.sh

USER midpoint