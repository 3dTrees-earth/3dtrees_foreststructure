FROM rocker/geospatial:4.5

ARG LIDR_VERSION=4.3.2
ARG LIDR_SHA256=3df920ff4146b0c29680c68e1fd654091906addbbdf9e3ae7e2fa8e964fec4e0

RUN install2.r --error --skipinstalled \
    argparse \
    BH \
    classInt \
    data.table \
    future \
    geometry \
    glue \
    lazyeval \
    parallelly \
    Rcpp \
    RcppArmadillo \
    rgl \
    rlas \
    sf \
    stars \
    terra \
    && wget --quiet \
      "https://cran.r-project.org/src/contrib/Archive/lidR/lidR_${LIDR_VERSION}.tar.gz" \
      -O /tmp/lidR.tar.gz \
    && printf '%s  %s\n' "${LIDR_SHA256}" /tmp/lidR.tar.gz \
      | sha256sum --check --strict \
    && R CMD INSTALL /tmp/lidR.tar.gz \
    && rm /tmp/lidR.tar.gz

COPY src /opt/foreststructure
RUN chmod -R a+rX /opt/foreststructure

ENTRYPOINT ["Rscript", "/opt/foreststructure/run.R"]
