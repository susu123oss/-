ifndef THEOS
  CODEX_COMPAT := $(shell echo "$$PATH" | grep -o '[^:]*TheosCoreCompat' | head -n 1)
  ifneq ($(CODEX_COMPAT),)
    CODEX_APP := $(patsubst %/Helpers/TheosCoreCompat,%,$(CODEX_COMPAT))
    export THEOS := $(CODEX_APP)/TheosRuntime/theos
    export PATH := $(CODEX_APP)/TheosRuntime/usr/bin:$(CODEX_APP)/TheosRuntime/usr/lib/llvm-16/bin:$(CODEX_APP)/TheosRuntime/theos/bin:$(CODEX_APP)/TheosRuntime/bin:$(PATH)
    export PERL5LIB := $(CODEX_APP)/TheosRuntime/usr/share/perl5/5.32:$(CODEX_APP)/TheosRuntime/usr/lib/perl5/5.32
  endif
endif

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

# OLLVM 参数由 CodexApp 设置层通过 CA_OLLVM_ARM64_CFLAGS /
# CA_OLLVM_ARM64E_CFLAGS 注入；这里不覆盖用户选择。

export PERL5LIB := $(THEOS)/../usr/share/perl5/5.32:$(THEOS)/../usr/lib/perl5/5.32:$(PERL5LIB)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PVZSun

PVZSun_FILES = Tweak.x
PVZSun_CFLAGS = -fobjc-arc -fno-modules -Wno-unused-variable -Wno-unused-value -Wno-unused-function -Wno-deprecated-declarations
PVZSun_LDFLAGS = -Wl,-no_fixup_chains
PVZSun_FRAMEWORKS = UIKit QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-all::
	@mkdir -p dist
	@([ -f .theos/obj/PVZSun.dylib ] && cp -f .theos/obj/PVZSun.dylib dist/PVZSun.dylib || cp -f .theos/obj/debug/PVZSun.dylib dist/PVZSun.dylib)
	@cp -f PVZSun.plist dist/PVZSun.plist
	@echo "==> 已同步最新双架构 dylib 至 dist/ (arm64 + arm64e)"

after-package::
	@mkdir -p dist
	@([ -f .theos/obj/PVZSun.dylib ] && cp -f .theos/obj/PVZSun.dylib dist/PVZSun.dylib || cp -f .theos/obj/debug/PVZSun.dylib dist/PVZSun.dylib)
	@cp -f PVZSun.plist dist/PVZSun.plist
	@python3 -c "import glob, os; files = sorted(glob.glob('packages/*.deb'), key=os.path.getmtime); [os.remove(f) for f in files[:-1]] if len(files) > 1 else None"
	@echo "==> 产物维护完毕：dist/ 仅保留最新双架构 dylib，packages/ 仅保留最新 deb"
