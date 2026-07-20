FROM rocker/geospatial:4.5

RUN install2.r --error --skipinstalled \
    argparse \
    data.table \
    lidR \
    rlas

COPY src /opt/foreststructure

ENTRYPOINT ["Rscript", "/opt/foreststructure/run.R"]
