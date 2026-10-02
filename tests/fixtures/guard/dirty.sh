#!/usr/bin/env bash
wget http://example.test/x
apt-get -y install fail2ban
usermod -s /bin/false bob
eval "$cmd"
curl "$u"   # lab-guard: allow install -- wrong rule named
