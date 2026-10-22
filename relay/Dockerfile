FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /pling-relay .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /pling-relay /pling-relay
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/pling-relay"]
