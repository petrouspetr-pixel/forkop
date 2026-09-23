include $(TOPDIR)/rules.mk

PKG_NAME:=trafira

TRAFIRA_SOURCE_VERSION:=$(or $(TRAFIRA_PACKAGE_VERSION),$(TRAFIRA_VERSION))
TRAFIRA_HAS_RELEASE_VERSION:=$(if $(filter dev,$(TRAFIRA_SOURCE_VERSION)),,$(TRAFIRA_SOURCE_VERSION))
TRAFIRA_COMPILED_VERSION:=$(if $(TRAFIRA_HAS_RELEASE_VERSION),$(TRAFIRA_SOURCE_VERSION),$(or $(TRAFIRA_SOURCE_VERSION),dev))
TRAFIRA_RELEASE_VERSION_VALID:=$(if $(TRAFIRA_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(TRAFIRA_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(TRAFIRA_RELEASE_VERSION_VALID),)
$(error TRAFIRA_PACKAGE_VERSION and TRAFIRA_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(TRAFIRA_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=petrouspetr-pixel
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/trafira
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +coreutils-base64 +bind-dig +nftables +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2 forkop podkop-plus podkop
	TITLE:=Trafira backend service
	URL:=https://github.com/petrouspetr-pixel/trafira
	PKGARCH:=all
	USERID:=trafirabyedpi:trafirabyedpi
endef

define Package/trafira/description
	Rule-based Trafira backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/trafira/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/trafira package_prerm " + (ARGV[0] || "") + " >/dev/null 2>&1");

exit(0);
endef

define Package/trafira/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
TRAFIRA_LIB=/usr/lib/trafira ucode -L /usr/lib/trafira /usr/lib/trafira/config/migration.uc migrate || exit $$?
/usr/bin/trafira package_postinst
endef

define Package/trafira/conffiles
/etc/config/trafira
endef

define Package/trafira/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/trafira $(1)/etc/init.d/trafira

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/trafira $(1)/etc/config/trafira

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/trafira $(1)/usr/bin/trafira

	$(INSTALL_DIR) $(1)/usr/lib/trafira
	$(CP) ./files/usr/lib/. $(1)/usr/lib/trafira/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TRAFIRA_COMPILED_VERSION)/g' $(1)/usr/lib/trafira/core/constants.uc
endef

$(eval $(call BuildPackage,trafira))
