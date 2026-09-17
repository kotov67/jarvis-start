FROM ubuntu:24.04
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus dbus-user-session sudo curl ca-certificates iproute2 procps less && apt-get clean && \
    rm -f /lib/systemd/system/multi-user.target.wants/getty* /lib/systemd/system/sysinit.target.wants/systemd-firstboot.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
