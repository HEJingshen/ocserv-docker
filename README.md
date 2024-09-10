# ocserv-docker
## Introduction
OpenConnect VPN server (ocserv) is an open source Linux SSL VPN server designed for organizations that require a remote access VPN with enterprise user management and control. **[OpenConnect Server](https://ocserv.openconnect-vpn.net/)**
## Features
- Flexible and easy editing the configurate and certificate files which no need to re-build the docker image.  
- Optimized for minimal size and efficient running.
## How to build the docker image
```
docker build -t ocserv:latest .
```
## Usage
Start the server with mounting external customized configurate and certificate files.<br>
```
docker run -d --name ocserv --privileged \
    -p 443:443/tcp -p 443:443/udp \
    -v /path/to/your/ocserv.conf:/etc/ocserv/ocserv.conf \
    -v /path/to/your/server-cert.pem:/etc/ocserv/server-cert.pem \
    -v /path/to/your/server-key.pem:/etc/ocserv/server-key.pem \
    ocserv:latest
```
You can create user with this command.<br>
```
docker exec -it ocserv ocpasswd -c /etc/ocserv/ocpasswd username
```
Or start the server with external pre-configurated user files.<br>
```
docker run -d --name ocserv --privileged \
    -p 443:443/tcp -p 443:443/udp \
    -v /path/to/your/ocserv.conf:/etc/ocserv/ocserv.conf \
    -v /path/to/your/server-cert.pem:/etc/ocserv/server-cert.pem \
    -v /path/to/your/server-key.pem:/etc/ocserv/server-key.pem \
    -v /path/to/your/ocpasswd:/etc/ocserv/ocpasswd \
    ocserv:latest
```