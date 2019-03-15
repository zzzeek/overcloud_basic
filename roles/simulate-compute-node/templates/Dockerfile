FROM centos

RUN \
	yum install tcpdump iproute

RUN \
	cd /etc/yum.repos.d/ && \
	curl -O {{ delorean_url }} && \
    curl -O {{ delorean_deps_url }}

# start small :)

ENTRYPOINT ["bash"]