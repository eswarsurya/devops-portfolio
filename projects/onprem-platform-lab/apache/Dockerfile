# Apache + PHP (WordPress image) with LDAP authentication and per-node identification
FROM wordpress:6.6.2-php8.3-apache
RUN a2enmod ldap authnz_ldap headers status
COPY lab.conf /etc/apache2/conf-enabled/lab.conf
COPY ops/ /srv/ops/
