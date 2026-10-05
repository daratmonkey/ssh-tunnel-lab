FROM alpine:3

RUN apk add --no-cache openssh-server python3 curl bind-tools \
 && ssh-keygen -A \
 && rm -f /etc/ssh/ssh_host_*.pub \
 && adduser -D -h /home/lab -s /bin/sh lab \
 # A password field of "!" makes sshd treat the account as locked and refuse
 # key auth ("User lab not allowed because account is locked"). "*" means no
 # possible password, which is what we want: key-only login.
 && printf 'lab:*\n' | chpasswd \
 && mkdir -p /home/lab/.ssh /run/sshd /lab \
 && chown -R lab:lab /home/lab /lab \
 && chmod 700 /home/lab/.ssh

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY demo_server.py /usr/local/bin/demo_server.py
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]