FROM golang:1.24-alpine AS build
ENV CGO_ENABLED=0 GOPROXY=https://goproxy.cn,direct
WORKDIR /src
COPY . .
RUN go build -trimpath -ldflags "-s -w" -o /go2rtc .

FROM ghcr.io/alexxit/go2rtc:1.9.13
COPY --from=build /go2rtc /usr/local/bin/go2rtc
