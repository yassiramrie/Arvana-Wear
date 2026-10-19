FROM nginx:1.31.7-alpine3.24@sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d

RUN apk upgrade --no-cache

COPY nginx/k8s.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/index.html
COPY images/ /usr/share/nginx/html/images/

USER 101:101
EXPOSE 8080
