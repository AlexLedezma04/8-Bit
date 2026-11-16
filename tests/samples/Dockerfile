# Build image.
FROM alpine:3.20 AS build
ARG VERSION=1
ENV APP_HOME="/app"
WORKDIR $APP_HOME
COPY . .
RUN apk add --no-cache gcc && make
CMD ["./app"]
