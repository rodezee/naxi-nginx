FROM nginx:1.24.0-alpine-slim

ENV NGX_V=1.24.0
ENV NJS_VERSION=0.7.12

RUN set -x \
    && apkArch="$(cat /etc/apk/arch)" \
    && nginxPackages=" \
        nginx=${NGINX_VERSION}-r${PKG_RELEASE} \
        nginx-module-xslt=${NGINX_VERSION}-r${PKG_RELEASE} \
        nginx-module-geoip=${NGINX_VERSION}-r${PKG_RELEASE} \
        nginx-module-image-filter=${NGINX_VERSION}-r${PKG_RELEASE} \
        nginx-module-njs=${NGINX_VERSION}.${NJS_VERSION}-r${PKG_RELEASE} \
    " \
# install prerequisites for public key and pkg-oss checks
    && apk add --no-cache --virtual .checksum-deps \
        openssl \
    && case "$apkArch" in \
        x86_64|aarch64) \
# arches officially built by upstream
            set -x \
            && KEY_SHA512="e09fa32f0a0eab2b879ccbbc4d0e4fb9751486eedda75e35fac65802cc9faa266425edf83e261137a2f4d16281ce2c1a5f4502930fe75154723da014214f0655" \
            && wget -O /tmp/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub \
            && if echo "$KEY_SHA512 */tmp/nginx_signing.rsa.pub" | sha512sum -c -; then \
                echo "key verification succeeded!"; \
                mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/; \
            else \
                echo "key verification failed!"; \
                exit 1; \
            fi \
            && apk add -X "https://nginx.org/packages/alpine/v$(egrep -o '^[0-9]+\.[0-9]+' /etc/alpine-release)/main" --no-cache $nginxPackages \
            ;; \
        *) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from the published packaging sources
            set -x \
            && tempDir="$(mktemp -d)" \
            && chown nobody:nobody $tempDir \
            && apk add --no-cache --virtual .build-deps \
                gcc \
                libc-dev \
                make \
                openssl-dev \
                pcre2-dev \
                zlib-dev \
                linux-headers \
                libxslt-dev \
                gd-dev \
                geoip-dev \
                libedit-dev \
                bash \
                alpine-sdk \
                findutils \
            && su nobody -s /bin/sh -c " \
                export HOME=${tempDir} \
                && cd ${tempDir} \
                && curl -f -O https://hg.nginx.org/pkg-oss/archive/${NGINX_VERSION}-${PKG_RELEASE}.tar.gz \
                && PKGOSSCHECKSUM=\"dc47dbaeb1c0874b264d34ddfec40e7d2b814e7db48d144e12d5991c743ef5fcf780ecbab72324e562dd84bb9c0e4dd71d14850b20ceaf470c46f8fe7510275b *${NGINX_VERSION}-${PKG_RELEASE}.tar.gz\" \
                && if [ \"\$(openssl sha512 -r ${NGINX_VERSION}-${PKG_RELEASE}.tar.gz)\" = \"\$PKGOSSCHECKSUM\" ]; then \
                    echo \"pkg-oss tarball checksum verification succeeded!\"; \
                else \
                    echo \"pkg-oss tarball checksum verification failed!\"; \
                    exit 1; \
                fi \
                && tar xzvf ${NGINX_VERSION}-${PKG_RELEASE}.tar.gz \
                && cd pkg-oss-${NGINX_VERSION}-${PKG_RELEASE} \
                && cd alpine \
                && make module-geoip module-image-filter module-njs module-xslt \
                && apk index -o ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz ${tempDir}/packages/alpine/${apkArch}/*.apk \
                && abuild-sign -k ${tempDir}/.abuild/abuild-key.rsa ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz \
                " \
            && cp ${tempDir}/.abuild/abuild-key.rsa.pub /etc/apk/keys/ \
            && apk del .build-deps \
            && apk add -X ${tempDir}/packages/alpine/ --no-cache $nginxPackages \
            ;; \
    esac \
# remove checksum deps
    && apk del .checksum-deps \
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
    && if [ -n "$tempDir" ]; then rm -rf "$tempDir"; fi \
    && if [ -n "/etc/apk/keys/abuild-key.rsa.pub" ]; then rm -f /etc/apk/keys/abuild-key.rsa.pub; fi \
    && if [ -n "/etc/apk/keys/nginx_signing.rsa.pub" ]; then rm -f /etc/apk/keys/nginx_signing.rsa.pub; fi \
# Bring in curl and ca-certificates to make registering on DNS SD easier
    && apk add --no-cache curl ca-certificates

WORKDIR /root/

RUN wget https://nginx.org/download/nginx-${NGX_V}.tar.gz && \
    tar -zxvf nginx-${NGX_V}.tar.gz && \
    rm nginx-${NGX_V}.tar.gz

WORKDIR /root/nginx-${NGX_V}

RUN apk add --no-cache --virtual .compile git build-base pcre2-dev zlib-dev util-linux-dev gd-dev libxml2-dev openssl-dev openssl

# CUSTOM MODULE PART
ARG NGX_CUSTOM_MODULE_NAME=naxsi

ENV NGX_MOD_DIRNAME=nginx-${NGX_CUSTOM_MODULE_NAME}-module
ENV NGX_MOD_FILENAME=ngx_http_${NGX_CUSTOM_MODULE_NAME}_module
ENV NGX_MOD_SUBPATH=/naxsi_src

RUN git clone https://github.com/nbs-system/naxsi ../${NGX_MOD_DIRNAME} && rm -Rf ../${NGX_MOD_DIRNAME}/.git

RUN ./configure --with-compat --add-dynamic-module=../${NGX_MOD_DIRNAME}${NGX_MOD_SUBPATH}

#RUN make modules
RUN make
                
RUN cp ./objs/${NGX_MOD_FILENAME}.so /etc/nginx/modules/
RUN cp -ra ./objs/nginx /usr/sbin/nginx

# CONFIGURATION PART
RUN sed -i "1s#^#load_module modules/${NGX_MOD_FILENAME}.so;#" /etc/nginx/nginx.conf
RUN cat /etc/nginx/nginx.conf
RUN echo -e "\
include /root/${NGX_MOD_DIRNAME}/naxsi_config/naxsi_core.rules;\n\
\n\
server {\n\
    listen 80 default_server;\n\
\n\
    location / {\n\
        root /usr/share/nginx/html;\n\
\n\
        # Enable NAXSI\n\
        SecRulesEnabled;\n\
\n\
        # Define where blocked requests go\n\
        DeniedUrl "/50x.html";\n\
\n\
        # CheckRules, determining when NAXSI needs to take action\n\
        CheckRule "$SQL >= 8" BLOCK;\n\
        CheckRule "$RFI >= 8" BLOCK;\n\
        CheckRule "$TRAVERSAL >= 4" BLOCK;\n\
        CheckRule "$EVADE >= 4" BLOCK;\n\
        CheckRule "$XSS >= 8" BLOCK;\n\
\n\
        # Don’t forget the error_log, where blocked requests are logged\n\
        error_log /tmp/naxsi.log;\n\
    }\n\
\n\
    error_page   500 502 503 504  /50x.html;\n\
}\
" > /etc/nginx/conf.d/${NGX_MOD_DIRNAME}.conf
RUN cat /etc/nginx/conf.d/${NGX_MOD_DIRNAME}.conf
