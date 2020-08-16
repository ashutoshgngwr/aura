FROM nginx:1.19.1

ADD nginx-conf/nginx.conf /etc/nginx/nginx.conf
ADD nginx-conf/default.conf.template /etc/nginx/conf.d/default.conf.template
ADD output /usr/share/nginx/html/aura

RUN echo '<!DOCTYPE html><html><head> \
  <meta http-equiv="refresh" content="0; url=https://github.com/ashutoshgngwr/aura" /> \
  </head><body></body></html>' > /usr/share/nginx/html/index.html

CMD /bin/bash -c "envsubst '\$PORT' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf" && nginx -g 'daemon off;'
