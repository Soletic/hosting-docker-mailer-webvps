FROM soletic/ubuntu
MAINTAINER Sol&TIC <serveur@soletic.org>

# APACHE GIT PHP5 MYSQL CLIENT
RUN apt-get -y update && \
  apt-get -y install nullmailer uuid-runtime

ENV DATA_VOLUME_HOME /home
VOLUME ["${DATA_VOLUME_HOME}"]

# SMTP parameters like this : <host>:<port>:<user>:<password>:<no|ssl>:<no|starttls>
ENV MAILER_SMTP ""
ADD start-mailer.sh /root/scripts/start-mailer.sh
ADD supervisord-mailer.conf /etc/supervisor/conf.d/supervisord-mailer.conf

# MAKE SCRIPT EXCUTABLE
RUN chmod 755 /root/scripts/*.sh