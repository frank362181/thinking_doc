FROM hyperledger/fabric-peer:amd64-1.4.0

RUN apt-get update && apt-get install -y net-tools curl inetutils-ping rsync openssh-client && rm -rf /var/cache/apt

ENV APPNAME="fabric.peer" \
    CLUSTER="peer0.tongdun" \
	ENV="dev" \
	LOG_LEVEL="info" \
    CONFIG_SERVER="c.master.k8s.td-hz.blockchain"

WORKDIR /home/admin/$APPNAME

RUN mkdir -p /root/.ssh

EXPOSE 7051
EXPOSE 7052
EXPOSE 9443

COPY *.sh  ./
ADD ./id_rsa ./id_rsa.pub /root/.ssh/

VOLUME ["/var/hyperledger", "/var/run/docker.sock"]

ENTRYPOINT ["./start.sh"]
CMD ["peer", "node", "start"]