#!/bin/bash

# -e          :: exit on error (do this in functions as well)
# -E          :: inherit the ERR trap to functions, command substitutions and sub-shells
# -u          :: show (and exit) when using unset variables
# -o pipefail :: exit on error in pipes
set -eE -u -o pipefail

VERSION_CODENAME='bookworm'

# shellcheck source=../helpers/log.sh
source /usr/local/bin/helpers/log.sh

_log_level_is 'trace' && QUIET='-y' || QUIET='-qq'

function _pre_installation_steps() {
  _log 'info' 'Starting package installation'
  _log 'debug' 'Running pre-installation steps'

  _log 'trace' 'Updating package signatures'
  apt-get "${QUIET}" update

  _log 'trace' 'Upgrading packages'
  apt-get "${QUIET}" upgrade

  _log 'trace' 'Installing packages that are needed early'
  # add packages usually required by apt to
  # - not log unnecessary warnings
  # - be able to add PPAs early (e.g., Rspamd)
  local EARLY_PACKAGES=(
    apt-utils # avoid useless warnings
    apt-transport-https ca-certificates curl gnupg # required for adding PPAs
    systemd-standalone-sysusers # avoid problems with SA / Amavis (https://github.com/docker-mailserver/docker-mailserver/pull/3403#pullrequestreview-1596689953)
  )
  apt-get "${QUIET}" install --no-install-recommends "${EARLY_PACKAGES[@]}" 2>/dev/null
}

function _install_utils() {
  _log 'debug' 'Installing utils sourced from Github'
  _log 'trace' 'Installing jaq'
  local JAQ_TAG='v1.3.0'
  curl -sSfL "https://github.com/01mf02/jaq/releases/download/${JAQ_TAG}/jaq-${JAQ_TAG}-$(uname -m)-unknown-linux-gnu" -o /usr/bin/jaq
  chmod +x /usr/bin/jaq

  _log 'trace' 'Installing swaks'
  local SWAKS_VERSION='20240103.0'
  local SWAKS_RELEASE="swaks-${SWAKS_VERSION}"
  curl -sSfL "https://github.com/jetmore/swaks/releases/download/v${SWAKS_VERSION}/${SWAKS_RELEASE}.tar.gz" | tar -xz
  mv "${SWAKS_RELEASE}/swaks" /usr/local/bin
  rm -r "${SWAKS_RELEASE}"
}

function _install_postfix() {
  _log 'debug' 'Installing Postfix'

  _log 'warn' 'Applying workaround for Postfix bug (see https://github.com/docker-mailserver/docker-mailserver/issues/2023#issuecomment-855326403)'

  # Debians postfix package has a post-install script that expects a valid FQDN hostname to work:
  mv /bin/hostname /bin/hostname.bak
  echo "echo 'docker-mailserver.invalid'" >/bin/hostname
  chmod +x /bin/hostname
  apt-get "${QUIET}" install --no-install-recommends postfix
  mv /bin/hostname.bak /bin/hostname

  # Irrelevant - Debian's default `chroot` jail config for Postfix needed a separate syslog socket:
  rm /etc/rsyslog.d/postfix.conf
}

function _install_packages() {
  _log 'debug' 'Installing all packages now'

  local ANTI_VIRUS_SPAM_PACKAGES=(
    clamav clamav-daemon
    # spamassassin is used only with amavisd-new, while pyzor + razor are used by spamassasin
    amavisd-new spamassassin pyzor razor
    # the following packages are all for Fail2Ban
    # https://github.com/docker-mailserver/docker-mailserver/pull/3403#discussion_r1306581431
    fail2ban python3-pyinotify python3-dnspython
  )

  # predominantly for Amavis support
  local CODECS_PACKAGES=(
    altermime arj bzip2
    cabextract cpio file
    gzip lhasa liblz4-tool
    lrzip lzop nomarch
    p7zip-full pax rpm2cpio
    unrar-free unzip xz-utils
  )

  local MISCELLANEOUS_PACKAGES=(
    binutils bsd-mailx
    dbconfig-no-thanks dumb-init iproute2
    libdate-manip-perl libldap-common libmail-spf-perl libnet-dns-perl
    locales logwatch netcat-openbsd
    nftables # primarily for Fail2Ban
    rsyslog supervisor
    uuid # used for file-locking
    whois
  )

  local POSTFIX_PACKAGES=(
    pflogsumm postgrey postfix-ldap postfix-mta-sts-resolver
    postfix-pcre postfix-policyd-spf-python postsrsd
  )

  local MAIL_PROGRAMS_PACKAGES=(
    opendkim opendkim-tools
    opendmarc libsasl2-modules sasl2-bin
  )

  # These packages support community contributed features.
  # If they cause too much maintenance burden in future, they are liable for removal.
  local COMMUNITY_PACKAGES=(
    fetchmail getmail6
  )

  # `bind9-dnsutils` provides the `dig` command
  # `iputils-ping` provides the `ping` command
  DEBUG_PACKAGES=(
    bind9-dnsutils iputils-ping less nano
  )

  apt-get "${QUIET}" --no-install-recommends install \
    "${ANTI_VIRUS_SPAM_PACKAGES[@]}" \
    "${CODECS_PACKAGES[@]}" \
    "${MISCELLANEOUS_PACKAGES[@]}" \
    "${POSTFIX_PACKAGES[@]}" \
    "${MAIL_PROGRAMS_PACKAGES[@]}" \
    "${DEBUG_PACKAGES[@]}" \
    "${COMMUNITY_PACKAGES[@]}"
}

function _install_dovecot() {
  local DOVECOT_PACKAGES=(
    dovecot-core dovecot-imapd
    dovecot-ldap dovecot-lmtpd dovecot-managesieved
    dovecot-pop3d dovecot-sieve
  )

  # Dovecot packages for community supported features.
  DOVECOT_PACKAGES+=(dovecot-auth-lua)

  # Dovecot's deb community repository only provides x86_64 packages, so do not include it
  # when building for another architecture.
  if [[ ${DOVECOT_COMMUNITY_REPO} -eq 1 ]] && [[ "$(uname --machine)" == "x86_64" ]]; then
    _log 'trace' 'Using Dovecot community repository'
    curl -sSfL https://repo.dovecot.org/DOVECOT-REPO-GPG | gpg --import
    gpg --export ED409DA1 > /etc/apt/trusted.gpg.d/dovecot.gpg
    echo "deb https://repo.dovecot.org/ce-2.3-latest/debian/${VERSION_CODENAME} ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/dovecot.list

    _log 'trace' 'Updating Dovecot package signatures'
    apt-get "${QUIET}" update

    # Additional community package needed for Lua support if the Dovecot community repository is used.
    DOVECOT_PACKAGES+=(dovecot-lua)
  fi

  _log 'debug' 'Installing Dovecot'
  apt-get "${QUIET}" --no-install-recommends install "${DOVECOT_PACKAGES[@]}"

  # dependency for fts_xapian
  apt-get "${QUIET}" --no-install-recommends install libxapian30
}

function _install_rspamd() {
  _log 'debug' 'Installing Rspamd'
  _log 'trace' 'Adding Rspamd PPA'
  curl -sSfL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor >/etc/apt/trusted.gpg.d/rspamd.gpg
  echo \
    "deb [signed-by=/etc/apt/trusted.gpg.d/rspamd.gpg] http://rspamd.com/apt-stable/ ${VERSION_CODENAME} main" \
    >/etc/apt/sources.list.d/rspamd.list

  _log 'trace' 'Updating package index after adding PPAs'
  apt-get "${QUIET}" update

  _log 'trace' 'Installing actual package'
  apt-get "${QUIET}" install rspamd redis-server
}

function _post_installation_steps() {
  _log 'debug' 'Running post-installation steps (cleanup)'
  _log 'debug' 'Deleting sensitive files (secrets)'
  rm /etc/postsrsd.secret

  _log 'debug' 'Deleting default logwatch cronjob'
  rm /etc/cron.daily/00logwatch

  _log 'trace' 'Removing leftovers from APT'
  apt-get "${QUIET}" clean
  rm -rf /var/lib/apt/lists/*

  _log 'debug' 'Patching Fail2ban to enable network bans'
  # Enable network bans
  # https://github.com/docker-mailserver/docker-mailserver/issues/2669
  sedfile -i -r 's/^_nft_add_set = .+/_nft_add_set = <nftables> add set <table_family> <table> <addr_set> \\{ type <addr_type>\\; flags interval\\; \\}/' /etc/fail2ban/action.d/nftables.conf
}

_pre_installation_steps
_install_utils
_install_postfix
_install_packages
_install_dovecot
_install_rspamd
_post_installation_steps
