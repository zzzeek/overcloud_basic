FROM centos

ARG delorean_url
ARG delorean_deps_url


RUN \
	yum install -y tcpdump iproute

RUN \
	cd /etc/yum.repos.d/ && \
	curl -O ${delorean_url} && \
    curl -O ${delorean_deps_url}

# start small :)

ENTRYPOINT ["bash"]
