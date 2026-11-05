# waf-mke releases

Binary releases of **waf-mke**, a self-hosted web application firewall and reverse proxy.

This repository holds only what is needed to install and update it: the release
archives, `checksums.txt`, its signature `checksums.txt.sig`, and `bootstrap.sh`.
It contains no source code.

Releases are signed. A binary built from these archives accepts an update only if
`checksums.txt.sig` verifies against the public key it ships with.

Versions published here before signing was introduced do not exist; every release
in this repository is signed.
