FROM evolveum/midpoint:4.10.1-alpine

USER root

# Configuration MidPoint provenant du repository Git
COPY objects/ /opt/midpoint/objects/

# Script d'import de la configuration
COPY import-config.sh /opt/midpoint/import-config.sh
RUN chmod +x /opt/midpoint/import-config.sh

USER midpoint