FROM golang:1.23-bookworm AS build
WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/cloudviewer-api ./

FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build /out/cloudviewer-api /cloudviewer-api
EXPOSE 8080
ENTRYPOINT ["/cloudviewer-api"]
