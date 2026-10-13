# Jenkins controller with the Docker CLI, so pipelines can build and run containers
# through the host's Docker daemon (socket mounted by docker-compose.yml).
FROM docker:29-cli AS dockercli

FROM jenkins/jenkins:2.580.1-lts-jdk21
USER root
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
# The pipeline checks out the repository mounted at /repo, which is owned by another user.
RUN git config --system --add safe.directory '*'
USER jenkins
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
