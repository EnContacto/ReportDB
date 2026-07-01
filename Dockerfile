FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

# Instalar sqlcmd y herramientas de línea de comandos de SQL Server
RUN apt-get update && \
    apt-get install -y curl apt-transport-https gnupg2 && \
    curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev && \
    # Limpiar cache para reducir tamaño de imagen
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Agregar herramientas al PATH para todos los usuarios
RUN echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> /etc/bash.bashrc
ENV PATH="$PATH:/opt/mssql-tools18/bin"

# Crear directorio para resultados y backups, asegurando permisos para 'mssql'
RUN mkdir -p /backups/full /backups/diff /backups/log /results && \
    chown -R mssql:mssql /backups /results && \
    chmod -R 755 /backups /results

# Volver al usuario mssql para la ejecución del servicio
USER mssql

EXPOSE 1433

# iniciar SQL Server.
CMD ["/opt/mssql/bin/sqlservr"]