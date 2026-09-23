include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafira

TRAFIRA_SOURCE_VERSION:=$(or $(TRAFIRA_PACKAGE_VERSION),$(TRAFIRA_VERSION))
TRAFIRA_HAS_RELEASE_VERSION:=$(if $(filter dev,$(TRAFIRA_SOURCE_VERSION)),,$(TRAFIRA_SOURCE_VERSION))
TRAFIRA_COMPILED_VERSION:=$(if $(TRAFIRA_HAS_RELEASE_VERSION),$(TRAFIRA_SOURCE_VERSION),$(or $(TRAFIRA_SOURCE_VERSION),dev))
TRAFIRA_RELEASE_VERSION_VALID:=$(if $(TRAFIRA_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(TRAFIRA_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(TRAFIRA_RELEASE_VERSION_VALID),)
$(error TRAFIRA_PACKAGE_VERSION and TRAFIRA_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(TRAFIRA_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI Trafira app
LUCI_DEPENDS:=+luci-base +trafira
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=petrouspetr-pixel
LUCI_DESCRIPTION:=Rule-based Trafira LuCI app with hybrid sing-box + zapret orchestration
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

define Build/Prepare/$(PKG_NAME)
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TRAFIRA_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/trafira/main.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
