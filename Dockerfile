FROM swift:6.3.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib \
    && install -m 0755 "$(swift build -c release --show-bin-path)/sql2sqlite" /usr/local/bin/

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/sql2sqlite /usr/local/bin/sql2sqlite
WORKDIR /data
ENTRYPOINT ["sql2sqlite"]
CMD ["--help"]
